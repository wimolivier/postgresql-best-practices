-- ============================================================================
-- SCHEMA ARCHITECTURE TESTS - THREE SCHEMA PATTERN
-- ============================================================================
-- Tests for the data/private/api schema separation pattern.
-- ============================================================================

-- ============================================================================
-- SETUP - Create test schemas
-- ============================================================================

DO $$
BEGIN
    -- Create schemas if they don't exist
    CREATE SCHEMA IF NOT EXISTS data;
    CREATE SCHEMA IF NOT EXISTS private;
    CREATE SCHEMA IF NOT EXISTS api;

    COMMENT ON SCHEMA data IS 'Data layer - tables and indexes';
    COMMENT ON SCHEMA private IS 'Private layer - triggers and internal helpers';
    COMMENT ON SCHEMA api IS 'API layer - public functions and procedures';
END;
$$;

-- ============================================================================
-- TEST FUNCTIONS
-- ============================================================================

-- Test: data schema exists
CREATE OR REPLACE FUNCTION test.test_schema_010_data_exists()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM test.set_context('test_schema_010_data_exists');

    PERFORM test.has_schema('data', 'data schema should exist');
END;
$$;

-- Test: private schema exists
CREATE OR REPLACE FUNCTION test.test_schema_011_private_exists()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM test.set_context('test_schema_011_private_exists');

    PERFORM test.has_schema('private', 'private schema should exist');
END;
$$;

-- Test: api schema exists
CREATE OR REPLACE FUNCTION test.test_schema_012_api_exists()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM test.set_context('test_schema_012_api_exists');

    PERFORM test.has_schema('api', 'api schema should exist');
END;
$$;

-- Test: Tables belong in data schema
CREATE OR REPLACE FUNCTION test.test_schema_013_table_in_data()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_schema_013_' || to_char(clock_timestamp(), 'HH24MISS');
BEGIN
    PERFORM test.set_context('test_schema_013_table_in_data');

    -- Create test table in data schema
    EXECUTE format('CREATE TABLE data.%I (id serial PRIMARY KEY, name text)', l_test_table);

    -- Verify it exists in data schema
    PERFORM test.has_table('data', l_test_table, 'table should exist in data schema');

    -- Clean up
    EXECUTE format('DROP TABLE data.%I', l_test_table);
END;
$$;

-- Test: Tables should NOT be in api schema
CREATE OR REPLACE FUNCTION test.test_schema_014_no_tables_in_api()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_table_count integer;
BEGIN
    PERFORM test.set_context('test_schema_014_no_tables_in_api');

    -- Count tables in api schema (excluding test tables)
    SELECT count(*) INTO l_table_count
    FROM information_schema.tables
    WHERE table_schema = 'api'
      AND table_type = 'BASE TABLE'
      AND table_name NOT LIKE 'test_%';

    -- API schema should have no tables (only functions and views)
    PERFORM test.is(l_table_count, 0, 'api schema should not contain base tables');
END;
$$;

-- Test: Functions with table access should be in api schema
CREATE OR REPLACE FUNCTION test.test_schema_015_functions_in_api()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_func text := 'test_api_func_' || to_char(clock_timestamp(), 'HH24MISS');
BEGIN
    PERFORM test.set_context('test_schema_015_functions_in_api');

    -- Create a proper API function
    EXECUTE format($fn$
        CREATE FUNCTION api.%I()
        RETURNS text
        LANGUAGE sql
        STABLE
        SECURITY DEFINER
        SET search_path = data, private, pg_temp
        AS $$ SELECT 'test'::text $$
    $fn$, l_test_func);

    -- Verify it exists in api schema
    PERFORM test.has_function('api', l_test_func, 'API function should exist in api schema');

    -- Clean up
    EXECUTE format('DROP FUNCTION api.%I()', l_test_func);
END;
$$;

-- Test: Trigger functions should be in private schema
CREATE OR REPLACE FUNCTION test.test_schema_016_triggers_in_private()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_func text := 'test_trigger_func_' || to_char(clock_timestamp(), 'HH24MISS');
BEGIN
    PERFORM test.set_context('test_schema_016_triggers_in_private');

    -- Create trigger function in private
    EXECUTE format($fn$
        CREATE FUNCTION private.%I()
        RETURNS trigger
        LANGUAGE plpgsql
        AS $$ BEGIN RETURN NEW; END; $$
    $fn$, l_test_func);

    -- Verify it exists in private schema
    PERFORM test.has_function('private', l_test_func, 'trigger function should exist in private schema');

    -- Clean up
    EXECUTE format('DROP FUNCTION private.%I()', l_test_func);
END;
$$;

-- Test: Helper functions should be in private schema
CREATE OR REPLACE FUNCTION test.test_schema_017_helpers_in_private()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_func text := 'test_helper_' || to_char(clock_timestamp(), 'HH24MISS');
BEGIN
    PERFORM test.set_context('test_schema_017_helpers_in_private');

    -- Create helper function in private
    EXECUTE format($fn$
        CREATE FUNCTION private.%I(in_value text)
        RETURNS text
        LANGUAGE sql
        IMMUTABLE
        AS $$ SELECT upper(in_value) $$
    $fn$, l_test_func);

    PERFORM test.has_function('private', l_test_func, 'helper function should exist in private schema');

    -- Clean up
    EXECUTE format('DROP FUNCTION private.%I(text)', l_test_func);
END;
$$;

-- Test: Standard table structure with uuidv7
CREATE OR REPLACE FUNCTION test.test_schema_018_table_structure()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_structure_' || to_char(clock_timestamp(), 'HH24MISS');
    l_has_uuidv7 boolean;
BEGIN
    PERFORM test.set_context('test_schema_018_table_structure');

    -- Check if uuidv7 is available
    SELECT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'uuidv7') INTO l_has_uuidv7;

    -- Create table with standard structure
    IF l_has_uuidv7 THEN
        EXECUTE format($tbl$
            CREATE TABLE data.%I (
                id uuid PRIMARY KEY DEFAULT uuidv7(),
                name text NOT NULL,
                created_at timestamptz NOT NULL DEFAULT now(),
                updated_at timestamptz NOT NULL DEFAULT now()
            )
        $tbl$, l_test_table);
    ELSE
        EXECUTE format($tbl$
            CREATE TABLE data.%I (
                id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
                name text NOT NULL,
                created_at timestamptz NOT NULL DEFAULT now(),
                updated_at timestamptz NOT NULL DEFAULT now()
            )
        $tbl$, l_test_table);
    END IF;

    -- Verify columns
    PERFORM test.has_column('data', l_test_table, 'id', 'table should have id column');
    PERFORM test.has_column('data', l_test_table, 'created_at', 'table should have created_at column');
    PERFORM test.has_column('data', l_test_table, 'updated_at', 'table should have updated_at column');

    -- Verify column types
    PERFORM test.col_type_is('data', l_test_table, 'id', 'uuid', 'id should be uuid');
    PERFORM test.col_type_is('data', l_test_table, 'created_at', 'timestamp with time zone', 'created_at should be timestamptz');
    PERFORM test.col_type_is('data', l_test_table, 'updated_at', 'timestamp with time zone', 'updated_at should be timestamptz');

    -- Clean up
    EXECUTE format('DROP TABLE data.%I', l_test_table);
END;
$$;

-- Test: API reads via functions, writes via procedures
CREATE OR REPLACE FUNCTION test.test_schema_019_api_pattern()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_prefix text := 'test_api_' || to_char(clock_timestamp(), 'HH24MISS');
BEGIN
    PERFORM test.set_context('test_schema_019_api_pattern');

    -- Create read function (SELECT)
    EXECUTE format($fn$
        CREATE FUNCTION api.select_%I()
        RETURNS TABLE(id int)
        LANGUAGE sql
        STABLE
        SECURITY DEFINER
        SET search_path = data, private, pg_temp
        AS $$ SELECT 1::int $$
    $fn$, l_prefix);

    -- Create write procedure (INSERT/UPDATE/DELETE)
    EXECUTE format($fn$
        CREATE PROCEDURE api.insert_%I(INOUT io_id int DEFAULT NULL)
        LANGUAGE plpgsql
        SECURITY DEFINER
        SET search_path = data, private, pg_temp
        AS $$ BEGIN io_id := 1; END; $$
    $fn$, l_prefix);

    -- Verify both exist
    PERFORM test.has_function('api', 'select_' || l_prefix, 'read function should exist');
    PERFORM test.has_procedure('api', 'insert_' || l_prefix, 'write procedure should exist');

    -- Clean up
    EXECUTE format('DROP FUNCTION api.select_%I()', l_prefix);
    EXECUTE format('DROP PROCEDURE api.insert_%I(int)', l_prefix);
END;
$$;

-- ============================================================================
-- RUN TESTS
-- ============================================================================

SELECT test.run_module('schema_01');
CALL test.print_run_summary();
