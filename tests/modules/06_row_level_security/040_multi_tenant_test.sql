-- ============================================================================
-- ROW-LEVEL SECURITY TESTS - MULTI-TENANT PATTERNS
-- ============================================================================
-- Tests for multi-tenant RLS policy configuration and session variable patterns.
-- Note: Actual enforcement requires non-owner role testing.
-- Reference: references/row-level-security.md
-- ============================================================================

-- ============================================================================
-- TEST FUNCTIONS
-- ============================================================================

-- Test: Session variable-based tenant context
CREATE OR REPLACE FUNCTION test.test_rls_040_session_tenant_context()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_tenant_id uuid := gen_random_uuid();
    l_retrieved_tenant uuid;
BEGIN
    PERFORM test.set_context('test_rls_040_session_tenant_context');

    -- Set tenant via session variable
    PERFORM set_config('app.current_tenant_id', l_tenant_id::text, true);

    -- Retrieve and verify
    l_retrieved_tenant := NULLIF(current_setting('app.current_tenant_id', true), '')::uuid;

    PERFORM test.is(l_retrieved_tenant, l_tenant_id, 'Should retrieve correct tenant_id from session');

    -- Clear tenant
    PERFORM set_config('app.current_tenant_id', '', true);

    l_retrieved_tenant := NULLIF(current_setting('app.current_tenant_id', true), '')::uuid;

    PERFORM test.is_null(l_retrieved_tenant, 'Should return NULL when tenant cleared');
END;
$$;

-- Test: Multi-tenant table RLS configuration
CREATE OR REPLACE FUNCTION test.test_rls_041_multi_tenant_config()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_rls_041_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_rowsecurity boolean;
    l_forcerowsecurity boolean;
    l_policy_count integer;
    l_policy_cmd text;
    l_has_index boolean;
BEGIN
    PERFORM test.set_context('test_rls_041_multi_tenant_config');

    -- Create multi-tenant table
    EXECUTE format('CREATE TABLE data.%I (
        id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        tenant_id uuid NOT NULL,
        name text NOT NULL,
        created_at timestamptz NOT NULL DEFAULT now()
    )', l_test_table);

    -- Create index on tenant_id (critical for RLS performance)
    EXECUTE format('CREATE INDEX %I ON data.%I(tenant_id)', l_test_table || '_tenant_idx', l_test_table);

    -- Enable RLS with FORCE
    EXECUTE format('ALTER TABLE data.%I ENABLE ROW LEVEL SECURITY', l_test_table);
    EXECUTE format('ALTER TABLE data.%I FORCE ROW LEVEL SECURITY', l_test_table);

    -- Create tenant isolation policy
    EXECUTE format('CREATE POLICY tenant_isolation ON data.%I
        FOR ALL
        USING (tenant_id = NULLIF(current_setting(''app.current_tenant_id'', true), '''')::uuid)
        WITH CHECK (tenant_id = NULLIF(current_setting(''app.current_tenant_id'', true), '''')::uuid)',
        l_test_table);

    -- Verify RLS settings
    SELECT c.relrowsecurity, c.relforcerowsecurity
    INTO l_rowsecurity, l_forcerowsecurity
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'data' AND c.relname = l_test_table;

    PERFORM test.ok(l_rowsecurity, 'RLS should be enabled');
    PERFORM test.ok(l_forcerowsecurity, 'FORCE RLS should be enabled');

    -- Verify policy exists
    SELECT COUNT(*) INTO l_policy_count
    FROM pg_policies
    WHERE schemaname = 'data' AND tablename = l_test_table AND policyname = 'tenant_isolation';

    PERFORM test.is(l_policy_count, 1, 'tenant_isolation policy should exist');

    -- Verify policy is FOR ALL
    SELECT cmd INTO l_policy_cmd
    FROM pg_policies
    WHERE schemaname = 'data' AND tablename = l_test_table AND policyname = 'tenant_isolation';

    PERFORM test.is(l_policy_cmd, 'ALL', 'Policy should be FOR ALL commands');

    -- Verify tenant_id index exists
    SELECT EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE schemaname = 'data' AND tablename = l_test_table AND indexname = l_test_table || '_tenant_idx'
    ) INTO l_has_index;

    PERFORM test.ok(l_has_index, 'Index on tenant_id should exist for RLS performance');

    -- Cleanup
    EXECUTE format('DROP TABLE data.%I CASCADE', l_test_table);
END;
$$;

-- Test: WITH CHECK clause configuration for INSERT protection
CREATE OR REPLACE FUNCTION test.test_rls_042_with_check_config()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_rls_042_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_with_check text;
BEGIN
    PERFORM test.set_context('test_rls_042_with_check_config');

    -- Create multi-tenant table
    EXECUTE format('CREATE TABLE data.%I (
        id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        tenant_id uuid NOT NULL,
        name text NOT NULL
    )', l_test_table);

    -- Enable RLS with FORCE
    EXECUTE format('ALTER TABLE data.%I ENABLE ROW LEVEL SECURITY', l_test_table);
    EXECUTE format('ALTER TABLE data.%I FORCE ROW LEVEL SECURITY', l_test_table);

    -- Create tenant policy with WITH CHECK
    EXECUTE format('CREATE POLICY tenant_policy ON data.%I
        FOR ALL
        USING (tenant_id = NULLIF(current_setting(''app.current_tenant_id'', true), '''')::uuid)
        WITH CHECK (tenant_id = NULLIF(current_setting(''app.current_tenant_id'', true), '''')::uuid)',
        l_test_table);

    -- Verify WITH CHECK clause exists
    SELECT with_check INTO l_with_check
    FROM pg_policies
    WHERE schemaname = 'data' AND tablename = l_test_table AND policyname = 'tenant_policy';

    PERFORM test.is_not_null(l_with_check, 'WITH CHECK clause should be defined');
    PERFORM test.matches(l_with_check, 'tenant_id', 'WITH CHECK should reference tenant_id');
    PERFORM test.matches(l_with_check, 'app.current_tenant_id', 'WITH CHECK should reference session variable');

    -- Cleanup
    EXECUTE format('DROP TABLE data.%I CASCADE', l_test_table);
END;
$$;

-- Test: Separate SELECT and DML policies
CREATE OR REPLACE FUNCTION test.test_rls_043_separate_policies()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_rls_043_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_policy_count integer;
    l_select_policy_exists boolean;
    l_insert_policy_exists boolean;
    l_update_policy_exists boolean;
    l_delete_policy_exists boolean;
BEGIN
    PERFORM test.set_context('test_rls_043_separate_policies');

    -- Create multi-tenant table
    EXECUTE format('CREATE TABLE data.%I (
        id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        tenant_id uuid NOT NULL,
        name text NOT NULL
    )', l_test_table);

    -- Enable RLS
    EXECUTE format('ALTER TABLE data.%I ENABLE ROW LEVEL SECURITY', l_test_table);
    EXECUTE format('ALTER TABLE data.%I FORCE ROW LEVEL SECURITY', l_test_table);

    -- Create separate policies for each operation
    EXECUTE format('CREATE POLICY tenant_select ON data.%I
        FOR SELECT
        USING (tenant_id = NULLIF(current_setting(''app.current_tenant_id'', true), '''')::uuid)',
        l_test_table);

    EXECUTE format('CREATE POLICY tenant_insert ON data.%I
        FOR INSERT
        WITH CHECK (tenant_id = NULLIF(current_setting(''app.current_tenant_id'', true), '''')::uuid)',
        l_test_table);

    EXECUTE format('CREATE POLICY tenant_update ON data.%I
        FOR UPDATE
        USING (tenant_id = NULLIF(current_setting(''app.current_tenant_id'', true), '''')::uuid)
        WITH CHECK (tenant_id = NULLIF(current_setting(''app.current_tenant_id'', true), '''')::uuid)',
        l_test_table);

    EXECUTE format('CREATE POLICY tenant_delete ON data.%I
        FOR DELETE
        USING (tenant_id = NULLIF(current_setting(''app.current_tenant_id'', true), '''')::uuid)',
        l_test_table);

    -- Count total policies
    SELECT COUNT(*) INTO l_policy_count
    FROM pg_policies
    WHERE schemaname = 'data' AND tablename = l_test_table;

    PERFORM test.is(l_policy_count, 4, 'Should have 4 separate policies');

    -- Verify each policy exists with correct command
    SELECT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'data' AND tablename = l_test_table AND cmd = 'SELECT') INTO l_select_policy_exists;
    SELECT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'data' AND tablename = l_test_table AND cmd = 'INSERT') INTO l_insert_policy_exists;
    SELECT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'data' AND tablename = l_test_table AND cmd = 'UPDATE') INTO l_update_policy_exists;
    SELECT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'data' AND tablename = l_test_table AND cmd = 'DELETE') INTO l_delete_policy_exists;

    PERFORM test.ok(l_select_policy_exists, 'SELECT policy should exist');
    PERFORM test.ok(l_insert_policy_exists, 'INSERT policy should exist');
    PERFORM test.ok(l_update_policy_exists, 'UPDATE policy should exist');
    PERFORM test.ok(l_delete_policy_exists, 'DELETE policy should exist');

    -- Cleanup
    EXECUTE format('DROP TABLE data.%I CASCADE', l_test_table);
END;
$$;

-- Test: Helper function for setting tenant context
CREATE OR REPLACE FUNCTION test.test_rls_044_tenant_context_function()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_func text := 'test_set_tenant_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_tenant_id uuid := gen_random_uuid();
    l_retrieved_tenant uuid;
BEGIN
    PERFORM test.set_context('test_rls_044_tenant_context_function');

    -- Create helper function (as documented in references/row-level-security.md)
    EXECUTE format('CREATE OR REPLACE FUNCTION private.%I(in_tenant_id uuid)
        RETURNS void
        LANGUAGE plpgsql
        AS $func$
        BEGIN
            PERFORM set_config(''app.current_tenant_id'', in_tenant_id::text, false);
        END;
        $func$', l_test_func);

    -- Use the helper function
    EXECUTE format('SELECT private.%I(%L)', l_test_func, l_tenant_id);

    -- Verify tenant is set
    l_retrieved_tenant := NULLIF(current_setting('app.current_tenant_id', true), '')::uuid;
    PERFORM test.is(l_retrieved_tenant, l_tenant_id, 'Helper function should set tenant_id');

    -- Cleanup
    EXECUTE format('DROP FUNCTION private.%I(uuid)', l_test_func);
    PERFORM set_config('app.current_tenant_id', '', false);
END;
$$;

-- Test: RLS policy referencing helper function
CREATE OR REPLACE FUNCTION test.test_rls_045_policy_with_helper_function()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_rls_045_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_helper_func text := 'current_tenant_id_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_policy_qual text;
BEGIN
    PERFORM test.set_context('test_rls_045_policy_with_helper_function');

    -- Create helper function to get current tenant
    EXECUTE format('CREATE OR REPLACE FUNCTION private.%I()
        RETURNS uuid
        LANGUAGE sql
        STABLE
        AS $func$
            SELECT NULLIF(current_setting(''app.current_tenant_id'', true), '''')::uuid;
        $func$', l_helper_func);

    -- Create multi-tenant table
    EXECUTE format('CREATE TABLE data.%I (
        id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        tenant_id uuid NOT NULL,
        name text NOT NULL
    )', l_test_table);

    -- Enable RLS with FORCE
    EXECUTE format('ALTER TABLE data.%I ENABLE ROW LEVEL SECURITY', l_test_table);
    EXECUTE format('ALTER TABLE data.%I FORCE ROW LEVEL SECURITY', l_test_table);

    -- Create policy using helper function
    EXECUTE format('CREATE POLICY tenant_policy ON data.%I
        FOR ALL
        USING (tenant_id = private.%I())
        WITH CHECK (tenant_id = private.%I())',
        l_test_table, l_helper_func, l_helper_func);

    -- Verify policy references the helper function
    SELECT qual INTO l_policy_qual
    FROM pg_policies
    WHERE schemaname = 'data' AND tablename = l_test_table AND policyname = 'tenant_policy';

    PERFORM test.is_not_null(l_policy_qual, 'Policy USING clause should exist');
    PERFORM test.matches(l_policy_qual, l_helper_func, 'Policy should reference helper function');

    -- Cleanup
    EXECUTE format('DROP TABLE data.%I CASCADE', l_test_table);
    EXECUTE format('DROP FUNCTION private.%I()', l_helper_func);
END;
$$;

-- Test: User-specific access pattern configuration
CREATE OR REPLACE FUNCTION test.test_rls_046_user_specific_config()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_rls_046_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_policy_qual text;
BEGIN
    PERFORM test.set_context('test_rls_046_user_specific_config');

    -- Create user-owned documents table
    EXECUTE format('CREATE TABLE data.%I (
        id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        owner_id uuid NOT NULL,
        title text NOT NULL
    )', l_test_table);

    -- Enable RLS with FORCE
    EXECUTE format('ALTER TABLE data.%I ENABLE ROW LEVEL SECURITY', l_test_table);
    EXECUTE format('ALTER TABLE data.%I FORCE ROW LEVEL SECURITY', l_test_table);

    -- Create owner policy
    EXECUTE format('CREATE POLICY owner_all ON data.%I
        FOR ALL
        USING (owner_id = NULLIF(current_setting(''app.current_user_id'', true), '''')::uuid)
        WITH CHECK (owner_id = NULLIF(current_setting(''app.current_user_id'', true), '''')::uuid)',
        l_test_table);

    -- Verify policy uses owner_id and user session variable
    SELECT qual INTO l_policy_qual
    FROM pg_policies
    WHERE schemaname = 'data' AND tablename = l_test_table AND policyname = 'owner_all';

    PERFORM test.matches(l_policy_qual, 'owner_id', 'Policy should reference owner_id column');
    PERFORM test.matches(l_policy_qual, 'app.current_user_id', 'Policy should reference user session variable');

    -- Cleanup
    EXECUTE format('DROP TABLE data.%I CASCADE', l_test_table);
END;
$$;

-- Test: Combined tenant and user isolation (PERMISSIVE + RESTRICTIVE)
CREATE OR REPLACE FUNCTION test.test_rls_047_tenant_plus_user_config()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_rls_047_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_permissive_count integer;
    l_restrictive_count integer;
    l_tenant_policy_permissive text;
    l_user_policy_permissive text;
BEGIN
    PERFORM test.set_context('test_rls_047_tenant_plus_user_config');

    -- Create table with both tenant and user ownership
    EXECUTE format('CREATE TABLE data.%I (
        id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        tenant_id uuid NOT NULL,
        created_by uuid NOT NULL,
        title text NOT NULL
    )', l_test_table);

    -- Enable RLS with FORCE
    EXECUTE format('ALTER TABLE data.%I ENABLE ROW LEVEL SECURITY', l_test_table);
    EXECUTE format('ALTER TABLE data.%I FORCE ROW LEVEL SECURITY', l_test_table);

    -- PERMISSIVE: tenant isolation (OR'd with other PERMISSIVE policies)
    EXECUTE format('CREATE POLICY tenant_access ON data.%I
        AS PERMISSIVE FOR SELECT
        USING (tenant_id = NULLIF(current_setting(''app.current_tenant_id'', true), '''')::uuid)',
        l_test_table);

    -- RESTRICTIVE: only own records (AND'd with PERMISSIVE result)
    EXECUTE format('CREATE POLICY user_own ON data.%I
        AS RESTRICTIVE FOR SELECT
        USING (created_by = NULLIF(current_setting(''app.current_user_id'', true), '''')::uuid)',
        l_test_table);

    -- Verify policy types
    SELECT permissive INTO l_tenant_policy_permissive
    FROM pg_policies
    WHERE schemaname = 'data' AND tablename = l_test_table AND policyname = 'tenant_access';

    SELECT permissive INTO l_user_policy_permissive
    FROM pg_policies
    WHERE schemaname = 'data' AND tablename = l_test_table AND policyname = 'user_own';

    PERFORM test.is(l_tenant_policy_permissive, 'PERMISSIVE', 'Tenant policy should be PERMISSIVE');
    PERFORM test.is(l_user_policy_permissive, 'RESTRICTIVE', 'User policy should be RESTRICTIVE');

    -- Count by type
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

-- Test: Session variable persistence within transaction
CREATE OR REPLACE FUNCTION test.test_rls_048_session_variable_transaction()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_tenant_id uuid := gen_random_uuid();
    l_retrieved_before uuid;
    l_retrieved_after uuid;
BEGIN
    PERFORM test.set_context('test_rls_048_session_variable_transaction');

    -- Set tenant with local=true (transaction-scoped)
    PERFORM set_config('app.current_tenant_id', l_tenant_id::text, true);

    l_retrieved_before := NULLIF(current_setting('app.current_tenant_id', true), '')::uuid;
    PERFORM test.is(l_retrieved_before, l_tenant_id, 'Tenant should be set within transaction');

    -- Start a savepoint and verify tenant persists
    BEGIN
        l_retrieved_after := NULLIF(current_setting('app.current_tenant_id', true), '')::uuid;
        PERFORM test.is(l_retrieved_after, l_tenant_id, 'Tenant should persist within nested block');
    END;

    -- Clear for other tests
    PERFORM set_config('app.current_tenant_id', '', true);
END;
$$;

-- ============================================================================
-- RUN TESTS
-- ============================================================================

SELECT test.run_module('rls_04');
CALL test.print_run_summary();
