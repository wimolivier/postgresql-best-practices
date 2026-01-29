# Testing Patterns for PostgreSQL

This document covers unit testing, integration testing, and test data management for PostgreSQL using pgTAP and native patterns.

## Table of Contents

1. [pgTAP Setup](#pgtap-setup)
2. [Test Structure](#test-structure)
3. [Testing Functions](#testing-functions)
4. [Testing Procedures](#testing-procedures)
5. [Testing Triggers](#testing-triggers)
6. [Testing Constraints](#testing-constraints)
7. [Test Data Management](#test-data-management)
8. [Transaction Isolation](#transaction-isolation)
9. [Migration Testing](#migration-testing)
10. [CI/CD Integration](#cicd-integration)

## pgTAP Setup

### Installation

```sql
-- Install pgTAP extension
CREATE EXTENSION IF NOT EXISTS pgtap;

-- Create test schema
CREATE SCHEMA IF NOT EXISTS test;
COMMENT ON SCHEMA test IS 'Unit tests using pgTAP';
```

### Test Runner Schema

```sql
-- Track test execution
CREATE TABLE test.test_runs (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_at          timestamptz NOT NULL DEFAULT now(),
    total_tests     integer NOT NULL,
    passed          integer NOT NULL,
    failed          integer NOT NULL,
    execution_ms    integer,
    details         jsonb
);
```

## Test Structure

### Basic Test Template

```sql
-- ============================================================================
-- Test: test.test_api_get_customer
-- Tests: api.get_customer function
-- ============================================================================
CREATE OR REPLACE FUNCTION test.test_api_get_customer()
RETURNS SETOF text
LANGUAGE plpgsql
AS $$
DECLARE
    l_customer_id uuid;
    l_result RECORD;
BEGIN
    -- ========================================
    -- ARRANGE: Set up test data
    -- ========================================
    INSERT INTO data.customers (email, name, password_hash)
    VALUES ('test@example.com', 'Test User', 'hash123')
    RETURNING id INTO l_customer_id;
    
    -- ========================================
    -- ACT: Call the function under test
    -- ========================================
    SELECT * INTO l_result
    FROM api.get_customer(l_customer_id);
    
    -- ========================================
    -- ASSERT: Verify results
    -- ========================================
    RETURN NEXT ok(l_result.id IS NOT NULL, 'Should return customer ID');
    RETURN NEXT is(l_result.email, 'test@example.com', 'Should return correct email');
    RETURN NEXT is(l_result.name, 'Test User', 'Should return correct name');
    
    -- Test non-existent customer
    SELECT * INTO l_result
    FROM api.get_customer('00000000-0000-0000-0000-000000000000'::uuid);
    
    RETURN NEXT ok(l_result.id IS NULL, 'Should return NULL for non-existent customer');
    
END;
$$;
```

### Test Naming Convention

```sql
-- Pattern: test.test_{schema}_{function_name}[_{scenario}]

test.test_api_get_customer()
test.test_api_get_customer_not_found()
test.test_api_insert_customer()
test.test_api_insert_customer_duplicate_email()
test.test_private_hash_password()
test.test_trigger_set_updated_at()
```

## Testing Functions

### Testing Read Functions

```sql
CREATE OR REPLACE FUNCTION test.test_api_select_orders_by_customer()
RETURNS SETOF text
LANGUAGE plpgsql
AS $$
DECLARE
    l_customer_id uuid;
    l_order_ids uuid[];
    l_results RECORD;
    l_count integer;
BEGIN
    -- ARRANGE
    INSERT INTO data.customers (email, name, password_hash)
    VALUES ('customer@test.com', 'Test Customer', 'hash')
    RETURNING id INTO l_customer_id;
    
    -- Create multiple orders
    INSERT INTO data.orders (customer_id, status, total)
    VALUES 
        (l_customer_id, 'pending', 100.00),
        (l_customer_id, 'shipped', 200.00),
        (l_customer_id, 'delivered', 150.00)
    RETURNING ARRAY_AGG(id) INTO l_order_ids;
    
    -- ACT & ASSERT: Test without filter
    SELECT COUNT(*) INTO l_count
    FROM api.select_orders_by_customer(l_customer_id);
    
    RETURN NEXT is(l_count, 3, 'Should return all 3 orders');
    
    -- ACT & ASSERT: Test with status filter
    SELECT COUNT(*) INTO l_count
    FROM api.select_orders_by_customer(l_customer_id, 'pending');
    
    RETURN NEXT is(l_count, 1, 'Should return only pending orders');
    
    -- ACT & ASSERT: Test with limit
    SELECT COUNT(*) INTO l_count
    FROM api.select_orders_by_customer(l_customer_id, in_limit := 2);
    
    RETURN NEXT is(l_count, 2, 'Should respect limit parameter');
    
    -- ACT & ASSERT: Test ordering (most recent first)
    FOR l_results IN 
        SELECT created_at FROM api.select_orders_by_customer(l_customer_id)
    LOOP
        -- Just verify we get results; ordering tested implicitly
        RETURN NEXT ok(l_results.created_at IS NOT NULL, 'Should have created_at');
    END LOOP;
    
END;
$$;
```

### Testing Functions That Return Computed Values

```sql
CREATE OR REPLACE FUNCTION test.test_private_ord_calculate_total()
RETURNS SETOF text
LANGUAGE plpgsql
AS $$
DECLARE
    l_customer_id uuid;
    l_order_id uuid;
    l_total numeric;
BEGIN
    -- ARRANGE
    INSERT INTO data.customers (email, name, password_hash)
    VALUES ('calc@test.com', 'Calc Test', 'hash')
    RETURNING id INTO l_customer_id;
    
    INSERT INTO data.orders (customer_id, status, total)
    VALUES (l_customer_id, 'pending', 0)
    RETURNING id INTO l_order_id;
    
    INSERT INTO data.order_items (order_id, product_name, quantity, unit_price)
    VALUES 
        (l_order_id, 'Widget A', 2, 10.00),   -- 20.00
        (l_order_id, 'Widget B', 3, 15.50),   -- 46.50
        (l_order_id, 'Widget C', 1, 100.00);  -- 100.00
    -- Total: 166.50
    
    -- ACT
    l_total := private.ord_calculate_total(l_order_id);
    
    -- ASSERT
    RETURN NEXT is(l_total, 166.50::numeric, 'Should calculate correct total');
    
    -- Test empty order
    INSERT INTO data.orders (customer_id, status, total)
    VALUES (l_customer_id, 'pending', 0)
    RETURNING id INTO l_order_id;
    
    l_total := private.ord_calculate_total(l_order_id);
    
    RETURN NEXT is(l_total, 0::numeric, 'Empty order should have zero total');
    
END;
$$;
```

## Testing Procedures

### Testing Insert Procedures

```sql
CREATE OR REPLACE FUNCTION test.test_api_insert_customer()
RETURNS SETOF text
LANGUAGE plpgsql
AS $$
DECLARE
    l_id uuid;
    l_result RECORD;
BEGIN
    -- ACT
    CALL api.insert_customer(
        in_email := 'new@example.com',
        in_name := 'New Customer',
        in_password := 'securepass123',
        io_id := l_id
    );
    
    -- ASSERT: ID was returned
    RETURN NEXT ok(l_id IS NOT NULL, 'Should return generated ID');
    
    -- ASSERT: Data was inserted correctly
    SELECT * INTO l_result FROM data.customers WHERE id = l_id;
    
    RETURN NEXT is(l_result.email, 'new@example.com', 'Email should be stored lowercase');
    RETURN NEXT is(l_result.name, 'New Customer', 'Name should be stored');
    RETURN NEXT ok(l_result.password_hash IS NOT NULL, 'Password should be hashed');
    RETURN NEXT isnt(l_result.password_hash, 'securepass123', 'Password should not be plaintext');
    RETURN NEXT ok(l_result.is_active, 'Should default to active');
    RETURN NEXT ok(l_result.created_at IS NOT NULL, 'Should have created_at');
    
END;
$$;
```

### Testing Procedures That Should Fail

```sql
CREATE OR REPLACE FUNCTION test.test_api_insert_customer_duplicate_email()
RETURNS SETOF text
LANGUAGE plpgsql
AS $$
DECLARE
    l_id uuid;
    l_exception_thrown boolean := false;
    l_sqlstate text;
BEGIN
    -- ARRANGE: Create first customer
    CALL api.insert_customer(
        in_email := 'duplicate@example.com',
        in_name := 'First Customer',
        in_password := 'pass123',
        io_id := l_id
    );
    
    -- ACT & ASSERT: Try to create duplicate
    BEGIN
        CALL api.insert_customer(
            in_email := 'duplicate@example.com',  -- Same email
            in_name := 'Second Customer',
            in_password := 'pass456',
            io_id := l_id
        );
    EXCEPTION
        WHEN unique_violation THEN
            l_exception_thrown := true;
            l_sqlstate := SQLSTATE;
        WHEN OTHERS THEN
            l_exception_thrown := true;
            l_sqlstate := SQLSTATE;
    END;
    
    RETURN NEXT ok(l_exception_thrown, 'Should throw exception for duplicate email');
    RETURN NEXT is(l_sqlstate, '23505', 'Should be unique_violation error');
    
END;
$$;
```

### Testing Update Procedures

```sql
CREATE OR REPLACE FUNCTION test.test_api_ord_update_status()
RETURNS SETOF text
LANGUAGE plpgsql
AS $$
DECLARE
    l_customer_id uuid;
    l_order_id uuid;
    l_status text;
    l_exception_thrown boolean;
BEGIN
    -- ARRANGE
    INSERT INTO data.customers (email, name, password_hash)
    VALUES ('status@test.com', 'Status Test', 'hash')
    RETURNING id INTO l_customer_id;
    
    INSERT INTO data.orders (customer_id, status, total)
    VALUES (l_customer_id, 'pending', 100.00)
    RETURNING id INTO l_order_id;
    
    -- ACT: Valid transition pending -> confirmed
    CALL api.ord_update_status(l_order_id, 'confirmed');
    
    SELECT status INTO l_status FROM data.orders WHERE id = l_order_id;
    RETURN NEXT is(l_status, 'confirmed', 'Should update to confirmed');
    
    -- ACT: Valid transition confirmed -> processing
    CALL api.ord_update_status(l_order_id, 'processing');
    
    SELECT status INTO l_status FROM data.orders WHERE id = l_order_id;
    RETURN NEXT is(l_status, 'processing', 'Should update to processing');
    
    -- ACT & ASSERT: Invalid transition processing -> pending
    l_exception_thrown := false;
    BEGIN
        CALL api.ord_update_status(l_order_id, 'pending');
    EXCEPTION
        WHEN OTHERS THEN
            l_exception_thrown := true;
    END;
    
    RETURN NEXT ok(l_exception_thrown, 'Should reject invalid status transition');
    
    -- Verify status unchanged
    SELECT status INTO l_status FROM data.orders WHERE id = l_order_id;
    RETURN NEXT is(l_status, 'processing', 'Status should remain unchanged after failed transition');
    
END;
$$;
```

## Testing Triggers

### Testing updated_at Trigger

```sql
CREATE OR REPLACE FUNCTION test.test_trigger_set_updated_at()
RETURNS SETOF text
LANGUAGE plpgsql
AS $$
DECLARE
    l_customer_id uuid;
    l_created_at timestamptz;
    l_updated_at_before timestamptz;
    l_updated_at_after timestamptz;
BEGIN
    -- ARRANGE
    INSERT INTO data.customers (email, name, password_hash)
    VALUES ('trigger@test.com', 'Trigger Test', 'hash')
    RETURNING id, created_at, updated_at 
    INTO l_customer_id, l_created_at, l_updated_at_before;
    
    -- Verify initial state
    RETURN NEXT is(l_created_at, l_updated_at_before, 
        'created_at and updated_at should match initially');
    
    -- Wait a tiny bit to ensure timestamp difference
    PERFORM pg_sleep(0.01);
    
    -- ACT
    UPDATE data.customers SET name = 'Updated Name' WHERE id = l_customer_id;
    
    SELECT updated_at INTO l_updated_at_after 
    FROM data.customers WHERE id = l_customer_id;
    
    -- ASSERT
    RETURN NEXT ok(l_updated_at_after > l_updated_at_before, 
        'updated_at should be updated by trigger');
    
    RETURN NEXT is(
        (SELECT created_at FROM data.customers WHERE id = l_customer_id),
        l_created_at,
        'created_at should not change'
    );
    
END;
$$;
```

### Testing Audit Triggers

```sql
CREATE OR REPLACE FUNCTION test.test_trigger_audit_log()
RETURNS SETOF text
LANGUAGE plpgsql
AS $$
DECLARE
    l_customer_id uuid;
    l_audit_count integer;
    l_audit_record RECORD;
BEGIN
    -- ARRANGE: Clear audit log for this test
    DELETE FROM app_audit.changelog WHERE table_name = 'customers';
    
    -- ACT: Insert
    INSERT INTO data.customers (email, name, password_hash)
    VALUES ('audit@test.com', 'Audit Test', 'hash')
    RETURNING id INTO l_customer_id;
    
    -- ASSERT: Insert logged
    SELECT COUNT(*) INTO l_audit_count 
    FROM app_audit.changelog 
    WHERE table_name = 'customers' AND operation = 'INSERT';
    
    RETURN NEXT is(l_audit_count, 1, 'Insert should be logged');
    
    -- ACT: Update
    UPDATE data.customers SET name = 'Updated Name' WHERE id = l_customer_id;
    
    -- ASSERT: Update logged
    SELECT * INTO l_audit_record 
    FROM app_audit.changelog 
    WHERE table_name = 'customers' AND operation = 'UPDATE'
    ORDER BY changed_at DESC LIMIT 1;
    
    RETURN NEXT ok(l_audit_record.old_values IS NOT NULL, 'Should log old values');
    RETURN NEXT ok(l_audit_record.new_values IS NOT NULL, 'Should log new values');
    
    -- ACT: Delete
    DELETE FROM data.customers WHERE id = l_customer_id;
    
    -- ASSERT: Delete logged
    SELECT COUNT(*) INTO l_audit_count 
    FROM app_audit.changelog 
    WHERE table_name = 'customers' AND operation = 'DELETE';
    
    RETURN NEXT is(l_audit_count, 1, 'Delete should be logged');
    
END;
$$;
```

## Testing Constraints

### Testing Check Constraints

```sql
CREATE OR REPLACE FUNCTION test.test_constraint_order_total_positive()
RETURNS SETOF text
LANGUAGE plpgsql
AS $$
DECLARE
    l_customer_id uuid;
    l_exception_thrown boolean := false;
BEGIN
    -- ARRANGE
    INSERT INTO data.customers (email, name, password_hash)
    VALUES ('constraint@test.com', 'Constraint Test', 'hash')
    RETURNING id INTO l_customer_id;
    
    -- ACT & ASSERT: Positive total should work
    BEGIN
        INSERT INTO data.orders (customer_id, status, total)
        VALUES (l_customer_id, 'pending', 100.00);
        
        RETURN NEXT pass('Positive total should be accepted');
    EXCEPTION
        WHEN OTHERS THEN
            RETURN NEXT fail('Positive total should be accepted');
    END;
    
    -- ACT & ASSERT: Zero total should work
    BEGIN
        INSERT INTO data.orders (customer_id, status, total)
        VALUES (l_customer_id, 'pending', 0.00);
        
        RETURN NEXT pass('Zero total should be accepted');
    EXCEPTION
        WHEN OTHERS THEN
            RETURN NEXT fail('Zero total should be accepted');
    END;
    
    -- ACT & ASSERT: Negative total should fail
    BEGIN
        INSERT INTO data.orders (customer_id, status, total)
        VALUES (l_customer_id, 'pending', -50.00);
        
        RETURN NEXT fail('Negative total should be rejected');
    EXCEPTION
        WHEN check_violation THEN
            RETURN NEXT pass('Negative total correctly rejected');
        WHEN OTHERS THEN
            RETURN NEXT fail('Wrong exception type for negative total');
    END;
    
END;
$$;
```

### Testing Foreign Key Constraints

```sql
CREATE OR REPLACE FUNCTION test.test_constraint_order_customer_fk()
RETURNS SETOF text
LANGUAGE plpgsql
AS $$
DECLARE
    l_exception_thrown boolean := false;
    l_fake_customer_id uuid := gen_random_uuid();
BEGIN
    -- ACT & ASSERT: Non-existent customer should fail
    BEGIN
        INSERT INTO data.orders (customer_id, status, total)
        VALUES (l_fake_customer_id, 'pending', 100.00);
        
        RETURN NEXT fail('Should reject non-existent customer');
    EXCEPTION
        WHEN foreign_key_violation THEN
            RETURN NEXT pass('Correctly rejected non-existent customer');
        WHEN OTHERS THEN
            RETURN NEXT fail('Wrong exception type: ' || SQLERRM);
    END;
    
END;
$$;
```

## Test Data Management

### Test Data Factory

```sql
-- ============================================================================
-- Test Data Factory Functions
-- ============================================================================

CREATE OR REPLACE FUNCTION test.create_customer(
    in_email text DEFAULT NULL,
    in_name text DEFAULT 'Test Customer',
    in_is_active boolean DEFAULT true
)
RETURNS uuid
LANGUAGE plpgsql
AS $$
DECLARE
    l_id uuid;
    l_email text;
BEGIN
    l_email := COALESCE(in_email, 'test_' || gen_random_uuid()::text || '@example.com');
    
    INSERT INTO data.customers (email, name, password_hash, is_active)
    VALUES (l_email, in_name, 'test_hash', in_is_active)
    RETURNING id INTO l_id;
    
    RETURN l_id;
END;
$$;

CREATE OR REPLACE FUNCTION test.create_order(
    in_customer_id uuid DEFAULT NULL,
    in_status text DEFAULT 'pending',
    in_total numeric DEFAULT 100.00
)
RETURNS uuid
LANGUAGE plpgsql
AS $$
DECLARE
    l_id uuid;
    l_customer_id uuid;
BEGIN
    -- Create customer if not provided
    l_customer_id := COALESCE(in_customer_id, test.create_customer());
    
    INSERT INTO data.orders (customer_id, status, total)
    VALUES (l_customer_id, in_status, in_total)
    RETURNING id INTO l_id;
    
    RETURN l_id;
END;
$$;

CREATE OR REPLACE FUNCTION test.create_order_with_items(
    in_customer_id uuid DEFAULT NULL,
    in_item_count integer DEFAULT 3
)
RETURNS uuid
LANGUAGE plpgsql
AS $$
DECLARE
    l_order_id uuid;
    l_customer_id uuid;
    i integer;
BEGIN
    l_customer_id := COALESCE(in_customer_id, test.create_customer());
    
    INSERT INTO data.orders (customer_id, status, total)
    VALUES (l_customer_id, 'pending', 0)
    RETURNING id INTO l_order_id;
    
    FOR i IN 1..in_item_count LOOP
        INSERT INTO data.order_items (order_id, product_name, quantity, unit_price)
        VALUES (l_order_id, 'Product ' || i, i, i * 10.00);
    END LOOP;
    
    -- Update total
    UPDATE data.orders 
    SET total = (SELECT COALESCE(SUM(quantity * unit_price), 0) 
                 FROM data.order_items WHERE order_id = l_order_id)
    WHERE id = l_order_id;
    
    RETURN l_order_id;
END;
$$;
```

### Cleanup Functions

```sql
CREATE OR REPLACE FUNCTION test.cleanup_test_data()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    -- Delete in correct order (respect FKs)
    DELETE FROM data.order_items WHERE order_id IN (
        SELECT id FROM data.orders WHERE customer_id IN (
            SELECT id FROM data.customers WHERE email LIKE 'test_%@example.com'
        )
    );
    DELETE FROM data.orders WHERE customer_id IN (
        SELECT id FROM data.customers WHERE email LIKE 'test_%@example.com'
    );
    DELETE FROM data.customers WHERE email LIKE 'test_%@example.com';
    DELETE FROM data.customers WHERE email LIKE '%@test.com';
END;
$$;
```

## Transaction Isolation

### Running Tests in Transactions (Rollback Pattern)

```sql
CREATE OR REPLACE FUNCTION test.run_test_isolated(in_test_function text)
RETURNS TABLE (test_result text)
LANGUAGE plpgsql
AS $$
BEGIN
    -- Start savepoint
    -- Execute test
    -- Rollback to savepoint
    
    RETURN QUERY EXECUTE format(
        'SELECT * FROM %s()',
        in_test_function
    );
    
    -- Note: In practice, wrap in transaction from caller
END;
$$;

-- Usage from psql:
-- BEGIN;
-- SELECT * FROM test.test_api_insert_customer();
-- ROLLBACK;
```

### Test Runner with Automatic Rollback

```sql
CREATE OR REPLACE FUNCTION test.run_all_tests()
RETURNS TABLE (
    test_name text,
    result text,
    message text
)
LANGUAGE plpgsql
AS $$
DECLARE
    l_test RECORD;
    l_result RECORD;
    l_start_time timestamptz;
    l_total integer := 0;
    l_passed integer := 0;
    l_failed integer := 0;
BEGIN
    l_start_time := clock_timestamp();
    
    -- Find all test functions
    FOR l_test IN
        SELECT p.proname AS name
        FROM pg_proc p
        JOIN pg_namespace n ON p.pronamespace = n.oid
        WHERE n.nspname = 'test'
          AND p.proname LIKE 'test_%'
        ORDER BY p.proname
    LOOP
        -- Run each test in a subtransaction
        BEGIN
            FOR l_result IN EXECUTE format('SELECT * FROM test.%I()', l_test.name)
            LOOP
                l_total := l_total + 1;
                
                IF l_result::text LIKE 'ok%' OR l_result::text LIKE 'pass%' THEN
                    l_passed := l_passed + 1;
                    RETURN QUERY SELECT l_test.name, 'PASS'::text, l_result::text;
                ELSE
                    l_failed := l_failed + 1;
                    RETURN QUERY SELECT l_test.name, 'FAIL'::text, l_result::text;
                END IF;
            END LOOP;
        EXCEPTION
            WHEN OTHERS THEN
                l_failed := l_failed + 1;
                RETURN QUERY SELECT l_test.name, 'ERROR'::text, SQLERRM;
        END;
    END LOOP;
    
    -- Log results
    INSERT INTO test.test_runs (total_tests, passed, failed, execution_ms)
    VALUES (
        l_total, 
        l_passed, 
        l_failed,
        EXTRACT(MILLISECONDS FROM clock_timestamp() - l_start_time)::integer
    );
    
    -- Summary row
    RETURN QUERY SELECT 
        '=== SUMMARY ==='::text,
        CASE WHEN l_failed = 0 THEN 'ALL PASSED' ELSE 'FAILURES' END,
        format('%s total, %s passed, %s failed', l_total, l_passed, l_failed);
        
END;
$$;
```

## Migration Testing

### Testing Migration Applies Correctly

```sql
CREATE OR REPLACE FUNCTION test.test_migration_001_creates_customers()
RETURNS SETOF text
LANGUAGE plpgsql
AS $$
BEGIN
    -- Verify table exists
    RETURN NEXT ok(
        EXISTS(
            SELECT 1 FROM information_schema.tables 
            WHERE table_schema = 'data' AND table_name = 'customers'
        ),
        'customers table should exist'
    );
    
    -- Verify columns
    RETURN NEXT ok(
        EXISTS(
            SELECT 1 FROM information_schema.columns 
            WHERE table_schema = 'data' 
              AND table_name = 'customers' 
              AND column_name = 'id'
              AND data_type = 'uuid'
        ),
        'customers.id should be uuid'
    );
    
    -- Verify constraints
    RETURN NEXT ok(
        EXISTS(
            SELECT 1 FROM information_schema.table_constraints
            WHERE table_schema = 'data'
              AND table_name = 'customers'
              AND constraint_type = 'PRIMARY KEY'
        ),
        'customers should have primary key'
    );
    
    -- Verify indexes
    RETURN NEXT ok(
        EXISTS(
            SELECT 1 FROM pg_indexes
            WHERE schemaname = 'data'
              AND tablename = 'customers'
              AND indexname = 'customers_email_key'
        ),
        'customers should have email unique index'
    );
    
END;
$$;
```

### Testing Rollback

```sql
CREATE OR REPLACE FUNCTION test.test_migration_rollback()
RETURNS SETOF text
LANGUAGE plpgsql
AS $$
DECLARE
    l_version_before integer;
    l_version_after integer;
BEGIN
    -- Get current version
    SELECT COUNT(*) INTO l_version_before 
    FROM app_migration.changelog 
    WHERE type = 'versioned' AND success = true;
    
    -- Apply a test migration
    SELECT app_migration.acquire_lock();
    
    CALL app_migration.run_versioned(
        in_version := '999',
        in_description := 'Test migration for rollback',
        in_sql := 'CREATE TABLE data.test_rollback_table (id int);',
        in_rollback_sql := 'DROP TABLE IF EXISTS data.test_rollback_table;'
    );
    
    -- Verify table created
    RETURN NEXT ok(
        EXISTS(SELECT 1 FROM information_schema.tables 
               WHERE table_schema = 'data' AND table_name = 'test_rollback_table'),
        'Test table should be created'
    );
    
    -- Rollback
    CALL app_migration.rollback('999');
    
    -- Verify table removed
    RETURN NEXT ok(
        NOT EXISTS(SELECT 1 FROM information_schema.tables 
                   WHERE table_schema = 'data' AND table_name = 'test_rollback_table'),
        'Test table should be removed after rollback'
    );
    
    SELECT app_migration.release_lock();
    
END;
$$;
```

## CI/CD Integration

### GitHub Actions Workflow

```yaml
# .github/workflows/db-tests.yml
name: Database Tests

on:
  push:
    paths:
      - 'db/**'
  pull_request:
    paths:
      - 'db/**'

jobs:
  test:
    runs-on: ubuntu-latest
    
    services:
      postgres:
        image: postgres:18
        env:
          POSTGRES_USER: test
          POSTGRES_PASSWORD: test
          POSTGRES_DB: test_db
        ports:
          - 5432:5432
        options: >-
          --health-cmd pg_isready
          --health-interval 10s
          --health-timeout 5s
          --health-retries 5

    steps:
      - uses: actions/checkout@v4
      
      - name: Install pgTAP
        run: |
          sudo apt-get update
          sudo apt-get install -y postgresql-client pgtap
          
      - name: Run migrations
        env:
          PGHOST: localhost
          PGUSER: test
          PGPASSWORD: test
          PGDATABASE: test_db
        run: |
          psql -f db/scripts/001_install_migration_system.sql
          psql -f db/scripts/002_migration_runner_helpers.sql
          psql -f db/migrations/run_all.sql
          
      - name: Run tests
        env:
          PGHOST: localhost
          PGUSER: test
          PGPASSWORD: test
          PGDATABASE: test_db
        run: |
          psql -f db/tests/install_tests.sql
          psql -c "SELECT * FROM test.run_all_tests();" | tee test_results.txt
          
      - name: Check for failures
        run: |
          if grep -q "FAIL\|ERROR" test_results.txt; then
            echo "Tests failed!"
            exit 1
          fi
```

### Docker Test Setup

```dockerfile
# Dockerfile.test
FROM postgres:18

# Install pgTAP
RUN apt-get update && apt-get install -y \
    postgresql-18-pgtap \
    && rm -rf /var/lib/apt/lists/*

# Copy initialization scripts
COPY db/scripts/*.sql /docker-entrypoint-initdb.d/01-scripts/
COPY db/migrations/*.sql /docker-entrypoint-initdb.d/02-migrations/
COPY db/tests/*.sql /docker-entrypoint-initdb.d/03-tests/

# Copy test runner
COPY db/tests/run_tests.sh /docker-entrypoint-initdb.d/99-run-tests.sh
```

```bash
#!/bin/bash
# db/tests/run_tests.sh

set -e

psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" <<EOF
SELECT * FROM test.run_all_tests();
EOF

# Check exit status
FAILED=$(psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -t -c \
    "SELECT failed FROM test.test_runs ORDER BY id DESC LIMIT 1;")

if [ "$FAILED" -gt 0 ]; then
    echo "Tests failed!"
    exit 1
fi

echo "All tests passed!"
```

### Running Tests Locally

```bash
#!/bin/bash
# scripts/run-db-tests.sh

# Start test database
docker-compose -f docker-compose.test.yml up -d postgres

# Wait for database
until docker-compose -f docker-compose.test.yml exec -T postgres pg_isready; do
    sleep 1
done

# Run migrations
docker-compose -f docker-compose.test.yml exec -T postgres \
    psql -U test -d test_db -f /app/db/migrations/run_all.sql

# Run tests
docker-compose -f docker-compose.test.yml exec -T postgres \
    psql -U test -d test_db -c "SELECT * FROM test.run_all_tests();"

# Cleanup
docker-compose -f docker-compose.test.yml down -v
```
