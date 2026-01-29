-- ============================================================================
-- SCHEMA ARCHITECTURE TESTS - ROLE PERMISSIONS
-- ============================================================================
-- Tests for role-based access control patterns.
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

-- Test: api schema should have USAGE granted to appropriate roles
CREATE OR REPLACE FUNCTION test.test_roles_030_api_usage()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_has_usage boolean;
BEGIN
    PERFORM test.set_context('test_roles_030_api_usage');

    -- The current user should have usage on api schema
    SELECT has_schema_privilege(current_user, 'api', 'USAGE') INTO l_has_usage;

    PERFORM test.ok(l_has_usage, 'current user should have USAGE on api schema');
END;
$$;

-- Test: data schema should be accessible to db owner
CREATE OR REPLACE FUNCTION test.test_roles_031_data_access()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_has_usage boolean;
BEGIN
    PERFORM test.set_context('test_roles_031_data_access');

    SELECT has_schema_privilege(current_user, 'data', 'USAGE') INTO l_has_usage;

    PERFORM test.ok(l_has_usage, 'db owner should have USAGE on data schema');
END;
$$;

-- Test: private schema should be accessible to db owner
CREATE OR REPLACE FUNCTION test.test_roles_032_private_access()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_has_usage boolean;
BEGIN
    PERFORM test.set_context('test_roles_032_private_access');

    SELECT has_schema_privilege(current_user, 'private', 'USAGE') INTO l_has_usage;

    PERFORM test.ok(l_has_usage, 'db owner should have USAGE on private schema');
END;
$$;

-- Test: Tables in data schema should have owner privileges
CREATE OR REPLACE FUNCTION test.test_roles_033_table_owner()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_owner_' || to_char(clock_timestamp(), 'HH24MISS');
    l_table_owner text;
BEGIN
    PERFORM test.set_context('test_roles_033_table_owner');

    -- Create test table
    EXECUTE format('CREATE TABLE data.%I (id int)', l_test_table);

    -- Get table owner
    SELECT tableowner INTO l_table_owner
    FROM pg_tables
    WHERE schemaname = 'data' AND tablename = l_test_table;

    PERFORM test.is(l_table_owner, current_user, 'table owner should be current user');

    -- Clean up
    EXECUTE format('DROP TABLE data.%I', l_test_table);
END;
$$;

-- Test: Function owner should be db owner
CREATE OR REPLACE FUNCTION test.test_roles_034_function_owner()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_func text := 'test_owner_' || to_char(clock_timestamp(), 'HH24MISS');
    l_func_owner text;
BEGIN
    PERFORM test.set_context('test_roles_034_function_owner');

    -- Create test function
    EXECUTE format($fn$
        CREATE FUNCTION api.%I()
        RETURNS text
        LANGUAGE sql
        AS $$ SELECT 'test'::text $$
    $fn$, l_test_func);

    -- Get function owner
    SELECT r.rolname INTO l_func_owner
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    JOIN pg_roles r ON r.oid = p.proowner
    WHERE n.nspname = 'api' AND p.proname = l_test_func;

    PERFORM test.is(l_func_owner, current_user, 'function owner should be current user');

    -- Clean up
    EXECUTE format('DROP FUNCTION api.%I()', l_test_func);
END;
$$;

-- Test: EXECUTE privilege on api functions
CREATE OR REPLACE FUNCTION test.test_roles_035_execute_privilege()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_func text := 'test_exec_' || to_char(clock_timestamp(), 'HH24MISS');
    l_can_execute boolean;
BEGIN
    PERFORM test.set_context('test_roles_035_execute_privilege');

    -- Create test function
    EXECUTE format($fn$
        CREATE FUNCTION api.%I()
        RETURNS text
        LANGUAGE sql
        AS $$ SELECT 'test'::text $$
    $fn$, l_test_func);

    -- Check execute privilege
    SELECT has_function_privilege(current_user, format('api.%I()', l_test_func), 'EXECUTE')
    INTO l_can_execute;

    PERFORM test.ok(l_can_execute, 'current user should have EXECUTE on api function');

    -- Clean up
    EXECUTE format('DROP FUNCTION api.%I()', l_test_func);
END;
$$;

-- Test: Table privileges include SELECT, INSERT, UPDATE, DELETE for owner
CREATE OR REPLACE FUNCTION test.test_roles_036_table_privileges()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_privs_' || to_char(clock_timestamp(), 'HH24MISS');
BEGIN
    PERFORM test.set_context('test_roles_036_table_privileges');

    -- Create test table
    EXECUTE format('CREATE TABLE data.%I (id int)', l_test_table);

    -- Check privileges
    PERFORM test.ok(
        has_table_privilege(current_user, format('data.%I', l_test_table), 'SELECT'),
        'owner should have SELECT'
    );
    PERFORM test.ok(
        has_table_privilege(current_user, format('data.%I', l_test_table), 'INSERT'),
        'owner should have INSERT'
    );
    PERFORM test.ok(
        has_table_privilege(current_user, format('data.%I', l_test_table), 'UPDATE'),
        'owner should have UPDATE'
    );
    PERFORM test.ok(
        has_table_privilege(current_user, format('data.%I', l_test_table), 'DELETE'),
        'owner should have DELETE'
    );

    -- Clean up
    EXECUTE format('DROP TABLE data.%I', l_test_table);
END;
$$;

-- Test: Sequence privileges for IDENTITY columns
CREATE OR REPLACE FUNCTION test.test_roles_037_sequence_privileges()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_seq_' || to_char(clock_timestamp(), 'HH24MISS');
    l_seq_name text;
    l_can_use boolean;
BEGIN
    PERFORM test.set_context('test_roles_037_sequence_privileges');

    -- Create table with IDENTITY column
    EXECUTE format('CREATE TABLE data.%I (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY)', l_test_table);

    -- Find the sequence name
    SELECT pg_get_serial_sequence(format('data.%I', l_test_table), 'id') INTO l_seq_name;

    IF l_seq_name IS NOT NULL THEN
        -- Check sequence usage
        SELECT has_sequence_privilege(current_user, l_seq_name, 'USAGE') INTO l_can_use;
        PERFORM test.ok(l_can_use, 'owner should have USAGE on identity sequence');
    ELSE
        PERFORM test.skip(1, 'No sequence found for IDENTITY column');
    END IF;

    -- Clean up
    EXECUTE format('DROP TABLE data.%I', l_test_table);
END;
$$;

-- ============================================================================
-- RUN TESTS
-- ============================================================================

SELECT test.run_module('roles_03');
CALL test.print_run_summary();
