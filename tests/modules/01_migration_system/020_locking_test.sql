-- ============================================================================
-- MIGRATION SYSTEM TESTS - LOCKING
-- ============================================================================
-- Tests for migration lock acquire, release, and status functions.
-- ============================================================================

-- ============================================================================
-- TEST FUNCTIONS
-- ============================================================================

-- Test: acquire_lock returns true when lock available
CREATE OR REPLACE FUNCTION test.test_migration_020_acquire_lock()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_acquired boolean;
BEGIN
    PERFORM test.set_context('test_migration_020_acquire_lock');

    -- Ensure lock is not held
    PERFORM app_migration.release_lock();

    -- Acquire should succeed
    l_acquired := app_migration.acquire_lock();
    PERFORM test.ok(l_acquired, 'acquire_lock should return true when lock is available');

    -- Clean up
    PERFORM app_migration.release_lock();
END;
$$;

-- Test: release_lock releases the lock
CREATE OR REPLACE FUNCTION test.test_migration_021_release_lock()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_released boolean;
BEGIN
    PERFORM test.set_context('test_migration_021_release_lock');

    -- Acquire first
    PERFORM app_migration.acquire_lock();

    -- Release should succeed
    l_released := app_migration.release_lock();
    PERFORM test.ok(l_released, 'release_lock should return true when lock was held');

    -- Releasing again should return false
    l_released := app_migration.release_lock();
    PERFORM test.not_ok(l_released, 'release_lock should return false when lock was not held');
END;
$$;

-- Test: is_locked returns correct status
CREATE OR REPLACE FUNCTION test.test_migration_022_is_locked()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_is_locked boolean;
BEGIN
    PERFORM test.set_context('test_migration_022_is_locked');

    -- Ensure clean state
    PERFORM app_migration.release_lock();

    -- Should not be locked
    l_is_locked := app_migration.is_locked();
    PERFORM test.not_ok(l_is_locked, 'is_locked should return false when lock not held');

    -- Acquire lock
    PERFORM app_migration.acquire_lock();

    -- Should be locked
    l_is_locked := app_migration.is_locked();
    PERFORM test.ok(l_is_locked, 'is_locked should return true when lock is held');

    -- Clean up
    PERFORM app_migration.release_lock();
END;
$$;

-- Test: acquire_lock is reentrant within same session
-- Note: PostgreSQL advisory locks ARE reentrant - same session can acquire multiple times
CREATE OR REPLACE FUNCTION test.test_migration_023_acquire_nonblocking()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_acquired boolean;
BEGIN
    PERFORM test.set_context('test_migration_023_acquire_nonblocking');

    -- Ensure clean state
    PERFORM app_migration.release_lock();

    -- Acquire lock first
    PERFORM app_migration.acquire_lock();

    -- Second acquire succeeds (reentrant within same session)
    l_acquired := app_migration.acquire_lock();
    PERFORM test.ok(l_acquired, 'advisory locks are reentrant within same session');

    -- Clean up (need to release twice since we acquired twice)
    PERFORM app_migration.release_lock();
    PERFORM app_migration.release_lock();
END;
$$;

-- Test: get_lock_holder returns info when locked
CREATE OR REPLACE FUNCTION test.test_migration_024_get_lock_holder()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_holder_count integer;
BEGIN
    PERFORM test.set_context('test_migration_024_get_lock_holder');

    -- Ensure clean state
    PERFORM app_migration.release_lock();

    -- No holder when not locked
    SELECT count(*) INTO l_holder_count FROM app_migration.get_lock_holder();
    PERFORM test.is(l_holder_count, 0, 'get_lock_holder should return 0 rows when not locked');

    -- Acquire lock
    PERFORM app_migration.acquire_lock();

    -- Should have holder info
    SELECT count(*) INTO l_holder_count FROM app_migration.get_lock_holder();
    PERFORM test.is(l_holder_count, 1, 'get_lock_holder should return 1 row when locked');

    -- Clean up
    PERFORM app_migration.release_lock();
END;
$$;

-- Test: acquire_lock_wait with immediate acquire
CREATE OR REPLACE FUNCTION test.test_migration_025_acquire_lock_wait()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_acquired boolean;
BEGIN
    PERFORM test.set_context('test_migration_025_acquire_lock_wait');

    -- Ensure clean state
    PERFORM app_migration.release_lock();

    -- Should acquire immediately
    l_acquired := app_migration.acquire_lock_wait(1);  -- 1 second timeout
    PERFORM test.ok(l_acquired, 'acquire_lock_wait should succeed when lock available');

    -- Clean up
    PERFORM app_migration.release_lock();
END;
$$;

-- Test: acquire_lock_wait succeeds for reentrant acquire (same session)
-- Note: True timeout testing requires multiple database sessions
CREATE OR REPLACE FUNCTION test.test_migration_026_acquire_lock_wait_timeout()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_acquired boolean;
BEGIN
    PERFORM test.set_context('test_migration_026_acquire_lock_wait_timeout');

    -- Ensure clean state
    PERFORM app_migration.release_lock();

    -- Acquire lock first
    PERFORM app_migration.acquire_lock();

    -- Same session acquire_lock_wait should succeed (reentrant)
    l_acquired := app_migration.acquire_lock_wait(1);
    PERFORM test.ok(l_acquired, 'acquire_lock_wait succeeds for same session (reentrant)');

    -- Clean up (release twice)
    PERFORM app_migration.release_lock();
    PERFORM app_migration.release_lock();
END;
$$;

-- Test: Lock survives transaction (advisory locks are session-level)
CREATE OR REPLACE FUNCTION test.test_migration_027_lock_session_level()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_is_locked boolean;
BEGIN
    PERFORM test.set_context('test_migration_027_lock_session_level');

    -- Ensure clean state
    PERFORM app_migration.release_lock();

    -- Acquire in a subtransaction
    BEGIN
        PERFORM app_migration.acquire_lock();
    END;

    -- Lock should still be held (advisory locks are session-level)
    l_is_locked := app_migration.is_locked();
    PERFORM test.ok(l_is_locked, 'advisory lock should persist across subtransaction boundary');

    -- Clean up
    PERFORM app_migration.release_lock();
END;
$$;

-- Test: Lock ID from config is used
CREATE OR REPLACE FUNCTION test.test_migration_028_lock_config()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_lock_id bigint;
BEGIN
    PERFORM test.set_context('test_migration_028_lock_config');

    -- Get configured lock ID
    SELECT lock_id INTO l_lock_id FROM app_migration.lock_config WHERE id = 1;

    PERFORM test.is_not_null(l_lock_id, 'lock_id should be configured');
    PERFORM test.is(l_lock_id, 8675309::bigint, 'lock_id should be default value 8675309');
END;
$$;

-- ============================================================================
-- RUN TESTS
-- ============================================================================

SELECT test.run_module('migration_02');
CALL test.print_run_summary();
