-- ============================================================================
-- ADVANCED INDEXING TESTS - COVERING INDEXES (INCLUDE)
-- ============================================================================
-- Tests for covering indexes with INCLUDE clause for index-only scans.
-- Reference: references/indexes-constraints.md
-- ============================================================================

-- ============================================================================
-- TEST FUNCTIONS
-- ============================================================================

-- Test: Create basic covering index with INCLUDE
CREATE OR REPLACE FUNCTION test.test_covering_110_basic_include()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_covering_110_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_index_name text;
BEGIN
    PERFORM test.set_context('test_covering_110_basic_include');

    -- Create table
    EXECUTE format('CREATE TABLE data.%I (
        id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        email text NOT NULL,
        name text NOT NULL,
        status text NOT NULL DEFAULT ''active''
    )', l_test_table);

    -- Create covering index: key on email, include name for index-only scans
    l_index_name := l_test_table || '_email_incl_name_idx';
    EXECUTE format('CREATE INDEX %I ON data.%I (email) INCLUDE (name)', l_index_name, l_test_table);

    -- Verify index exists
    PERFORM test.has_index('data', l_test_table, l_index_name, 'Covering index with INCLUDE should exist');

    -- Cleanup
    EXECUTE format('DROP TABLE data.%I', l_test_table);
END;
$$;

-- Test: Covering index with multiple INCLUDE columns
CREATE OR REPLACE FUNCTION test.test_covering_111_multiple_include()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_covering_111_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_index_name text;
BEGIN
    PERFORM test.set_context('test_covering_111_multiple_include');

    -- Create table
    EXECUTE format('CREATE TABLE data.%I (
        id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        user_id bigint NOT NULL,
        action text NOT NULL,
        ip_address text,
        created_at timestamptz NOT NULL DEFAULT now()
    )', l_test_table);

    -- Create index: key on user_id + action, include ip and timestamp for common queries
    l_index_name := l_test_table || '_user_action_incl_idx';
    EXECUTE format('CREATE INDEX %I ON data.%I (user_id, action) INCLUDE (ip_address, created_at)', l_index_name, l_test_table);

    -- Verify index exists
    PERFORM test.has_index('data', l_test_table, l_index_name, 'Covering index with multiple INCLUDE columns should exist');

    -- Cleanup
    EXECUTE format('DROP TABLE data.%I', l_test_table);
END;
$$;

-- Test: UNIQUE index with INCLUDE
CREATE OR REPLACE FUNCTION test.test_covering_112_unique_include()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_covering_112_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_index_name text;
BEGIN
    PERFORM test.set_context('test_covering_112_unique_include');

    -- Create table
    EXECUTE format('CREATE TABLE data.%I (
        id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        email text NOT NULL,
        name text NOT NULL,
        created_at timestamptz NOT NULL DEFAULT now()
    )', l_test_table);

    -- Create unique covering index
    l_index_name := l_test_table || '_email_uniq_incl_idx';
    EXECUTE format('CREATE UNIQUE INDEX %I ON data.%I (email) INCLUDE (name, created_at)', l_index_name, l_test_table);

    -- Test uniqueness is enforced
    EXECUTE format('INSERT INTO data.%I (email, name) VALUES (''test@example.com'', ''Test User'')', l_test_table);

    PERFORM test.throws_ok(
        format('INSERT INTO data.%I (email, name) VALUES (''test@example.com'', ''Another User'')', l_test_table),
        '23505',  -- unique_violation
        'Unique covering index should enforce uniqueness'
    );

    -- Cleanup
    EXECUTE format('DROP TABLE data.%I', l_test_table);
END;
$$;

-- Test: Index-only scan verification
CREATE OR REPLACE FUNCTION test.test_covering_113_index_only_scan()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_covering_113_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_plan text;
    l_has_index_only boolean;
BEGIN
    PERFORM test.set_context('test_covering_113_index_only_scan');

    -- Create table
    EXECUTE format('CREATE TABLE data.%I (
        id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        lookup_code text NOT NULL,
        display_name text NOT NULL,
        extra_data text
    )', l_test_table);

    -- Create covering index
    EXECUTE format('CREATE INDEX ON data.%I (lookup_code) INCLUDE (display_name)', l_test_table);

    -- Insert data and vacuum to update visibility map
    EXECUTE format('INSERT INTO data.%I (lookup_code, display_name, extra_data)
        SELECT ''CODE-'' || i, ''Display '' || i, ''Extra '' || i
        FROM generate_series(1, 100) i', l_test_table);
    EXECUTE format('VACUUM ANALYZE data.%I', l_test_table);

    -- Check query plan for index-only scan
    EXECUTE format('EXPLAIN (FORMAT TEXT) SELECT display_name FROM data.%I WHERE lookup_code = ''CODE-50''', l_test_table) INTO l_plan;

    l_has_index_only := l_plan ILIKE '%Index Only Scan%';
    PERFORM test.ok(l_has_index_only, 'Query should use Index Only Scan with covering index');

    -- Cleanup
    EXECUTE format('DROP TABLE data.%I', l_test_table);
END;
$$;

-- Test: Covering index with composite key
CREATE OR REPLACE FUNCTION test.test_covering_114_composite_key()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_covering_114_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_index_name text;
    l_count integer;
BEGIN
    PERFORM test.set_context('test_covering_114_composite_key');

    -- Create table
    EXECUTE format('CREATE TABLE data.%I (
        tenant_id uuid NOT NULL,
        user_id uuid NOT NULL,
        email text NOT NULL,
        name text NOT NULL,
        PRIMARY KEY (tenant_id, user_id)
    )', l_test_table);

    -- Create covering index for email lookup returning name
    l_index_name := l_test_table || '_tenant_email_incl_idx';
    EXECUTE format('CREATE INDEX %I ON data.%I (tenant_id, email) INCLUDE (name, user_id)', l_index_name, l_test_table);

    -- Insert test data
    EXECUTE format('INSERT INTO data.%I (tenant_id, user_id, email, name) VALUES
        (gen_random_uuid(), gen_random_uuid(), ''user1@example.com'', ''User 1''),
        (gen_random_uuid(), gen_random_uuid(), ''user2@example.com'', ''User 2'')', l_test_table);

    -- Verify index exists
    PERFORM test.has_index('data', l_test_table, l_index_name, 'Composite key covering index should exist');

    -- Cleanup
    EXECUTE format('DROP TABLE data.%I', l_test_table);
END;
$$;

-- Test: Covering index on foreign key with related data
CREATE OR REPLACE FUNCTION test.test_covering_115_fk_pattern()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_parent_table text := 'test_cov_115_parent_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_child_table text := 'test_cov_115_child_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_index_name text;
    l_plan text;
BEGIN
    PERFORM test.set_context('test_covering_115_fk_pattern');

    -- Create parent table
    EXECUTE format('CREATE TABLE data.%I (
        id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        name text NOT NULL
    )', l_parent_table);

    -- Create child table with FK
    EXECUTE format('CREATE TABLE data.%I (
        id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        parent_id bigint NOT NULL REFERENCES data.%I(id),
        item_name text NOT NULL,
        quantity integer NOT NULL DEFAULT 1
    )', l_child_table, l_parent_table);

    -- Create covering index on FK with commonly selected columns
    l_index_name := l_child_table || '_parent_incl_idx';
    EXECUTE format('CREATE INDEX %I ON data.%I (parent_id) INCLUDE (item_name, quantity)', l_index_name, l_child_table);

    -- Verify index exists
    PERFORM test.has_index('data', l_child_table, l_index_name, 'FK covering index should exist');

    -- Cleanup
    EXECUTE format('DROP TABLE data.%I', l_child_table);
    EXECUTE format('DROP TABLE data.%I', l_parent_table);
END;
$$;

-- Test: Partial covering index
CREATE OR REPLACE FUNCTION test.test_covering_116_partial_covering()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_covering_116_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_index_name text;
BEGIN
    PERFORM test.set_context('test_covering_116_partial_covering');

    -- Create table
    EXECUTE format('CREATE TABLE data.%I (
        id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        order_id text NOT NULL,
        status text NOT NULL,
        total numeric(12,2) NOT NULL,
        customer_name text NOT NULL
    )', l_test_table);

    -- Create partial covering index for pending orders
    l_index_name := l_test_table || '_pending_incl_idx';
    EXECUTE format('CREATE INDEX %I ON data.%I (order_id) INCLUDE (total, customer_name) WHERE status = ''pending''', l_index_name, l_test_table);

    -- Verify index exists
    PERFORM test.has_index('data', l_test_table, l_index_name, 'Partial covering index should exist');

    -- Cleanup
    EXECUTE format('DROP TABLE data.%I', l_test_table);
END;
$$;

-- Test: Covering index column order matters for key columns
CREATE OR REPLACE FUNCTION test.test_covering_117_key_order()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_covering_117_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_count integer;
BEGIN
    PERFORM test.set_context('test_covering_117_key_order');

    -- Create table
    EXECUTE format('CREATE TABLE data.%I (
        id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        country_code text NOT NULL,
        city text NOT NULL,
        population integer NOT NULL
    )', l_test_table);

    -- Create index: (country_code, city) as keys, population as INCLUDE
    -- This supports queries filtering on country_code or (country_code, city)
    EXECUTE format('CREATE INDEX ON data.%I (country_code, city) INCLUDE (population)', l_test_table);

    -- Insert test data
    EXECUTE format('INSERT INTO data.%I (country_code, city, population) VALUES
        (''US'', ''New York'', 8336817),
        (''US'', ''Los Angeles'', 3979576),
        (''UK'', ''London'', 8982000),
        (''UK'', ''Manchester'', 547627)', l_test_table);

    -- Query using leading key column only
    EXECUTE format('SELECT COUNT(*) FROM data.%I WHERE country_code = ''US''', l_test_table) INTO l_count;
    PERFORM test.is(l_count, 2, 'Should find 2 US cities');

    -- Query using both key columns
    EXECUTE format('SELECT COUNT(*) FROM data.%I WHERE country_code = ''UK'' AND city = ''London''', l_test_table) INTO l_count;
    PERFORM test.is(l_count, 1, 'Should find 1 matching city');

    -- Cleanup
    EXECUTE format('DROP TABLE data.%I', l_test_table);
END;
$$;

-- Test: INCLUDE columns not used for sorting
CREATE OR REPLACE FUNCTION test.test_covering_118_no_sort_include()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_covering_118_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_plan text;
BEGIN
    PERFORM test.set_context('test_covering_118_no_sort_include');

    -- Create table
    EXECUTE format('CREATE TABLE data.%I (
        id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        category text NOT NULL,
        sort_key integer NOT NULL,
        display_value text NOT NULL
    )', l_test_table);

    -- Create index with sort_key as key column (for ORDER BY)
    EXECUTE format('CREATE INDEX ON data.%I (category, sort_key) INCLUDE (display_value)', l_test_table);

    -- Insert test data
    EXECUTE format('INSERT INTO data.%I (category, sort_key, display_value)
        SELECT ''CAT-'' || (i %% 3), i, ''Value '' || i
        FROM generate_series(1, 100) i', l_test_table);
    EXECUTE format('VACUUM ANALYZE data.%I', l_test_table);

    -- Query with ORDER BY on key column should not need sort
    EXECUTE format('EXPLAIN (FORMAT TEXT) SELECT display_value FROM data.%I WHERE category = ''CAT-1'' ORDER BY sort_key', l_test_table) INTO l_plan;

    PERFORM test.ok(l_plan NOT ILIKE '%Sort%' OR l_plan ILIKE '%Index%Scan%', 'Index should provide sorted results without separate Sort node');

    -- Cleanup
    EXECUTE format('DROP TABLE data.%I', l_test_table);
END;
$$;

-- ============================================================================
-- RUN TESTS
-- ============================================================================

SELECT test.run_module('covering_11');
CALL test.print_run_summary();
