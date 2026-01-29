-- ============================================================================
-- INSTALL TEST FRAMEWORK
-- ============================================================================
-- Creates test schema and installs assertion functions, test runner, and helpers.
-- Safe to run multiple times (uses CREATE OR REPLACE and IF NOT EXISTS).
-- ============================================================================

\echo ''
\echo '============================================================'
\echo 'INSTALLING TEST FRAMEWORK'
\echo '============================================================'
\echo ''

-- Install assertions
\echo 'Installing assertions...'
\i ../framework/assertions.sql

-- Install test runner
\echo 'Installing test runner...'
\i ../framework/test_runner.sql

-- Install helpers
\echo 'Installing helpers...'
\i ../framework/test_helpers.sql

-- Verify installation
DO $$
DECLARE
    l_func_count integer;
    l_table_count integer;
BEGIN
    -- Count test functions
    SELECT count(*) INTO l_func_count
    FROM information_schema.routines
    WHERE routine_schema = 'test';

    -- Count test tables
    SELECT count(*) INTO l_table_count
    FROM information_schema.tables
    WHERE table_schema = 'test';

    RAISE NOTICE '';
    RAISE NOTICE '============================================================';
    RAISE NOTICE 'TEST FRAMEWORK INSTALLED';
    RAISE NOTICE '============================================================';
    RAISE NOTICE '';
    RAISE NOTICE 'Schema: test';
    RAISE NOTICE 'Functions/Procedures: %', l_func_count;
    RAISE NOTICE 'Tables: %', l_table_count;
    RAISE NOTICE '';
    RAISE NOTICE 'Key functions:';
    RAISE NOTICE '  test.ok(condition, description)';
    RAISE NOTICE '  test.is(got, expected, description)';
    RAISE NOTICE '  test.throws_ok(sql, errcode, description)';
    RAISE NOTICE '  test.lives_ok(sql, description)';
    RAISE NOTICE '  test.has_table(schema, table, description)';
    RAISE NOTICE '  test.has_function(schema, function, description)';
    RAISE NOTICE '';
    RAISE NOTICE 'Test execution:';
    RAISE NOTICE '  test.run_test(function_name)';
    RAISE NOTICE '  test.run_all(schema, pattern)';
    RAISE NOTICE '  test.run_module(module_name)';
    RAISE NOTICE '';
    RAISE NOTICE '============================================================';
END;
$$;
