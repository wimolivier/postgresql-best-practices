-- ============================================================================
-- BULK OPERATIONS TESTS - BATCH INSERT
-- ============================================================================
-- Tests for batch insert patterns and INSERT ... SELECT.
-- Reference: references/bulk-operations.md
-- ============================================================================

-- ============================================================================
-- TEST FUNCTIONS
-- ============================================================================

-- Test: Multi-row VALUES insert
CREATE OR REPLACE FUNCTION test.test_batch_140_multirow_values()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_batch_140_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_count integer;
BEGIN
    PERFORM test.set_context('test_batch_140_multirow_values');

    -- Create table
    EXECUTE format('CREATE TABLE data.%I (
        id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        name text NOT NULL,
        value integer NOT NULL
    )', l_test_table);

    -- Insert multiple rows in single statement
    EXECUTE format('INSERT INTO data.%I (name, value) VALUES
        (''Row 1'', 100),
        (''Row 2'', 200),
        (''Row 3'', 300),
        (''Row 4'', 400),
        (''Row 5'', 500)', l_test_table);

    -- Verify count
    EXECUTE format('SELECT COUNT(*) FROM data.%I', l_test_table) INTO l_count;
    PERFORM test.is(l_count, 5, 'Should insert 5 rows in single statement');

    -- Cleanup
    EXECUTE format('DROP TABLE data.%I', l_test_table);
END;
$$;

-- Test: INSERT ... SELECT from another table
CREATE OR REPLACE FUNCTION test.test_batch_141_insert_select()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_src_table text := 'test_batch_141_src_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_dst_table text := 'test_batch_141_dst_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_count integer;
BEGIN
    PERFORM test.set_context('test_batch_141_insert_select');

    -- Create source table
    EXECUTE format('CREATE TABLE data.%I (
        id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        code text NOT NULL,
        amount numeric(12,2) NOT NULL
    )', l_src_table);

    -- Create destination table
    EXECUTE format('CREATE TABLE data.%I (
        id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        code text NOT NULL,
        amount numeric(12,2) NOT NULL,
        imported_at timestamptz NOT NULL DEFAULT now()
    )', l_dst_table);

    -- Populate source
    EXECUTE format('INSERT INTO data.%I (code, amount) VALUES
        (''A'', 100.00),
        (''B'', 200.00),
        (''C'', 300.00)', l_src_table);

    -- Insert from select
    EXECUTE format('INSERT INTO data.%I (code, amount)
        SELECT code, amount FROM data.%I WHERE amount >= 200', l_dst_table, l_src_table);

    -- Verify
    EXECUTE format('SELECT COUNT(*) FROM data.%I', l_dst_table) INTO l_count;
    PERFORM test.is(l_count, 2, 'Should insert 2 rows from SELECT');

    -- Cleanup
    EXECUTE format('DROP TABLE data.%I', l_dst_table);
    EXECUTE format('DROP TABLE data.%I', l_src_table);
END;
$$;

-- Test: INSERT ... SELECT with transformation
CREATE OR REPLACE FUNCTION test.test_batch_142_select_transform()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_src_table text := 'test_batch_142_src_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_dst_table text := 'test_batch_142_dst_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_record RECORD;
BEGIN
    PERFORM test.set_context('test_batch_142_select_transform');

    -- Create source (raw data)
    EXECUTE format('CREATE TABLE data.%I (
        id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        raw_email text NOT NULL,
        raw_name text NOT NULL
    )', l_src_table);

    -- Create destination (cleansed data)
    EXECUTE format('CREATE TABLE data.%I (
        id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        email text NOT NULL,
        name text NOT NULL
    )', l_dst_table);

    -- Insert raw data
    EXECUTE format('INSERT INTO data.%I (raw_email, raw_name) VALUES
        (''  USER@EXAMPLE.COM  '', ''  John Doe  ''),
        (''Admin@Test.Org'', ''Jane Smith'')', l_src_table);

    -- Transform and insert
    EXECUTE format('INSERT INTO data.%I (email, name)
        SELECT lower(trim(raw_email)), initcap(trim(raw_name))
        FROM data.%I', l_dst_table, l_src_table);

    -- Verify transformation
    EXECUTE format('SELECT * FROM data.%I WHERE email = ''user@example.com''', l_dst_table) INTO l_record;
    PERFORM test.is(l_record.name, 'John Doe', 'Name should be title-cased');

    -- Cleanup
    EXECUTE format('DROP TABLE data.%I', l_dst_table);
    EXECUTE format('DROP TABLE data.%I', l_src_table);
END;
$$;

-- Test: INSERT with generate_series for test data
CREATE OR REPLACE FUNCTION test.test_batch_143_generate_series()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_batch_143_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_count integer;
BEGIN
    PERFORM test.set_context('test_batch_143_generate_series');

    -- Create table
    EXECUTE format('CREATE TABLE data.%I (
        id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        sequence_num integer NOT NULL,
        label text NOT NULL
    )', l_test_table);

    -- Insert using generate_series
    EXECUTE format('INSERT INTO data.%I (sequence_num, label)
        SELECT i, ''Item '' || i
        FROM generate_series(1, 100) i', l_test_table);

    -- Verify count
    EXECUTE format('SELECT COUNT(*) FROM data.%I', l_test_table) INTO l_count;
    PERFORM test.is(l_count, 100, 'Should insert 100 rows');

    -- Cleanup
    EXECUTE format('DROP TABLE data.%I', l_test_table);
END;
$$;

-- Test: RETURNING clause with batch insert
CREATE OR REPLACE FUNCTION test.test_batch_144_returning()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_batch_144_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_ids bigint[];
BEGIN
    PERFORM test.set_context('test_batch_144_returning');

    -- Create table
    EXECUTE format('CREATE TABLE data.%I (
        id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        name text NOT NULL
    )', l_test_table);

    -- Insert and capture all IDs
    EXECUTE format('INSERT INTO data.%I (name) VALUES
        (''First''),
        (''Second''),
        (''Third'')
        RETURNING id', l_test_table)
    INTO l_ids;

    -- Note: INTO captures first row only; use array_agg for all
    EXECUTE format('SELECT array_agg(id ORDER BY id) FROM data.%I', l_test_table) INTO l_ids;

    PERFORM test.is(array_length(l_ids, 1), 3, 'Should return 3 IDs');
    PERFORM test.ok(l_ids[1] < l_ids[2] AND l_ids[2] < l_ids[3], 'IDs should be sequential');

    -- Cleanup
    EXECUTE format('DROP TABLE data.%I', l_test_table);
END;
$$;

-- Test: INSERT with CTE (Common Table Expression)
CREATE OR REPLACE FUNCTION test.test_batch_145_cte_insert()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_batch_145_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_count integer;
BEGIN
    PERFORM test.set_context('test_batch_145_cte_insert');

    -- Create table
    EXECUTE format('CREATE TABLE data.%I (
        id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        category text NOT NULL,
        item_name text NOT NULL,
        price numeric(10,2) NOT NULL
    )', l_test_table);

    -- Insert using CTE for complex data generation
    EXECUTE format('WITH items AS (
        SELECT
            CASE WHEN i %% 3 = 0 THEN ''Electronics''
                 WHEN i %% 3 = 1 THEN ''Clothing''
                 ELSE ''Food'' END AS category,
            ''Item '' || i AS item_name,
            (i * 10.50)::numeric(10,2) AS price
        FROM generate_series(1, 9) i
    )
    INSERT INTO data.%I (category, item_name, price)
    SELECT category, item_name, price FROM items', l_test_table);

    -- Verify
    EXECUTE format('SELECT COUNT(*) FROM data.%I WHERE category = ''Electronics''', l_test_table) INTO l_count;
    PERFORM test.is(l_count, 3, 'Should have 3 Electronics items');

    -- Cleanup
    EXECUTE format('DROP TABLE data.%I', l_test_table);
END;
$$;

-- Test: INSERT with default values
CREATE OR REPLACE FUNCTION test.test_batch_146_default_values()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_batch_146_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_record RECORD;
BEGIN
    PERFORM test.set_context('test_batch_146_default_values');

    -- Create table with defaults
    EXECUTE format('CREATE TABLE data.%I (
        id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        name text NOT NULL,
        status text NOT NULL DEFAULT ''pending'',
        priority integer NOT NULL DEFAULT 0,
        created_at timestamptz NOT NULL DEFAULT now()
    )', l_test_table);

    -- Insert only name, let defaults fill the rest
    EXECUTE format('INSERT INTO data.%I (name) VALUES (''Test Item'')', l_test_table);

    -- Verify defaults applied
    EXECUTE format('SELECT * FROM data.%I WHERE name = ''Test Item''', l_test_table) INTO l_record;
    PERFORM test.is(l_record.status, 'pending', 'Status should default to pending');
    PERFORM test.is(l_record.priority, 0, 'Priority should default to 0');
    PERFORM test.is_not_null(l_record.created_at, 'created_at should be set');

    -- Cleanup
    EXECUTE format('DROP TABLE data.%I', l_test_table);
END;
$$;

-- Test: INSERT overriding system value for identity
CREATE OR REPLACE FUNCTION test.test_batch_147_overriding_identity()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_batch_147_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_id bigint;
BEGIN
    PERFORM test.set_context('test_batch_147_overriding_identity');

    -- Create table with GENERATED ALWAYS AS IDENTITY
    EXECUTE format('CREATE TABLE data.%I (
        id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        name text NOT NULL
    )', l_test_table);

    -- Can use OVERRIDING SYSTEM VALUE to specify ID
    EXECUTE format('INSERT INTO data.%I (id, name)
        OVERRIDING SYSTEM VALUE
        VALUES (999, ''Manual ID'')', l_test_table);

    -- Verify
    EXECUTE format('SELECT id FROM data.%I WHERE name = ''Manual ID''', l_test_table) INTO l_id;
    PERFORM test.is(l_id, 999::bigint, 'Should have specified ID');

    -- Cleanup
    EXECUTE format('DROP TABLE data.%I', l_test_table);
END;
$$;

-- Test: INSERT from UNNEST for array data
CREATE OR REPLACE FUNCTION test.test_batch_148_unnest()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_batch_148_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_codes text[] := ARRAY['A', 'B', 'C', 'D', 'E'];
    l_values integer[] := ARRAY[10, 20, 30, 40, 50];
    l_count integer;
BEGIN
    PERFORM test.set_context('test_batch_148_unnest');

    -- Create table
    EXECUTE format('CREATE TABLE data.%I (
        id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        code text NOT NULL,
        value integer NOT NULL
    )', l_test_table);

    -- Insert from parallel arrays using UNNEST
    EXECUTE format('INSERT INTO data.%I (code, value)
        SELECT * FROM unnest($1::text[], $2::integer[])', l_test_table)
        USING l_codes, l_values;

    -- Verify
    EXECUTE format('SELECT COUNT(*) FROM data.%I', l_test_table) INTO l_count;
    PERFORM test.is(l_count, 5, 'Should insert 5 rows from arrays');

    -- Cleanup
    EXECUTE format('DROP TABLE data.%I', l_test_table);
END;
$$;

-- Test: Batch insert with COPY-like performance
CREATE OR REPLACE FUNCTION test.test_batch_149_large_batch()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_batch_149_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_count integer;
    l_start_time timestamptz;
    l_duration interval;
BEGIN
    PERFORM test.set_context('test_batch_149_large_batch');

    -- Create table
    EXECUTE format('CREATE TABLE data.%I (
        id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        data text NOT NULL,
        created_at timestamptz NOT NULL DEFAULT now()
    )', l_test_table);

    -- Insert 1000 rows efficiently
    l_start_time := clock_timestamp();

    EXECUTE format('INSERT INTO data.%I (data)
        SELECT ''Data row '' || i
        FROM generate_series(1, 1000) i', l_test_table);

    l_duration := clock_timestamp() - l_start_time;

    -- Verify count
    EXECUTE format('SELECT COUNT(*) FROM data.%I', l_test_table) INTO l_count;
    PERFORM test.is(l_count, 1000, 'Should insert 1000 rows');

    -- Cleanup
    EXECUTE format('DROP TABLE data.%I', l_test_table);
END;
$$;

-- Test: INSERT ... SELECT DISTINCT
CREATE OR REPLACE FUNCTION test.test_batch_150_select_distinct()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_src_table text := 'test_batch_150_src_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_dst_table text := 'test_batch_150_dst_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_count integer;
BEGIN
    PERFORM test.set_context('test_batch_150_select_distinct');

    -- Create source with duplicates
    EXECUTE format('CREATE TABLE data.%I (
        id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        category text NOT NULL
    )', l_src_table);

    -- Create destination for unique categories
    EXECUTE format('CREATE TABLE data.%I (
        id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        category text NOT NULL UNIQUE
    )', l_dst_table);

    -- Insert with duplicates
    EXECUTE format('INSERT INTO data.%I (category) VALUES
        (''Tech''), (''Tech''), (''Science''),
        (''Art''), (''Science''), (''Tech'')', l_src_table);

    -- Insert distinct values
    EXECUTE format('INSERT INTO data.%I (category)
        SELECT DISTINCT category FROM data.%I', l_dst_table, l_src_table);

    -- Verify
    EXECUTE format('SELECT COUNT(*) FROM data.%I', l_dst_table) INTO l_count;
    PERFORM test.is(l_count, 3, 'Should insert 3 unique categories');

    -- Cleanup
    EXECUTE format('DROP TABLE data.%I', l_dst_table);
    EXECUTE format('DROP TABLE data.%I', l_src_table);
END;
$$;

-- ============================================================================
-- RUN TESTS
-- ============================================================================

SELECT test.run_module('batch_14');
CALL test.print_run_summary();
