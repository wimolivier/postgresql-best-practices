-- ============================================================================
-- ROW-LEVEL SECURITY TESTS - RESTRICTIVE POLICIES
-- ============================================================================
-- Tests for RESTRICTIVE policy creation and configuration.
-- RESTRICTIVE policies are AND'd with PERMISSIVE policies.
-- Note: Actual enforcement requires non-owner role testing.
-- Reference: references/row-level-security.md
-- ============================================================================

-- ============================================================================
-- TEST FUNCTIONS
-- ============================================================================

-- Test: RESTRICTIVE policy combined with PERMISSIVE
CREATE OR REPLACE FUNCTION test.test_rls_030_restrictive_and_behavior()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_rls_030_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_permissive_count integer;
    l_restrictive_count integer;
BEGIN
    PERFORM test.set_context('test_rls_030_restrictive_and_behavior');

    -- Create test table
    EXECUTE format('CREATE TABLE data.%I (
        id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        tenant_id uuid NOT NULL,
        is_active boolean NOT NULL DEFAULT true,
        name text NOT NULL
    )', l_test_table);

    -- Enable RLS
    EXECUTE format('ALTER TABLE data.%I ENABLE ROW LEVEL SECURITY', l_test_table);

    -- Create PERMISSIVE policy for tenant
    EXECUTE format('CREATE POLICY tenant_access ON data.%I
        AS PERMISSIVE FOR SELECT
        USING (tenant_id = NULLIF(current_setting(''app.current_tenant_id'', true), '''')::uuid)',
        l_test_table);

    -- Create RESTRICTIVE policy for active only
    EXECUTE format('CREATE POLICY active_only ON data.%I
        AS RESTRICTIVE FOR SELECT
        USING (is_active = true)',
        l_test_table);

    -- Verify policy counts
    SELECT COUNT(*) INTO l_permissive_count
    FROM pg_policies
    WHERE schemaname = 'data' AND tablename = l_test_table AND permissive = 'PERMISSIVE';

    SELECT COUNT(*) INTO l_restrictive_count
    FROM pg_policies
    WHERE schemaname = 'data' AND tablename = l_test_table AND permissive = 'RESTRICTIVE';

    PERFORM test.is(l_permissive_count, 1, 'Should have 1 PERMISSIVE policy');
    PERFORM test.is(l_restrictive_count, 1, 'Should have 1 RESTRICTIVE policy');

    -- Cleanup
    EXECUTE format('DROP TABLE data.%I CASCADE', l_test_table);
END;
$$;

-- Test: Multiple RESTRICTIVE policies (all AND'd)
CREATE OR REPLACE FUNCTION test.test_rls_031_multiple_restrictive()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_rls_031_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_restrictive_count integer;
BEGIN
    PERFORM test.set_context('test_rls_031_multiple_restrictive');

    -- Create test table
    EXECUTE format('CREATE TABLE data.%I (
        id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        tenant_id uuid NOT NULL,
        is_active boolean NOT NULL DEFAULT true,
        is_approved boolean NOT NULL DEFAULT false,
        name text NOT NULL
    )', l_test_table);

    -- Enable RLS
    EXECUTE format('ALTER TABLE data.%I ENABLE ROW LEVEL SECURITY', l_test_table);

    -- Create PERMISSIVE base policy
    EXECUTE format('CREATE POLICY tenant_access ON data.%I
        AS PERMISSIVE FOR SELECT
        USING (tenant_id = NULLIF(current_setting(''app.current_tenant_id'', true), '''')::uuid)',
        l_test_table);

    -- Create multiple RESTRICTIVE policies (all must pass)
    EXECUTE format('CREATE POLICY active_only ON data.%I
        AS RESTRICTIVE FOR SELECT
        USING (is_active = true)',
        l_test_table);

    EXECUTE format('CREATE POLICY approved_only ON data.%I
        AS RESTRICTIVE FOR SELECT
        USING (is_approved = true)',
        l_test_table);

    -- Verify restrictive count
    SELECT COUNT(*) INTO l_restrictive_count
    FROM pg_policies
    WHERE schemaname = 'data' AND tablename = l_test_table AND permissive = 'RESTRICTIVE';

    PERFORM test.is(l_restrictive_count, 2, 'Should have 2 RESTRICTIVE policies');

    -- Cleanup
    EXECUTE format('DROP TABLE data.%I CASCADE', l_test_table);
END;
$$;

-- Test: RESTRICTIVE only (without PERMISSIVE) blocks all
CREATE OR REPLACE FUNCTION test.test_rls_032_restrictive_only()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_rls_032_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_permissive text;
BEGIN
    PERFORM test.set_context('test_rls_032_restrictive_only');

    -- Create test table
    EXECUTE format('CREATE TABLE data.%I (
        id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        name text NOT NULL
    )', l_test_table);

    -- Enable RLS
    EXECUTE format('ALTER TABLE data.%I ENABLE ROW LEVEL SECURITY', l_test_table);

    -- Create only RESTRICTIVE policy (no PERMISSIVE)
    EXECUTE format('CREATE POLICY restrictive_only ON data.%I
        AS RESTRICTIVE FOR SELECT
        USING (true)',
        l_test_table);

    -- Verify only restrictive exists
    SELECT permissive INTO l_permissive
    FROM pg_policies
    WHERE schemaname = 'data' AND tablename = l_test_table;

    PERFORM test.is(l_permissive, 'RESTRICTIVE', 'Only policy should be RESTRICTIVE');

    -- Cleanup
    EXECUTE format('DROP TABLE data.%I CASCADE', l_test_table);
END;
$$;

-- Test: Verify RESTRICTIVE policy type in pg_policies
CREATE OR REPLACE FUNCTION test.test_rls_033_restrictive_type()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_rls_033_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_permissive_value text;
BEGIN
    PERFORM test.set_context('test_rls_033_restrictive_type');

    -- Create test table
    EXECUTE format('CREATE TABLE data.%I (
        id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        name text NOT NULL
    )', l_test_table);

    -- Enable RLS
    EXECUTE format('ALTER TABLE data.%I ENABLE ROW LEVEL SECURITY', l_test_table);

    -- Create RESTRICTIVE policy
    EXECUTE format('CREATE POLICY test_restrictive ON data.%I
        AS RESTRICTIVE FOR SELECT
        USING (true)',
        l_test_table);

    -- Verify permissive column value
    SELECT permissive INTO l_permissive_value
    FROM pg_policies
    WHERE schemaname = 'data' AND tablename = l_test_table AND policyname = 'test_restrictive';

    PERFORM test.is(l_permissive_value, 'RESTRICTIVE', 'pg_policies.permissive should be RESTRICTIVE');

    -- Cleanup
    EXECUTE format('DROP TABLE data.%I CASCADE', l_test_table);
END;
$$;

-- Test: RESTRICTIVE policy for UPDATE
CREATE OR REPLACE FUNCTION test.test_rls_034_restrictive_update()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_rls_034_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_policy_cmd text;
BEGIN
    PERFORM test.set_context('test_rls_034_restrictive_update');

    -- Create test table
    EXECUTE format('CREATE TABLE data.%I (
        id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        is_locked boolean NOT NULL DEFAULT false,
        name text NOT NULL
    )', l_test_table);

    -- Enable RLS
    EXECUTE format('ALTER TABLE data.%I ENABLE ROW LEVEL SECURITY', l_test_table);

    -- PERMISSIVE base policy
    EXECUTE format('CREATE POLICY all_access ON data.%I
        AS PERMISSIVE FOR ALL
        USING (true) WITH CHECK (true)',
        l_test_table);

    -- RESTRICTIVE policy to prevent updating locked rows
    EXECUTE format('CREATE POLICY no_locked_update ON data.%I
        AS RESTRICTIVE FOR UPDATE
        USING (is_locked = false)',
        l_test_table);

    -- Verify policy command
    SELECT cmd INTO l_policy_cmd
    FROM pg_policies
    WHERE schemaname = 'data' AND tablename = l_test_table AND policyname = 'no_locked_update';

    PERFORM test.is(l_policy_cmd, 'UPDATE', 'RESTRICTIVE policy should be for UPDATE');

    -- Cleanup
    EXECUTE format('DROP TABLE data.%I CASCADE', l_test_table);
END;
$$;

-- Test: Complex PERMISSIVE + RESTRICTIVE combination
CREATE OR REPLACE FUNCTION test.test_rls_035_complex_permissive_restrictive()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_rls_035_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_total_policies integer;
    l_permissive_count integer;
    l_restrictive_count integer;
BEGIN
    PERFORM test.set_context('test_rls_035_complex_permissive_restrictive');

    -- Create test table
    EXECUTE format('CREATE TABLE data.%I (
        id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        owner_id uuid NOT NULL,
        is_public boolean NOT NULL DEFAULT false,
        is_active boolean NOT NULL DEFAULT true,
        name text NOT NULL
    )', l_test_table);

    -- Enable RLS
    EXECUTE format('ALTER TABLE data.%I ENABLE ROW LEVEL SECURITY', l_test_table);

    -- Multiple PERMISSIVE policies (OR'd)
    EXECUTE format('CREATE POLICY owner_access ON data.%I
        AS PERMISSIVE FOR SELECT
        USING (owner_id = NULLIF(current_setting(''app.current_user_id'', true), '''')::uuid)',
        l_test_table);

    EXECUTE format('CREATE POLICY public_access ON data.%I
        AS PERMISSIVE FOR SELECT
        USING (is_public = true)',
        l_test_table);

    -- RESTRICTIVE policy (AND'd with PERMISSIVE result)
    EXECUTE format('CREATE POLICY active_only ON data.%I
        AS RESTRICTIVE FOR SELECT
        USING (is_active = true)',
        l_test_table);

    -- Verify counts
    SELECT COUNT(*) INTO l_total_policies
    FROM pg_policies WHERE schemaname = 'data' AND tablename = l_test_table;

    SELECT COUNT(*) INTO l_permissive_count
    FROM pg_policies WHERE schemaname = 'data' AND tablename = l_test_table AND permissive = 'PERMISSIVE';

    SELECT COUNT(*) INTO l_restrictive_count
    FROM pg_policies WHERE schemaname = 'data' AND tablename = l_test_table AND permissive = 'RESTRICTIVE';

    PERFORM test.is(l_total_policies, 3, 'Should have 3 total policies');
    PERFORM test.is(l_permissive_count, 2, 'Should have 2 PERMISSIVE policies');
    PERFORM test.is(l_restrictive_count, 1, 'Should have 1 RESTRICTIVE policy');

    -- Cleanup
    EXECUTE format('DROP TABLE data.%I CASCADE', l_test_table);
END;
$$;

-- ============================================================================
-- RUN TESTS
-- ============================================================================

SELECT test.run_module('rls_03');
CALL test.print_run_summary();
