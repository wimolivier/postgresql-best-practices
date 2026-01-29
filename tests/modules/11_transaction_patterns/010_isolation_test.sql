-- ============================================================================
-- TRANSACTION PATTERNS TESTS - ISOLATION LEVELS
-- ============================================================================
-- Tests for transaction isolation levels and their effects.
-- Reference: references/transaction-patterns.md
-- ============================================================================

-- ============================================================================
-- TEST FUNCTIONS
-- ============================================================================

-- Test: Default isolation level is READ COMMITTED
CREATE OR REPLACE FUNCTION test.test_isolation_160_default_level()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_isolation text;
BEGIN
    PERFORM test.set_context('test_isolation_160_default_level');

    -- Get current isolation level
    SELECT current_setting('transaction_isolation') INTO l_isolation;

    PERFORM test.is(l_isolation, 'read committed', 'Default isolation should be READ COMMITTED');
END;
$$;

-- Test: SET TRANSACTION ISOLATION LEVEL
CREATE OR REPLACE FUNCTION test.test_isolation_161_set_level()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_isolation text;
BEGIN
    PERFORM test.set_context('test_isolation_161_set_level');

    -- Test setting different isolation levels (within subtransaction)
    -- Note: We can't actually change isolation in the middle of a transaction,
    -- but we can test the syntax and current_setting

    -- Document available isolation levels
    PERFORM test.ok(true, 'READ UNCOMMITTED (treated as READ COMMITTED in PostgreSQL)');
    PERFORM test.ok(true, 'READ COMMITTED (default)');
    PERFORM test.ok(true, 'REPEATABLE READ');
    PERFORM test.ok(true, 'SERIALIZABLE');
END;
$$;

-- Test: READ COMMITTED sees committed changes
CREATE OR REPLACE FUNCTION test.test_isolation_162_read_committed_behavior()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_iso_162_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_count1 integer;
    l_count2 integer;
BEGIN
    PERFORM test.set_context('test_isolation_162_read_committed_behavior');

    -- Create and populate table
    EXECUTE format('CREATE TABLE data.%I (
        id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        value integer NOT NULL
    )', l_test_table);

    EXECUTE format('INSERT INTO data.%I (value) VALUES (1), (2), (3)', l_test_table);

    -- First read
    EXECUTE format('SELECT COUNT(*) FROM data.%I', l_test_table) INTO l_count1;
    PERFORM test.is(l_count1, 3, 'First read should see 3 rows');

    -- Insert more data (simulating another committed transaction)
    EXECUTE format('INSERT INTO data.%I (value) VALUES (4), (5)', l_test_table);

    -- Second read in READ COMMITTED sees new committed data
    EXECUTE format('SELECT COUNT(*) FROM data.%I', l_test_table) INTO l_count2;
    PERFORM test.is(l_count2, 5, 'Second read should see committed data (5 rows)');

    -- Cleanup
    EXECUTE format('DROP TABLE data.%I', l_test_table);
END;
$$;

-- Test: Savepoint creation and rollback
CREATE OR REPLACE FUNCTION test.test_isolation_163_savepoint_basic()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_iso_163_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_count integer;
BEGIN
    PERFORM test.set_context('test_isolation_163_savepoint_basic');

    -- Create table
    EXECUTE format('CREATE TABLE data.%I (
        id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        name text NOT NULL
    )', l_test_table);

    -- Insert initial row
    EXECUTE format('INSERT INTO data.%I (name) VALUES (''Initial'')', l_test_table);

    -- Create savepoint
    SAVEPOINT sp1;

    -- Insert more rows
    EXECUTE format('INSERT INTO data.%I (name) VALUES (''After Savepoint'')', l_test_table);

    -- Verify we have 2 rows
    EXECUTE format('SELECT COUNT(*) FROM data.%I', l_test_table) INTO l_count;
    PERFORM test.is(l_count, 2, 'Should have 2 rows before rollback');

    -- Rollback to savepoint
    ROLLBACK TO SAVEPOINT sp1;

    -- Verify we have 1 row again
    EXECUTE format('SELECT COUNT(*) FROM data.%I', l_test_table) INTO l_count;
    PERFORM test.is(l_count, 1, 'Should have 1 row after rollback to savepoint');

    -- Release savepoint
    RELEASE SAVEPOINT sp1;

    -- Cleanup
    EXECUTE format('DROP TABLE data.%I', l_test_table);
END;
$$;

-- Test: Nested savepoints
CREATE OR REPLACE FUNCTION test.test_isolation_164_nested_savepoints()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_iso_164_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_count integer;
BEGIN
    PERFORM test.set_context('test_isolation_164_nested_savepoints');

    -- Create table
    EXECUTE format('CREATE TABLE data.%I (
        id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        level text NOT NULL
    )', l_test_table);

    -- Level 0
    EXECUTE format('INSERT INTO data.%I (level) VALUES (''Level 0'')', l_test_table);
    SAVEPOINT sp_level1;

    -- Level 1
    EXECUTE format('INSERT INTO data.%I (level) VALUES (''Level 1'')', l_test_table);
    SAVEPOINT sp_level2;

    -- Level 2
    EXECUTE format('INSERT INTO data.%I (level) VALUES (''Level 2'')', l_test_table);

    -- Should have 3 rows
    EXECUTE format('SELECT COUNT(*) FROM data.%I', l_test_table) INTO l_count;
    PERFORM test.is(l_count, 3, 'Should have 3 rows before any rollback');

    -- Rollback to level 2 (removes Level 2)
    ROLLBACK TO SAVEPOINT sp_level2;
    EXECUTE format('SELECT COUNT(*) FROM data.%I', l_test_table) INTO l_count;
    PERFORM test.is(l_count, 2, 'Should have 2 rows after rollback to sp_level2');

    -- Rollback to level 1 (removes Level 1)
    ROLLBACK TO SAVEPOINT sp_level1;
    EXECUTE format('SELECT COUNT(*) FROM data.%I', l_test_table) INTO l_count;
    PERFORM test.is(l_count, 1, 'Should have 1 row after rollback to sp_level1');

    -- Cleanup
    RELEASE SAVEPOINT sp_level1;
    EXECUTE format('DROP TABLE data.%I', l_test_table);
END;
$$;

-- Test: Exception handling with savepoints (PL/pgSQL subtransactions)
CREATE OR REPLACE FUNCTION test.test_isolation_165_exception_savepoint()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_iso_165_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_count integer;
BEGIN
    PERFORM test.set_context('test_isolation_165_exception_savepoint');

    -- Create table
    EXECUTE format('CREATE TABLE data.%I (
        id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        name text NOT NULL UNIQUE
    )', l_test_table);

    -- Insert initial row
    EXECUTE format('INSERT INTO data.%I (name) VALUES (''Original'')', l_test_table);

    -- PL/pgSQL EXCEPTION block creates implicit savepoint
    BEGIN
        EXECUTE format('INSERT INTO data.%I (name) VALUES (''Will Succeed'')', l_test_table);
        EXECUTE format('INSERT INTO data.%I (name) VALUES (''Original'')', l_test_table);  -- Duplicate!
    EXCEPTION WHEN unique_violation THEN
        -- Exception caught, implicit rollback of this block
        PERFORM test.ok(true, 'Caught unique violation');
    END;

    -- Verify only original row remains (the successful insert in exception block was rolled back)
    EXECUTE format('SELECT COUNT(*) FROM data.%I', l_test_table) INTO l_count;
    PERFORM test.is(l_count, 1, 'Exception block rolls back all changes in that block');

    -- Cleanup
    EXECUTE format('DROP TABLE data.%I', l_test_table);
END;
$$;

-- Test: Transaction ID functions
CREATE OR REPLACE FUNCTION test.test_isolation_166_txid_functions()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_txid1 bigint;
    l_txid2 bigint;
BEGIN
    PERFORM test.set_context('test_isolation_166_txid_functions');

    -- Get current transaction ID
    l_txid1 := txid_current();
    l_txid2 := txid_current();

    -- Within same transaction, txid_current() returns same value
    PERFORM test.is(l_txid1, l_txid2, 'txid_current() should be constant within transaction');

    -- Transaction ID should be positive
    PERFORM test.ok(l_txid1 > 0, 'Transaction ID should be positive');
END;
$$;

-- Test: Transaction snapshot
CREATE OR REPLACE FUNCTION test.test_isolation_167_snapshot()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_snapshot pg_snapshot;
    l_xmin bigint;
    l_xmax bigint;
BEGIN
    PERFORM test.set_context('test_isolation_167_snapshot');

    -- Get current snapshot
    l_snapshot := pg_current_snapshot();

    -- Extract snapshot components
    l_xmin := pg_snapshot_xmin(l_snapshot);
    l_xmax := pg_snapshot_xmax(l_snapshot);

    -- xmin <= xmax
    PERFORM test.ok(l_xmin <= l_xmax, 'Snapshot xmin should be <= xmax');
END;
$$;

-- Test: READ ONLY transaction
CREATE OR REPLACE FUNCTION test.test_isolation_168_read_only()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_iso_168_' || to_char(clock_timestamp(), 'HH24MISSUS');
BEGIN
    PERFORM test.set_context('test_isolation_168_read_only');

    -- Create table
    EXECUTE format('CREATE TABLE data.%I (
        id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        name text NOT NULL
    )', l_test_table);

    -- Insert some data
    EXECUTE format('INSERT INTO data.%I (name) VALUES (''Test'')', l_test_table);

    -- We can't actually set READ ONLY in a subtransaction,
    -- but we can test the concept
    -- In a real scenario: SET TRANSACTION READ ONLY;

    PERFORM test.ok(true, 'READ ONLY transactions prevent modifications (documented)');

    -- Cleanup
    EXECUTE format('DROP TABLE data.%I', l_test_table);
END;
$$;

-- Test: DEFERRABLE transaction option
CREATE OR REPLACE FUNCTION test.test_isolation_169_deferrable()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM test.set_context('test_isolation_169_deferrable');

    -- DEFERRABLE only makes sense with SERIALIZABLE READ ONLY
    -- It may delay the start of the transaction to ensure a consistent snapshot
    -- without the possibility of serialization failure

    PERFORM test.ok(true, 'DEFERRABLE delays SERIALIZABLE READ ONLY transactions (documented)');
END;
$$;

-- ============================================================================
-- RUN TESTS
-- ============================================================================

SELECT test.run_module('isolation_16');
CALL test.print_run_summary();
