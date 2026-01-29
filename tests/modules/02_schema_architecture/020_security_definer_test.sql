-- ============================================================================
-- SCHEMA ARCHITECTURE TESTS - SECURITY DEFINER
-- ============================================================================
-- Tests for SECURITY DEFINER functions with SET search_path.
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

-- Test: API function should be SECURITY DEFINER
CREATE OR REPLACE FUNCTION test.test_security_020_definer_required()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_func text := 'test_sec_' || to_char(clock_timestamp(), 'HH24MISS');
    l_is_definer boolean;
BEGIN
    PERFORM test.set_context('test_security_020_definer_required');

    -- Create function with SECURITY DEFINER
    EXECUTE format($fn$
        CREATE FUNCTION api.%I()
        RETURNS text
        LANGUAGE sql
        STABLE
        SECURITY DEFINER
        SET search_path = data, private, pg_temp
        AS $$ SELECT 'test'::text $$
    $fn$, l_test_func);

    -- Check it's SECURITY DEFINER
    SELECT p.prosecdef INTO l_is_definer
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'api' AND p.proname = l_test_func;

    PERFORM test.ok(l_is_definer, 'API function should be SECURITY DEFINER');

    -- Clean up
    EXECUTE format('DROP FUNCTION api.%I()', l_test_func);
END;
$$;

-- Test: SECURITY DEFINER must have SET search_path
CREATE OR REPLACE FUNCTION test.test_security_021_search_path_required()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_func text := 'test_path_' || to_char(clock_timestamp(), 'HH24MISS');
    l_search_path text;
BEGIN
    PERFORM test.set_context('test_security_021_search_path_required');

    -- Create function with SET search_path
    EXECUTE format($fn$
        CREATE FUNCTION api.%I()
        RETURNS text
        LANGUAGE sql
        STABLE
        SECURITY DEFINER
        SET search_path = data, private, pg_temp
        AS $$ SELECT 'test'::text $$
    $fn$, l_test_func);

    -- Get search_path setting
    SELECT unnest(p.proconfig)
    INTO l_search_path
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'api' AND p.proname = l_test_func
      AND unnest(p.proconfig) LIKE 'search_path=%';

    PERFORM test.is_not_null(l_search_path, 'SECURITY DEFINER function should have SET search_path');
    PERFORM test.matches(l_search_path, 'data', 'search_path should include data schema');

    -- Clean up
    EXECUTE format('DROP FUNCTION api.%I()', l_test_func);
END;
$$;

-- Test: search_path should include pg_temp for safety
CREATE OR REPLACE FUNCTION test.test_security_022_pg_temp_in_path()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_func text := 'test_temp_' || to_char(clock_timestamp(), 'HH24MISS');
    l_search_path text;
BEGIN
    PERFORM test.set_context('test_security_022_pg_temp_in_path');

    -- Create function with pg_temp in search_path
    EXECUTE format($fn$
        CREATE FUNCTION api.%I()
        RETURNS text
        LANGUAGE sql
        STABLE
        SECURITY DEFINER
        SET search_path = data, private, pg_temp
        AS $$ SELECT 'test'::text $$
    $fn$, l_test_func);

    -- Get search_path
    SELECT unnest(p.proconfig)
    INTO l_search_path
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'api' AND p.proname = l_test_func
      AND unnest(p.proconfig) LIKE 'search_path=%';

    PERFORM test.matches(l_search_path, 'pg_temp', 'search_path should include pg_temp');

    -- Clean up
    EXECUTE format('DROP FUNCTION api.%I()', l_test_func);
END;
$$;

-- Test: is_secure_function helper validates correctly
CREATE OR REPLACE FUNCTION test.test_security_023_is_secure_helper()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_secure_func text := 'test_secure_' || to_char(clock_timestamp(), 'HH24MISS');
    l_insecure_func text := 'test_insecure_' || to_char(clock_timestamp(), 'HH24MISS');
BEGIN
    PERFORM test.set_context('test_security_023_is_secure_helper');

    -- Create secure function
    EXECUTE format($fn$
        CREATE FUNCTION api.%I()
        RETURNS text
        LANGUAGE sql
        STABLE
        SECURITY DEFINER
        SET search_path = data, private, pg_temp
        AS $$ SELECT 'secure'::text $$
    $fn$, l_secure_func);

    -- Create insecure function (SECURITY INVOKER, no search_path)
    EXECUTE format($fn$
        CREATE FUNCTION api.%I()
        RETURNS text
        LANGUAGE sql
        STABLE
        AS $$ SELECT 'insecure'::text $$
    $fn$, l_insecure_func);

    -- Secure function should pass
    PERFORM test.ok(
        test.is_security_definer('api', l_secure_func),
        'secure function should be SECURITY DEFINER'
    );

    -- Insecure function should fail
    PERFORM test.not_ok(
        test.is_security_definer('api', l_insecure_func),
        'insecure function should not be SECURITY DEFINER'
    );

    -- Clean up
    EXECUTE format('DROP FUNCTION api.%I()', l_secure_func);
    EXECUTE format('DROP FUNCTION api.%I()', l_insecure_func);
END;
$$;

-- Test: Procedure should also be SECURITY DEFINER
CREATE OR REPLACE FUNCTION test.test_security_024_procedure_definer()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_proc text := 'test_proc_' || to_char(clock_timestamp(), 'HH24MISS');
    l_is_definer boolean;
BEGIN
    PERFORM test.set_context('test_security_024_procedure_definer');

    -- Create procedure with SECURITY DEFINER
    EXECUTE format($fn$
        CREATE PROCEDURE api.%I(INOUT io_result text DEFAULT NULL)
        LANGUAGE plpgsql
        SECURITY DEFINER
        SET search_path = data, private, pg_temp
        AS $$ BEGIN io_result := 'done'; END; $$
    $fn$, l_test_proc);

    -- Check it's SECURITY DEFINER
    SELECT p.prosecdef INTO l_is_definer
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'api' AND p.proname = l_test_proc;

    PERFORM test.ok(l_is_definer, 'API procedure should be SECURITY DEFINER');

    -- Clean up
    EXECUTE format('DROP PROCEDURE api.%I(text)', l_test_proc);
END;
$$;

-- Test: Detect missing search_path on SECURITY DEFINER
CREATE OR REPLACE FUNCTION test.test_security_025_detect_missing_path()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_func text := 'test_nopath_' || to_char(clock_timestamp(), 'HH24MISS');
    l_search_path text;
BEGIN
    PERFORM test.set_context('test_security_025_detect_missing_path');

    -- Create function WITHOUT search_path (bad practice)
    EXECUTE format($fn$
        CREATE FUNCTION api.%I()
        RETURNS text
        LANGUAGE sql
        STABLE
        SECURITY DEFINER
        AS $$ SELECT 'no path'::text $$
    $fn$, l_test_func);

    -- Get search_path (should be null)
    l_search_path := test.get_function_search_path('api', l_test_func);

    PERFORM test.is_null(l_search_path, 'function without SET search_path should return null');

    -- Clean up
    EXECUTE format('DROP FUNCTION api.%I()', l_test_func);
END;
$$;

-- Test: SECURITY INVOKER functions don't need search_path
CREATE OR REPLACE FUNCTION test.test_security_026_invoker_no_path_ok()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_func text := 'test_invoker_' || to_char(clock_timestamp(), 'HH24MISS');
    l_is_definer boolean;
BEGIN
    PERFORM test.set_context('test_security_026_invoker_no_path_ok');

    -- Create SECURITY INVOKER function (implicit default)
    EXECUTE format($fn$
        CREATE FUNCTION private.%I()
        RETURNS text
        LANGUAGE sql
        STABLE
        AS $$ SELECT 'invoker'::text $$
    $fn$, l_test_func);

    -- Should NOT be SECURITY DEFINER
    l_is_definer := test.is_security_definer('private', l_test_func);

    PERFORM test.not_ok(l_is_definer, 'private helper can be SECURITY INVOKER');

    -- Clean up
    EXECUTE format('DROP FUNCTION private.%I()', l_test_func);
END;
$$;

-- ============================================================================
-- RUN TESTS
-- ============================================================================

SELECT test.run_module('security_02');
CALL test.print_run_summary();
