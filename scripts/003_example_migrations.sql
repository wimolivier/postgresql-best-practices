-- ============================================================================
-- EXAMPLE MIGRATIONS
-- ============================================================================
-- This file demonstrates how to write and execute migrations using the
-- migration system. Copy and adapt these patterns for your own migrations.
-- ============================================================================

-- ============================================================================
-- EXAMPLE 1: Simple Versioned Migration
-- ============================================================================
-- Versioned migrations run exactly once, in order.
-- Naming: V{version}__{description}.sql

/*
-- Acquire lock first
SELECT app_migration.acquire_lock();

-- Run the migration
CALL app_migration.run_versioned(
    in_version := '001',
    in_description := 'Create customers table',
    in_sql := $mig$
        CREATE TABLE data.customers (
            id uuid PRIMARY KEY DEFAULT uuidv7(),
            email text NOT NULL,
            name text NOT NULL,
            is_active boolean NOT NULL DEFAULT true,
            created_at timestamptz NOT NULL DEFAULT now(),
            updated_at timestamptz NOT NULL DEFAULT now()
        );
        
        CREATE UNIQUE INDEX customers_email_key ON data.customers(lower(email));
        CREATE INDEX idx_customers_is_active ON data.customers(is_active) WHERE is_active;
        
        COMMENT ON TABLE data.customers IS 'Customer accounts';
    $mig$,
    in_rollback_sql := $rollback$
        DROP TABLE IF EXISTS data.customers CASCADE;
    $rollback$
);

-- Release lock
SELECT app_migration.release_lock();
*/

-- ============================================================================
-- EXAMPLE 2: Migration with Foreign Key
-- ============================================================================

/*
SELECT app_migration.acquire_lock();

CALL app_migration.run_versioned(
    in_version := '002',
    in_description := 'Create orders table',
    in_sql := $mig$
        CREATE TABLE data.orders (
            id uuid PRIMARY KEY DEFAULT uuidv7(),
            customer_id uuid NOT NULL REFERENCES data.customers(id),
            status text NOT NULL DEFAULT 'pending',
            subtotal numeric(15,2) NOT NULL,
            tax_rate numeric(5,4) NOT NULL DEFAULT 0.0875,
            total numeric(15,2) GENERATED ALWAYS AS (subtotal * (1 + tax_rate)),
            created_at timestamptz NOT NULL DEFAULT now(),
            updated_at timestamptz NOT NULL DEFAULT now(),
            
            CONSTRAINT orders_status_check 
                CHECK (status IN ('pending', 'confirmed', 'shipped', 'delivered', 'cancelled')),
            CONSTRAINT orders_subtotal_positive CHECK (subtotal >= 0)
        );
        
        CREATE INDEX idx_orders_customer_id ON data.orders(customer_id);
        CREATE INDEX idx_orders_status ON data.orders(status) WHERE status NOT IN ('delivered', 'cancelled');
        CREATE INDEX idx_orders_created ON data.orders(created_at DESC);
    $mig$,
    in_rollback_sql := 'DROP TABLE IF EXISTS data.orders CASCADE;'
);

SELECT app_migration.release_lock();
*/

-- ============================================================================
-- EXAMPLE 3: Adding Column to Existing Table
-- ============================================================================

/*
SELECT app_migration.acquire_lock();

CALL app_migration.run_versioned(
    in_version := '003',
    in_description := 'Add phone to customers',
    in_sql := $mig$
        ALTER TABLE data.customers ADD COLUMN phone text;
        
        COMMENT ON COLUMN data.customers.phone IS 'Customer phone number';
    $mig$,
    in_rollback_sql := 'ALTER TABLE data.customers DROP COLUMN IF EXISTS phone;'
);

SELECT app_migration.release_lock();
*/

-- ============================================================================
-- EXAMPLE 4: Creating Index Concurrently
-- ============================================================================
-- Note: CONCURRENTLY cannot be inside a transaction, so this migration
-- must be run outside of a transaction block.

/*
-- This migration requires special handling - no transaction
SELECT app_migration.acquire_lock();

-- Execute outside transaction
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_customers_phone 
    ON data.customers(phone) 
    WHERE phone IS NOT NULL;

-- Register the migration manually
SELECT app_migration.register_execution(
    in_version := '004',
    in_description := 'Add phone index (concurrent)',
    in_type := 'versioned',
    in_filename := 'V004__add_phone_index.sql',
    in_checksum := app_migration.calculate_checksum('CREATE INDEX idx_customers_phone'),
    in_success := true
);

-- Register rollback
CALL app_migration.register_rollback('004', 'DROP INDEX IF EXISTS data.idx_customers_phone;');

SELECT app_migration.release_lock();
*/

-- ============================================================================
-- EXAMPLE 5: Repeatable Migration (Views)
-- ============================================================================
-- Repeatable migrations run whenever their content changes.
-- Use for views, functions, and other replaceable objects.

/*
SELECT app_migration.acquire_lock();

CALL app_migration.run_repeatable(
    in_filename := 'R__views.sql',
    in_description := 'Application views',
    in_sql := $mig$
        -- Active customers view
        DROP VIEW IF EXISTS api.v_active_customers CASCADE;
        CREATE VIEW api.v_active_customers AS
        SELECT id, email, name, phone, created_at
        FROM data.customers
        WHERE is_active = true;
        
        -- Order summary view
        DROP VIEW IF EXISTS api.v_order_summary CASCADE;
        CREATE VIEW api.v_order_summary AS
        SELECT 
            o.id,
            o.customer_id,
            c.email AS customer_email,
            c.name AS customer_name,
            o.status,
            o.subtotal,
            o.total,
            o.created_at
        FROM data.orders o
        JOIN data.customers c ON c.id = o.customer_id;
        
        -- Pending orders view
        DROP VIEW IF EXISTS api.v_pending_orders CASCADE;
        CREATE VIEW api.v_pending_orders AS
        SELECT * FROM api.v_order_summary WHERE status = 'pending';
    $mig$
);

SELECT app_migration.release_lock();
*/

-- ============================================================================
-- EXAMPLE 6: Repeatable Migration (Functions)
-- ============================================================================

/*
SELECT app_migration.acquire_lock();

CALL app_migration.run_repeatable(
    in_filename := 'R__functions.sql',
    in_description := 'Application functions',
    in_sql := $mig$
        -- Get customer by email
        CREATE OR REPLACE FUNCTION data.get_customer_by_email(in_email text)
        RETURNS data.customers
        LANGUAGE sql
        STABLE
        PARALLEL SAFE
        AS $fn$
            SELECT * FROM data.customers WHERE lower(email) = lower(in_email);
        $fn$;
        
        -- Get customer orders
        CREATE OR REPLACE FUNCTION data.select_orders_by_customer(
            in_customer_id uuid,
            in_status text DEFAULT NULL,
            in_limit integer DEFAULT 100
        )
        RETURNS TABLE (id uuid, status text, total numeric, created_at timestamptz)
        LANGUAGE sql
        STABLE
        SECURITY DEFINER
        SET search_path = data, private, pg_temp
        AS $fn$
            SELECT id, status, total, created_at 
            FROM data.orders
            WHERE customer_id = in_customer_id
              AND (in_status IS NULL OR status = in_status)
            ORDER BY created_at DESC
            LIMIT in_limit;
        $fn$;
        
        -- Insert order procedure
        CREATE OR REPLACE PROCEDURE api.insert_order(
            in_customer_id uuid,
            in_subtotal numeric,
            INOUT io_id uuid DEFAULT NULL
        )
        LANGUAGE plpgsql
        SECURITY DEFINER
        SET search_path = data, private, pg_temp
        AS $fn$
        BEGIN
            INSERT INTO data.orders (customer_id, subtotal)
            VALUES (in_customer_id, in_subtotal)
            RETURNING id INTO io_id;
        END;
        $fn$;
    $mig$
);

SELECT app_migration.release_lock();
*/

-- ============================================================================
-- EXAMPLE 7: Repeatable Migration (Triggers)
-- ============================================================================

/*
SELECT app_migration.acquire_lock();

CALL app_migration.run_repeatable(
    in_filename := 'R__triggers.sql',
    in_description := 'Application triggers',
    in_sql := $mig$
        -- Updated_at trigger function
        CREATE OR REPLACE FUNCTION data.set_updated_at()
        RETURNS trigger
        LANGUAGE plpgsql
        AS $fn$
        BEGIN
            NEW.updated_at := now();
            RETURN NEW;
        END;
        $fn$;
        
        -- Apply to customers
        DROP TRIGGER IF EXISTS customers_biu_updated_trg ON data.customers;
        CREATE TRIGGER customers_biu_updated_trg
            BEFORE INSERT OR UPDATE ON data.customers
            FOR EACH ROW
            EXECUTE FUNCTION data.set_updated_at();
        
        -- Apply to orders
        DROP TRIGGER IF EXISTS orders_biu_updated_trg ON data.orders;
        CREATE TRIGGER orders_biu_updated_trg
            BEFORE INSERT OR UPDATE ON data.orders
            FOR EACH ROW
            EXECUTE FUNCTION data.set_updated_at();
    $mig$
);

SELECT app_migration.release_lock();
*/

-- ============================================================================
-- EXAMPLE 8: Batch Migration Execution
-- ============================================================================
-- Run multiple migrations at once using JSON

/*
SELECT app_migration.acquire_lock();

CALL app_migration.run_all(
    in_versioned_migrations := '[
        {
            "version": "001",
            "description": "Create customers table",
            "filename": "V001__create_customers.sql",
            "sql": "CREATE TABLE data.customers (id uuid PRIMARY KEY DEFAULT uuidv7(), email text NOT NULL);"
        },
        {
            "version": "002", 
            "description": "Create orders table",
            "filename": "V002__create_orders.sql",
            "sql": "CREATE TABLE data.orders (id uuid PRIMARY KEY DEFAULT uuidv7(), customer_id uuid NOT NULL);"
        }
    ]'::jsonb,
    in_repeatable_migrations := '[
        {
            "filename": "R__views.sql",
            "description": "Views",
            "sql": "CREATE OR REPLACE VIEW api.v_customers AS SELECT id, email, name, created_at FROM data.customers;"
        }
    ]'::jsonb
);

SELECT app_migration.release_lock();
*/

-- ============================================================================
-- CHECKING STATUS
-- ============================================================================

-- View migration status
-- SELECT * FROM app_migration.info();

-- View migration history
-- SELECT * FROM app_migration.get_history(20);

-- Print formatted status
-- CALL app_migration.print_status();

-- Check specific version
-- SELECT app_migration.is_version_applied('001');

-- Get current version
-- SELECT app_migration.get_current_version();

-- ============================================================================
-- ROLLBACK EXAMPLES
-- ============================================================================

/*
-- Rollback a single version
SELECT app_migration.acquire_lock();
CALL app_migration.rollback('003');
SELECT app_migration.release_lock();

-- Rollback to a specific version (rolls back all after target)
SELECT app_migration.acquire_lock();
CALL app_migration.rollback_to('001');  -- Rolls back 002, 003, etc.
SELECT app_migration.release_lock();

-- Check available rollbacks
SELECT * FROM app_migration.get_rollback_versions();
*/
