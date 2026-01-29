-- ============================================================================
-- ROW-LEVEL SECURITY TESTS - ENABLE/DISABLE RLS
-- ============================================================================
-- Tests for RLS enable/disable, FORCE ROW LEVEL SECURITY, and basic policies.
-- Reference: references/row-level-security.md
-- ============================================================================

-- ============================================================================
-- TEST FUNCTIONS
-- ============================================================================

-- Test: Enable RLS on a table
CREATE OR REPLACE FUNCTION test.test_rls_010_enable_rls()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_rls_010_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_rls_enabled boolean;
BEGIN
    PERFORM test.set_context('test_rls_010_enable_rls');

    -- Create test table
    EXECUTE format('CREATE TABLE data.%I (
        id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        tenant_id uuid NOT NULL,
        name text NOT NULL
    )', l_test_table);

    -- Verify RLS is initially disabled
    SELECT relrowsecurity INTO l_rls_enabled
    FROM pg_class
    WHERE oid = ('data.' || l_test_table)::regclass;

    PERFORM test.ok(NOT l_rls_enabled, 'RLS should be disabled by default');

    -- Enable RLS
    EXECUTE format('ALTER TABLE data.%I ENABLE ROW LEVEL SECURITY', l_test_table);

    -- Verify RLS is enabled
    SELECT relrowsecurity INTO l_rls_enabled
    FROM pg_class
    WHERE oid = ('data.' || l_test_table)::regclass;

    PERFORM test.ok(l_rls_enabled, 'RLS should be enabled after ALTER TABLE');

    -- Cleanup
    EXECUTE format('DROP TABLE data.%I', l_test_table);
END;
$$;

-- Test: Disable RLS on a table
CREATE OR REPLACE FUNCTION test.test_rls_011_disable_rls()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_rls_011_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_rls_enabled boolean;
BEGIN
    PERFORM test.set_context('test_rls_011_disable_rls');

    -- Create test table with RLS enabled
    EXECUTE format('CREATE TABLE data.%I (
        id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        tenant_id uuid NOT NULL
    )', l_test_table);

    EXECUTE format('ALTER TABLE data.%I ENABLE ROW LEVEL SECURITY', l_test_table);

    -- Verify RLS is enabled
    SELECT relrowsecurity INTO l_rls_enabled
    FROM pg_class
    WHERE oid = ('data.' || l_test_table)::regclass;

    PERFORM test.ok(l_rls_enabled, 'RLS should be enabled');

    -- Disable RLS
    EXECUTE format('ALTER TABLE data.%I DISABLE ROW LEVEL SECURITY', l_test_table);

    -- Verify RLS is disabled
    SELECT relrowsecurity INTO l_rls_enabled
    FROM pg_class
    WHERE oid = ('data.' || l_test_table)::regclass;

    PERFORM test.ok(NOT l_rls_enabled, 'RLS should be disabled after ALTER TABLE');

    -- Cleanup
    EXECUTE format('DROP TABLE data.%I', l_test_table);
END;
$$;

-- Test: FORCE ROW LEVEL SECURITY
CREATE OR REPLACE FUNCTION test.test_rls_012_force_rls()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_rls_012_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_force_rls boolean;
BEGIN
    PERFORM test.set_context('test_rls_012_force_rls');

    -- Create test table
    EXECUTE format('CREATE TABLE data.%I (
        id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        tenant_id uuid NOT NULL
    )', l_test_table);

    -- Enable RLS
    EXECUTE format('ALTER TABLE data.%I ENABLE ROW LEVEL SECURITY', l_test_table);

    -- Verify FORCE is initially disabled
    SELECT relforcerowsecurity INTO l_force_rls
    FROM pg_class
    WHERE oid = ('data.' || l_test_table)::regclass;

    PERFORM test.ok(NOT l_force_rls, 'FORCE RLS should be disabled by default');

    -- Enable FORCE RLS
    EXECUTE format('ALTER TABLE data.%I FORCE ROW LEVEL SECURITY', l_test_table);

    -- Verify FORCE is enabled
    SELECT relforcerowsecurity INTO l_force_rls
    FROM pg_class
    WHERE oid = ('data.' || l_test_table)::regclass;

    PERFORM test.ok(l_force_rls, 'FORCE RLS should be enabled after ALTER TABLE');

    -- Cleanup
    EXECUTE format('DROP TABLE data.%I', l_test_table);
END;
$$;

-- Test: Create basic RLS policy
CREATE OR REPLACE FUNCTION test.test_rls_013_create_policy()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_rls_013_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_policy_name text;
    l_policy_count integer;
BEGIN
    PERFORM test.set_context('test_rls_013_create_policy');

    -- Create test table with RLS
    EXECUTE format('CREATE TABLE data.%I (
        id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        tenant_id uuid NOT NULL,
        name text NOT NULL
    )', l_test_table);

    EXECUTE format('ALTER TABLE data.%I ENABLE ROW LEVEL SECURITY', l_test_table);

    l_policy_name := l_test_table || '_tenant_policy';

    -- Create policy
    EXECUTE format('CREATE POLICY %I ON data.%I
        FOR ALL
        USING (tenant_id = NULLIF(current_setting(''app.current_tenant_id'', true), '''')::uuid)',
        l_policy_name, l_test_table);

    -- Verify policy exists
    SELECT COUNT(*) INTO l_policy_count
    FROM pg_policies
    WHERE schemaname = 'data'
      AND tablename = l_test_table
      AND policyname = l_policy_name;

    PERFORM test.is(l_policy_count, 1, 'Policy should be created');

    -- Cleanup
    EXECUTE format('DROP TABLE data.%I CASCADE', l_test_table);
END;
$$;

-- Test: Drop RLS policy
CREATE OR REPLACE FUNCTION test.test_rls_014_drop_policy()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_rls_014_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_policy_name text;
    l_policy_count integer;
BEGIN
    PERFORM test.set_context('test_rls_014_drop_policy');

    -- Create test table with RLS and policy
    EXECUTE format('CREATE TABLE data.%I (
        id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        tenant_id uuid NOT NULL
    )', l_test_table);

    EXECUTE format('ALTER TABLE data.%I ENABLE ROW LEVEL SECURITY', l_test_table);

    l_policy_name := l_test_table || '_policy';
    EXECUTE format('CREATE POLICY %I ON data.%I FOR SELECT USING (true)', l_policy_name, l_test_table);

    -- Verify policy exists
    SELECT COUNT(*) INTO l_policy_count
    FROM pg_policies
    WHERE schemaname = 'data' AND tablename = l_test_table;

    PERFORM test.is(l_policy_count, 1, 'Policy should exist before drop');

    -- Drop policy
    EXECUTE format('DROP POLICY %I ON data.%I', l_policy_name, l_test_table);

    -- Verify policy is removed
    SELECT COUNT(*) INTO l_policy_count
    FROM pg_policies
    WHERE schemaname = 'data' AND tablename = l_test_table;

    PERFORM test.is(l_policy_count, 0, 'Policy should be removed after drop');

    -- Cleanup
    EXECUTE format('DROP TABLE data.%I', l_test_table);
END;
$$;

-- Test: RLS configuration verification (no policy state)
CREATE OR REPLACE FUNCTION test.test_rls_015_no_policy_blocks_access()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_rls_015_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_has_rls boolean;
    l_has_force boolean;
    l_policy_count integer;
BEGIN
    PERFORM test.set_context('test_rls_015_no_policy_blocks_access');

    -- Create test table
    EXECUTE format('CREATE TABLE data.%I (
        id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        name text NOT NULL
    )', l_test_table);

    -- Insert data
    EXECUTE format('INSERT INTO data.%I (name) VALUES (''Test'')', l_test_table);

    -- Enable RLS with FORCE
    EXECUTE format('ALTER TABLE data.%I ENABLE ROW LEVEL SECURITY', l_test_table);
    EXECUTE format('ALTER TABLE data.%I FORCE ROW LEVEL SECURITY', l_test_table);

    -- Verify RLS is enabled via pg_class
    SELECT c.relrowsecurity, c.relforcerowsecurity
    INTO l_has_rls, l_has_force
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'data' AND c.relname = l_test_table;

    PERFORM test.ok(l_has_rls AND l_has_force, 'RLS and FORCE RLS should be enabled');

    -- No policies should exist
    SELECT COUNT(*) INTO l_policy_count
    FROM pg_policies
    WHERE schemaname = 'data' AND tablename = l_test_table;

    PERFORM test.is(l_policy_count, 0, 'No policies should exist');

    -- Note: With no policies and FORCE RLS, non-owner roles would see 0 rows
    -- Table owner in same session retains access (PostgreSQL behavior)

    -- Cleanup
    EXECUTE format('DROP TABLE data.%I', l_test_table);
END;
$$;

-- Test: Check RLS status via pg_class
CREATE OR REPLACE FUNCTION test.test_rls_016_check_rls_status()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_rls_016_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_rowsecurity boolean;
    l_forcerowsecurity boolean;
BEGIN
    PERFORM test.set_context('test_rls_016_check_rls_status');

    -- Create test table
    EXECUTE format('CREATE TABLE data.%I (id serial PRIMARY KEY)', l_test_table);

    -- Check initial status via pg_class (relrowsecurity, relforcerowsecurity)
    SELECT c.relrowsecurity, c.relforcerowsecurity
    INTO l_rowsecurity, l_forcerowsecurity
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'data' AND c.relname = l_test_table;

    PERFORM test.ok(NOT l_rowsecurity, 'relrowsecurity should be false initially');
    PERFORM test.ok(NOT l_forcerowsecurity, 'relforcerowsecurity should be false initially');

    -- Enable RLS
    EXECUTE format('ALTER TABLE data.%I ENABLE ROW LEVEL SECURITY', l_test_table);
    EXECUTE format('ALTER TABLE data.%I FORCE ROW LEVEL SECURITY', l_test_table);

    -- Check updated status
    SELECT c.relrowsecurity, c.relforcerowsecurity
    INTO l_rowsecurity, l_forcerowsecurity
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'data' AND c.relname = l_test_table;

    PERFORM test.ok(l_rowsecurity, 'relrowsecurity should be true after enable');
    PERFORM test.ok(l_forcerowsecurity, 'relforcerowsecurity should be true after force');

    -- Cleanup
    EXECUTE format('DROP TABLE data.%I', l_test_table);
END;
$$;

-- ============================================================================
-- RUN TESTS
-- ============================================================================

SELECT test.run_module('rls_01');
CALL test.print_run_summary();
