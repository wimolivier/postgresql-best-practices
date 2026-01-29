-- ============================================================================
-- INTEGRATION TEST - ROW-LEVEL SECURITY WORKFLOW
-- ============================================================================
-- Tests RLS integrated with API layer.
-- Demonstrates a complete multi-tenant workflow.
--
-- Note: RLS with SECURITY DEFINER functions requires careful design.
-- This test demonstrates application-level tenant enforcement in the API layer,
-- which is the recommended pattern for multi-tenant applications.
-- ============================================================================

-- ============================================================================
-- SETUP: Create integration test schema
-- ============================================================================

DO $$
BEGIN
    CREATE SCHEMA IF NOT EXISTS rls_test_data;
    CREATE SCHEMA IF NOT EXISTS rls_test_api;
    COMMENT ON SCHEMA rls_test_data IS 'Integration test data schema';
    COMMENT ON SCHEMA rls_test_api IS 'Integration test API schema';
END;
$$;

-- Drop and recreate table to ensure clean state
DROP TABLE IF EXISTS rls_test_data.customers CASCADE;

-- Create multi-tenant customers table
CREATE TABLE rls_test_data.customers (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id uuid NOT NULL,
    name text NOT NULL,
    email text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

-- Create index on tenant_id for performance
CREATE INDEX customers_tenant_idx ON rls_test_data.customers (tenant_id);

-- ============================================================================
-- API LAYER WITH APPLICATION-LEVEL TENANT ENFORCEMENT
-- ============================================================================
-- This pattern enforces tenant isolation in the API layer rather than relying
-- solely on RLS policies. This is more reliable with SECURITY DEFINER functions.
-- ============================================================================

-- Helper function to get current tenant (with validation)
CREATE OR REPLACE FUNCTION rls_test_api.get_current_tenant_id()
RETURNS uuid
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    l_tenant_id uuid;
BEGIN
    l_tenant_id := NULLIF(current_setting('app.current_tenant_id', true), '')::uuid;
    RETURN l_tenant_id;
EXCEPTION WHEN invalid_text_representation THEN
    RETURN NULL;
END;
$$;

-- Create API function for listing customers (enforces tenant filter)
CREATE OR REPLACE FUNCTION rls_test_api.list_customers()
RETURNS TABLE (
    id uuid,
    name text,
    email text,
    created_at timestamptz
)
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = rls_test_data, rls_test_api, pg_temp
AS $$
DECLARE
    l_tenant_id uuid;
BEGIN
    l_tenant_id := get_current_tenant_id();

    -- Return empty if no tenant context
    IF l_tenant_id IS NULL THEN
        RETURN;
    END IF;

    RETURN QUERY
    SELECT c.id, c.name, c.email, c.created_at
    FROM customers c
    WHERE c.tenant_id = l_tenant_id
    ORDER BY c.created_at DESC;
END;
$$;

-- Create API procedure for creating customers
CREATE OR REPLACE PROCEDURE rls_test_api.create_customer(
    in_name text,
    in_email text,
    INOUT io_id uuid DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = rls_test_data, rls_test_api, pg_temp
AS $$
DECLARE
    l_tenant_id uuid;
BEGIN
    l_tenant_id := get_current_tenant_id();

    IF l_tenant_id IS NULL THEN
        RAISE EXCEPTION 'Tenant context required';
    END IF;

    INSERT INTO customers (tenant_id, name, email)
    VALUES (l_tenant_id, in_name, in_email)
    RETURNING id INTO io_id;
END;
$$;

-- Create API procedure for updating customers (enforces tenant ownership)
CREATE OR REPLACE PROCEDURE rls_test_api.update_customer(
    in_id uuid,
    in_name text DEFAULT NULL,
    in_email text DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = rls_test_data, rls_test_api, pg_temp
AS $$
DECLARE
    l_tenant_id uuid;
    l_rows_affected integer;
BEGIN
    l_tenant_id := get_current_tenant_id();

    IF l_tenant_id IS NULL THEN
        RAISE EXCEPTION 'Tenant context required';
    END IF;

    UPDATE customers
    SET
        name = COALESCE(in_name, name),
        email = COALESCE(in_email, email),
        updated_at = now()
    WHERE id = in_id
      AND tenant_id = l_tenant_id;  -- Enforce tenant ownership

    GET DIAGNOSTICS l_rows_affected = ROW_COUNT;

    IF l_rows_affected = 0 THEN
        RAISE EXCEPTION 'Customer not found or access denied';
    END IF;
END;
$$;

-- Create API function for getting a customer (enforces tenant ownership)
CREATE OR REPLACE FUNCTION rls_test_api.get_customer(in_id uuid)
RETURNS TABLE (
    id uuid,
    name text,
    email text,
    created_at timestamptz,
    updated_at timestamptz
)
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = rls_test_data, rls_test_api, pg_temp
AS $$
DECLARE
    l_tenant_id uuid;
BEGIN
    l_tenant_id := get_current_tenant_id();

    -- Return empty if no tenant context
    IF l_tenant_id IS NULL THEN
        RETURN;
    END IF;

    RETURN QUERY
    SELECT c.id, c.name, c.email, c.created_at, c.updated_at
    FROM customers c
    WHERE c.id = in_id
      AND c.tenant_id = l_tenant_id;  -- Enforce tenant ownership
END;
$$;

-- ============================================================================
-- TEST FUNCTIONS
-- ============================================================================

-- Test: Complete tenant isolation workflow
CREATE OR REPLACE FUNCTION test.test_rls_integration_180_tenant_workflow()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_tenant_a uuid := gen_random_uuid();
    l_tenant_b uuid := gen_random_uuid();
    l_customer_a_id uuid;
    l_customer_b_id uuid;
    l_count integer;
    l_name text;
BEGIN
    PERFORM test.set_context('test_rls_integration_180_tenant_workflow');

    -- === Tenant A creates customer ===
    PERFORM set_config('app.current_tenant_id', l_tenant_a::text, true);
    CALL rls_test_api.create_customer('Alice', 'alice@tenant-a.com', l_customer_a_id);
    PERFORM test.is_not_null(l_customer_a_id, 'Tenant A should create customer');

    -- === Tenant B creates customer ===
    PERFORM set_config('app.current_tenant_id', l_tenant_b::text, true);
    CALL rls_test_api.create_customer('Bob', 'bob@tenant-b.com', l_customer_b_id);
    PERFORM test.is_not_null(l_customer_b_id, 'Tenant B should create customer');

    -- === Tenant A can only see their customer ===
    PERFORM set_config('app.current_tenant_id', l_tenant_a::text, true);
    SELECT COUNT(*) INTO l_count FROM rls_test_api.list_customers();
    PERFORM test.is(l_count, 1, 'Tenant A should see only 1 customer');

    SELECT name INTO l_name FROM rls_test_api.get_customer(l_customer_a_id);
    PERFORM test.is(l_name, 'Alice', 'Tenant A should see Alice');

    -- Tenant A cannot see Tenant B's customer
    SELECT name INTO l_name FROM rls_test_api.get_customer(l_customer_b_id);
    PERFORM test.is_null(l_name, 'Tenant A should NOT see Bob');

    -- === Tenant B can only see their customer ===
    PERFORM set_config('app.current_tenant_id', l_tenant_b::text, true);
    SELECT COUNT(*) INTO l_count FROM rls_test_api.list_customers();
    PERFORM test.is(l_count, 1, 'Tenant B should see only 1 customer');

    SELECT name INTO l_name FROM rls_test_api.get_customer(l_customer_b_id);
    PERFORM test.is(l_name, 'Bob', 'Tenant B should see Bob');

    -- Cleanup
    PERFORM set_config('app.current_tenant_id', '', true);
    DELETE FROM rls_test_data.customers WHERE tenant_id IN (l_tenant_a, l_tenant_b);
END;
$$;

-- Test: Cross-tenant update blocked
CREATE OR REPLACE FUNCTION test.test_rls_integration_181_cross_tenant_update()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_tenant_a uuid := gen_random_uuid();
    l_tenant_b uuid := gen_random_uuid();
    l_customer_a_id uuid;
    l_original_name text;
BEGIN
    PERFORM test.set_context('test_rls_integration_181_cross_tenant_update');

    -- Tenant A creates customer
    PERFORM set_config('app.current_tenant_id', l_tenant_a::text, true);
    CALL rls_test_api.create_customer('Original Name', 'test@tenant-a.com', l_customer_a_id);

    -- Tenant B tries to update Tenant A's customer
    PERFORM set_config('app.current_tenant_id', l_tenant_b::text, true);
    PERFORM test.throws_ok(
        format('CALL rls_test_api.update_customer(%L, ''Hacked Name'')', l_customer_a_id),
        'P0001',  -- raise_exception
        'Cross-tenant update should be blocked'
    );

    -- Verify original name unchanged
    PERFORM set_config('app.current_tenant_id', l_tenant_a::text, true);
    SELECT name INTO l_original_name FROM rls_test_api.get_customer(l_customer_a_id);
    PERFORM test.is(l_original_name, 'Original Name', 'Customer name should be unchanged');

    -- Cleanup
    PERFORM set_config('app.current_tenant_id', '', true);
    DELETE FROM rls_test_data.customers WHERE tenant_id IN (l_tenant_a, l_tenant_b);
END;
$$;

-- Test: Same-tenant update allowed
CREATE OR REPLACE FUNCTION test.test_rls_integration_182_same_tenant_update()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_tenant_id uuid := gen_random_uuid();
    l_customer_id uuid;
    l_updated_name text;
BEGIN
    PERFORM test.set_context('test_rls_integration_182_same_tenant_update');

    -- Set tenant context
    PERFORM set_config('app.current_tenant_id', l_tenant_id::text, true);

    -- Create customer
    CALL rls_test_api.create_customer('Before Update', 'customer@test.com', l_customer_id);

    -- Update own customer
    CALL rls_test_api.update_customer(l_customer_id, 'After Update');

    -- Verify update
    SELECT name INTO l_updated_name FROM rls_test_api.get_customer(l_customer_id);
    PERFORM test.is(l_updated_name, 'After Update', 'Same-tenant update should succeed');

    -- Cleanup
    PERFORM set_config('app.current_tenant_id', '', true);
    DELETE FROM rls_test_data.customers WHERE tenant_id = l_tenant_id;
END;
$$;

-- Test: No tenant context blocks all access
CREATE OR REPLACE FUNCTION test.test_rls_integration_183_no_context()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_tenant_id uuid := gen_random_uuid();
    l_customer_id uuid;
    l_count integer;
BEGIN
    PERFORM test.set_context('test_rls_integration_183_no_context');

    -- Create customer with tenant context
    PERFORM set_config('app.current_tenant_id', l_tenant_id::text, true);
    CALL rls_test_api.create_customer('Test Customer', 'test@example.com', l_customer_id);

    -- Clear tenant context
    PERFORM set_config('app.current_tenant_id', '', true);

    -- Try to list customers - should see nothing (no tenant context)
    SELECT COUNT(*) INTO l_count FROM rls_test_api.list_customers();
    PERFORM test.is(l_count, 0, 'No tenant context should see no customers');

    -- Try to create customer without context - should fail
    PERFORM test.throws_ok(
        'CALL rls_test_api.create_customer(''No Tenant'', ''fail@example.com'', NULL)',
        'P0001',
        'Creating customer without tenant context should fail'
    );

    -- Cleanup (direct delete as we have no context for API)
    DELETE FROM rls_test_data.customers WHERE tenant_id = l_tenant_id;
END;
$$;

-- Test: Multiple customers per tenant
CREATE OR REPLACE FUNCTION test.test_rls_integration_184_multiple_customers()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_tenant_id uuid := gen_random_uuid();
    l_id1 uuid;
    l_id2 uuid;
    l_id3 uuid;
    l_count integer;
BEGIN
    PERFORM test.set_context('test_rls_integration_184_multiple_customers');

    -- Set tenant context
    PERFORM set_config('app.current_tenant_id', l_tenant_id::text, true);

    -- Create multiple customers
    CALL rls_test_api.create_customer('Customer 1', 'c1@test.com', l_id1);
    CALL rls_test_api.create_customer('Customer 2', 'c2@test.com', l_id2);
    CALL rls_test_api.create_customer('Customer 3', 'c3@test.com', l_id3);

    -- Verify all visible
    SELECT COUNT(*) INTO l_count FROM rls_test_api.list_customers();
    PERFORM test.is(l_count, 3, 'Should see all 3 customers');

    -- Cleanup
    PERFORM set_config('app.current_tenant_id', '', true);
    DELETE FROM rls_test_data.customers WHERE tenant_id = l_tenant_id;
END;
$$;

-- Test: Tenant isolation with concurrent data
CREATE OR REPLACE FUNCTION test.test_rls_integration_185_concurrent_tenants()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_tenant_a uuid := gen_random_uuid();
    l_tenant_b uuid := gen_random_uuid();
    l_count_a integer;
    l_count_b integer;
BEGIN
    PERFORM test.set_context('test_rls_integration_185_concurrent_tenants');

    -- Create customers for Tenant A
    PERFORM set_config('app.current_tenant_id', l_tenant_a::text, true);
    CALL rls_test_api.create_customer('A1', 'a1@a.com', NULL);
    CALL rls_test_api.create_customer('A2', 'a2@a.com', NULL);

    -- Create customers for Tenant B
    PERFORM set_config('app.current_tenant_id', l_tenant_b::text, true);
    CALL rls_test_api.create_customer('B1', 'b1@b.com', NULL);
    CALL rls_test_api.create_customer('B2', 'b2@b.com', NULL);
    CALL rls_test_api.create_customer('B3', 'b3@b.com', NULL);

    -- Verify Tenant A sees only their customers
    PERFORM set_config('app.current_tenant_id', l_tenant_a::text, true);
    SELECT COUNT(*) INTO l_count_a FROM rls_test_api.list_customers();
    PERFORM test.is(l_count_a, 2, 'Tenant A should see 2 customers');

    -- Verify Tenant B sees only their customers
    PERFORM set_config('app.current_tenant_id', l_tenant_b::text, true);
    SELECT COUNT(*) INTO l_count_b FROM rls_test_api.list_customers();
    PERFORM test.is(l_count_b, 3, 'Tenant B should see 3 customers');

    -- Cleanup
    PERFORM set_config('app.current_tenant_id', '', true);
    DELETE FROM rls_test_data.customers WHERE tenant_id IN (l_tenant_a, l_tenant_b);
END;
$$;

-- Test: API layer enforces tenant context
CREATE OR REPLACE FUNCTION test.test_rls_integration_186_api_context_enforcement()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_tenant_id uuid := gen_random_uuid();
    l_customer_id uuid;
BEGIN
    PERFORM test.set_context('test_rls_integration_186_api_context_enforcement');

    -- Clear any existing tenant context
    PERFORM set_config('app.current_tenant_id', '', true);

    -- Create via API requires tenant context
    PERFORM test.throws_ok(
        'CALL rls_test_api.create_customer(''No Tenant'', ''test@test.com'', NULL)',
        'P0001',
        'API should require tenant context'
    );

    -- With context, creation works
    PERFORM set_config('app.current_tenant_id', l_tenant_id::text, true);
    PERFORM test.lives_ok(
        format('CALL rls_test_api.create_customer(''With Tenant'', ''test@test.com'', NULL)'),
        'API should work with tenant context'
    );

    -- Cleanup
    PERFORM set_config('app.current_tenant_id', '', true);
    DELETE FROM rls_test_data.customers WHERE tenant_id = l_tenant_id;
END;
$$;

-- Test: Get customer returns empty for wrong tenant
CREATE OR REPLACE FUNCTION test.test_rls_integration_187_get_wrong_tenant()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_tenant_a uuid := gen_random_uuid();
    l_tenant_b uuid := gen_random_uuid();
    l_customer_id uuid;
    l_result_count integer;
BEGIN
    PERFORM test.set_context('test_rls_integration_187_get_wrong_tenant');

    -- Tenant A creates customer
    PERFORM set_config('app.current_tenant_id', l_tenant_a::text, true);
    CALL rls_test_api.create_customer('Secret Data', 'secret@a.com', l_customer_id);

    -- Tenant B tries to get Tenant A's customer by ID
    PERFORM set_config('app.current_tenant_id', l_tenant_b::text, true);
    SELECT COUNT(*) INTO l_result_count FROM rls_test_api.get_customer(l_customer_id);
    PERFORM test.is(l_result_count, 0, 'Tenant B should not see Tenant A customer by ID');

    -- Cleanup
    PERFORM set_config('app.current_tenant_id', '', true);
    DELETE FROM rls_test_data.customers WHERE tenant_id IN (l_tenant_a, l_tenant_b);
END;
$$;

-- ============================================================================
-- CLEANUP FUNCTION
-- ============================================================================

CREATE OR REPLACE FUNCTION test.cleanup_rls_integration()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    -- Clear context
    PERFORM set_config('app.current_tenant_id', '', true);

    -- Drop test objects
    DROP TABLE IF EXISTS rls_test_data.customers CASCADE;
    DROP SCHEMA IF EXISTS rls_test_api CASCADE;
    DROP SCHEMA IF EXISTS rls_test_data CASCADE;
END;
$$;

-- ============================================================================
-- RUN TESTS
-- ============================================================================

SELECT test.run_module('rls_integration_18');
CALL test.print_run_summary();

-- Note: Uncomment to cleanup after tests
-- SELECT test.cleanup_rls_integration();
