-- ============================================================================
-- MIGRATION SYSTEM TESTS - VERSIONED MIGRATIONS
-- ============================================================================
-- Tests for versioned migration execution and tracking.
-- ============================================================================

-- ============================================================================
-- TEST FUNCTIONS
-- ============================================================================

-- Test: Versioned migration executes and is recorded
CREATE OR REPLACE FUNCTION test.test_migration_030_versioned_execute()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_version text := 'TEST_030_' || to_char(clock_timestamp(), 'HH24MISS');
    l_is_applied boolean;
BEGIN
    PERFORM test.set_context('test_migration_030_versioned_execute');

    -- Acquire lock
    PERFORM app_migration.acquire_lock();

    -- Run a simple migration
    CALL app_migration.run_versioned(
        in_version := l_version,
        in_description := 'Test versioned migration',
        in_sql := 'SELECT 1'
    );

    -- Should be recorded as applied
    l_is_applied := app_migration.is_version_applied(l_version);
    PERFORM test.ok(l_is_applied, 'versioned migration should be recorded as applied');

    -- Check changelog entry
    PERFORM test.isnt_empty(
        format('SELECT 1 FROM app_migration.changelog WHERE version = %L AND success = true', l_version),
        'changelog should have successful entry'
    );

    -- Clean up
    PERFORM app_migration.release_lock();
    DELETE FROM app_migration.changelog WHERE version = l_version;
END;
$$;

-- Test: Versioned migration skipped if already applied
CREATE OR REPLACE FUNCTION test.test_migration_031_versioned_skip_applied()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_version text := 'TEST_031_' || to_char(clock_timestamp(), 'HH24MISS');
    l_count_before integer;
    l_count_after integer;
BEGIN
    PERFORM test.set_context('test_migration_031_versioned_skip_applied');

    -- Acquire lock
    PERFORM app_migration.acquire_lock();

    -- Run migration first time
    CALL app_migration.run_versioned(
        in_version := l_version,
        in_description := 'Test skip migration',
        in_sql := 'SELECT 1'
    );

    -- Count entries
    SELECT count(*) INTO l_count_before
    FROM app_migration.changelog WHERE version = l_version;

    -- Run migration second time
    CALL app_migration.run_versioned(
        in_version := l_version,
        in_description := 'Test skip migration',
        in_sql := 'SELECT 1'
    );

    -- Count should be same (not inserted again)
    SELECT count(*) INTO l_count_after
    FROM app_migration.changelog WHERE version = l_version;

    PERFORM test.is(l_count_after, l_count_before, 'migration should not be recorded again');

    -- Clean up
    PERFORM app_migration.release_lock();
    DELETE FROM app_migration.changelog WHERE version = l_version;
END;
$$;

-- Test: Execution time is recorded
CREATE OR REPLACE FUNCTION test.test_migration_032_execution_time()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_version text := 'TEST_032_' || to_char(clock_timestamp(), 'HH24MISS');
    l_exec_time integer;
BEGIN
    PERFORM test.set_context('test_migration_032_execution_time');

    -- Acquire lock
    PERFORM app_migration.acquire_lock();

    -- Run migration with delay
    CALL app_migration.run_versioned(
        in_version := l_version,
        in_description := 'Test execution time',
        in_sql := 'SELECT pg_sleep(0.01)'  -- 10ms sleep
    );

    -- Check execution time was recorded
    SELECT execution_time_ms INTO l_exec_time
    FROM app_migration.changelog
    WHERE version = l_version;

    PERFORM test.is_not_null(l_exec_time, 'execution_time_ms should be recorded');
    PERFORM test.ok(l_exec_time >= 10, 'execution_time_ms should be at least 10ms');

    -- Clean up
    PERFORM app_migration.release_lock();
    DELETE FROM app_migration.changelog WHERE version = l_version;
END;
$$;

-- Test: executed_by is recorded
CREATE OR REPLACE FUNCTION test.test_migration_033_executed_by()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_version text := 'TEST_033_' || to_char(clock_timestamp(), 'HH24MISS');
    l_executed_by text;
BEGIN
    PERFORM test.set_context('test_migration_033_executed_by');

    -- Acquire lock
    PERFORM app_migration.acquire_lock();

    CALL app_migration.run_versioned(
        in_version := l_version,
        in_description := 'Test executed_by',
        in_sql := 'SELECT 1'
    );

    SELECT executed_by INTO l_executed_by
    FROM app_migration.changelog
    WHERE version = l_version;

    PERFORM test.is(l_executed_by, current_user, 'executed_by should be current user');

    -- Clean up
    PERFORM app_migration.release_lock();
    DELETE FROM app_migration.changelog WHERE version = l_version;
END;
$$;

-- Test: Failed migration is NOT recorded (PostgreSQL behavior)
-- Note: PostgreSQL doesn't support autonomous transactions, so failed migrations
-- roll back their changelog entry along with the failed SQL.
CREATE OR REPLACE FUNCTION test.test_migration_034_failed_recorded()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_version text := 'TEST_034_' || to_char(clock_timestamp(), 'HH24MISS');
    l_count integer;
    l_exception_raised boolean := false;
BEGIN
    PERFORM test.set_context('test_migration_034_failed_recorded');

    -- Acquire lock
    PERFORM app_migration.acquire_lock();

    -- Run migration that will fail
    BEGIN
        CALL app_migration.run_versioned(
            in_version := l_version,
            in_description := 'Test failed migration',
            in_sql := 'SELECT * FROM nonexistent_table_xyz'
        );
    EXCEPTION WHEN OTHERS THEN
        -- Expected to fail
        l_exception_raised := true;
    END;

    -- Verify exception was raised
    PERFORM test.ok(l_exception_raised, 'failed migration should raise exception');

    -- PostgreSQL behavior: failed migration is NOT recorded because the
    -- subtransaction is rolled back (no autonomous transactions)
    SELECT count(*) INTO l_count
    FROM app_migration.changelog
    WHERE version = l_version;

    PERFORM test.is(l_count, 0, 'failed migration is not recorded (PostgreSQL rollback behavior)');

    -- Clean up
    PERFORM app_migration.release_lock();
END;
$$;

-- Test: get_current_version returns latest version
CREATE OR REPLACE FUNCTION test.test_migration_035_get_current_version()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_version1 text := 'TEST_035_A_' || to_char(clock_timestamp(), 'HH24MISS');
    l_version2 text := 'TEST_035_B_' || to_char(clock_timestamp(), 'HH24MISS');
    l_current text;
BEGIN
    PERFORM test.set_context('test_migration_035_get_current_version');

    -- Acquire lock
    PERFORM app_migration.acquire_lock();

    -- Run first migration
    CALL app_migration.run_versioned(
        in_version := l_version1,
        in_description := 'First test migration',
        in_sql := 'SELECT 1'
    );

    -- Short delay to ensure different timestamp
    PERFORM pg_sleep(0.01);

    -- Run second migration
    CALL app_migration.run_versioned(
        in_version := l_version2,
        in_description := 'Second test migration',
        in_sql := 'SELECT 1'
    );

    -- Current version should be the second one
    l_current := app_migration.get_current_version();
    PERFORM test.is(l_current, l_version2, 'get_current_version should return latest version');

    -- Clean up
    PERFORM app_migration.release_lock();
    DELETE FROM app_migration.changelog WHERE version IN (l_version1, l_version2);
END;
$$;

-- Test: is_version_applied works correctly
CREATE OR REPLACE FUNCTION test.test_migration_036_is_version_applied()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_version text := 'TEST_036_' || to_char(clock_timestamp(), 'HH24MISS');
    l_applied boolean;
BEGIN
    PERFORM test.set_context('test_migration_036_is_version_applied');

    -- Should not be applied yet
    l_applied := app_migration.is_version_applied(l_version);
    PERFORM test.not_ok(l_applied, 'version should not be applied initially');

    -- Acquire lock and run
    PERFORM app_migration.acquire_lock();
    CALL app_migration.run_versioned(
        in_version := l_version,
        in_description := 'Test is_version_applied',
        in_sql := 'SELECT 1'
    );

    -- Should be applied now
    l_applied := app_migration.is_version_applied(l_version);
    PERFORM test.ok(l_applied, 'version should be applied after run');

    -- Clean up
    PERFORM app_migration.release_lock();
    DELETE FROM app_migration.changelog WHERE version = l_version;
END;
$$;

-- Test: Filename is auto-generated if not provided
CREATE OR REPLACE FUNCTION test.test_migration_037_auto_filename()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_version text := 'TEST_037_' || to_char(clock_timestamp(), 'HH24MISS');
    l_filename text;
BEGIN
    PERFORM test.set_context('test_migration_037_auto_filename');

    -- Acquire lock
    PERFORM app_migration.acquire_lock();

    CALL app_migration.run_versioned(
        in_version := l_version,
        in_description := 'Test Auto Filename',
        in_sql := 'SELECT 1'
    );

    SELECT filename INTO l_filename
    FROM app_migration.changelog
    WHERE version = l_version;

    -- Filename should be auto-generated
    PERFORM test.matches(l_filename, '^V' || l_version, 'filename should start with V{version}');
    PERFORM test.matches(l_filename, 'test_auto_filename', 'filename should contain normalized description');

    -- Clean up
    PERFORM app_migration.release_lock();
    DELETE FROM app_migration.changelog WHERE version = l_version;
END;
$$;

-- Test: Custom filename is preserved
CREATE OR REPLACE FUNCTION test.test_migration_038_custom_filename()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_version text := 'TEST_038_' || to_char(clock_timestamp(), 'HH24MISS');
    l_filename text;
BEGIN
    PERFORM test.set_context('test_migration_038_custom_filename');

    -- Acquire lock
    PERFORM app_migration.acquire_lock();

    CALL app_migration.run_versioned(
        in_version := l_version,
        in_description := 'Test custom filename',
        in_sql := 'SELECT 1',
        in_filename := 'CUSTOM_FILENAME.sql'
    );

    SELECT filename INTO l_filename
    FROM app_migration.changelog
    WHERE version = l_version;

    PERFORM test.is(l_filename, 'CUSTOM_FILENAME.sql', 'custom filename should be preserved');

    -- Clean up
    PERFORM app_migration.release_lock();
    DELETE FROM app_migration.changelog WHERE version = l_version;
END;
$$;

-- ============================================================================
-- RUN TESTS
-- ============================================================================

SELECT test.run_module('migration_03');
CALL test.print_run_summary();
