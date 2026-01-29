-- ============================================================================
-- ADVANCED INDEXING TESTS - PARTIAL INDEXES
-- ============================================================================
-- Tests for partial indexes with WHERE clauses.
-- Reference: references/indexes-constraints.md
-- ============================================================================

-- ============================================================================
-- TEST FUNCTIONS
-- ============================================================================

-- Test: Create partial index with WHERE clause
CREATE OR REPLACE FUNCTION test.test_partial_100_create_basic()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_partial_100_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_index_name text;
BEGIN
    PERFORM test.set_context('test_partial_100_create_basic');

    -- Create table with status column
    EXECUTE format('CREATE TABLE data.%I (
        id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        email text NOT NULL,
        status text NOT NULL DEFAULT ''active''
    )', l_test_table);

    -- Create partial index for active records only
    l_index_name := l_test_table || '_active_email_idx';
    EXECUTE format('CREATE INDEX %I ON data.%I (email) WHERE status = ''active''', l_index_name, l_test_table);

    -- Verify index exists
    PERFORM test.has_index('data', l_test_table, l_index_name, 'Partial index should exist');

    -- Cleanup
    EXECUTE format('DROP TABLE data.%I', l_test_table);
END;
$$;

-- Test: Partial unique index (common for soft delete)
CREATE OR REPLACE FUNCTION test.test_partial_101_unique_active()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_partial_101_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_index_name text;
BEGIN
    PERFORM test.set_context('test_partial_101_unique_active');

    -- Create table with soft delete pattern
    EXECUTE format('CREATE TABLE data.%I (
        id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        email text NOT NULL,
        deleted_at timestamptz
    )', l_test_table);

    -- Create unique index only for non-deleted records
    l_index_name := l_test_table || '_email_uniq_active_idx';
    EXECUTE format('CREATE UNIQUE INDEX %I ON data.%I (email) WHERE deleted_at IS NULL', l_index_name, l_test_table);

    -- Insert first active record
    EXECUTE format('INSERT INTO data.%I (email) VALUES (''user@example.com'')', l_test_table);

    -- Soft-delete the record
    EXECUTE format('UPDATE data.%I SET deleted_at = now() WHERE email = ''user@example.com''', l_test_table);

    -- Insert same email again (should work - previous is deleted)
    PERFORM test.lives_ok(
        format('INSERT INTO data.%I (email) VALUES (''user@example.com'')', l_test_table),
        'Should allow same email after soft delete'
    );

    -- Third insert should fail (duplicate active)
    PERFORM test.throws_ok(
        format('INSERT INTO data.%I (email) VALUES (''user@example.com'')', l_test_table),
        '23505',  -- unique_violation
        'Duplicate active email should fail'
    );

    -- Cleanup
    EXECUTE format('DROP TABLE data.%I', l_test_table);
END;
$$;

-- Test: Partial index on boolean condition
CREATE OR REPLACE FUNCTION test.test_partial_102_boolean_condition()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_partial_102_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_index_name text;
    l_count integer;
BEGIN
    PERFORM test.set_context('test_partial_102_boolean_condition');

    -- Create table with boolean flag
    EXECUTE format('CREATE TABLE data.%I (
        id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        task_name text NOT NULL,
        is_pending boolean NOT NULL DEFAULT true,
        priority integer NOT NULL DEFAULT 0
    )', l_test_table);

    -- Create partial index for pending tasks only
    l_index_name := l_test_table || '_pending_priority_idx';
    EXECUTE format('CREATE INDEX %I ON data.%I (priority DESC) WHERE is_pending = true', l_index_name, l_test_table);

    -- Insert test data
    EXECUTE format('INSERT INTO data.%I (task_name, is_pending, priority) VALUES
        (''Task A'', true, 5),
        (''Task B'', true, 10),
        (''Task C'', false, 15),
        (''Task D'', true, 3)', l_test_table);

    -- Query using the partial index condition
    EXECUTE format('SELECT COUNT(*) FROM data.%I WHERE is_pending = true AND priority > 4', l_test_table) INTO l_count;
    PERFORM test.is(l_count, 2, 'Should find 2 pending tasks with priority > 4');

    -- Cleanup
    EXECUTE format('DROP TABLE data.%I', l_test_table);
END;
$$;

-- Test: Partial index with IS NOT NULL
CREATE OR REPLACE FUNCTION test.test_partial_103_not_null()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_partial_103_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_index_name text;
BEGIN
    PERFORM test.set_context('test_partial_103_not_null');

    -- Create table with optional field
    EXECUTE format('CREATE TABLE data.%I (
        id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        name text NOT NULL,
        phone text
    )', l_test_table);

    -- Index only rows that have phone numbers
    l_index_name := l_test_table || '_phone_idx';
    EXECUTE format('CREATE INDEX %I ON data.%I (phone) WHERE phone IS NOT NULL', l_index_name, l_test_table);

    -- Verify index exists
    PERFORM test.has_index('data', l_test_table, l_index_name, 'Partial index on non-null phone should exist');

    -- Cleanup
    EXECUTE format('DROP TABLE data.%I', l_test_table);
END;
$$;

-- Test: Partial index with IN clause
CREATE OR REPLACE FUNCTION test.test_partial_104_in_clause()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_partial_104_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_index_name text;
BEGIN
    PERFORM test.set_context('test_partial_104_in_clause');

    -- Create table with status
    EXECUTE format('CREATE TABLE data.%I (
        id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        order_number text NOT NULL,
        status text NOT NULL
    )', l_test_table);

    -- Index only actionable statuses
    l_index_name := l_test_table || '_actionable_idx';
    EXECUTE format('CREATE INDEX %I ON data.%I (order_number) WHERE status IN (''pending'', ''processing'', ''shipped'')', l_index_name, l_test_table);

    -- Verify index exists
    PERFORM test.has_index('data', l_test_table, l_index_name, 'Partial index with IN clause should exist');

    -- Cleanup
    EXECUTE format('DROP TABLE data.%I', l_test_table);
END;
$$;

-- Test: Partial index with comparison operator
CREATE OR REPLACE FUNCTION test.test_partial_105_comparison()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_partial_105_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_index_name text;
    l_count integer;
BEGIN
    PERFORM test.set_context('test_partial_105_comparison');

    -- Create table with amount
    EXECUTE format('CREATE TABLE data.%I (
        id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        transaction_id text NOT NULL,
        amount numeric(12,2) NOT NULL
    )', l_test_table);

    -- Index only high-value transactions
    l_index_name := l_test_table || '_highvalue_idx';
    EXECUTE format('CREATE INDEX %I ON data.%I (transaction_id) WHERE amount >= 10000', l_index_name, l_test_table);

    -- Insert test data
    EXECUTE format('INSERT INTO data.%I (transaction_id, amount) VALUES
        (''TXN-001'', 500.00),
        (''TXN-002'', 15000.00),
        (''TXN-003'', 10000.00),
        (''TXN-004'', 9999.99)', l_test_table);

    -- Query high-value transactions
    EXECUTE format('SELECT COUNT(*) FROM data.%I WHERE amount >= 10000', l_test_table) INTO l_count;
    PERFORM test.is(l_count, 2, 'Should find 2 high-value transactions');

    -- Cleanup
    EXECUTE format('DROP TABLE data.%I', l_test_table);
END;
$$;

-- Test: Partial index size savings
CREATE OR REPLACE FUNCTION test.test_partial_106_size_comparison()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_partial_106_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_full_idx text;
    l_partial_idx text;
    l_full_size bigint;
    l_partial_size bigint;
BEGIN
    PERFORM test.set_context('test_partial_106_size_comparison');

    -- Create table
    EXECUTE format('CREATE TABLE data.%I (
        id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        code text NOT NULL,
        is_active boolean NOT NULL DEFAULT false
    )', l_test_table);

    -- Insert data with only 5% active
    EXECUTE format('INSERT INTO data.%I (code, is_active)
        SELECT ''CODE-'' || i, (i %% 20 = 0)
        FROM generate_series(1, 1000) i', l_test_table);

    -- Create full index
    l_full_idx := l_test_table || '_code_full_idx';
    EXECUTE format('CREATE INDEX %I ON data.%I (code)', l_full_idx, l_test_table);

    -- Create partial index
    l_partial_idx := l_test_table || '_code_partial_idx';
    EXECUTE format('CREATE INDEX %I ON data.%I (code) WHERE is_active = true', l_partial_idx, l_test_table);

    -- Compare sizes
    SELECT pg_relation_size(('data.' || l_full_idx)::regclass) INTO l_full_size;
    SELECT pg_relation_size(('data.' || l_partial_idx)::regclass) INTO l_partial_size;

    PERFORM test.ok(l_partial_size < l_full_size, 'Partial index should be smaller than full index');

    -- Cleanup
    EXECUTE format('DROP TABLE data.%I', l_test_table);
END;
$$;

-- Test: Partial index with complex expression
CREATE OR REPLACE FUNCTION test.test_partial_107_complex_expression()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_partial_107_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_index_name text;
BEGIN
    PERFORM test.set_context('test_partial_107_complex_expression');

    -- Create table
    EXECUTE format('CREATE TABLE data.%I (
        id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        email text NOT NULL,
        verified_at timestamptz,
        banned_at timestamptz
    )', l_test_table);

    -- Index only verified, non-banned users
    l_index_name := l_test_table || '_verified_notbanned_idx';
    EXECUTE format('CREATE INDEX %I ON data.%I (email) WHERE verified_at IS NOT NULL AND banned_at IS NULL', l_index_name, l_test_table);

    -- Verify index exists
    PERFORM test.has_index('data', l_test_table, l_index_name, 'Complex partial index should exist');

    -- Cleanup
    EXECUTE format('DROP TABLE data.%I', l_test_table);
END;
$$;

-- Test: Partial index on timestamp range
CREATE OR REPLACE FUNCTION test.test_partial_108_timestamp_range()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_partial_108_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_index_name text;
    l_count integer;
BEGIN
    PERFORM test.set_context('test_partial_108_timestamp_range');

    -- Create table with timestamp
    EXECUTE format('CREATE TABLE data.%I (
        id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        event_name text NOT NULL,
        created_at timestamptz NOT NULL DEFAULT now()
    )', l_test_table);

    -- Index only recent records (last 30 days) - note: this is for pattern demonstration
    l_index_name := l_test_table || '_recent_idx';
    EXECUTE format('CREATE INDEX %I ON data.%I (event_name) WHERE created_at >= now() - interval ''30 days''', l_index_name, l_test_table);

    -- Insert test data
    EXECUTE format('INSERT INTO data.%I (event_name, created_at) VALUES
        (''Recent Event 1'', now()),
        (''Recent Event 2'', now() - interval ''10 days''),
        (''Old Event'', now() - interval ''60 days'')', l_test_table);

    -- Query recent events
    EXECUTE format('SELECT COUNT(*) FROM data.%I WHERE created_at >= now() - interval ''30 days''', l_test_table) INTO l_count;
    PERFORM test.is(l_count, 2, 'Should find 2 recent events');

    -- Cleanup
    EXECUTE format('DROP TABLE data.%I', l_test_table);
END;
$$;

-- ============================================================================
-- RUN TESTS
-- ============================================================================

SELECT test.run_module('partial_10');
CALL test.print_run_summary();
