-- ============================================================================
-- PL/PGSQL PATTERNS TESTS - PREPARED STATEMENTS
-- ============================================================================
-- Tests for prepared statement patterns documented in performance-tuning.md:
-- 1. PREPARE / EXECUTE / DEALLOCATE lifecycle
-- 2. Plan caching (generic vs custom plans)
-- 3. Monitoring via pg_prepared_statements
-- Reference: references/performance-tuning.md §Prepared Statements
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

-- Test: PREPARE / EXECUTE / DEALLOCATE lifecycle
CREATE OR REPLACE FUNCTION test.test_prepared_050_basic_lifecycle()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_prep_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_stmt_name text := 'test_stmt_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_result_count integer;
    l_stmt_exists boolean;
BEGIN
    PERFORM test.set_context('test_prepared_050_basic_lifecycle');

    -- Create test table with data
    EXECUTE format('CREATE TABLE data.%I (
        id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        name text NOT NULL,
        status text NOT NULL DEFAULT ''active''
    )', l_test_table);

    EXECUTE format('INSERT INTO data.%I (name, status) VALUES
        (''Alice'', ''active''), (''Bob'', ''active''), (''Carol'', ''inactive'')',
        l_test_table);

    -- PREPARE a parameterized count statement (count query returns a single value)
    EXECUTE format('PREPARE %I (text) AS SELECT count(*) FROM data.%I WHERE status = $1',
        l_stmt_name, l_test_table);

    -- Verify it appears in pg_prepared_statements
    SELECT EXISTS (
        SELECT 1 FROM pg_prepared_statements WHERE name = l_stmt_name
    ) INTO l_stmt_exists;

    PERFORM test.ok(l_stmt_exists, 'Prepared statement should appear in pg_prepared_statements');

    -- EXECUTE the prepared statement and fetch result
    EXECUTE format('EXECUTE %I(%L)', l_stmt_name, 'active')
    INTO l_result_count;

    PERFORM test.is(l_result_count, 2, 'EXECUTE should return filtered count');

    -- DEALLOCATE
    EXECUTE format('DEALLOCATE %I', l_stmt_name);

    -- Verify it is removed
    SELECT EXISTS (
        SELECT 1 FROM pg_prepared_statements WHERE name = l_stmt_name
    ) INTO l_stmt_exists;

    PERFORM test.not_ok(l_stmt_exists, 'Deallocated statement should not be in pg_prepared_statements');

    -- Clean up
    EXECUTE format('DROP TABLE data.%I CASCADE', l_test_table);
END;
$$;

-- Test: Prepared statement reuse (execute multiple times with different params)
CREATE OR REPLACE FUNCTION test.test_prepared_051_reuse()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_reuse_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_stmt_name text := 'test_reuse_stmt_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_count_active integer;
    l_count_inactive integer;
BEGIN
    PERFORM test.set_context('test_prepared_051_reuse');

    -- Create test table
    EXECUTE format('CREATE TABLE data.%I (
        id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        status text NOT NULL
    )', l_test_table);

    EXECUTE format('INSERT INTO data.%I (status) VALUES
        (''active''), (''active''), (''inactive'')', l_test_table);

    -- Prepare a count query once
    EXECUTE format('PREPARE %I (text) AS SELECT count(*) FROM data.%I WHERE status = $1',
        l_stmt_name, l_test_table);

    -- Execute with different parameters to demonstrate plan reuse
    EXECUTE format('EXECUTE %I(%L)', l_stmt_name, 'active')
    INTO l_count_active;

    EXECUTE format('EXECUTE %I(%L)', l_stmt_name, 'inactive')
    INTO l_count_inactive;

    PERFORM test.is(l_count_active, 2, 'Reused statement should return 2 active');
    PERFORM test.is(l_count_inactive, 1, 'Reused statement should return 1 inactive');

    -- Clean up
    EXECUTE format('DEALLOCATE %I', l_stmt_name);
    EXECUTE format('DROP TABLE data.%I CASCADE', l_test_table);
END;
$$;

-- Test: DEALLOCATE ALL removes all prepared statements
CREATE OR REPLACE FUNCTION test.test_prepared_052_deallocate_all()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_stmt1 text := 'test_da_1_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_stmt2 text := 'test_da_2_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_has_stmt1 boolean;
    l_has_stmt2 boolean;
BEGIN
    PERFORM test.set_context('test_prepared_052_deallocate_all');

    -- Prepare two statements
    EXECUTE format('PREPARE %I AS SELECT 1', l_stmt1);
    EXECUTE format('PREPARE %I AS SELECT 2', l_stmt2);

    -- Both should exist
    SELECT EXISTS (SELECT 1 FROM pg_prepared_statements WHERE name = l_stmt1) INTO l_has_stmt1;
    SELECT EXISTS (SELECT 1 FROM pg_prepared_statements WHERE name = l_stmt2) INTO l_has_stmt2;

    PERFORM test.ok(l_has_stmt1, 'First statement should exist before DEALLOCATE ALL');
    PERFORM test.ok(l_has_stmt2, 'Second statement should exist before DEALLOCATE ALL');

    -- DEALLOCATE ALL (as recommended in pgbouncer server_reset_query)
    DEALLOCATE ALL;

    -- Neither should exist now
    SELECT EXISTS (SELECT 1 FROM pg_prepared_statements WHERE name = l_stmt1) INTO l_has_stmt1;
    SELECT EXISTS (SELECT 1 FROM pg_prepared_statements WHERE name = l_stmt2) INTO l_has_stmt2;

    PERFORM test.not_ok(l_has_stmt1, 'First statement should be gone after DEALLOCATE ALL');
    PERFORM test.not_ok(l_has_stmt2, 'Second statement should be gone after DEALLOCATE ALL');
END;
$$;

-- Test: pg_prepared_statements view shows statement details
CREATE OR REPLACE FUNCTION test.test_prepared_053_monitoring_view()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_stmt_name text := 'test_mon_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_statement text;
    l_prepare_time timestamptz;
    l_param_types regtype[];
BEGIN
    PERFORM test.set_context('test_prepared_053_monitoring_view');

    -- Prepare a statement with a typed parameter
    EXECUTE format('PREPARE %I (uuid) AS SELECT $1::text', l_stmt_name);

    -- Check monitoring view returns metadata
    SELECT statement, prepare_time, parameter_types
    INTO l_statement, l_prepare_time, l_param_types
    FROM pg_prepared_statements
    WHERE name = l_stmt_name;

    PERFORM test.is_not_null(l_statement, 'Monitoring view should show statement text');
    PERFORM test.is_not_null(l_prepare_time, 'Monitoring view should show prepare_time');
    PERFORM test.is_not_null(l_param_types, 'Monitoring view should show parameter_types');
    PERFORM test.is(l_param_types[1]::text, 'uuid', 'Parameter type should be uuid');

    -- Clean up
    EXECUTE format('DEALLOCATE %I', l_stmt_name);
END;
$$;

-- Test: Table API function is the preferred alternative to client-side PREPARE
CREATE OR REPLACE FUNCTION test.test_prepared_054_table_api_preferred()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_tapi_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_test_func text := 'test_tapi_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_result_name text;
    l_is_definer boolean;
BEGIN
    PERFORM test.set_context('test_prepared_054_table_api_preferred');

    -- Create test table
    EXECUTE format('CREATE TABLE data.%I (
        id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        email text NOT NULL,
        name text NOT NULL
    )', l_test_table);

    EXECUTE format('INSERT INTO data.%I (email, name) VALUES (''alice@test.com'', ''Alice'')',
        l_test_table);

    -- Create a Table API function (the recommended pooling-safe alternative)
    EXECUTE format($fn$
        CREATE FUNCTION api.get_%I(in_id uuid)
        RETURNS TABLE (id uuid, email text, name text)
        LANGUAGE sql
        STABLE
        SECURITY DEFINER
        SET search_path = data, private, pg_temp
        AS $body$
            SELECT id, email, name FROM %I WHERE id = in_id;
        $body$
    $fn$, l_test_func, l_test_table);

    -- The function works without any client-side PREPARE
    EXECUTE format('SELECT name FROM api.get_%I((SELECT id FROM data.%I LIMIT 1))',
        l_test_func, l_test_table)
    INTO l_result_name;

    PERFORM test.is(l_result_name, 'Alice', 'Table API function works without client PREPARE');

    -- Verify it follows the security conventions
    l_is_definer := test.is_security_definer('api', 'get_' || l_test_func);
    PERFORM test.ok(l_is_definer, 'Table API function should be SECURITY DEFINER');

    -- Clean up
    EXECUTE format('DROP FUNCTION api.get_%I(uuid)', l_test_func);
    EXECUTE format('DROP TABLE data.%I CASCADE', l_test_table);
END;
$$;

-- Test: plan_cache_mode setting can be changed
CREATE OR REPLACE FUNCTION test.test_prepared_055_plan_cache_mode()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_original_mode text;
    l_current_mode text;
BEGIN
    PERFORM test.set_context('test_prepared_055_plan_cache_mode');

    -- Save original setting
    l_original_mode := current_setting('plan_cache_mode');
    PERFORM test.is_not_null(l_original_mode, 'plan_cache_mode should have a value');

    -- Set to force_generic_plan
    SET LOCAL plan_cache_mode = 'force_generic_plan';
    l_current_mode := current_setting('plan_cache_mode');
    PERFORM test.is(l_current_mode, 'force_generic_plan', 'Should accept force_generic_plan');

    -- Set to force_custom_plan
    SET LOCAL plan_cache_mode = 'force_custom_plan';
    l_current_mode := current_setting('plan_cache_mode');
    PERFORM test.is(l_current_mode, 'force_custom_plan', 'Should accept force_custom_plan');

    -- Set back to auto
    SET LOCAL plan_cache_mode = 'auto';
    l_current_mode := current_setting('plan_cache_mode');
    PERFORM test.is(l_current_mode, 'auto', 'Should accept auto');
END;
$$;

-- ============================================================================
-- RUN TESTS
-- ============================================================================

SELECT test.run_module('prepared_05');
CALL test.print_run_summary();
