-- ============================================================================
-- MIGRATION SYSTEM TESTS - ROLLBACK
-- ============================================================================
-- Tests for rollback script registration and execution.
-- ============================================================================

-- ============================================================================
-- TEST FUNCTIONS
-- ============================================================================

-- Test: Register rollback script
CREATE OR REPLACE FUNCTION test.test_migration_060_register_rollback()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_version text := 'TEST_060_' || to_char(clock_timestamp(), 'HH24MISS');
    l_rollback_sql text;
BEGIN
    PERFORM test.set_context('test_migration_060_register_rollback');

    -- Register rollback
    CALL app_migration.register_rollback(l_version, 'DROP TABLE IF EXISTS test_table');

    -- Verify it was stored
    SELECT rollback_sql INTO l_rollback_sql
    FROM app_migration.rollback_scripts
    WHERE version = l_version;

    PERFORM test.is(l_rollback_sql, 'DROP TABLE IF EXISTS test_table', 'rollback script should be stored');

    -- Clean up
    DELETE FROM app_migration.rollback_scripts WHERE version = l_version;
END;
$$;

-- Test: Register rollback updates existing
CREATE OR REPLACE FUNCTION test.test_migration_061_register_rollback_update()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_version text := 'TEST_061_' || to_char(clock_timestamp(), 'HH24MISS');
    l_rollback_sql text;
BEGIN
    PERFORM test.set_context('test_migration_061_register_rollback_update');

    -- Register initial rollback
    CALL app_migration.register_rollback(l_version, 'SELECT 1');

    -- Update rollback
    CALL app_migration.register_rollback(l_version, 'SELECT 2');

    -- Should have updated value
    SELECT rollback_sql INTO l_rollback_sql
    FROM app_migration.rollback_scripts
    WHERE version = l_version;

    PERFORM test.is(l_rollback_sql, 'SELECT 2', 'rollback script should be updated');

    -- Clean up
    DELETE FROM app_migration.rollback_scripts WHERE version = l_version;
END;
$$;

-- Test: run_versioned with rollback_sql registers it
CREATE OR REPLACE FUNCTION test.test_migration_062_versioned_with_rollback()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_version text := 'TEST_062_' || to_char(clock_timestamp(), 'HH24MISS');
    l_has_rollback boolean;
BEGIN
    PERFORM test.set_context('test_migration_062_versioned_with_rollback');

    -- Acquire lock
    PERFORM app_migration.acquire_lock();

    -- Run with rollback
    CALL app_migration.run_versioned(
        in_version := l_version,
        in_description := 'Test with rollback',
        in_sql := 'SELECT 1',
        in_rollback_sql := 'SELECT 0'
    );

    -- Should have rollback script
    SELECT EXISTS (
        SELECT 1 FROM app_migration.rollback_scripts WHERE version = l_version
    ) INTO l_has_rollback;

    PERFORM test.ok(l_has_rollback, 'rollback script should be registered');

    -- Clean up
    PERFORM app_migration.release_lock();
    DELETE FROM app_migration.changelog WHERE version = l_version;
    DELETE FROM app_migration.rollback_scripts WHERE version = l_version;
END;
$$;

-- Test: Rollback executes SQL
CREATE OR REPLACE FUNCTION test.test_migration_063_rollback_execute()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_version text := 'TEST_063_' || to_char(clock_timestamp(), 'HH24MISS');
    l_table_name text;
    l_table_exists boolean;
BEGIN
    PERFORM test.set_context('test_migration_063_rollback_execute');

    -- PostgreSQL folds unquoted identifiers to lowercase
    l_table_name := lower('test_rollback_' || l_version);

    -- Acquire lock
    PERFORM app_migration.acquire_lock();

    -- Create a test table via migration
    CALL app_migration.run_versioned(
        in_version := l_version,
        in_description := 'Create test table',
        in_sql := format('CREATE TABLE test.%I (id int)', l_table_name),
        in_rollback_sql := format('DROP TABLE IF EXISTS test.%I', l_table_name)
    );

    -- Table should exist
    SELECT EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'test' AND table_name = l_table_name
    ) INTO l_table_exists;

    PERFORM test.ok(l_table_exists, 'table should exist after migration');

    -- Execute rollback
    CALL app_migration.rollback(l_version);

    -- Table should not exist
    SELECT EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'test' AND table_name = l_table_name
    ) INTO l_table_exists;

    PERFORM test.not_ok(l_table_exists, 'table should not exist after rollback');

    -- Clean up
    PERFORM app_migration.release_lock();
    DELETE FROM app_migration.changelog WHERE version = l_version;
    DELETE FROM app_migration.rollback_scripts WHERE version = l_version;
    DELETE FROM app_migration.rollback_history WHERE version = l_version;
END;
$$;

-- Test: Rollback marks migration as rolled back
CREATE OR REPLACE FUNCTION test.test_migration_064_rollback_marks_failed()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_version text := 'TEST_064_' || to_char(clock_timestamp(), 'HH24MISS');
    l_is_applied boolean;
BEGIN
    PERFORM test.set_context('test_migration_064_rollback_marks_failed');

    -- Acquire lock
    PERFORM app_migration.acquire_lock();

    -- Run migration
    CALL app_migration.run_versioned(
        in_version := l_version,
        in_description := 'Test rollback marking',
        in_sql := 'SELECT 1',
        in_rollback_sql := 'SELECT 0'
    );

    -- Should be applied
    l_is_applied := app_migration.is_version_applied(l_version);
    PERFORM test.ok(l_is_applied, 'migration should be applied before rollback');

    -- Rollback
    CALL app_migration.rollback(l_version);

    -- Should no longer be applied
    l_is_applied := app_migration.is_version_applied(l_version);
    PERFORM test.not_ok(l_is_applied, 'migration should not be applied after rollback');

    -- Clean up
    PERFORM app_migration.release_lock();
    DELETE FROM app_migration.changelog WHERE version = l_version;
    DELETE FROM app_migration.rollback_scripts WHERE version = l_version;
    DELETE FROM app_migration.rollback_history WHERE version = l_version;
END;
$$;

-- Test: Rollback history is recorded
CREATE OR REPLACE FUNCTION test.test_migration_065_rollback_history()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_version text := 'TEST_065_' || to_char(clock_timestamp(), 'HH24MISS');
    l_history_count integer;
BEGIN
    PERFORM test.set_context('test_migration_065_rollback_history');

    -- Acquire lock
    PERFORM app_migration.acquire_lock();

    CALL app_migration.run_versioned(
        in_version := l_version,
        in_description := 'Test rollback history',
        in_sql := 'SELECT 1',
        in_rollback_sql := 'SELECT 0'
    );

    CALL app_migration.rollback(l_version);

    -- Check history was recorded
    SELECT count(*) INTO l_history_count
    FROM app_migration.rollback_history
    WHERE version = l_version AND success = true;

    PERFORM test.is(l_history_count, 1, 'rollback history should be recorded');

    -- Clean up
    PERFORM app_migration.release_lock();
    DELETE FROM app_migration.changelog WHERE version = l_version;
    DELETE FROM app_migration.rollback_scripts WHERE version = l_version;
    DELETE FROM app_migration.rollback_history WHERE version = l_version;
END;
$$;

-- Test: Rollback fails without script
CREATE OR REPLACE FUNCTION test.test_migration_066_rollback_requires_script()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_version text := 'TEST_066_' || to_char(clock_timestamp(), 'HH24MISS');
BEGIN
    PERFORM test.set_context('test_migration_066_rollback_requires_script');

    -- Acquire lock
    PERFORM app_migration.acquire_lock();

    -- Run migration without rollback script
    CALL app_migration.run_versioned(
        in_version := l_version,
        in_description := 'No rollback script',
        in_sql := 'SELECT 1'
        -- No in_rollback_sql
    );

    -- Rollback should fail
    PERFORM test.throws_like(
        format('CALL app_migration.rollback(%L)', l_version),
        'No rollback script',
        'rollback should fail without script'
    );

    -- Clean up
    PERFORM app_migration.release_lock();
    DELETE FROM app_migration.changelog WHERE version = l_version;
END;
$$;

-- Test: Rollback fails for non-existent version
CREATE OR REPLACE FUNCTION test.test_migration_067_rollback_nonexistent()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM test.set_context('test_migration_067_rollback_nonexistent');

    PERFORM test.throws_like(
        $$CALL app_migration.rollback('NONEXISTENT_VERSION_XYZ')$$,
        'not found|already rolled back',
        'rollback should fail for non-existent version'
    );
END;
$$;

-- Test: get_rollback_versions lists available rollbacks
CREATE OR REPLACE FUNCTION test.test_migration_068_get_rollback_versions()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_version text := 'TEST_068_' || to_char(clock_timestamp(), 'HH24MISS');
    l_found boolean;
BEGIN
    PERFORM test.set_context('test_migration_068_get_rollback_versions');

    -- Acquire lock
    PERFORM app_migration.acquire_lock();

    CALL app_migration.run_versioned(
        in_version := l_version,
        in_description := 'Test get_rollback_versions',
        in_sql := 'SELECT 1',
        in_rollback_sql := 'SELECT 0'
    );

    -- Should be in rollback versions
    SELECT EXISTS (
        SELECT 1 FROM app_migration.get_rollback_versions()
        WHERE version = l_version AND has_rollback_script = true
    ) INTO l_found;

    PERFORM test.ok(l_found, 'version should be in get_rollback_versions with has_rollback_script=true');

    -- Clean up
    PERFORM app_migration.release_lock();
    DELETE FROM app_migration.changelog WHERE version = l_version;
    DELETE FROM app_migration.rollback_scripts WHERE version = l_version;
END;
$$;

-- Test: rollback_to rolls back multiple versions
CREATE OR REPLACE FUNCTION test.test_migration_069_rollback_to()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_version1 text := 'TEST_069_A_' || to_char(clock_timestamp(), 'HH24MISS');
    l_version2 text := 'TEST_069_B_' || to_char(clock_timestamp(), 'HH24MISS');
    l_version3 text := 'TEST_069_C_' || to_char(clock_timestamp(), 'HH24MISS');
    l_applied1 boolean;
    l_applied2 boolean;
    l_applied3 boolean;
BEGIN
    PERFORM test.set_context('test_migration_069_rollback_to');

    -- Acquire lock
    PERFORM app_migration.acquire_lock();

    -- Run three migrations
    CALL app_migration.run_versioned(l_version1, 'Version 1', 'SELECT 1', NULL, 'SELECT 0');
    PERFORM pg_sleep(0.01);
    CALL app_migration.run_versioned(l_version2, 'Version 2', 'SELECT 2', NULL, 'SELECT 0');
    PERFORM pg_sleep(0.01);
    CALL app_migration.run_versioned(l_version3, 'Version 3', 'SELECT 3', NULL, 'SELECT 0');

    -- All should be applied
    PERFORM test.ok(app_migration.is_version_applied(l_version1), 'v1 should be applied');
    PERFORM test.ok(app_migration.is_version_applied(l_version2), 'v2 should be applied');
    PERFORM test.ok(app_migration.is_version_applied(l_version3), 'v3 should be applied');

    -- Rollback to version 1 (should rollback 2 and 3)
    CALL app_migration.rollback_to(l_version1);

    -- Check results
    l_applied1 := app_migration.is_version_applied(l_version1);
    l_applied2 := app_migration.is_version_applied(l_version2);
    l_applied3 := app_migration.is_version_applied(l_version3);

    PERFORM test.ok(l_applied1, 'v1 should still be applied after rollback_to');
    PERFORM test.not_ok(l_applied2, 'v2 should be rolled back');
    PERFORM test.not_ok(l_applied3, 'v3 should be rolled back');

    -- Clean up
    PERFORM app_migration.release_lock();
    DELETE FROM app_migration.changelog WHERE version LIKE 'TEST_069_%';
    DELETE FROM app_migration.rollback_scripts WHERE version LIKE 'TEST_069_%';
    DELETE FROM app_migration.rollback_history WHERE version LIKE 'TEST_069_%';
END;
$$;

-- ============================================================================
-- RUN TESTS
-- ============================================================================

SELECT test.run_module('migration_06');
CALL test.print_run_summary();
