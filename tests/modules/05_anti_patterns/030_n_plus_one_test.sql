-- ============================================================================
-- ANTI-PATTERNS TESTS - N+1 QUERY DETECTION AND SOLUTIONS
-- ============================================================================
-- Tests for the three N+1 query solutions documented in anti-patterns.md:
-- 1. Batch fetch with ANY(uuid[])
-- 2. JOIN-based denormalized API function
-- 3. LATERAL join for top-N-per-group
-- Reference: references/anti-patterns.md §N+1 Query Pattern
-- ============================================================================

-- ============================================================================
-- SETUP
-- ============================================================================

DO $$
BEGIN
    CREATE SCHEMA IF NOT EXISTS data;
    CREATE SCHEMA IF NOT EXISTS private;
    CREATE SCHEMA IF NOT EXISTS api;
END;
$$;

-- ============================================================================
-- TEST FUNCTIONS
-- ============================================================================

-- Test: Batch fetch with ANY(uuid[]) replaces N individual queries
CREATE OR REPLACE FUNCTION test.test_antipattern_030_batch_fetch_any()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_customers_table text := 'test_np1_cust_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_orders_table text := 'test_np1_ord_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_batch_func text := 'test_batch_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_cust_ids uuid[];
    l_result_count integer;
BEGIN
    PERFORM test.set_context('test_antipattern_030_batch_fetch_any');

    -- Create parent and child tables
    EXECUTE format('CREATE TABLE data.%I (
        id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        name text NOT NULL,
        is_active boolean NOT NULL DEFAULT true
    )', l_customers_table);

    EXECUTE format('CREATE TABLE data.%I (
        id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        customer_id uuid NOT NULL REFERENCES data.%I(id),
        total numeric(12,2) NOT NULL,
        created_at timestamptz NOT NULL DEFAULT now()
    )', l_orders_table, l_customers_table);

    -- Insert test customers
    EXECUTE format('INSERT INTO data.%I (name) VALUES (''Alice''), (''Bob''), (''Carol'')
        RETURNING id', l_customers_table);

    -- Collect customer IDs
    EXECUTE format('SELECT array_agg(id) FROM data.%I', l_customers_table)
    INTO l_cust_ids;

    -- Insert orders for each customer
    EXECUTE format('INSERT INTO data.%I (customer_id, total)
        SELECT id, 100.00 FROM data.%I
        UNION ALL
        SELECT id, 200.00 FROM data.%I WHERE name = ''Alice''',
        l_orders_table, l_customers_table, l_customers_table);

    -- Create batch fetch function (Solution 1 from anti-patterns.md)
    EXECUTE format($fn$
        CREATE FUNCTION api.%I(in_customer_ids uuid[])
        RETURNS TABLE (
            customer_id uuid,
            order_id uuid,
            total numeric,
            created_at timestamptz
        )
        LANGUAGE sql
        STABLE
        SECURITY DEFINER
        SET search_path = data, private, pg_temp
        AS $body$
            SELECT customer_id, id, total, created_at
            FROM %I
            WHERE customer_id = ANY(in_customer_ids)
            ORDER BY customer_id, created_at DESC;
        $body$
    $fn$, l_batch_func, l_orders_table);

    -- Single batch call should return all orders for all customers
    EXECUTE format('SELECT count(*) FROM api.%I($1)', l_batch_func)
    INTO l_result_count
    USING l_cust_ids;

    PERFORM test.is(l_result_count, 4, 'Batch fetch should return all orders in one call');

    -- Verify it works with a subset of IDs
    EXECUTE format('SELECT count(*) FROM api.%I($1)', l_batch_func)
    INTO l_result_count
    USING l_cust_ids[1:1];

    PERFORM test.ok(l_result_count >= 1, 'Batch fetch should work with subset of IDs');

    -- Verify empty array returns no rows
    EXECUTE format('SELECT count(*) FROM api.%I($1)', l_batch_func)
    INTO l_result_count
    USING ARRAY[]::uuid[];

    PERFORM test.is(l_result_count, 0, 'Batch fetch with empty array returns no rows');

    -- Clean up
    EXECUTE format('DROP FUNCTION api.%I(uuid[])', l_batch_func);
    EXECUTE format('DROP TABLE data.%I CASCADE', l_orders_table);
    EXECUTE format('DROP TABLE data.%I CASCADE', l_customers_table);
END;
$$;

-- Test: JOIN-based API function with DISTINCT ON for latest-per-group
CREATE OR REPLACE FUNCTION test.test_antipattern_031_join_distinct_on()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_customers_table text := 'test_np1_jc_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_orders_table text := 'test_np1_jo_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_join_func text := 'test_join_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_result_count integer;
    l_alice_total numeric;
BEGIN
    PERFORM test.set_context('test_antipattern_031_join_distinct_on');

    -- Create tables
    EXECUTE format('CREATE TABLE data.%I (
        id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        name text NOT NULL,
        is_active boolean NOT NULL DEFAULT true
    )', l_customers_table);

    EXECUTE format('CREATE TABLE data.%I (
        id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        customer_id uuid NOT NULL REFERENCES data.%I(id),
        total numeric(12,2) NOT NULL,
        created_at timestamptz NOT NULL DEFAULT now()
    )', l_orders_table, l_customers_table);

    -- Insert customers
    EXECUTE format('INSERT INTO data.%I (name) VALUES (''Alice''), (''Bob'')', l_customers_table);

    -- Insert orders (Alice has 2 orders, Bob has 1)
    EXECUTE format($ins$
        INSERT INTO data.%I (customer_id, total, created_at)
        SELECT c.id, 100.00, now() - interval '2 days'
        FROM data.%I c WHERE c.name = 'Alice'
        UNION ALL
        SELECT c.id, 250.00, now() - interval '1 day'
        FROM data.%I c WHERE c.name = 'Alice'
        UNION ALL
        SELECT c.id, 75.00, now()
        FROM data.%I c WHERE c.name = 'Bob'
    $ins$, l_orders_table, l_customers_table, l_customers_table, l_customers_table);

    -- Create JOIN-based function (Solution 2 from anti-patterns.md)
    EXECUTE format($fn$
        CREATE FUNCTION api.%I()
        RETURNS TABLE (
            customer_id uuid,
            customer_name text,
            latest_order_id uuid,
            latest_order_total numeric,
            latest_order_date timestamptz
        )
        LANGUAGE sql
        STABLE
        SECURITY DEFINER
        SET search_path = data, private, pg_temp
        AS $body$
            SELECT DISTINCT ON (c.id)
                c.id,
                c.name,
                o.id,
                o.total,
                o.created_at
            FROM %I c
            LEFT JOIN %I o ON o.customer_id = c.id
            WHERE c.is_active = true
            ORDER BY c.id, o.created_at DESC;
        $body$
    $fn$, l_join_func, l_customers_table, l_orders_table);

    -- Should return one row per customer (DISTINCT ON)
    EXECUTE format('SELECT count(*) FROM api.%I()', l_join_func)
    INTO l_result_count;

    PERFORM test.is(l_result_count, 2, 'JOIN function should return one row per customer');

    -- Alice should have her latest order (250.00)
    EXECUTE format('SELECT latest_order_total FROM api.%I() WHERE customer_name = ''Alice''', l_join_func)
    INTO l_alice_total;

    PERFORM test.is(l_alice_total, 250.00::numeric, 'DISTINCT ON should pick latest order');

    -- Clean up
    EXECUTE format('DROP FUNCTION api.%I()', l_join_func);
    EXECUTE format('DROP TABLE data.%I CASCADE', l_orders_table);
    EXECUTE format('DROP TABLE data.%I CASCADE', l_customers_table);
END;
$$;

-- Test: LATERAL join for top-N-per-group pattern
CREATE OR REPLACE FUNCTION test.test_antipattern_032_lateral_join()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_customers_table text := 'test_np1_lc_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_orders_table text := 'test_np1_lo_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_lateral_func text := 'test_lateral_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_result_count integer;
    l_alice_orders integer;
BEGIN
    PERFORM test.set_context('test_antipattern_032_lateral_join');

    -- Create tables
    EXECUTE format('CREATE TABLE data.%I (
        id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        name text NOT NULL,
        is_active boolean NOT NULL DEFAULT true
    )', l_customers_table);

    EXECUTE format('CREATE TABLE data.%I (
        id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        customer_id uuid NOT NULL REFERENCES data.%I(id),
        total numeric(12,2) NOT NULL,
        created_at timestamptz NOT NULL DEFAULT now()
    )', l_orders_table, l_customers_table);

    -- Insert customers
    EXECUTE format('INSERT INTO data.%I (name) VALUES (''Alice''), (''Bob'')', l_customers_table);

    -- Insert 5 orders for Alice, 2 for Bob
    EXECUTE format($ins$
        INSERT INTO data.%I (customer_id, total, created_at)
        SELECT c.id, n * 10.00, now() - (n || ' days')::interval
        FROM data.%I c
        CROSS JOIN generate_series(1, 5) n
        WHERE c.name = 'Alice'
        UNION ALL
        SELECT c.id, n * 20.00, now() - (n || ' days')::interval
        FROM data.%I c
        CROSS JOIN generate_series(1, 2) n
        WHERE c.name = 'Bob'
    $ins$, l_orders_table, l_customers_table, l_customers_table);

    -- Create LATERAL join function (Solution 3 from anti-patterns.md)
    EXECUTE format($fn$
        CREATE FUNCTION api.%I(in_limit integer DEFAULT 3)
        RETURNS TABLE (
            customer_id uuid,
            customer_name text,
            order_id uuid,
            order_total numeric,
            order_date timestamptz
        )
        LANGUAGE sql
        STABLE
        SECURITY DEFINER
        SET search_path = data, private, pg_temp
        AS $body$
            SELECT
                c.id,
                c.name,
                lo.id,
                lo.total,
                lo.created_at
            FROM %I c
            CROSS JOIN LATERAL (
                SELECT o.id, o.total, o.created_at
                FROM %I o
                WHERE o.customer_id = c.id
                ORDER BY o.created_at DESC
                LIMIT in_limit
            ) lo
            WHERE c.is_active = true
            ORDER BY c.id, lo.created_at DESC;
        $body$
    $fn$, l_lateral_func, l_customers_table, l_orders_table);

    -- With limit=3: Alice gets 3, Bob gets 2 (he only has 2) = 5 total
    EXECUTE format('SELECT count(*) FROM api.%I(3)', l_lateral_func)
    INTO l_result_count;

    PERFORM test.is(l_result_count, 5, 'LATERAL join should return top-N per customer');

    -- Check Alice specifically gets 3
    EXECUTE format('SELECT count(*) FROM api.%I(3) WHERE customer_name = ''Alice''', l_lateral_func)
    INTO l_alice_orders;

    PERFORM test.is(l_alice_orders, 3, 'Alice should have exactly 3 (limit) orders');

    -- With limit=1: each customer gets at most 1 order
    EXECUTE format('SELECT count(*) FROM api.%I(1)', l_lateral_func)
    INTO l_result_count;

    PERFORM test.is(l_result_count, 2, 'LATERAL with limit=1 returns 1 per customer');

    -- Clean up
    EXECUTE format('DROP FUNCTION api.%I(integer)', l_lateral_func);
    EXECUTE format('DROP TABLE data.%I CASCADE', l_orders_table);
    EXECUTE format('DROP TABLE data.%I CASCADE', l_customers_table);
END;
$$;

-- Test: Batch fetch function follows Table API conventions
CREATE OR REPLACE FUNCTION test.test_antipattern_033_batch_api_conventions()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_batch_func text := 'test_conv_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_is_definer boolean;
    l_search_path text;
    l_volatility text;
BEGIN
    PERFORM test.set_context('test_antipattern_033_batch_api_conventions');

    -- Create a batch fetch function following all conventions
    EXECUTE format($fn$
        CREATE FUNCTION api.select_%I(in_ids uuid[])
        RETURNS TABLE (id uuid, name text)
        LANGUAGE sql
        STABLE
        SECURITY DEFINER
        SET search_path = data, private, pg_temp
        AS $body$
            SELECT gen_random_uuid(), 'test'::text WHERE false
        $body$
    $fn$, l_batch_func);

    -- Verify SECURITY DEFINER
    l_is_definer := test.is_security_definer('api', 'select_' || l_batch_func);
    PERFORM test.ok(l_is_definer, 'Batch function should be SECURITY DEFINER');

    -- Verify SET search_path
    l_search_path := test.get_function_search_path('api', 'select_' || l_batch_func);
    PERFORM test.is_not_null(l_search_path, 'Batch function should have SET search_path');

    -- Verify STABLE volatility
    SELECT p.provolatile INTO l_volatility
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'api' AND p.proname = 'select_' || l_batch_func;

    PERFORM test.is(l_volatility, 's', 'Batch function should be STABLE');

    -- Clean up
    EXECUTE format('DROP FUNCTION api.select_%I(uuid[])', l_batch_func);
END;
$$;

-- ============================================================================
-- RUN TESTS
-- ============================================================================

SELECT test.run_module('antipattern_03');
CALL test.print_run_summary();
