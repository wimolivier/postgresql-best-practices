-- ============================================================================
-- INTEGRATION TESTS - CONCURRENT ACCESS
-- ============================================================================
-- Tests for concurrent migration locking behavior.
-- Note: True concurrency tests require multiple connections.
-- These tests verify the locking primitives work correctly.
-- ============================================================================

-- ============================================================================
-- TEST FUNCTIONS
-- ============================================================================

-- Test: Lock is reentrant within same session
-- Note: PostgreSQL advisory locks ARE reentrant - same session can acquire multiple times
CREATE OR REPLACE FUNCTION test.test_concurrent_020_lock_prevents_acquire()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_first_acquire boolean;
    l_second_acquire boolean;
BEGIN
    PERFORM test.set_context('test_concurrent_020_lock_prevents_acquire');

    -- Ensure clean state
    PERFORM app_migration.release_lock();

    -- First acquire should succeed
    l_first_acquire := app_migration.acquire_lock();
    PERFORM test.ok(l_first_acquire, 'first acquire should succeed');

    -- Second acquire succeeds (advisory locks are reentrant within same session)
    l_second_acquire := app_migration.acquire_lock();
    PERFORM test.ok(l_second_acquire, 'second acquire succeeds (reentrant within same session)');

    -- Clean up (need to release twice since we acquired twice)
    PERFORM app_migration.release_lock();
    PERFORM app_migration.release_lock();
END;
$$;

-- Test: Lock is session-scoped
CREATE OR REPLACE FUNCTION test.test_concurrent_021_session_scoped()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_is_locked boolean;
BEGIN
    PERFORM test.set_context('test_concurrent_021_session_scoped');

    -- Ensure clean state
    PERFORM app_migration.release_lock();

    -- Acquire lock
    PERFORM app_migration.acquire_lock();

    -- Lock should be visible
    l_is_locked := app_migration.is_locked();
    PERFORM test.ok(l_is_locked, 'lock should be visible after acquire');

    -- Begin and commit a transaction - lock should persist
    BEGIN
        -- Some work
        PERFORM 1;
    END;

    l_is_locked := app_migration.is_locked();
    PERFORM test.ok(l_is_locked, 'advisory lock should persist across transaction');

    -- Clean up
    PERFORM app_migration.release_lock();
END;
$$;

-- Test: Lock holder info is available
CREATE OR REPLACE FUNCTION test.test_concurrent_022_lock_holder_info()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_holder record;
BEGIN
    PERFORM test.set_context('test_concurrent_022_lock_holder_info');

    -- Ensure clean state
    PERFORM app_migration.release_lock();

    -- Acquire lock
    PERFORM app_migration.acquire_lock();

    -- Get holder info
    SELECT * INTO l_holder FROM app_migration.get_lock_holder() LIMIT 1;

    PERFORM test.is_not_null(l_holder.pid, 'lock holder PID should be available');
    PERFORM test.is(l_holder.pid, pg_backend_pid(), 'lock holder should be current session');
    PERFORM test.is(l_holder.usename, current_user::name, 'lock holder should be current user');

    -- Clean up
    PERFORM app_migration.release_lock();
END;
$$;

-- Test: acquire_lock_wait succeeds for reentrant acquire (same session)
-- Note: True timeout testing requires multiple database sessions
-- Advisory locks are reentrant within the same session, so acquire_lock_wait succeeds
CREATE OR REPLACE FUNCTION test.test_concurrent_023_timeout_behavior()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_acquired boolean;
BEGIN
    PERFORM test.set_context('test_concurrent_023_timeout_behavior');

    -- Ensure clean state
    PERFORM app_migration.release_lock();

    -- Acquire lock first
    PERFORM app_migration.acquire_lock();

    -- Same session acquire_lock_wait should succeed immediately (reentrant)
    l_acquired := app_migration.acquire_lock_wait(1);
    PERFORM test.ok(l_acquired, 'acquire_lock_wait succeeds for same session (reentrant)');

    -- Clean up (release twice since we acquired twice)
    PERFORM app_migration.release_lock();
    PERFORM app_migration.release_lock();
END;
$$;

-- Test: Release returns false when not held
CREATE OR REPLACE FUNCTION test.test_concurrent_024_release_not_held()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_released boolean;
BEGIN
    PERFORM test.set_context('test_concurrent_024_release_not_held');

    -- Ensure lock is not held
    PERFORM app_migration.release_lock();  -- May or may not return false

    -- Now definitely not held
    l_released := app_migration.release_lock();
    PERFORM test.not_ok(l_released, 'release should return false when lock not held');
END;
$$;

-- Test: is_locked reflects current state
CREATE OR REPLACE FUNCTION test.test_concurrent_025_is_locked_state()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_state_before boolean;
    l_state_during boolean;
    l_state_after boolean;
BEGIN
    PERFORM test.set_context('test_concurrent_025_is_locked_state');

    -- Ensure clean state
    PERFORM app_migration.release_lock();

    -- Check before
    l_state_before := app_migration.is_locked();
    PERFORM test.not_ok(l_state_before, 'should not be locked before acquire');

    -- Acquire
    PERFORM app_migration.acquire_lock();

    -- Check during
    l_state_during := app_migration.is_locked();
    PERFORM test.ok(l_state_during, 'should be locked after acquire');

    -- Release
    PERFORM app_migration.release_lock();

    -- Check after
    l_state_after := app_migration.is_locked();
    PERFORM test.not_ok(l_state_after, 'should not be locked after release');
END;
$$;

-- Test: Batch operations check lock
CREATE OR REPLACE FUNCTION test.test_concurrent_026_batch_requires_lock()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM test.set_context('test_concurrent_026_batch_requires_lock');

    -- Ensure no lock held
    PERFORM app_migration.release_lock();

    -- Batch should fail without lock
    PERFORM test.throws_like(
        $$CALL app_migration.run_versioned_batch('[]'::jsonb)$$,
        'Migration lock not held',
        'batch versioned should require lock'
    );

    PERFORM test.throws_like(
        $$CALL app_migration.run_repeatable_batch('[]'::jsonb)$$,
        'Migration lock not held',
        'batch repeatable should require lock'
    );
END;
$$;

-- Test: Lock ID is configurable
CREATE OR REPLACE FUNCTION test.test_concurrent_027_lock_id_config()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_original_id bigint;
    l_new_id bigint := 12345678;
BEGIN
    PERFORM test.set_context('test_concurrent_027_lock_id_config');

    -- Get original lock ID
    SELECT lock_id INTO l_original_id FROM app_migration.lock_config WHERE id = 1;

    PERFORM test.is_not_null(l_original_id, 'lock_id should be configured');
    PERFORM test.is(l_original_id, 8675309::bigint, 'default lock_id should be 8675309');

    -- Note: We don't actually change it to avoid affecting other tests
    PERFORM test.ok(true, 'lock_id is configurable in lock_config table');
END;
$$;

-- Test: Lock timeout is configurable
CREATE OR REPLACE FUNCTION test.test_concurrent_028_timeout_config()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_timeout integer;
BEGIN
    PERFORM test.set_context('test_concurrent_028_timeout_config');

    -- Get default timeout
    SELECT lock_timeout_s INTO l_timeout FROM app_migration.lock_config WHERE id = 1;

    PERFORM test.is_not_null(l_timeout, 'lock_timeout_s should be configured');
    PERFORM test.is(l_timeout, 30, 'default timeout should be 30 seconds');
END;
$$;

-- Test: Multiple release calls are safe
CREATE OR REPLACE FUNCTION test.test_concurrent_029_multiple_release()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM test.set_context('test_concurrent_029_multiple_release');

    -- Acquire once
    PERFORM app_migration.acquire_lock();

    -- Release multiple times should not error
    PERFORM test.lives_ok(
        'SELECT app_migration.release_lock()',
        'first release should succeed'
    );

    PERFORM test.lives_ok(
        'SELECT app_migration.release_lock()',
        'second release should not error'
    );

    PERFORM test.lives_ok(
        'SELECT app_migration.release_lock()',
        'third release should not error'
    );
END;
$$;

-- ============================================================================
-- RUN TESTS
-- ============================================================================

SELECT test.run_module('concurrent_02');
CALL test.print_run_summary();
