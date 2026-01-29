-- ============================================================================
-- MEDALLION ARCHITECTURE TESTS - SILVER LAYER
-- ============================================================================
-- Tests for cleansed data patterns including SCD Type 2.
-- Reference: references/data-warehousing-medallion.md
-- ============================================================================

-- ============================================================================
-- SETUP: Create silver schema
-- ============================================================================

DO $$
BEGIN
    CREATE SCHEMA IF NOT EXISTS silver;
    COMMENT ON SCHEMA silver IS 'Cleansed and validated data - single source of truth';
END;
$$;

-- ============================================================================
-- TEST FUNCTIONS
-- ============================================================================

-- Test: Silver schema exists
CREATE OR REPLACE FUNCTION test.test_medallion_020_silver_schema()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM test.set_context('test_medallion_020_silver_schema');

    PERFORM test.has_schema('silver', 'silver schema should exist');
END;
$$;

-- Test: Silver table with SCD Type 2 columns
CREATE OR REPLACE FUNCTION test.test_medallion_021_silver_scd2_structure()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_021_' || to_char(clock_timestamp(), 'HH24MISSUS');
BEGIN
    PERFORM test.set_context('test_medallion_021_silver_scd2_structure');

    -- Create silver table with SCD2 pattern
    EXECUTE format('CREATE TABLE silver.%I (
        -- Surrogate key
        customer_sk         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,

        -- Natural/business key
        customer_id         uuid NOT NULL,

        -- Cleansed attributes
        email               text NOT NULL,
        name                text NOT NULL,
        status              text NOT NULL,

        -- SCD Type 2 tracking
        valid_from          timestamptz NOT NULL DEFAULT now(),
        valid_to            timestamptz,
        is_current          boolean NOT NULL DEFAULT true,

        -- Lineage
        _source_bronze_id   bigint,
        _batch_id           uuid NOT NULL,
        _loaded_at          timestamptz NOT NULL DEFAULT now()
    )', l_test_table);

    -- Verify SCD2 columns
    PERFORM test.has_column('silver', l_test_table, 'valid_from', 'valid_from exists');
    PERFORM test.has_column('silver', l_test_table, 'valid_to', 'valid_to exists');
    PERFORM test.has_column('silver', l_test_table, 'is_current', 'is_current exists');
    PERFORM test.has_column('silver', l_test_table, '_source_bronze_id', '_source_bronze_id exists');
    PERFORM test.has_column('silver', l_test_table, '_batch_id', '_batch_id exists');

    -- Cleanup
    EXECUTE format('DROP TABLE silver.%I', l_test_table);
END;
$$;

-- Test: Silver unique index on business key for current records
CREATE OR REPLACE FUNCTION test.test_medallion_022_silver_bk_index()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_022_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_index_name text;
BEGIN
    PERFORM test.set_context('test_medallion_022_silver_bk_index');

    -- Create silver table
    EXECUTE format('CREATE TABLE silver.%I (
        customer_sk         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        customer_id         uuid NOT NULL,
        name                text NOT NULL,
        valid_from          timestamptz NOT NULL DEFAULT now(),
        valid_to            timestamptz,
        is_current          boolean NOT NULL DEFAULT true,
        _batch_id           uuid NOT NULL
    )', l_test_table);

    -- Create unique index on business key for current records
    l_index_name := l_test_table || '_bk_idx';
    EXECUTE format('CREATE UNIQUE INDEX %I ON silver.%I(customer_id) WHERE is_current = true', l_index_name, l_test_table);

    -- Verify index exists
    PERFORM test.has_index('silver', l_test_table, l_index_name, 'Business key unique index should exist');

    -- Cleanup
    EXECUTE format('DROP TABLE silver.%I', l_test_table);
END;
$$;

-- Test: Silver SCD2 insert new record
CREATE OR REPLACE FUNCTION test.test_medallion_023_silver_scd2_insert()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_023_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_customer_id uuid := gen_random_uuid();
    l_batch_id uuid := gen_random_uuid();
    l_record RECORD;
BEGIN
    PERFORM test.set_context('test_medallion_023_silver_scd2_insert');

    -- Create silver table
    EXECUTE format('CREATE TABLE silver.%I (
        customer_sk         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        customer_id         uuid NOT NULL,
        name                text NOT NULL,
        valid_from          timestamptz NOT NULL DEFAULT now(),
        valid_to            timestamptz,
        is_current          boolean NOT NULL DEFAULT true,
        _batch_id           uuid NOT NULL
    )', l_test_table);

    EXECUTE format('CREATE UNIQUE INDEX ON silver.%I(customer_id) WHERE is_current = true', l_test_table);

    -- Insert new record
    EXECUTE format('INSERT INTO silver.%I (customer_id, name, _batch_id) VALUES ($1, ''John Doe'', $2)', l_test_table)
        USING l_customer_id, l_batch_id;

    -- Verify record
    EXECUTE format('SELECT * FROM silver.%I WHERE customer_id = $1', l_test_table) INTO l_record USING l_customer_id;

    PERFORM test.is(l_record.name, 'John Doe', 'Name should match');
    PERFORM test.ok(l_record.is_current, 'is_current should be true');
    PERFORM test.is_null(l_record.valid_to, 'valid_to should be NULL for current record');
    PERFORM test.is_not_null(l_record.valid_from, 'valid_from should be set');

    -- Cleanup
    EXECUTE format('DROP TABLE silver.%I', l_test_table);
END;
$$;

-- Test: Silver SCD2 update creates new version
CREATE OR REPLACE FUNCTION test.test_medallion_024_silver_scd2_update()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_024_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_customer_id uuid := gen_random_uuid();
    l_batch_id uuid := gen_random_uuid();
    l_version_count integer;
    l_current_name text;
    l_old_is_current boolean;
BEGIN
    PERFORM test.set_context('test_medallion_024_silver_scd2_update');

    -- Create silver table
    EXECUTE format('CREATE TABLE silver.%I (
        customer_sk         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        customer_id         uuid NOT NULL,
        name                text NOT NULL,
        valid_from          timestamptz NOT NULL DEFAULT now(),
        valid_to            timestamptz,
        is_current          boolean NOT NULL DEFAULT true,
        _batch_id           uuid NOT NULL
    )', l_test_table);

    -- Insert initial version
    EXECUTE format('INSERT INTO silver.%I (customer_id, name, _batch_id) VALUES ($1, ''Original Name'', $2)', l_test_table)
        USING l_customer_id, l_batch_id;

    -- Simulate SCD2 update: close old record, insert new
    -- 1. Close existing record
    EXECUTE format('UPDATE silver.%I SET valid_to = now(), is_current = false WHERE customer_id = $1 AND is_current = true', l_test_table)
        USING l_customer_id;

    -- 2. Insert new version
    EXECUTE format('INSERT INTO silver.%I (customer_id, name, _batch_id) VALUES ($1, ''Updated Name'', $2)', l_test_table)
        USING l_customer_id, gen_random_uuid();

    -- Verify two versions exist
    EXECUTE format('SELECT COUNT(*) FROM silver.%I WHERE customer_id = $1', l_test_table) INTO l_version_count USING l_customer_id;
    PERFORM test.is(l_version_count, 2, 'Should have 2 versions');

    -- Verify current version
    EXECUTE format('SELECT name FROM silver.%I WHERE customer_id = $1 AND is_current = true', l_test_table) INTO l_current_name USING l_customer_id;
    PERFORM test.is(l_current_name, 'Updated Name', 'Current version should have updated name');

    -- Verify old version closed
    EXECUTE format('SELECT is_current FROM silver.%I WHERE customer_id = $1 AND name = ''Original Name''', l_test_table) INTO l_old_is_current USING l_customer_id;
    PERFORM test.ok(NOT l_old_is_current, 'Old version should not be current');

    -- Cleanup
    EXECUTE format('DROP TABLE silver.%I', l_test_table);
END;
$$;

-- Test: Silver type conversion from bronze
CREATE OR REPLACE FUNCTION test.test_medallion_025_silver_type_conversion()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_bronze_table text := 'raw_test_025_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_silver_table text := 'test_025_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_batch_id uuid := gen_random_uuid();
    l_converted_amount numeric;
    l_converted_active boolean;
BEGIN
    PERFORM test.set_context('test_medallion_025_silver_type_conversion');

    -- Create bronze table (text types)
    EXECUTE format('CREATE TABLE bronze.%I (
        _bronze_id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        _ingested_at        timestamptz NOT NULL DEFAULT now(),
        _source_system      text NOT NULL,
        id                  text,
        amount              text,
        is_active           text
    )', l_bronze_table);

    -- Create silver table (proper types)
    EXECUTE format('CREATE TABLE silver.%I (
        item_sk             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        item_id             uuid NOT NULL,
        amount              numeric(10,2) NOT NULL,
        is_active           boolean NOT NULL,
        _source_bronze_id   bigint,
        _batch_id           uuid NOT NULL
    )', l_silver_table);

    -- Insert raw data
    EXECUTE format('INSERT INTO bronze.%I (_source_system, id, amount, is_active) VALUES
        (''source'', ''%s'', ''123.45'', ''true'')',
        l_bronze_table, gen_random_uuid());

    -- Transform to silver (simulated)
    EXECUTE format('INSERT INTO silver.%I (item_id, amount, is_active, _source_bronze_id, _batch_id)
        SELECT
            id::uuid,
            amount::numeric(10,2),
            is_active::boolean,
            _bronze_id,
            $1
        FROM bronze.%I',
        l_silver_table, l_bronze_table) USING l_batch_id;

    -- Verify type conversion
    EXECUTE format('SELECT amount, is_active FROM silver.%I LIMIT 1', l_silver_table) INTO l_converted_amount, l_converted_active;

    PERFORM test.is(l_converted_amount, 123.45::numeric, 'Amount should be converted to numeric');
    PERFORM test.ok(l_converted_active, 'is_active should be converted to boolean');

    -- Cleanup
    EXECUTE format('DROP TABLE silver.%I', l_silver_table);
    EXECUTE format('DROP TABLE bronze.%I', l_bronze_table);
END;
$$;

-- Test: Silver data cleansing (trim, lowercase)
CREATE OR REPLACE FUNCTION test.test_medallion_026_silver_cleansing()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_026_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_cleansed_email text;
    l_cleansed_name text;
BEGIN
    PERFORM test.set_context('test_medallion_026_silver_cleansing');

    -- Create silver table
    EXECUTE format('CREATE TABLE silver.%I (
        customer_sk         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        customer_id         uuid NOT NULL,
        email               text NOT NULL,
        name                text NOT NULL,
        _batch_id           uuid NOT NULL
    )', l_test_table);

    -- Insert with cleansing applied
    EXECUTE format('INSERT INTO silver.%I (customer_id, email, name, _batch_id) VALUES
        ($1, lower(trim(''  JOHN@EXAMPLE.COM  '')), trim(''  John Doe  ''), $2)',
        l_test_table) USING gen_random_uuid(), gen_random_uuid();

    -- Verify cleansing
    EXECUTE format('SELECT email, name FROM silver.%I LIMIT 1', l_test_table) INTO l_cleansed_email, l_cleansed_name;

    PERFORM test.is(l_cleansed_email, 'john@example.com', 'Email should be lowercased and trimmed');
    PERFORM test.is(l_cleansed_name, 'John Doe', 'Name should be trimmed');

    -- Cleanup
    EXECUTE format('DROP TABLE silver.%I', l_test_table);
END;
$$;

-- Test: Silver generated column for derived fields
CREATE OR REPLACE FUNCTION test.test_medallion_027_silver_generated_column()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_027_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_email_domain text;
BEGIN
    PERFORM test.set_context('test_medallion_027_silver_generated_column');

    -- Create silver table with generated column
    EXECUTE format('CREATE TABLE silver.%I (
        customer_sk         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        customer_id         uuid NOT NULL,
        email               text NOT NULL,
        email_domain        text GENERATED ALWAYS AS (split_part(email, ''@'', 2)) STORED,
        _batch_id           uuid NOT NULL
    )', l_test_table);

    -- Insert data
    EXECUTE format('INSERT INTO silver.%I (customer_id, email, _batch_id) VALUES ($1, ''user@example.com'', $2)', l_test_table)
        USING gen_random_uuid(), gen_random_uuid();

    -- Verify generated column
    EXECUTE format('SELECT email_domain FROM silver.%I LIMIT 1', l_test_table) INTO l_email_domain;

    PERFORM test.is(l_email_domain, 'example.com', 'email_domain should be auto-generated');

    -- Cleanup
    EXECUTE format('DROP TABLE silver.%I', l_test_table);
END;
$$;

-- Test: Silver CHECK constraint for data quality
CREATE OR REPLACE FUNCTION test.test_medallion_028_silver_check_constraint()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_028_' || to_char(clock_timestamp(), 'HH24MISSUS');
BEGIN
    PERFORM test.set_context('test_medallion_028_silver_check_constraint');

    -- Create silver table with CHECK constraint
    EXECUTE format('CREATE TABLE silver.%I (
        customer_sk         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        customer_id         uuid NOT NULL,
        status              text NOT NULL CHECK (status IN (''active'', ''inactive'', ''suspended'')),
        _batch_id           uuid NOT NULL
    )', l_test_table);

    -- Valid status should succeed
    PERFORM test.lives_ok(
        format('INSERT INTO silver.%I (customer_id, status, _batch_id) VALUES (gen_random_uuid(), ''active'', gen_random_uuid())', l_test_table),
        'Valid status should be accepted'
    );

    -- Invalid status should fail
    PERFORM test.throws_ok(
        format('INSERT INTO silver.%I (customer_id, status, _batch_id) VALUES (gen_random_uuid(), ''invalid'', gen_random_uuid())', l_test_table),
        '23514',  -- check_violation
        'Invalid status should be rejected'
    );

    -- Cleanup
    EXECUTE format('DROP TABLE silver.%I', l_test_table);
END;
$$;

-- Test: Silver lineage tracking
CREATE OR REPLACE FUNCTION test.test_medallion_029_silver_lineage()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_bronze_table text := 'raw_test_029_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_silver_table text := 'test_029_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_batch_id uuid := gen_random_uuid();
    l_bronze_id bigint;
    l_silver_bronze_id bigint;
BEGIN
    PERFORM test.set_context('test_medallion_029_silver_lineage');

    -- Create bronze table
    EXECUTE format('CREATE TABLE bronze.%I (
        _bronze_id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        _ingested_at        timestamptz NOT NULL DEFAULT now(),
        _source_system      text NOT NULL,
        id                  text,
        name                text
    )', l_bronze_table);

    -- Create silver table
    EXECUTE format('CREATE TABLE silver.%I (
        customer_sk         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        customer_id         uuid NOT NULL,
        name                text NOT NULL,
        _source_bronze_id   bigint,
        _batch_id           uuid NOT NULL,
        _loaded_at          timestamptz NOT NULL DEFAULT now()
    )', l_silver_table);

    -- Insert into bronze
    EXECUTE format('INSERT INTO bronze.%I (_source_system, id, name) VALUES (''source'', $1, ''Test'') RETURNING _bronze_id',
        l_bronze_table) USING gen_random_uuid()::text INTO l_bronze_id;

    -- Transform to silver with lineage
    EXECUTE format('INSERT INTO silver.%I (customer_id, name, _source_bronze_id, _batch_id)
        SELECT id::uuid, name, _bronze_id, $1 FROM bronze.%I WHERE _bronze_id = $2',
        l_silver_table, l_bronze_table) USING l_batch_id, l_bronze_id;

    -- Verify lineage preserved
    EXECUTE format('SELECT _source_bronze_id FROM silver.%I LIMIT 1', l_silver_table) INTO l_silver_bronze_id;

    PERFORM test.is(l_silver_bronze_id, l_bronze_id, '_source_bronze_id should link to bronze');

    -- Cleanup
    EXECUTE format('DROP TABLE silver.%I', l_silver_table);
    EXECUTE format('DROP TABLE bronze.%I', l_bronze_table);
END;
$$;

-- ============================================================================
-- RUN TESTS
-- ============================================================================

SELECT test.run_module('medallion_02');
CALL test.print_run_summary();
