-- ============================================================================
-- TEST FRAMEWORK - HELPERS
-- ============================================================================
-- Test data factories, transaction wrappers, and utility functions.
-- ============================================================================

BEGIN;

-- ============================================================================
-- TEST DATA NAMING
-- ============================================================================
-- All test data uses TEST_ prefix for easy identification and cleanup

-- Generate a unique test identifier
CREATE OR REPLACE FUNCTION test.unique_id()
RETURNS text
LANGUAGE sql
VOLATILE
AS $$
    SELECT 'TEST_' || to_char(clock_timestamp(), 'YYYYMMDD_HH24MISS_US');
$$;

COMMENT ON FUNCTION test.unique_id() IS 'Generate unique test identifier with TEST_ prefix';

-- Generate a test email
CREATE OR REPLACE FUNCTION test.test_email(in_suffix text DEFAULT NULL)
RETURNS text
LANGUAGE sql
VOLATILE
AS $$
    SELECT 'test_' || COALESCE(in_suffix || '_', '') ||
           to_char(clock_timestamp(), 'HH24MISS_US') || '@example.test';
$$;

COMMENT ON FUNCTION test.test_email(text) IS 'Generate unique test email address';

-- ============================================================================
-- SAVEPOINT MANAGEMENT
-- ============================================================================

-- Create a savepoint for test isolation
CREATE OR REPLACE FUNCTION test.begin_test(in_name text DEFAULT 'test_savepoint')
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    EXECUTE 'SAVEPOINT ' || quote_ident(in_name);
    PERFORM test.set_context(in_name);
END;
$$;

COMMENT ON FUNCTION test.begin_test(text) IS 'Create savepoint for test isolation';

-- Rollback to savepoint
CREATE OR REPLACE FUNCTION test.rollback_test(in_name text DEFAULT 'test_savepoint')
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    EXECUTE 'ROLLBACK TO SAVEPOINT ' || quote_ident(in_name);
END;
$$;

COMMENT ON FUNCTION test.rollback_test(text) IS 'Rollback to test savepoint';

-- Release savepoint (commit test changes)
CREATE OR REPLACE FUNCTION test.commit_test(in_name text DEFAULT 'test_savepoint')
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    EXECUTE 'RELEASE SAVEPOINT ' || quote_ident(in_name);
END;
$$;

COMMENT ON FUNCTION test.commit_test(text) IS 'Release test savepoint (keep changes)';

-- ============================================================================
-- EXECUTION HELPERS
-- ============================================================================

-- Execute SQL and return affected row count
CREATE OR REPLACE FUNCTION test.exec_count(in_sql text)
RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
    l_count bigint;
BEGIN
    EXECUTE in_sql;
    GET DIAGNOSTICS l_count = ROW_COUNT;
    RETURN l_count;
END;
$$;

COMMENT ON FUNCTION test.exec_count(text) IS 'Execute SQL and return affected row count';

-- Execute SQL and return single value
CREATE OR REPLACE FUNCTION test.exec_scalar(in_sql text)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
    l_result text;
BEGIN
    EXECUTE in_sql INTO l_result;
    RETURN l_result;
END;
$$;

COMMENT ON FUNCTION test.exec_scalar(text) IS 'Execute SQL and return single scalar value';

-- Check if query returns any rows
CREATE OR REPLACE FUNCTION test.query_returns_rows(in_sql text)
RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
    l_exists boolean;
BEGIN
    EXECUTE 'SELECT EXISTS (' || in_sql || ')' INTO l_exists;
    RETURN l_exists;
END;
$$;

COMMENT ON FUNCTION test.query_returns_rows(text) IS 'Check if query returns any rows';

-- ============================================================================
-- TIMING HELPERS
-- ============================================================================

-- Measure execution time of SQL
CREATE OR REPLACE FUNCTION test.measure_time(in_sql text)
RETURNS numeric
LANGUAGE plpgsql
AS $$
DECLARE
    l_start timestamptz;
    l_end timestamptz;
BEGIN
    l_start := clock_timestamp();
    EXECUTE in_sql;
    l_end := clock_timestamp();
    RETURN extract(milliseconds from l_end - l_start);
END;
$$;

COMMENT ON FUNCTION test.measure_time(text) IS 'Measure execution time in milliseconds';

-- Assert execution time is under threshold
CREATE OR REPLACE FUNCTION test.runs_within(
    in_sql text,
    in_max_ms numeric,
    in_description text DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
    l_time numeric;
BEGIN
    l_time := test.measure_time(in_sql);

    RETURN test._record(
        l_time <= in_max_ms,
        COALESCE(in_description, 'Should complete within ' || in_max_ms || 'ms'),
        l_time || 'ms',
        '<= ' || in_max_ms || 'ms'
    );
END;
$$;

COMMENT ON FUNCTION test.runs_within(text, numeric, text) IS 'Assert SQL completes within time limit';

-- ============================================================================
-- DATA COMPARISON HELPERS
-- ============================================================================

-- Compare two queries return same results
CREATE OR REPLACE FUNCTION test.results_eq(
    in_query1 text,
    in_query2 text,
    in_description text DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
    l_diff_count bigint;
BEGIN
    -- Use EXCEPT to find differences
    EXECUTE format('
        SELECT count(*) FROM (
            ((%s) EXCEPT (%s))
            UNION ALL
            ((%s) EXCEPT (%s))
        ) diff
    ', in_query1, in_query2, in_query2, in_query1)
    INTO l_diff_count;

    RETURN test._record(
        l_diff_count = 0,
        in_description,
        CASE WHEN l_diff_count = 0 THEN 'identical' ELSE l_diff_count || ' differences' END,
        'identical'
    );
END;
$$;

COMMENT ON FUNCTION test.results_eq(text, text, text) IS 'Assert two queries return identical results';

-- ============================================================================
-- SCHEMA INSPECTION HELPERS
-- ============================================================================

-- Get column names for a table
CREATE OR REPLACE FUNCTION test.get_columns(
    in_schema text,
    in_table text
)
RETURNS text[]
LANGUAGE sql
STABLE
AS $$
    SELECT array_agg(column_name::text ORDER BY ordinal_position)
    FROM information_schema.columns
    WHERE table_schema = in_schema AND table_name = in_table;
$$;

COMMENT ON FUNCTION test.get_columns(text, text) IS 'Get array of column names for a table';

-- Get function definition
CREATE OR REPLACE FUNCTION test.get_function_def(
    in_schema text,
    in_function text
)
RETURNS text
LANGUAGE sql
STABLE
AS $$
    SELECT pg_get_functiondef(p.oid)
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = in_schema AND p.proname = in_function
    LIMIT 1;
$$;

COMMENT ON FUNCTION test.get_function_def(text, text) IS 'Get function definition';

-- Check if function has SECURITY DEFINER
CREATE OR REPLACE FUNCTION test.is_security_definer(
    in_schema text,
    in_function text
)
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
    SELECT p.prosecdef
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = in_schema AND p.proname = in_function
    LIMIT 1;
$$;

COMMENT ON FUNCTION test.is_security_definer(text, text) IS 'Check if function uses SECURITY DEFINER';

-- Get function's search_path setting
CREATE OR REPLACE FUNCTION test.get_function_search_path(
    in_schema text,
    in_function text
)
RETURNS text
LANGUAGE sql
STABLE
AS $$
    SELECT config
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    CROSS JOIN LATERAL unnest(p.proconfig) AS config
    WHERE n.nspname = in_schema AND p.proname = in_function
      AND config LIKE 'search_path=%'
    LIMIT 1;
$$;

COMMENT ON FUNCTION test.get_function_search_path(text, text) IS 'Get function search_path setting';

-- ============================================================================
-- UUID HELPERS
-- ============================================================================

-- Generate a test UUID (if uuidv7 not available)
CREATE OR REPLACE FUNCTION test.gen_uuid()
RETURNS uuid
LANGUAGE sql
VOLATILE
AS $$
    SELECT COALESCE(
        (SELECT uuidv7()),
        gen_random_uuid()
    );
$$;

COMMENT ON FUNCTION test.gen_uuid() IS 'Generate UUID using uuidv7() or fallback to gen_random_uuid()';

-- Check if UUID is valid UUIDv7 format
CREATE OR REPLACE FUNCTION test.is_uuidv7(in_uuid uuid)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
    -- UUIDv7 has version 7 (bits 48-51) and variant 2 (bits 64-65)
    SELECT
        -- Check version: 7
        ((in_uuid::text)::uuid::text LIKE '________-____-7___-____-____________')
        AND
        -- Check variant: 8, 9, a, or b
        ((substring(in_uuid::text from 20 for 1)) = ANY(ARRAY['8','9','a','b']));
$$;

COMMENT ON FUNCTION test.is_uuidv7(uuid) IS 'Check if UUID follows UUIDv7 format';

-- ============================================================================
-- CLEANUP HELPERS
-- ============================================================================

-- Drop all objects with TEST_ prefix in a schema
CREATE OR REPLACE PROCEDURE test.cleanup_test_objects(in_schema text DEFAULT 'data')
LANGUAGE plpgsql
AS $$
DECLARE
    l_obj record;
    l_count integer := 0;
BEGIN
    -- Drop tables
    FOR l_obj IN
        SELECT table_name
        FROM information_schema.tables
        WHERE table_schema = in_schema
          AND table_name LIKE 'test_%'
    LOOP
        EXECUTE format('DROP TABLE IF EXISTS %I.%I CASCADE', in_schema, l_obj.table_name);
        l_count := l_count + 1;
    END LOOP;

    -- Drop functions
    FOR l_obj IN
        SELECT routine_name, routine_type
        FROM information_schema.routines
        WHERE routine_schema = in_schema
          AND routine_name LIKE 'test_%'
    LOOP
        IF l_obj.routine_type = 'FUNCTION' THEN
            EXECUTE format('DROP FUNCTION IF EXISTS %I.%I CASCADE', in_schema, l_obj.routine_name);
        ELSE
            EXECUTE format('DROP PROCEDURE IF EXISTS %I.%I CASCADE', in_schema, l_obj.routine_name);
        END IF;
        l_count := l_count + 1;
    END LOOP;

    RAISE NOTICE 'Cleaned up % test objects from %', l_count, in_schema;
END;
$$;

COMMENT ON PROCEDURE test.cleanup_test_objects(text) IS 'Drop all test_ prefixed objects in schema';

-- Delete test data from migration changelog
CREATE OR REPLACE PROCEDURE test.cleanup_test_migrations()
LANGUAGE plpgsql
AS $$
DECLARE
    l_count integer;
BEGIN
    DELETE FROM app_migration.changelog
    WHERE version LIKE 'TEST_%' OR filename LIKE 'TEST_%';
    GET DIAGNOSTICS l_count = ROW_COUNT;

    DELETE FROM app_migration.rollback_scripts WHERE version LIKE 'TEST_%';
    DELETE FROM app_migration.rollback_history WHERE version LIKE 'TEST_%';

    RAISE NOTICE 'Cleaned up % test migration records', l_count;
END;
$$;

COMMENT ON PROCEDURE test.cleanup_test_migrations() IS 'Delete test migration records from changelog';

-- ============================================================================
-- PARALLEL TEST HELPERS
-- ============================================================================

-- Check for concurrent access (advisory lock test)
CREATE OR REPLACE FUNCTION test.try_lock(in_key bigint)
RETURNS boolean
LANGUAGE sql
AS $$
    SELECT pg_try_advisory_lock(in_key);
$$;

COMMENT ON FUNCTION test.try_lock(bigint) IS 'Try to acquire advisory lock';

-- Release advisory lock
CREATE OR REPLACE FUNCTION test.release_lock(in_key bigint)
RETURNS boolean
LANGUAGE sql
AS $$
    SELECT pg_advisory_unlock(in_key);
$$;

COMMENT ON FUNCTION test.release_lock(bigint) IS 'Release advisory lock';

-- ============================================================================
-- ASSERTION HELPERS FOR COMMON PATTERNS
-- ============================================================================

-- Assert table has expected columns
CREATE OR REPLACE FUNCTION test.table_has_columns(
    in_schema text,
    in_table text,
    in_columns text[],
    in_description text DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
    l_actual text[];
    l_missing text[];
BEGIN
    l_actual := test.get_columns(in_schema, in_table);

    SELECT array_agg(col) INTO l_missing
    FROM unnest(in_columns) AS col
    WHERE col != ALL(COALESCE(l_actual, ARRAY[]::text[]));

    RETURN test._record(
        l_missing IS NULL OR array_length(l_missing, 1) IS NULL,
        COALESCE(in_description, 'Table should have required columns'),
        CASE WHEN l_missing IS NULL THEN 'all present' ELSE 'missing: ' || array_to_string(l_missing, ', ') END,
        'all present'
    );
END;
$$;

COMMENT ON FUNCTION test.table_has_columns(text, text, text[], text) IS 'Assert table has all expected columns';

-- Assert function exists with SECURITY DEFINER and search_path
CREATE OR REPLACE FUNCTION test.is_secure_function(
    in_schema text,
    in_function text,
    in_description text DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
    l_is_definer boolean;
    l_search_path text;
    l_passed boolean := true;
BEGIN
    l_is_definer := test.is_security_definer(in_schema, in_function);
    l_search_path := test.get_function_search_path(in_schema, in_function);

    -- Check SECURITY DEFINER
    IF NOT COALESCE(l_is_definer, false) THEN
        PERFORM test._record(false,
            COALESCE(in_description, in_function || ' should be SECURITY DEFINER'),
            'SECURITY INVOKER', 'SECURITY DEFINER');
        l_passed := false;
    ELSE
        PERFORM test._record(true, in_function || ' is SECURITY DEFINER');
    END IF;

    -- Check search_path is set
    IF l_search_path IS NULL THEN
        PERFORM test._record(false,
            in_function || ' should have SET search_path',
            'no search_path', 'SET search_path = ...');
        l_passed := false;
    ELSE
        PERFORM test._record(true, in_function || ' has SET search_path');
    END IF;

    RETURN l_passed;
END;
$$;

COMMENT ON FUNCTION test.is_secure_function(text, text, text) IS 'Assert function has SECURITY DEFINER and SET search_path';

COMMIT;
