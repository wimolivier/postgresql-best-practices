-- ============================================================================
-- MEDALLION ARCHITECTURE TESTS - BRONZE LAYER
-- ============================================================================
-- Tests for raw data landing zone patterns.
-- Reference: references/data-warehousing-medallion.md
-- ============================================================================

-- ============================================================================
-- SETUP: Create bronze schema
-- ============================================================================

DO $$
BEGIN
    CREATE SCHEMA IF NOT EXISTS bronze;
    COMMENT ON SCHEMA bronze IS 'Raw data landing zone - exact copies from sources';
END;
$$;

-- ============================================================================
-- TEST FUNCTIONS
-- ============================================================================

-- Test: Bronze schema exists
CREATE OR REPLACE FUNCTION test.test_medallion_010_bronze_schema()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM test.set_context('test_medallion_010_bronze_schema');

    PERFORM test.has_schema('bronze', 'bronze schema should exist');
END;
$$;

-- Test: Bronze table with ingestion metadata
CREATE OR REPLACE FUNCTION test.test_medallion_011_bronze_metadata_columns()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'raw_test_011_' || to_char(clock_timestamp(), 'HH24MISSUS');
BEGIN
    PERFORM test.set_context('test_medallion_011_bronze_metadata_columns');

    -- Create bronze table with standard metadata
    EXECUTE format('CREATE TABLE bronze.%I (
        _bronze_id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        _ingested_at        timestamptz NOT NULL DEFAULT now(),
        _source_system      text NOT NULL,
        _source_file        text,
        _batch_id           uuid,

        -- Source data
        id                  text,
        name                text,
        value               text
    )', l_test_table);

    -- Verify metadata columns exist
    PERFORM test.has_column('bronze', l_test_table, '_bronze_id', '_bronze_id column exists');
    PERFORM test.has_column('bronze', l_test_table, '_ingested_at', '_ingested_at column exists');
    PERFORM test.has_column('bronze', l_test_table, '_source_system', '_source_system column exists');
    PERFORM test.has_column('bronze', l_test_table, '_source_file', '_source_file column exists');
    PERFORM test.has_column('bronze', l_test_table, '_batch_id', '_batch_id column exists');

    -- Cleanup
    EXECUTE format('DROP TABLE bronze.%I', l_test_table);
END;
$$;

-- Test: Bronze append-only pattern
CREATE OR REPLACE FUNCTION test.test_medallion_012_bronze_append_only()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'raw_test_012_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_count integer;
    l_id1 bigint;
    l_id2 bigint;
BEGIN
    PERFORM test.set_context('test_medallion_012_bronze_append_only');

    -- Create bronze table
    EXECUTE format('CREATE TABLE bronze.%I (
        _bronze_id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        _ingested_at        timestamptz NOT NULL DEFAULT now(),
        _source_system      text NOT NULL,
        id                  text,
        name                text
    )', l_test_table);

    -- Insert same source ID multiple times (append-only pattern)
    EXECUTE format('INSERT INTO bronze.%I (_source_system, id, name) VALUES (''source1'', ''ID-001'', ''First Version'') RETURNING _bronze_id', l_test_table) INTO l_id1;
    EXECUTE format('INSERT INTO bronze.%I (_source_system, id, name) VALUES (''source1'', ''ID-001'', ''Second Version'') RETURNING _bronze_id', l_test_table) INTO l_id2;

    -- Both records should exist (no deduplication in bronze)
    EXECUTE format('SELECT COUNT(*) FROM bronze.%I WHERE id = ''ID-001''', l_test_table) INTO l_count;

    PERFORM test.is(l_count, 2, 'Bronze should allow duplicate source IDs (append-only)');
    PERFORM test.isnt(l_id1, l_id2, '_bronze_id should be unique for each append');

    -- Cleanup
    EXECUTE format('DROP TABLE bronze.%I', l_test_table);
END;
$$;

-- Test: Bronze ingestion with batch_id tracking
CREATE OR REPLACE FUNCTION test.test_medallion_013_bronze_batch_tracking()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'raw_test_013_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_batch_id uuid := gen_random_uuid();
    l_count integer;
BEGIN
    PERFORM test.set_context('test_medallion_013_bronze_batch_tracking');

    -- Create bronze table
    EXECUTE format('CREATE TABLE bronze.%I (
        _bronze_id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        _ingested_at        timestamptz NOT NULL DEFAULT now(),
        _source_system      text NOT NULL,
        _batch_id           uuid,
        id                  text,
        name                text
    )', l_test_table);

    -- Insert multiple rows with same batch_id
    EXECUTE format('INSERT INTO bronze.%I (_source_system, _batch_id, id, name) VALUES
        (''csv_import'', $1, ''1'', ''Row 1''),
        (''csv_import'', $1, ''2'', ''Row 2''),
        (''csv_import'', $1, ''3'', ''Row 3'')',
        l_test_table) USING l_batch_id;

    -- Verify all rows have same batch_id
    EXECUTE format('SELECT COUNT(*) FROM bronze.%I WHERE _batch_id = $1', l_test_table) INTO l_count USING l_batch_id;

    PERFORM test.is(l_count, 3, 'All rows should have same batch_id');

    -- Cleanup
    EXECUTE format('DROP TABLE bronze.%I', l_test_table);
END;
$$;

-- Test: Bronze stores raw text types (no parsing in bronze)
CREATE OR REPLACE FUNCTION test.test_medallion_014_bronze_text_types()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'raw_test_014_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_row_count integer;
BEGIN
    PERFORM test.set_context('test_medallion_014_bronze_text_types');

    -- Create bronze table with all text columns (raw, unparsed)
    EXECUTE format('CREATE TABLE bronze.%I (
        _bronze_id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        _ingested_at        timestamptz NOT NULL DEFAULT now(),
        _source_system      text NOT NULL,

        -- All source columns as text (no type conversion)
        id                  text,
        amount              text,  -- Should be numeric in silver
        created_date        text,  -- Should be timestamptz in silver
        is_active           text   -- Should be boolean in silver
    )', l_test_table);

    -- Verify column types are text
    PERFORM test.col_type_is('bronze', l_test_table, 'id', 'text', 'id should be text');
    PERFORM test.col_type_is('bronze', l_test_table, 'amount', 'text', 'amount should be text (raw)');
    PERFORM test.col_type_is('bronze', l_test_table, 'created_date', 'text', 'created_date should be text (raw)');
    PERFORM test.col_type_is('bronze', l_test_table, 'is_active', 'text', 'is_active should be text (raw)');

    -- Can store "bad" data that would fail type conversion
    EXECUTE format('INSERT INTO bronze.%I (_source_system, id, amount, created_date, is_active) VALUES
        (''source'', ''1'', ''invalid_number'', ''not-a-date'', ''maybe'')',
        l_test_table);

    EXECUTE format('SELECT COUNT(*) FROM bronze.%I', l_test_table) INTO l_row_count;
    PERFORM test.is(l_row_count, 1, 'Bronze should accept data that would fail type conversion');

    -- Cleanup
    EXECUTE format('DROP TABLE bronze.%I', l_test_table);
END;
$$;

-- Test: Bronze JSONB payload storage
CREATE OR REPLACE FUNCTION test.test_medallion_015_bronze_jsonb_payload()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'raw_test_015_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_payload jsonb;
BEGIN
    PERFORM test.set_context('test_medallion_015_bronze_jsonb_payload');

    -- Create bronze table with raw JSON storage
    EXECUTE format('CREATE TABLE bronze.%I (
        _bronze_id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        _ingested_at        timestamptz NOT NULL DEFAULT now(),
        _source_system      text NOT NULL,
        _raw_payload        jsonb,  -- Original JSON preserved

        -- Extracted fields
        id                  text,
        name                text
    )', l_test_table);

    -- Insert with raw payload
    EXECUTE format('INSERT INTO bronze.%I (_source_system, _raw_payload, id, name) VALUES
        (''api'', ''{"id": "123", "name": "Test", "extra_field": "value", "nested": {"a": 1}}'', ''123'', ''Test'')',
        l_test_table);

    -- Verify raw payload preserved
    EXECUTE format('SELECT _raw_payload FROM bronze.%I LIMIT 1', l_test_table) INTO l_payload;

    PERFORM test.ok(l_payload ? 'extra_field', 'Raw payload should preserve extra fields');
    PERFORM test.ok(l_payload ? 'nested', 'Raw payload should preserve nested structure');

    -- Cleanup
    EXECUTE format('DROP TABLE bronze.%I', l_test_table);
END;
$$;

-- Test: Bronze with partitioning by ingestion date
CREATE OR REPLACE FUNCTION test.test_medallion_016_bronze_partitioned()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'raw_test_016_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_partition_name text;
    l_today date := current_date;
    l_partition_count integer;
BEGIN
    PERFORM test.set_context('test_medallion_016_bronze_partitioned');

    -- Create partitioned bronze table
    EXECUTE format('CREATE TABLE bronze.%I (
        _bronze_id          bigint GENERATED ALWAYS AS IDENTITY,
        _ingested_at        timestamptz NOT NULL DEFAULT now(),
        _source_system      text NOT NULL,
        id                  text,
        name                text,
        PRIMARY KEY (_bronze_id, _ingested_at)
    ) PARTITION BY RANGE (_ingested_at)', l_test_table);

    -- Create partition for current month
    l_partition_name := l_test_table || '_' || to_char(l_today, 'YYYY_MM');
    EXECUTE format('CREATE TABLE bronze.%I PARTITION OF bronze.%I
        FOR VALUES FROM (%L) TO (%L)',
        l_partition_name, l_test_table,
        date_trunc('month', l_today),
        date_trunc('month', l_today) + interval '1 month');

    -- Insert data (should go to partition)
    EXECUTE format('INSERT INTO bronze.%I (_source_system, id, name) VALUES (''source'', ''1'', ''Test'')', l_test_table);

    -- Verify partition created
    SELECT COUNT(*) INTO l_partition_count
    FROM pg_tables
    WHERE schemaname = 'bronze'
      AND tablename = l_partition_name;

    PERFORM test.is(l_partition_count, 1, 'Monthly partition should exist');

    -- Cleanup
    EXECUTE format('DROP TABLE bronze.%I CASCADE', l_test_table);
END;
$$;

-- Test: Bronze index on ingestion timestamp
CREATE OR REPLACE FUNCTION test.test_medallion_017_bronze_time_index()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'raw_test_017_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_index_name text;
BEGIN
    PERFORM test.set_context('test_medallion_017_bronze_time_index');

    -- Create bronze table
    EXECUTE format('CREATE TABLE bronze.%I (
        _bronze_id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        _ingested_at        timestamptz NOT NULL DEFAULT now(),
        _source_system      text NOT NULL,
        id                  text
    )', l_test_table);

    -- Create index on ingestion time
    l_index_name := l_test_table || '_ingested_idx';
    EXECUTE format('CREATE INDEX %I ON bronze.%I(_ingested_at)', l_index_name, l_test_table);

    -- Verify index exists
    PERFORM test.has_index('bronze', l_test_table, l_index_name, 'Ingestion time index should exist');

    -- Cleanup
    EXECUTE format('DROP TABLE bronze.%I', l_test_table);
END;
$$;

-- Test: Bronze CDC pattern with operation tracking
CREATE OR REPLACE FUNCTION test.test_medallion_018_bronze_cdc()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'raw_test_018_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_count integer;
BEGIN
    PERFORM test.set_context('test_medallion_018_bronze_cdc');

    -- Create CDC-style bronze table
    EXECUTE format('CREATE TABLE bronze.%I (
        _bronze_id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        _ingested_at        timestamptz NOT NULL DEFAULT now(),
        _cdc_operation      text NOT NULL,  -- INSERT, UPDATE, DELETE
        _cdc_timestamp      timestamptz NOT NULL,
        _cdc_lsn            text,
        _batch_id           uuid,

        before_data         jsonb,
        after_data          jsonb
    )', l_test_table);

    -- Verify CDC columns
    PERFORM test.has_column('bronze', l_test_table, '_cdc_operation', '_cdc_operation exists');
    PERFORM test.has_column('bronze', l_test_table, '_cdc_timestamp', '_cdc_timestamp exists');
    PERFORM test.has_column('bronze', l_test_table, 'before_data', 'before_data exists');
    PERFORM test.has_column('bronze', l_test_table, 'after_data', 'after_data exists');

    -- Insert CDC events
    EXECUTE format('INSERT INTO bronze.%I (_cdc_operation, _cdc_timestamp, before_data, after_data) VALUES
        (''INSERT'', now() - interval ''3 minutes'', NULL, ''{"id": 1, "name": "New"}''),
        (''UPDATE'', now() - interval ''2 minutes'', ''{"id": 1, "name": "New"}'', ''{"id": 1, "name": "Updated"}''),
        (''DELETE'', now() - interval ''1 minute'', ''{"id": 1, "name": "Updated"}'', NULL)',
        l_test_table);

    EXECUTE format('SELECT COUNT(*) FROM bronze.%I', l_test_table) INTO l_count;
    PERFORM test.is(l_count, 3, 'Should store all CDC operations');

    -- Cleanup
    EXECUTE format('DROP TABLE bronze.%I', l_test_table);
END;
$$;

-- ============================================================================
-- RUN TESTS
-- ============================================================================

SELECT test.run_module('medallion_01');
CALL test.print_run_summary();
