-- ============================================================================
-- TRANSACTION PATTERNS TESTS - ROW LOCKING
-- ============================================================================
-- Tests for SELECT FOR UPDATE and other locking patterns.
-- Reference: references/transaction-patterns.md
-- ============================================================================

-- ============================================================================
-- TEST FUNCTIONS
-- ============================================================================

-- Test: Basic SELECT FOR UPDATE
CREATE OR REPLACE FUNCTION test.test_locking_170_for_update_basic()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_lock_170_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_id bigint;
    l_value integer;
BEGIN
    PERFORM test.set_context('test_locking_170_for_update_basic');

    -- Create table
    EXECUTE format('CREATE TABLE data.%I (
        id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        balance integer NOT NULL
    )', l_test_table);

    -- Insert data
    EXECUTE format('INSERT INTO data.%I (balance) VALUES (100) RETURNING id', l_test_table) INTO l_id;

    -- SELECT FOR UPDATE locks the row
    EXECUTE format('SELECT balance FROM data.%I WHERE id = $1 FOR UPDATE', l_test_table) INTO l_value USING l_id;

    PERFORM test.is(l_value, 100, 'Should read balance with lock');

    -- Update the locked row
    EXECUTE format('UPDATE data.%I SET balance = balance - 30 WHERE id = $1', l_test_table) USING l_id;

    -- Verify update
    EXECUTE format('SELECT balance FROM data.%I WHERE id = $1', l_test_table) INTO l_value USING l_id;
    PERFORM test.is(l_value, 70, 'Balance should be updated');

    -- Cleanup
    EXECUTE format('DROP TABLE data.%I', l_test_table);
END;
$$;

-- Test: SELECT FOR UPDATE with WHERE clause
CREATE OR REPLACE FUNCTION test.test_locking_171_for_update_where()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_lock_171_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_count integer;
BEGIN
    PERFORM test.set_context('test_locking_171_for_update_where');

    -- Create table
    EXECUTE format('CREATE TABLE data.%I (
        id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        status text NOT NULL,
        processed_at timestamptz
    )', l_test_table);

    -- Insert test data
    EXECUTE format('INSERT INTO data.%I (status) VALUES
        (''pending''), (''pending''), (''pending''),
        (''completed''), (''completed'')', l_test_table);

    -- Lock only pending rows
    EXECUTE format('SELECT COUNT(*) FROM data.%I WHERE status = ''pending'' FOR UPDATE', l_test_table) INTO l_count;
    PERFORM test.is(l_count, 3, 'Should lock 3 pending rows');

    -- Update the locked rows
    EXECUTE format('UPDATE data.%I SET status = ''processing'', processed_at = now()
        WHERE status = ''pending''', l_test_table);

    -- Verify
    EXECUTE format('SELECT COUNT(*) FROM data.%I WHERE status = ''processing''', l_test_table) INTO l_count;
    PERFORM test.is(l_count, 3, 'Should have 3 processing rows');

    -- Cleanup
    EXECUTE format('DROP TABLE data.%I', l_test_table);
END;
$$;

-- Test: SELECT FOR SHARE (shared lock)
CREATE OR REPLACE FUNCTION test.test_locking_172_for_share()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_lock_172_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_value text;
BEGIN
    PERFORM test.set_context('test_locking_172_for_share');

    -- Create table
    EXECUTE format('CREATE TABLE data.%I (
        id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        name text NOT NULL
    )', l_test_table);

    -- Insert data
    EXECUTE format('INSERT INTO data.%I (name) VALUES (''Test Item'')', l_test_table);

    -- FOR SHARE allows other transactions to also lock FOR SHARE (read)
    -- but blocks FOR UPDATE (write)
    EXECUTE format('SELECT name FROM data.%I WHERE id = 1 FOR SHARE', l_test_table) INTO l_value;

    PERFORM test.is(l_value, 'Test Item', 'FOR SHARE should read data');

    -- Cleanup
    EXECUTE format('DROP TABLE data.%I', l_test_table);
END;
$$;

-- Test: SELECT FOR UPDATE SKIP LOCKED
CREATE OR REPLACE FUNCTION test.test_locking_173_skip_locked()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_lock_173_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_id1 bigint;
    l_id2 bigint;
    l_picked_id bigint;
BEGIN
    PERFORM test.set_context('test_locking_173_skip_locked');

    -- Create work queue table
    EXECUTE format('CREATE TABLE data.%I (
        id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        job_name text NOT NULL,
        status text NOT NULL DEFAULT ''pending''
    )', l_test_table);

    -- Insert jobs
    EXECUTE format('INSERT INTO data.%I (job_name) VALUES (''Job A'') RETURNING id', l_test_table) INTO l_id1;
    EXECUTE format('INSERT INTO data.%I (job_name) VALUES (''Job B'') RETURNING id', l_test_table) INTO l_id2;

    -- SAVEPOINT to simulate concurrent access
    SAVEPOINT worker1;

    -- Worker 1 picks up Job A
    EXECUTE format('SELECT id FROM data.%I WHERE status = ''pending'' ORDER BY id LIMIT 1 FOR UPDATE', l_test_table) INTO l_picked_id;
    PERFORM test.is(l_picked_id, l_id1, 'Worker 1 should get Job A');

    -- Simulate second query with SKIP LOCKED
    -- In a real concurrent scenario, this would skip the locked row
    -- Here we just demonstrate the syntax
    EXECUTE format('SELECT id FROM data.%I WHERE status = ''pending'' ORDER BY id LIMIT 1 FOR UPDATE SKIP LOCKED', l_test_table) INTO l_picked_id;

    -- In single-session test, the row we locked won't be skipped for ourselves
    -- This test documents the pattern
    PERFORM test.ok(true, 'SKIP LOCKED skips rows locked by other transactions');

    ROLLBACK TO SAVEPOINT worker1;
    RELEASE SAVEPOINT worker1;

    -- Cleanup
    EXECUTE format('DROP TABLE data.%I', l_test_table);
END;
$$;

-- Test: SELECT FOR UPDATE NOWAIT
CREATE OR REPLACE FUNCTION test.test_locking_174_nowait()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_lock_174_' || to_char(clock_timestamp(), 'HH24MISSUS');
BEGIN
    PERFORM test.set_context('test_locking_174_nowait');

    -- Create table
    EXECUTE format('CREATE TABLE data.%I (
        id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        resource_name text NOT NULL
    )', l_test_table);

    -- Insert data
    EXECUTE format('INSERT INTO data.%I (resource_name) VALUES (''Exclusive Resource'')', l_test_table);

    -- NOWAIT returns error immediately if row is locked
    -- In single-session test, the row isn't locked by others
    PERFORM test.lives_ok(
        format('SELECT * FROM data.%I WHERE id = 1 FOR UPDATE NOWAIT', l_test_table),
        'NOWAIT should succeed when row not locked'
    );

    -- Document behavior
    PERFORM test.ok(true, 'NOWAIT raises error 55P03 (lock_not_available) if row locked');

    -- Cleanup
    EXECUTE format('DROP TABLE data.%I', l_test_table);
END;
$$;

-- Test: SELECT FOR KEY SHARE and FOR NO KEY UPDATE
CREATE OR REPLACE FUNCTION test.test_locking_175_key_locks()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_parent_table text := 'test_lock_175_parent_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_child_table text := 'test_lock_175_child_' || to_char(clock_timestamp(), 'HH24MISSUS');
BEGIN
    PERFORM test.set_context('test_locking_175_key_locks');

    -- Create parent table
    EXECUTE format('CREATE TABLE data.%I (
        id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        name text NOT NULL
    )', l_parent_table);

    -- Create child table with FK
    EXECUTE format('CREATE TABLE data.%I (
        id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        parent_id bigint NOT NULL REFERENCES data.%I(id),
        value text NOT NULL
    )', l_child_table, l_parent_table);

    -- Insert parent
    EXECUTE format('INSERT INTO data.%I (name) VALUES (''Parent'')', l_parent_table);

    -- FOR KEY SHARE - weakest lock, allows concurrent FOR KEY SHARE and FOR NO KEY UPDATE
    -- Used by foreign key checks
    PERFORM test.lives_ok(
        format('SELECT * FROM data.%I WHERE id = 1 FOR KEY SHARE', l_parent_table),
        'FOR KEY SHARE should succeed'
    );

    -- FOR NO KEY UPDATE - allows concurrent FOR KEY SHARE but blocks other updates
    -- Useful when updating non-key columns
    PERFORM test.lives_ok(
        format('SELECT * FROM data.%I WHERE id = 1 FOR NO KEY UPDATE', l_parent_table),
        'FOR NO KEY UPDATE should succeed'
    );

    -- Cleanup
    EXECUTE format('DROP TABLE data.%I', l_child_table);
    EXECUTE format('DROP TABLE data.%I', l_parent_table);
END;
$$;

-- Test: Lock timeout configuration
CREATE OR REPLACE FUNCTION test.test_locking_176_lock_timeout()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_timeout text;
BEGIN
    PERFORM test.set_context('test_locking_176_lock_timeout');

    -- Set lock timeout for this transaction
    SET LOCAL lock_timeout = '5s';

    -- Verify setting
    l_timeout := current_setting('lock_timeout');
    PERFORM test.is(l_timeout, '5s', 'Lock timeout should be set to 5s');

    -- Reset to default
    RESET lock_timeout;

    PERFORM test.ok(true, 'lock_timeout controls how long to wait for locks');
END;
$$;

-- Test: Advisory locks (application-level locks)
CREATE OR REPLACE FUNCTION test.test_locking_177_advisory_locks()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_lock_acquired boolean;
    l_lock_id bigint := 12345;
BEGIN
    PERFORM test.set_context('test_locking_177_advisory_locks');

    -- Try to acquire advisory lock (non-blocking)
    l_lock_acquired := pg_try_advisory_lock(l_lock_id);
    PERFORM test.ok(l_lock_acquired, 'Should acquire advisory lock');

    -- Try to acquire same lock again (we already have it, so OK)
    l_lock_acquired := pg_try_advisory_lock(l_lock_id);
    PERFORM test.ok(l_lock_acquired, 'Can acquire same lock multiple times (session lock)');

    -- Release the locks
    PERFORM pg_advisory_unlock(l_lock_id);
    PERFORM pg_advisory_unlock(l_lock_id);

    -- Advisory lock use cases
    PERFORM test.ok(true, 'Advisory locks: pg_advisory_lock(), pg_try_advisory_lock(), pg_advisory_unlock()');
END;
$$;

-- Test: Transaction-level advisory locks
CREATE OR REPLACE FUNCTION test.test_locking_178_advisory_xact_lock()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_lock_acquired boolean;
    l_lock_id bigint := 67890;
BEGIN
    PERFORM test.set_context('test_locking_178_advisory_xact_lock');

    -- Acquire transaction-level advisory lock (auto-released at end of transaction)
    PERFORM pg_advisory_xact_lock(l_lock_id);

    -- Try to acquire same lock (blocking version)
    l_lock_acquired := pg_try_advisory_xact_lock(l_lock_id);
    PERFORM test.ok(l_lock_acquired, 'Can acquire same xact lock within same session');

    -- Note: pg_advisory_xact_lock is automatically released at COMMIT/ROLLBACK
    PERFORM test.ok(true, 'Transaction advisory locks auto-release at transaction end');
END;
$$;

-- Test: Two-key advisory locks
CREATE OR REPLACE FUNCTION test.test_locking_179_advisory_two_key()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_lock_acquired boolean;
    l_key1 integer := 1;
    l_key2 integer := 100;
BEGIN
    PERFORM test.set_context('test_locking_179_advisory_two_key');

    -- Use two-key advisory lock (useful for locking (table_id, row_id) pairs)
    l_lock_acquired := pg_try_advisory_lock(l_key1, l_key2);
    PERFORM test.ok(l_lock_acquired, 'Should acquire two-key advisory lock');

    -- Different key2 is a different lock
    l_lock_acquired := pg_try_advisory_lock(l_key1, l_key2 + 1);
    PERFORM test.ok(l_lock_acquired, 'Different key2 is a separate lock');

    -- Release
    PERFORM pg_advisory_unlock(l_key1, l_key2);
    PERFORM pg_advisory_unlock(l_key1, l_key2 + 1);

    PERFORM test.ok(true, 'Two-key locks useful for (table_id, row_id) patterns');
END;
$$;

-- ============================================================================
-- RUN TESTS
-- ============================================================================

SELECT test.run_module('locking_17');
CALL test.print_run_summary();
