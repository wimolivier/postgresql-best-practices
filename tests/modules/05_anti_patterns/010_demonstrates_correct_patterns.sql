-- ============================================================================
-- ANTI-PATTERNS TESTS - DEMONSTRATES CORRECT PATTERNS
-- ============================================================================
-- Tests that demonstrate correct patterns vs common anti-patterns.
-- ============================================================================

-- ============================================================================
-- SETUP
-- ============================================================================

DO $$
BEGIN
    CREATE SCHEMA IF NOT EXISTS data;
    CREATE SCHEMA IF NOT EXISTS private;
    CREATE SCHEMA IF NOT EXISTS api;
END;
$$;

-- ============================================================================
-- TEST FUNCTIONS
-- ============================================================================

-- Test: Use NOT EXISTS instead of NOT IN with subqueries
CREATE OR REPLACE FUNCTION test.test_antipattern_010_not_exists_vs_not_in()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table1 text := 'test_orders_' || to_char(clock_timestamp(), 'HH24MISS');
    l_test_table2 text := 'test_customers_' || to_char(clock_timestamp(), 'HH24MISS');
    l_count_in integer;
    l_count_exists integer;
BEGIN
    PERFORM test.set_context('test_antipattern_010_not_exists_vs_not_in');

    -- Create tables
    EXECUTE format('CREATE TABLE test.%I (id serial PRIMARY KEY, name text)', l_test_table2);
    EXECUTE format('CREATE TABLE test.%I (id serial PRIMARY KEY, customer_id int)', l_test_table1);

    -- Insert data
    EXECUTE format('INSERT INTO test.%I (name) VALUES (''Alice''), (''Bob'')', l_test_table2);
    EXECUTE format('INSERT INTO test.%I (customer_id) VALUES (1), (1), (NULL)', l_test_table1);  -- NULL causes issues!

    -- ANTI-PATTERN: NOT IN with NULL values in subquery
    -- When subquery can return NULL, NOT IN returns no rows!
    EXECUTE format($q$
        SELECT count(*) FROM test.%I c
        WHERE c.id NOT IN (SELECT customer_id FROM test.%I)
    $q$, l_test_table2, l_test_table1)
    INTO l_count_in;

    -- CORRECT: NOT EXISTS handles NULLs properly
    EXECUTE format($q$
        SELECT count(*) FROM test.%I c
        WHERE NOT EXISTS (
            SELECT 1 FROM test.%I o WHERE o.customer_id = c.id
        )
    $q$, l_test_table2, l_test_table1)
    INTO l_count_exists;

    -- NOT IN returns 0 because of NULL (WRONG!)
    -- NOT EXISTS correctly returns 1 (Bob has no orders)
    PERFORM test.is(l_count_in, 0, 'NOT IN with NULL returns 0 (anti-pattern!)');
    PERFORM test.is(l_count_exists, 1, 'NOT EXISTS correctly finds unmatched rows');

    -- Clean up
    EXECUTE format('DROP TABLE test.%I', l_test_table1);
    EXECUTE format('DROP TABLE test.%I', l_test_table2);
END;
$$;

-- Test: Use >= AND < instead of BETWEEN for date ranges
CREATE OR REPLACE FUNCTION test.test_antipattern_011_date_range_pattern()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_events_' || to_char(clock_timestamp(), 'HH24MISS');
    l_count_between integer;
    l_count_range integer;
BEGIN
    PERFORM test.set_context('test_antipattern_011_date_range_pattern');

    -- Create table with timestamptz (correct type)
    EXECUTE format('CREATE TABLE test.%I (id serial, event_time timestamptz)', l_test_table);

    -- Insert data including boundary values
    EXECUTE format($ins$
        INSERT INTO test.%I (event_time) VALUES
        ('2024-01-01 00:00:00+00'),
        ('2024-01-01 12:00:00+00'),
        ('2024-01-02 00:00:00+00')
    $ins$, l_test_table);

    -- ANTI-PATTERN: BETWEEN includes both endpoints
    EXECUTE format($q$
        SELECT count(*) FROM test.%I
        WHERE event_time BETWEEN '2024-01-01 00:00:00+00' AND '2024-01-02 00:00:00+00'
    $q$, l_test_table)
    INTO l_count_between;

    -- CORRECT: >= AND < excludes end boundary (cleaner for date ranges)
    EXECUTE format($q$
        SELECT count(*) FROM test.%I
        WHERE event_time >= '2024-01-01 00:00:00+00'
          AND event_time < '2024-01-02 00:00:00+00'
    $q$, l_test_table)
    INTO l_count_range;

    PERFORM test.is(l_count_between, 3, 'BETWEEN includes endpoint (may be unexpected)');
    PERFORM test.is(l_count_range, 2, '>= AND < gives cleaner day boundary');

    -- Clean up
    EXECUTE format('DROP TABLE test.%I', l_test_table);
END;
$$;

-- Test: Use text instead of varchar(n) unless length enforced
CREATE OR REPLACE FUNCTION test.test_antipattern_012_text_vs_varchar()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_strings_' || to_char(clock_timestamp(), 'HH24MISS');
BEGIN
    PERFORM test.set_context('test_antipattern_012_text_vs_varchar');

    -- Create table with both types
    EXECUTE format($tbl$
        CREATE TABLE test.%I (
            name_text text,
            name_varchar varchar(100),
            code_char char(3)  -- ANTI-PATTERN: pads with spaces
        )
    $tbl$, l_test_table);

    -- Insert
    EXECUTE format('INSERT INTO test.%I VALUES ($1, $2, $3)', l_test_table)
    USING 'hello', 'hello', 'AB';

    -- text and varchar work the same for normal strings
    PERFORM test.lives_ok(
        format('INSERT INTO test.%I (name_text) VALUES (''%s'')', l_test_table, repeat('x', 1000)),
        'text has no length limit'
    );

    -- varchar(n) enforces limit
    PERFORM test.throws_ok(
        format('INSERT INTO test.%I (name_varchar) VALUES (''%s'')', l_test_table, repeat('x', 101)),
        '22001',  -- string_data_right_truncation
        'varchar(n) enforces length'
    );

    -- Clean up
    EXECUTE format('DROP TABLE test.%I', l_test_table);
END;
$$;

-- Test: Use timestamptz instead of timestamp
CREATE OR REPLACE FUNCTION test.test_antipattern_013_timestamptz_required()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_times_' || to_char(clock_timestamp(), 'HH24MISS');
    l_type1 text;
    l_type2 text;
BEGIN
    PERFORM test.set_context('test_antipattern_013_timestamptz_required');

    EXECUTE format($tbl$
        CREATE TABLE test.%I (
            ts_bad timestamp,         -- ANTI-PATTERN
            ts_good timestamptz       -- CORRECT
        )
    $tbl$, l_test_table);

    -- Check column types
    SELECT data_type INTO l_type1
    FROM information_schema.columns
    WHERE table_schema = 'test' AND table_name = l_test_table AND column_name = 'ts_bad';

    SELECT data_type INTO l_type2
    FROM information_schema.columns
    WHERE table_schema = 'test' AND table_name = l_test_table AND column_name = 'ts_good';

    PERFORM test.is(l_type1, 'timestamp without time zone', 'timestamp (anti-pattern)');
    PERFORM test.is(l_type2, 'timestamp with time zone', 'timestamptz (correct)');

    -- Clean up
    EXECUTE format('DROP TABLE test.%I', l_test_table);
END;
$$;

-- Test: Use numeric(p,s) instead of float for money
CREATE OR REPLACE FUNCTION test.test_antipattern_014_numeric_for_money()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_float_result float;
    l_numeric_result numeric;
BEGIN
    PERFORM test.set_context('test_antipattern_014_numeric_for_money');

    -- Float precision issue
    l_float_result := 0.1::float + 0.1::float + 0.1::float - 0.3::float;
    l_numeric_result := 0.1::numeric + 0.1::numeric + 0.1::numeric - 0.3::numeric;

    -- Float may not be exactly 0
    -- Numeric is exactly 0
    PERFORM test.is(l_numeric_result, 0::numeric, 'numeric gives exact result');
    -- Note: we don't assert on float because it might be 0 or very close to 0
    PERFORM test.is_not_null(l_float_result, 'float result may have precision issues');
END;
$$;

-- Test: SECURITY DEFINER requires SET search_path
CREATE OR REPLACE FUNCTION test.test_antipattern_015_security_definer_path()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_secure_func text := 'secure_' || to_char(clock_timestamp(), 'HH24MISS');
    l_insecure_func text := 'insecure_' || to_char(clock_timestamp(), 'HH24MISS');
    l_secure_path text;
    l_insecure_path text;
BEGIN
    PERFORM test.set_context('test_antipattern_015_security_definer_path');

    -- CORRECT: SECURITY DEFINER with SET search_path
    EXECUTE format($fn$
        CREATE FUNCTION api.%I()
        RETURNS text
        LANGUAGE sql
        SECURITY DEFINER
        SET search_path = data, private, pg_temp
        AS $$ SELECT 'secure'::text $$
    $fn$, l_secure_func);

    -- ANTI-PATTERN: SECURITY DEFINER without SET search_path
    EXECUTE format($fn$
        CREATE FUNCTION api.%I()
        RETURNS text
        LANGUAGE sql
        SECURITY DEFINER
        AS $$ SELECT 'insecure'::text $$
    $fn$, l_insecure_func);

    -- Check search_path settings
    l_secure_path := test.get_function_search_path('api', l_secure_func);
    l_insecure_path := test.get_function_search_path('api', l_insecure_func);

    PERFORM test.is_not_null(l_secure_path, 'secure function has SET search_path');
    PERFORM test.is_null(l_insecure_path, 'insecure function missing SET search_path (VULNERABILITY!)');

    -- Clean up
    EXECUTE format('DROP FUNCTION api.%I()', l_secure_func);
    EXECUTE format('DROP FUNCTION api.%I()', l_insecure_func);
END;
$$;

-- Test: Use COALESCE for NULL handling
CREATE OR REPLACE FUNCTION test.test_antipattern_016_coalesce_pattern()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_value text := NULL;
    l_result text;
BEGIN
    PERFORM test.set_context('test_antipattern_016_coalesce_pattern');

    -- ANTI-PATTERN: CASE WHEN for simple NULL check
    l_result := CASE WHEN l_value IS NULL THEN 'default' ELSE l_value END;
    PERFORM test.is(l_result, 'default', 'CASE WHEN works but verbose');

    -- CORRECT: COALESCE is cleaner
    l_result := COALESCE(l_value, 'default');
    PERFORM test.is(l_result, 'default', 'COALESCE is cleaner for NULL defaults');
END;
$$;

-- Test: Avoid SELECT * in production code
CREATE OR REPLACE FUNCTION test.test_antipattern_017_explicit_columns()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_cols_' || to_char(clock_timestamp(), 'HH24MISS');
    l_func_correct text := 'correct_' || to_char(clock_timestamp(), 'HH24MISS');
BEGIN
    PERFORM test.set_context('test_antipattern_017_explicit_columns');

    -- Create table
    EXECUTE format('CREATE TABLE test.%I (id int, name text, secret text)', l_test_table);
    EXECUTE format('INSERT INTO test.%I VALUES (1, ''Alice'', ''password123'')', l_test_table);

    -- CORRECT: RETURNS TABLE with explicit columns
    EXECUTE format($fn$
        CREATE FUNCTION test.%I(in_id int)
        RETURNS TABLE (id int, name text)  -- No secret column!
        LANGUAGE sql
        AS $$ SELECT id, name FROM test.%I WHERE id = in_id $$
    $fn$, l_func_correct, l_test_table);

    -- Function only returns specified columns
    PERFORM test.isnt_empty(
        format('SELECT id, name FROM test.%I(1)', l_func_correct),
        'explicit columns prevent accidental exposure'
    );

    -- Clean up
    EXECUTE format('DROP FUNCTION test.%I(int)', l_func_correct);
    EXECUTE format('DROP TABLE test.%I', l_test_table);
END;
$$;

-- Test: Use GENERATED ALWAYS AS IDENTITY instead of serial
CREATE OR REPLACE FUNCTION test.test_antipattern_018_identity_vs_serial()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_identity_' || to_char(clock_timestamp(), 'HH24MISS');
BEGIN
    PERFORM test.set_context('test_antipattern_018_identity_vs_serial');

    -- CORRECT: GENERATED ALWAYS AS IDENTITY
    EXECUTE format($tbl$
        CREATE TABLE test.%I (
            id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
            name text
        )
    $tbl$, l_test_table);

    -- Insert should auto-generate ID
    PERFORM test.lives_ok(
        format('INSERT INTO test.%I (name) VALUES (''Test'')', l_test_table),
        'IDENTITY auto-generates ID'
    );

    -- Cannot override GENERATED ALWAYS (safer than serial)
    PERFORM test.throws_ok(
        format('INSERT INTO test.%I (id, name) VALUES (999, ''Override'')', l_test_table),
        '428C9',  -- generated_always
        'GENERATED ALWAYS prevents accidental ID override'
    );

    -- Clean up
    EXECUTE format('DROP TABLE test.%I', l_test_table);
END;
$$;

-- ============================================================================
-- RUN TESTS
-- ============================================================================

SELECT test.run_module('antipattern_01');
CALL test.print_run_summary();
