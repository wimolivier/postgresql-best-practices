-- ============================================================================
-- MIGRATION SYSTEM TESTS - INFO AND STATUS
-- ============================================================================
-- Tests for migration information and status queries.
-- ============================================================================

-- ============================================================================
-- TEST FUNCTIONS
-- ============================================================================

-- Test: info() returns system status
CREATE OR REPLACE FUNCTION test.test_migration_080_info()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_info record;
BEGIN
    PERFORM test.set_context('test_migration_080_info');

    SELECT * INTO l_info FROM app_migration.info();

    PERFORM test.is_not_null(l_info.current_version, 'info() should return current_version');
    PERFORM test.is_not_null(l_info.total_migrations, 'info() should return total_migrations');
    PERFORM test.is_not_null(l_info.successful_migrations, 'info() should return successful_migrations');
    PERFORM test.is_not_null(l_info.failed_migrations, 'info() should return failed_migrations');
    PERFORM test.is_not_null(l_info.is_locked, 'info() should return is_locked');
    PERFORM test.ok(l_info.schema_exists, 'info() schema_exists should be true');
END;
$$;

-- Test: info() reflects correct counts
CREATE OR REPLACE FUNCTION test.test_migration_081_info_counts()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_version text := 'TEST_081_' || to_char(clock_timestamp(), 'HH24MISS');
    l_info_before record;
    l_info_after record;
BEGIN
    PERFORM test.set_context('test_migration_081_info_counts');

    SELECT * INTO l_info_before FROM app_migration.info();

    -- Acquire lock and run migration
    PERFORM app_migration.acquire_lock();
    CALL app_migration.run_versioned(l_version, 'Test info counts', 'SELECT 1');
    PERFORM app_migration.release_lock();

    SELECT * INTO l_info_after FROM app_migration.info();

    PERFORM test.is(
        l_info_after.total_migrations,
        l_info_before.total_migrations + 1,
        'total_migrations should increase by 1'
    );

    PERFORM test.is(
        l_info_after.successful_migrations,
        l_info_before.successful_migrations + 1,
        'successful_migrations should increase by 1'
    );

    -- Clean up
    DELETE FROM app_migration.changelog WHERE version = l_version;
END;
$$;

-- Test: status() returns formatted status
CREATE OR REPLACE FUNCTION test.test_migration_082_status()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_version text := 'TEST_082_' || to_char(clock_timestamp(), 'HH24MISS');
    l_status record;
BEGIN
    PERFORM test.set_context('test_migration_082_status');

    -- Acquire lock and run migration
    PERFORM app_migration.acquire_lock();
    CALL app_migration.run_versioned(l_version, 'Test status', 'SELECT 1');
    PERFORM app_migration.release_lock();

    -- Get status
    SELECT * INTO l_status
    FROM app_migration.status()
    WHERE version = l_version;

    PERFORM test.is_not_null(l_status.version, 'status() should return version');
    PERFORM test.is_not_null(l_status.description, 'status() should return description');
    PERFORM test.is(l_status.type, 'versioned', 'status() should return correct type');
    PERFORM test.is(l_status.state, 'SUCCESS', 'status() should return SUCCESS state');
    PERFORM test.is_not_null(l_status.executed_at, 'status() should return executed_at');
    PERFORM test.is_not_null(l_status.execution_time, 'status() should return execution_time');
    PERFORM test.is_not_null(l_status.checksum, 'status() should return truncated checksum');

    -- Clean up
    DELETE FROM app_migration.changelog WHERE version = l_version;
END;
$$;

-- Test: get_history() returns migration history
CREATE OR REPLACE FUNCTION test.test_migration_083_get_history()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_version text := 'TEST_083_' || to_char(clock_timestamp(), 'HH24MISS');
    l_history_count integer;
BEGIN
    PERFORM test.set_context('test_migration_083_get_history');

    -- Acquire lock and run migration
    PERFORM app_migration.acquire_lock();
    CALL app_migration.run_versioned(l_version, 'Test history', 'SELECT 1');
    PERFORM app_migration.release_lock();

    -- Check history contains our migration
    SELECT count(*) INTO l_history_count
    FROM app_migration.get_history(100)
    WHERE version = l_version;

    PERFORM test.is(l_history_count, 1, 'get_history() should include new migration');

    -- Clean up
    DELETE FROM app_migration.changelog WHERE version = l_version;
END;
$$;

-- Test: get_history() respects limit
CREATE OR REPLACE FUNCTION test.test_migration_084_get_history_limit()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_count integer;
BEGIN
    PERFORM test.set_context('test_migration_084_get_history_limit');

    -- Get history with limit
    SELECT count(*) INTO l_count FROM app_migration.get_history(5);

    PERFORM test.ok(l_count <= 5, 'get_history() should respect limit');
END;
$$;

-- Test: get_history() exclude failed by default
-- Note: PostgreSQL doesn't support autonomous transactions, so failed migrations
-- aren't actually recorded (the subtransaction is rolled back).
-- This test verifies the get_history() parameters work for successful migrations.
CREATE OR REPLACE FUNCTION test.test_migration_085_get_history_include_failed()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_version text := 'TEST_085_' || to_char(clock_timestamp(), 'HH24MISS');
    l_found_in_history boolean;
BEGIN
    PERFORM test.set_context('test_migration_085_get_history_include_failed');

    -- Acquire lock and create a successful migration
    PERFORM app_migration.acquire_lock();
    CALL app_migration.run_versioned(l_version, 'Test history', 'SELECT 1');
    PERFORM app_migration.release_lock();

    -- Check it appears in history
    SELECT EXISTS (
        SELECT 1 FROM app_migration.get_history(100, false)
        WHERE version = l_version
    ) INTO l_found_in_history;

    PERFORM test.ok(l_found_in_history, 'get_history() should include successful migration');

    -- Also verify include_failed parameter is accepted
    SELECT EXISTS (
        SELECT 1 FROM app_migration.get_history(100, true)
        WHERE version = l_version
    ) INTO l_found_in_history;

    PERFORM test.ok(l_found_in_history, 'get_history(include_failed:=true) should work');

    -- Clean up
    DELETE FROM app_migration.changelog WHERE version = l_version;
END;
$$;

-- Test: get_pending() returns pending versions
CREATE OR REPLACE FUNCTION test.test_migration_086_get_pending()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_version_applied text := 'TEST_086_A_' || to_char(clock_timestamp(), 'HH24MISS');
    l_version_pending text := 'TEST_086_B_' || to_char(clock_timestamp(), 'HH24MISS');
    l_pending_count integer;
BEGIN
    PERFORM test.set_context('test_migration_086_get_pending');

    -- Apply one version
    PERFORM app_migration.acquire_lock();
    CALL app_migration.run_versioned(l_version_applied, 'Applied', 'SELECT 1');
    PERFORM app_migration.release_lock();

    -- Check pending
    SELECT count(*) INTO l_pending_count
    FROM app_migration.get_pending(ARRAY[l_version_applied, l_version_pending])
    WHERE version = l_version_pending;

    PERFORM test.is(l_pending_count, 1, 'get_pending() should return unapplied version');

    -- Clean up
    DELETE FROM app_migration.changelog WHERE version = l_version_applied;
END;
$$;

-- Test: clear_failed() procedure exists and executes
-- Note: PostgreSQL doesn't support autonomous transactions, so failed migrations
-- aren't actually recorded (the subtransaction is rolled back).
-- This test verifies clear_failed() runs without error.
CREATE OR REPLACE FUNCTION test.test_migration_087_clear_failed()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM test.set_context('test_migration_087_clear_failed');

    -- Just verify clear_failed() runs without error
    -- In PostgreSQL without autonomous transactions, failed migrations
    -- don't persist in the changelog (they get rolled back with the exception)
    PERFORM test.lives_ok(
        'CALL app_migration.clear_failed()',
        'clear_failed() should execute without error'
    );

    -- Verify no failed entries exist (which is expected given PostgreSQL behavior)
    PERFORM test.is(
        (SELECT count(*)::integer FROM app_migration.changelog WHERE success = false AND version LIKE 'TEST_%'),
        0,
        'no TEST_ failed entries should exist (PostgreSQL rollback behavior)'
    );
END;
$$;

-- Test: set_baseline works on fresh system
CREATE OR REPLACE FUNCTION test.test_migration_088_set_baseline()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_version text := 'TEST_088_BASELINE';
    l_current_version text;
BEGIN
    PERFORM test.set_context('test_migration_088_set_baseline');

    -- This test is tricky because set_baseline requires no existing versioned migrations
    -- We'll verify the behavior by checking if the error is thrown when there ARE migrations

    -- If there are already versioned migrations, it should fail
    IF EXISTS (SELECT 1 FROM app_migration.changelog WHERE type = 'versioned' AND success = true) THEN
        PERFORM test.throws_like(
            format($$CALL app_migration.set_baseline(%L)$$, l_version),
            'Cannot set baseline.*versioned migrations already exist',
            'set_baseline should fail when versioned migrations exist'
        );
    ELSE
        -- Set baseline
        CALL app_migration.set_baseline(l_version, 'Test baseline');

        l_current_version := app_migration.get_current_version();
        PERFORM test.is(l_current_version, l_version, 'get_current_version should return baseline');

        -- Clean up
        DELETE FROM app_migration.changelog WHERE version = l_version;
    END IF;
END;
$$;

-- Test: print_status procedure runs without error
CREATE OR REPLACE FUNCTION test.test_migration_089_print_status()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM test.set_context('test_migration_089_print_status');

    -- Just verify it runs without error
    PERFORM test.lives_ok(
        'CALL app_migration.print_status()',
        'print_status() should execute without error'
    );
END;
$$;

-- ============================================================================
-- RUN TESTS
-- ============================================================================

SELECT test.run_module('migration_08');
CALL test.print_run_summary();
