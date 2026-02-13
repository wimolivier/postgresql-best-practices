-- ============================================================================
-- ROW-LEVEL SECURITY TESTS - PERFORMANCE PATTERNS
-- ============================================================================
-- Tests for RLS performance optimization patterns documented in
-- row-level-security.md §Cache Function Results with Subselect:
-- 1. Subselect wrapper for function caching in policies
-- 2. SECURITY DEFINER helper function for complex access checks
-- Reference: references/row-level-security.md §Cache Function Results
-- ============================================================================

-- ============================================================================
-- TEST FUNCTIONS
-- ============================================================================

-- Test: Policy with subselect-wrapped function call (correct pattern)
CREATE OR REPLACE FUNCTION test.test_rls_050_subselect_policy_config()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_rls_050_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_helper_func text := 'current_tenant_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_policy_qual text;
BEGIN
    PERFORM test.set_context('test_rls_050_subselect_policy_config');

    -- Create helper function that reads session variable
    EXECUTE format($fn$
        CREATE FUNCTION private.%I()
        RETURNS uuid
        LANGUAGE sql
        STABLE
        AS $body$
            SELECT NULLIF(current_setting('app.current_tenant_id', true), '')::uuid;
        $body$
    $fn$, l_helper_func);

    -- Create table
    EXECUTE format('CREATE TABLE data.%I (
        id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        tenant_id uuid NOT NULL,
        name text NOT NULL
    )', l_test_table);

    EXECUTE format('ALTER TABLE data.%I ENABLE ROW LEVEL SECURITY', l_test_table);
    EXECUTE format('ALTER TABLE data.%I FORCE ROW LEVEL SECURITY', l_test_table);

    -- GOOD pattern: subselect wrapper for function caching
    EXECUTE format('CREATE POLICY tenant_iso ON data.%I
        FOR ALL
        USING (tenant_id = (SELECT private.%I()))
        WITH CHECK (tenant_id = (SELECT private.%I()))',
        l_test_table, l_helper_func, l_helper_func);

    -- Verify the policy USING clause contains a subselect pattern
    SELECT qual INTO l_policy_qual
    FROM pg_policies
    WHERE schemaname = 'data' AND tablename = l_test_table AND policyname = 'tenant_iso';

    PERFORM test.is_not_null(l_policy_qual, 'Policy USING clause should exist');
    PERFORM test.matches(l_policy_qual, l_helper_func, 'Policy should reference the helper function');

    -- Clean up
    EXECUTE format('DROP TABLE data.%I CASCADE', l_test_table);
    EXECUTE format('DROP FUNCTION private.%I()', l_helper_func);
END;
$$;

-- Test: SECURITY DEFINER helper function for complex RLS checks
CREATE OR REPLACE FUNCTION test.test_rls_051_security_definer_helper()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_teams_table text := 'test_rls_051_teams_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_members_table text := 'test_rls_051_members_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_helper_func text := 'is_team_member_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_user_id uuid := gen_random_uuid();
    l_team_id uuid := gen_random_uuid();
    l_is_member boolean;
    l_is_definer boolean;
    l_search_path text;
BEGIN
    PERFORM test.set_context('test_rls_051_security_definer_helper');

    -- Create team tables
    EXECUTE format('CREATE TABLE data.%I (
        id uuid PRIMARY KEY,
        name text NOT NULL
    )', l_teams_table);

    EXECUTE format('CREATE TABLE data.%I (
        team_id uuid NOT NULL REFERENCES data.%I(id),
        user_id uuid NOT NULL,
        PRIMARY KEY (team_id, user_id)
    )', l_members_table, l_teams_table);

    -- Insert test data
    EXECUTE format('INSERT INTO data.%I (id, name) VALUES ($1, ''Engineering'')', l_teams_table)
    USING l_team_id;

    EXECUTE format('INSERT INTO data.%I (team_id, user_id) VALUES ($1, $2)', l_members_table)
    USING l_team_id, l_user_id;

    -- Create SECURITY DEFINER helper (as documented in row-level-security.md)
    EXECUTE format($fn$
        CREATE FUNCTION private.%I(in_team_id uuid)
        RETURNS boolean
        LANGUAGE sql
        STABLE
        SECURITY DEFINER
        SET search_path = data, private, pg_temp
        AS $body$
            SELECT EXISTS (
                SELECT 1 FROM %I
                WHERE team_id = in_team_id
                  AND user_id = NULLIF(current_setting('app.current_user_id', true), '')::uuid
            );
        $body$
    $fn$, l_helper_func, l_members_table);

    -- Verify SECURITY DEFINER
    l_is_definer := test.is_security_definer('private', l_helper_func);
    PERFORM test.ok(l_is_definer, 'Helper should be SECURITY DEFINER');

    -- Verify SET search_path
    l_search_path := test.get_function_search_path('private', l_helper_func);
    PERFORM test.is_not_null(l_search_path, 'Helper should have SET search_path');

    -- Test with matching user
    PERFORM set_config('app.current_user_id', l_user_id::text, true);
    EXECUTE format('SELECT private.%I($1)', l_helper_func)
    INTO l_is_member
    USING l_team_id;

    PERFORM test.ok(l_is_member, 'Should return true for team member');

    -- Test with non-matching user
    PERFORM set_config('app.current_user_id', gen_random_uuid()::text, true);
    EXECUTE format('SELECT private.%I($1)', l_helper_func)
    INTO l_is_member
    USING l_team_id;

    PERFORM test.not_ok(l_is_member, 'Should return false for non-member');

    -- Clean up
    PERFORM set_config('app.current_user_id', '', true);
    EXECUTE format('DROP FUNCTION private.%I(uuid)', l_helper_func);
    EXECUTE format('DROP TABLE data.%I CASCADE', l_members_table);
    EXECUTE format('DROP TABLE data.%I CASCADE', l_teams_table);
END;
$$;

-- Test: Helper function used in policy with subselect wrapper
CREATE OR REPLACE FUNCTION test.test_rls_052_helper_in_policy()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_teams_table text := 'test_rls_052_teams_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_members_table text := 'test_rls_052_members_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_orders_table text := 'test_rls_052_orders_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_helper_func text := 'is_team_member_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_policy_qual text;
    l_policy_count integer;
BEGIN
    PERFORM test.set_context('test_rls_052_helper_in_policy');

    -- Create tables
    EXECUTE format('CREATE TABLE data.%I (id uuid PRIMARY KEY, name text NOT NULL)', l_teams_table);
    EXECUTE format('CREATE TABLE data.%I (
        team_id uuid NOT NULL REFERENCES data.%I(id),
        user_id uuid NOT NULL,
        PRIMARY KEY (team_id, user_id)
    )', l_members_table, l_teams_table);
    EXECUTE format('CREATE TABLE data.%I (
        id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        team_id uuid NOT NULL REFERENCES data.%I(id),
        total numeric(12,2) NOT NULL
    )', l_orders_table, l_teams_table);

    -- Create helper function
    EXECUTE format($fn$
        CREATE FUNCTION private.%I(in_team_id uuid)
        RETURNS boolean
        LANGUAGE sql
        STABLE
        SECURITY DEFINER
        SET search_path = data, private, pg_temp
        AS $body$
            SELECT EXISTS (
                SELECT 1 FROM %I
                WHERE team_id = in_team_id
                  AND user_id = NULLIF(current_setting('app.current_user_id', true), '')::uuid
            );
        $body$
    $fn$, l_helper_func, l_members_table);

    -- Enable RLS
    EXECUTE format('ALTER TABLE data.%I ENABLE ROW LEVEL SECURITY', l_orders_table);
    EXECUTE format('ALTER TABLE data.%I FORCE ROW LEVEL SECURITY', l_orders_table);

    -- Create policy with subselect-wrapped helper (recommended pattern)
    EXECUTE format('CREATE POLICY team_orders ON data.%I
        FOR SELECT
        USING ((SELECT private.%I(team_id)))',
        l_orders_table, l_helper_func);

    -- Verify policy exists
    SELECT COUNT(*) INTO l_policy_count
    FROM pg_policies
    WHERE schemaname = 'data' AND tablename = l_orders_table AND policyname = 'team_orders';

    PERFORM test.is(l_policy_count, 1, 'team_orders policy should exist');

    -- Verify policy references helper function
    SELECT qual INTO l_policy_qual
    FROM pg_policies
    WHERE schemaname = 'data' AND tablename = l_orders_table AND policyname = 'team_orders';

    PERFORM test.is_not_null(l_policy_qual, 'Policy should have USING clause');
    PERFORM test.matches(l_policy_qual, l_helper_func, 'Policy should reference helper function');

    -- Clean up
    EXECUTE format('DROP TABLE data.%I CASCADE', l_orders_table);
    EXECUTE format('DROP TABLE data.%I CASCADE', l_members_table);
    EXECUTE format('DROP TABLE data.%I CASCADE', l_teams_table);
    EXECUTE format('DROP FUNCTION private.%I(uuid)', l_helper_func);
END;
$$;

-- Test: Stable volatility is required for RLS helper functions
CREATE OR REPLACE FUNCTION test.test_rls_053_helper_volatility()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_helper_func text := 'test_vol_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_volatility text;
BEGIN
    PERFORM test.set_context('test_rls_053_helper_volatility');

    -- Create STABLE helper (correct for RLS caching)
    EXECUTE format($fn$
        CREATE FUNCTION private.%I()
        RETURNS uuid
        LANGUAGE sql
        STABLE
        AS $body$
            SELECT NULLIF(current_setting('app.current_tenant_id', true), '')::uuid;
        $body$
    $fn$, l_helper_func);

    -- Verify volatility is STABLE
    SELECT p.provolatile INTO l_volatility
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'private' AND p.proname = l_helper_func;

    PERFORM test.is(l_volatility, 's', 'RLS helper should be STABLE for plan caching');

    -- Clean up
    EXECUTE format('DROP FUNCTION private.%I()', l_helper_func);
END;
$$;

-- ============================================================================
-- RUN TESTS
-- ============================================================================

SELECT test.run_module('rls_05');
CALL test.print_run_summary();
