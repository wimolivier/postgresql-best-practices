-- ============================================================================
-- ROW-LEVEL SECURITY TESTS - PERMISSIVE POLICIES
-- ============================================================================
-- Tests for PERMISSIVE policy creation and configuration.
-- Note: Actual enforcement requires non-owner role testing which is complex.
-- These tests verify policy structure and configuration.
-- Reference: references/row-level-security.md
-- ============================================================================

-- ============================================================================
-- TEST FUNCTIONS
-- ============================================================================

-- Test: Create PERMISSIVE policy for SELECT
CREATE OR REPLACE FUNCTION test.test_rls_020_permissive_select()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_rls_020_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_policy_count integer;
    l_policy_cmd text;
    l_policy_permissive text;
BEGIN
    PERFORM test.set_context('test_rls_020_permissive_select');

    -- Create test table with tenant_id
    EXECUTE format('CREATE TABLE data.%I (
        id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        tenant_id uuid NOT NULL,
        name text NOT NULL
    )', l_test_table);

    -- Enable RLS
    EXECUTE format('ALTER TABLE data.%I ENABLE ROW LEVEL SECURITY', l_test_table);

    -- Create PERMISSIVE policy for tenant isolation
    EXECUTE format('CREATE POLICY tenant_select ON data.%I
        AS PERMISSIVE
        FOR SELECT
        USING (tenant_id = NULLIF(current_setting(''app.current_tenant_id'', true), '''')::uuid)',
        l_test_table);

    -- Verify policy exists
    SELECT COUNT(*) INTO l_policy_count
    FROM pg_policies
    WHERE schemaname = 'data' AND tablename = l_test_table AND policyname = 'tenant_select';

    PERFORM test.is(l_policy_count, 1, 'Policy tenant_select should exist');

    -- Verify policy is PERMISSIVE and for SELECT
    SELECT cmd, permissive INTO l_policy_cmd, l_policy_permissive
    FROM pg_policies
    WHERE schemaname = 'data' AND tablename = l_test_table AND policyname = 'tenant_select';

    PERFORM test.is(l_policy_cmd, 'SELECT', 'Policy should be for SELECT');
    PERFORM test.is(l_policy_permissive, 'PERMISSIVE', 'Policy should be PERMISSIVE');

    -- Cleanup
    EXECUTE format('DROP TABLE data.%I CASCADE', l_test_table);
END;
$$;

-- Test: Multiple PERMISSIVE policies configuration
CREATE OR REPLACE FUNCTION test.test_rls_021_permissive_or_behavior()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_rls_021_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_policy_count integer;
BEGIN
    PERFORM test.set_context('test_rls_021_permissive_or_behavior');

    -- Create test table with owner and public flags
    EXECUTE format('CREATE TABLE data.%I (
        id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        owner_id uuid NOT NULL,
        is_public boolean NOT NULL DEFAULT false,
        title text NOT NULL
    )', l_test_table);

    -- Enable RLS
    EXECUTE format('ALTER TABLE data.%I ENABLE ROW LEVEL SECURITY', l_test_table);

    -- Create two PERMISSIVE policies (will be OR'd in enforcement)
    EXECUTE format('CREATE POLICY owner_access ON data.%I
        AS PERMISSIVE FOR SELECT
        USING (owner_id = NULLIF(current_setting(''app.current_user_id'', true), '''')::uuid)',
        l_test_table);

    EXECUTE format('CREATE POLICY public_access ON data.%I
        AS PERMISSIVE FOR SELECT
        USING (is_public = true)',
        l_test_table);

    -- Verify both policies exist
    SELECT COUNT(*) INTO l_policy_count
    FROM pg_policies
    WHERE schemaname = 'data' AND tablename = l_test_table;

    PERFORM test.is(l_policy_count, 2, 'Should have 2 PERMISSIVE policies');

    -- Verify both are PERMISSIVE
    SELECT COUNT(*) INTO l_policy_count
    FROM pg_policies
    WHERE schemaname = 'data' AND tablename = l_test_table AND permissive = 'PERMISSIVE';

    PERFORM test.is(l_policy_count, 2, 'Both policies should be PERMISSIVE');

    -- Cleanup
    EXECUTE format('DROP TABLE data.%I CASCADE', l_test_table);
END;
$$;

-- Test: PERMISSIVE policy WITH CHECK for INSERT
CREATE OR REPLACE FUNCTION test.test_rls_022_permissive_insert()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_rls_022_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_policy_count integer;
    l_has_with_check boolean;
BEGIN
    PERFORM test.set_context('test_rls_022_permissive_insert');

    -- Create test table
    EXECUTE format('CREATE TABLE data.%I (
        id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        tenant_id uuid NOT NULL,
        name text NOT NULL
    )', l_test_table);

    -- Enable RLS
    EXECUTE format('ALTER TABLE data.%I ENABLE ROW LEVEL SECURITY', l_test_table);

    -- Create policy for INSERT with WITH CHECK
    EXECUTE format('CREATE POLICY tenant_insert ON data.%I
        AS PERMISSIVE
        FOR INSERT
        WITH CHECK (tenant_id = NULLIF(current_setting(''app.current_tenant_id'', true), '''')::uuid)',
        l_test_table);

    -- Verify policy exists
    SELECT COUNT(*) INTO l_policy_count
    FROM pg_policies
    WHERE schemaname = 'data' AND tablename = l_test_table AND policyname = 'tenant_insert';

    PERFORM test.is(l_policy_count, 1, 'INSERT policy should exist');

    -- Verify policy is for INSERT
    SELECT cmd = 'INSERT' INTO l_has_with_check
    FROM pg_policies
    WHERE schemaname = 'data' AND tablename = l_test_table AND policyname = 'tenant_insert';

    PERFORM test.ok(l_has_with_check, 'Policy should be for INSERT');

    -- Cleanup
    EXECUTE format('DROP TABLE data.%I CASCADE', l_test_table);
END;
$$;

-- Test: PERMISSIVE policy for UPDATE
CREATE OR REPLACE FUNCTION test.test_rls_023_permissive_update()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_rls_023_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_policy_cmd text;
BEGIN
    PERFORM test.set_context('test_rls_023_permissive_update');

    -- Create test table
    EXECUTE format('CREATE TABLE data.%I (
        id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        tenant_id uuid NOT NULL,
        name text NOT NULL
    )', l_test_table);

    -- Enable RLS
    EXECUTE format('ALTER TABLE data.%I ENABLE ROW LEVEL SECURITY', l_test_table);

    -- Create policy for UPDATE (needs both USING and WITH CHECK)
    EXECUTE format('CREATE POLICY tenant_update ON data.%I
        AS PERMISSIVE
        FOR UPDATE
        USING (tenant_id = NULLIF(current_setting(''app.current_tenant_id'', true), '''')::uuid)
        WITH CHECK (tenant_id = NULLIF(current_setting(''app.current_tenant_id'', true), '''')::uuid)',
        l_test_table);

    -- Verify policy command
    SELECT cmd INTO l_policy_cmd
    FROM pg_policies
    WHERE schemaname = 'data' AND tablename = l_test_table AND policyname = 'tenant_update';

    PERFORM test.is(l_policy_cmd, 'UPDATE', 'Policy should be for UPDATE');

    -- Cleanup
    EXECUTE format('DROP TABLE data.%I CASCADE', l_test_table);
END;
$$;

-- Test: PERMISSIVE policy for DELETE
CREATE OR REPLACE FUNCTION test.test_rls_024_permissive_delete()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_rls_024_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_policy_cmd text;
BEGIN
    PERFORM test.set_context('test_rls_024_permissive_delete');

    -- Create test table
    EXECUTE format('CREATE TABLE data.%I (
        id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        tenant_id uuid NOT NULL,
        name text NOT NULL
    )', l_test_table);

    -- Enable RLS
    EXECUTE format('ALTER TABLE data.%I ENABLE ROW LEVEL SECURITY', l_test_table);

    -- Create policy for DELETE
    EXECUTE format('CREATE POLICY tenant_delete ON data.%I
        AS PERMISSIVE
        FOR DELETE
        USING (tenant_id = NULLIF(current_setting(''app.current_tenant_id'', true), '''')::uuid)',
        l_test_table);

    -- Verify policy command
    SELECT cmd INTO l_policy_cmd
    FROM pg_policies
    WHERE schemaname = 'data' AND tablename = l_test_table AND policyname = 'tenant_delete';

    PERFORM test.is(l_policy_cmd, 'DELETE', 'Policy should be for DELETE');

    -- Cleanup
    EXECUTE format('DROP TABLE data.%I CASCADE', l_test_table);
END;
$$;

-- Test: PERMISSIVE policy FOR ALL commands
CREATE OR REPLACE FUNCTION test.test_rls_025_permissive_all()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_rls_025_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_policy_cmd text;
BEGIN
    PERFORM test.set_context('test_rls_025_permissive_all');

    -- Create test table
    EXECUTE format('CREATE TABLE data.%I (
        id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        tenant_id uuid NOT NULL,
        name text NOT NULL
    )', l_test_table);

    -- Enable RLS
    EXECUTE format('ALTER TABLE data.%I ENABLE ROW LEVEL SECURITY', l_test_table);

    -- Create policy FOR ALL (applies to SELECT, INSERT, UPDATE, DELETE)
    EXECUTE format('CREATE POLICY tenant_all ON data.%I
        AS PERMISSIVE
        FOR ALL
        USING (tenant_id = NULLIF(current_setting(''app.current_tenant_id'', true), '''')::uuid)
        WITH CHECK (tenant_id = NULLIF(current_setting(''app.current_tenant_id'', true), '''')::uuid)',
        l_test_table);

    -- Verify policy is for ALL
    SELECT cmd INTO l_policy_cmd
    FROM pg_policies
    WHERE schemaname = 'data' AND tablename = l_test_table AND policyname = 'tenant_all';

    PERFORM test.is(l_policy_cmd, 'ALL', 'Policy should be for ALL commands');

    -- Cleanup
    EXECUTE format('DROP TABLE data.%I CASCADE', l_test_table);
END;
$$;

-- ============================================================================
-- RUN TESTS
-- ============================================================================

SELECT test.run_module('rls_02');
CALL test.print_run_summary();
