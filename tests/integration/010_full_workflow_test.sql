-- ============================================================================
-- INTEGRATION TESTS - FULL WORKFLOW
-- ============================================================================
-- End-to-end test of the complete migration and schema pattern workflow.
-- ============================================================================

-- ============================================================================
-- FULL WORKFLOW TEST
-- ============================================================================

-- Test: Complete application setup workflow
CREATE OR REPLACE FUNCTION test.test_integration_010_full_workflow()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_prefix text := 'TEST_INT_' || to_char(clock_timestamp(), 'HH24MISS');
    l_customer_id uuid;
    l_order_id uuid;
    l_order_total numeric;
    l_order_count integer;
BEGIN
    PERFORM test.set_context('test_integration_010_full_workflow');

    PERFORM test.diag('=== Starting Full Workflow Integration Test ===');

    -- =========================================================================
    -- STEP 1: Acquire migration lock
    -- =========================================================================
    PERFORM test.diag('Step 1: Acquire migration lock');
    PERFORM test.ok(app_migration.acquire_lock(), 'acquire migration lock');

    -- =========================================================================
    -- STEP 2: Create data schema objects (versioned migrations)
    -- =========================================================================
    PERFORM test.diag('Step 2: Create data tables');

    -- Migration 001: Create customers table
    CALL app_migration.run_versioned(
        in_version := l_prefix || '_001',
        in_description := 'Create customers table',
        in_sql := format($mig$
            CREATE TABLE data.%I (
                id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
                email text NOT NULL,
                name text NOT NULL,
                is_active boolean NOT NULL DEFAULT true,
                created_at timestamptz NOT NULL DEFAULT now(),
                updated_at timestamptz NOT NULL DEFAULT now()
            );
            CREATE UNIQUE INDEX %I_email_key ON data.%I(lower(email));
        $mig$, l_prefix || '_customers', l_prefix || '_customers', l_prefix || '_customers'),
        in_rollback_sql := format('DROP TABLE IF EXISTS data.%I CASCADE', l_prefix || '_customers')
    );

    PERFORM test.has_table('data', l_prefix || '_customers', 'customers table created');

    -- Migration 002: Create orders table
    CALL app_migration.run_versioned(
        in_version := l_prefix || '_002',
        in_description := 'Create orders table',
        in_sql := format($mig$
            CREATE TABLE data.%I (
                id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
                customer_id uuid NOT NULL REFERENCES data.%I(id),
                status text NOT NULL DEFAULT 'pending',
                subtotal numeric(15,2) NOT NULL,
                tax_rate numeric(5,4) NOT NULL DEFAULT 0.0875,
                total numeric(15,2) GENERATED ALWAYS AS (round(subtotal * (1 + tax_rate), 2)) STORED,
                created_at timestamptz NOT NULL DEFAULT now(),
                updated_at timestamptz NOT NULL DEFAULT now(),
                CONSTRAINT %I_status_check CHECK (status IN ('pending', 'confirmed', 'shipped', 'delivered', 'cancelled'))
            );
            CREATE INDEX %I_customer_idx ON data.%I(customer_id);
            CREATE INDEX %I_status_idx ON data.%I(status) WHERE status NOT IN ('delivered', 'cancelled');
        $mig$,
            l_prefix || '_orders', l_prefix || '_customers',
            l_prefix || '_orders',
            l_prefix || '_orders', l_prefix || '_orders',
            l_prefix || '_orders', l_prefix || '_orders'
        ),
        in_rollback_sql := format('DROP TABLE IF EXISTS data.%I CASCADE', l_prefix || '_orders')
    );

    PERFORM test.has_table('data', l_prefix || '_orders', 'orders table created');

    -- =========================================================================
    -- STEP 3: Create private schema objects (repeatable migration)
    -- =========================================================================
    PERFORM test.diag('Step 3: Create trigger functions');

    CALL app_migration.run_repeatable(
        in_filename := l_prefix || '_R__triggers.sql',
        in_description := 'Trigger functions',
        in_sql := format($mig$
            -- Updated_at trigger function
            CREATE OR REPLACE FUNCTION private.%I_set_updated_at()
            RETURNS trigger
            LANGUAGE plpgsql
            AS $fn$
            BEGIN
                NEW.updated_at := now();
                RETURN NEW;
            END;
            $fn$;

            -- Apply to customers
            DROP TRIGGER IF EXISTS %I_biu_updated_trg ON data.%I;
            CREATE TRIGGER %I_biu_updated_trg
                BEFORE INSERT OR UPDATE ON data.%I
                FOR EACH ROW
                EXECUTE FUNCTION private.%I_set_updated_at();

            -- Apply to orders
            DROP TRIGGER IF EXISTS %I_biu_updated_trg ON data.%I;
            CREATE TRIGGER %I_biu_updated_trg
                BEFORE INSERT OR UPDATE ON data.%I
                FOR EACH ROW
                EXECUTE FUNCTION private.%I_set_updated_at();
        $mig$,
            l_prefix,
            l_prefix || '_customers', l_prefix || '_customers',
            l_prefix || '_customers', l_prefix || '_customers',
            l_prefix,
            l_prefix || '_orders', l_prefix || '_orders',
            l_prefix || '_orders', l_prefix || '_orders',
            l_prefix
        )
    );

    PERFORM test.has_function('private', l_prefix || '_set_updated_at', 'trigger function created');

    -- =========================================================================
    -- STEP 4: Create API layer functions (repeatable migration)
    -- =========================================================================
    PERFORM test.diag('Step 4: Create API functions');

    CALL app_migration.run_repeatable(
        in_filename := l_prefix || '_R__api.sql',
        in_description := 'API functions',
        in_sql := format($mig$
            -- Insert customer procedure
            CREATE OR REPLACE PROCEDURE api.%I(
                in_email text,
                in_name text,
                INOUT io_id uuid DEFAULT NULL
            )
            LANGUAGE plpgsql
            SECURITY DEFINER
            SET search_path = data, private, pg_temp
            AS $fn$
            BEGIN
                INSERT INTO %I (email, name)
                VALUES (in_email, in_name)
                RETURNING id INTO io_id;
            END;
            $fn$;

            -- Select customers function
            CREATE OR REPLACE FUNCTION api.%I(
                in_email_filter text DEFAULT NULL,
                in_active_only boolean DEFAULT true
            )
            RETURNS TABLE (id uuid, email text, name text, created_at timestamptz)
            LANGUAGE sql
            STABLE
            SECURITY DEFINER
            SET search_path = data, private, pg_temp
            AS $fn$
                SELECT id, email, name, created_at
                FROM %I
                WHERE (in_email_filter IS NULL OR email ILIKE '%%' || in_email_filter || '%%')
                  AND (NOT in_active_only OR is_active = true)
            $fn$;

            -- Insert order procedure
            CREATE OR REPLACE PROCEDURE api.%I(
                in_customer_id uuid,
                in_subtotal numeric,
                INOUT io_id uuid DEFAULT NULL
            )
            LANGUAGE plpgsql
            SECURITY DEFINER
            SET search_path = data, private, pg_temp
            AS $fn$
            BEGIN
                INSERT INTO %I (customer_id, subtotal)
                VALUES (in_customer_id, in_subtotal)
                RETURNING id INTO io_id;
            END;
            $fn$;

            -- Select orders function
            CREATE OR REPLACE FUNCTION api.%I(
                in_customer_id uuid DEFAULT NULL,
                in_status text DEFAULT NULL
            )
            RETURNS TABLE (id uuid, customer_id uuid, status text, subtotal numeric, total numeric, created_at timestamptz)
            LANGUAGE sql
            STABLE
            SECURITY DEFINER
            SET search_path = data, private, pg_temp
            AS $fn$
                SELECT id, customer_id, status, subtotal, total, created_at
                FROM %I
                WHERE (in_customer_id IS NULL OR customer_id = in_customer_id)
                  AND (in_status IS NULL OR status = in_status)
                ORDER BY created_at DESC
            $fn$;
        $mig$,
            l_prefix || '_insert_customer', l_prefix || '_customers',
            l_prefix || '_select_customers', l_prefix || '_customers',
            l_prefix || '_insert_order', l_prefix || '_orders',
            l_prefix || '_select_orders', l_prefix || '_orders'
        )
    );

    PERFORM test.has_procedure('api', l_prefix || '_insert_customer', 'insert_customer procedure created');
    PERFORM test.has_function('api', l_prefix || '_select_customers', 'select_customers function created');

    -- =========================================================================
    -- STEP 5: Test the application
    -- =========================================================================
    PERFORM test.diag('Step 5: Test application workflow');

    -- Create a customer via API
    EXECUTE format('CALL api.%I($1, $2, $3)', l_prefix || '_insert_customer')
    USING 'alice@example.com', 'Alice Smith', l_customer_id;

    PERFORM test.is_not_null(l_customer_id, 'customer created via API');

    -- Create an order via API
    EXECUTE format('CALL api.%I($1, $2, $3)', l_prefix || '_insert_order')
    USING l_customer_id, 100.00::numeric, l_order_id;

    PERFORM test.is_not_null(l_order_id, 'order created via API');

    -- Query orders via API
    EXECUTE format('SELECT total FROM api.%I($1)', l_prefix || '_select_orders')
    INTO l_order_total
    USING l_customer_id;

    -- Total should include tax: 100 * 1.0875 = 108.75
    PERFORM test.is(l_order_total, 108.75::numeric, 'order total calculated correctly with tax');

    -- =========================================================================
    -- STEP 6: Verify migration tracking
    -- =========================================================================
    PERFORM test.diag('Step 6: Verify migration history');

    PERFORM test.ok(
        app_migration.is_version_applied(l_prefix || '_001'),
        'migration 001 is tracked'
    );

    PERFORM test.ok(
        app_migration.is_version_applied(l_prefix || '_002'),
        'migration 002 is tracked'
    );

    -- =========================================================================
    -- STEP 7: Release lock
    -- =========================================================================
    PERFORM test.diag('Step 7: Release migration lock');
    PERFORM test.ok(app_migration.release_lock(), 'release migration lock');

    -- =========================================================================
    -- CLEANUP
    -- =========================================================================
    PERFORM test.diag('Cleanup: Rolling back migrations');

    PERFORM app_migration.acquire_lock();

    -- Rollback in reverse order
    CALL app_migration.rollback(l_prefix || '_002');
    CALL app_migration.rollback(l_prefix || '_001');

    PERFORM app_migration.release_lock();

    -- Drop API objects
    EXECUTE format('DROP PROCEDURE IF EXISTS api.%I(text, text, uuid)', l_prefix || '_insert_customer');
    EXECUTE format('DROP FUNCTION IF EXISTS api.%I(text, boolean)', l_prefix || '_select_customers');
    EXECUTE format('DROP PROCEDURE IF EXISTS api.%I(uuid, numeric, uuid)', l_prefix || '_insert_order');
    EXECUTE format('DROP FUNCTION IF EXISTS api.%I(uuid, text)', l_prefix || '_select_orders');
    EXECUTE format('DROP FUNCTION IF EXISTS private.%I_set_updated_at()', l_prefix);

    -- Clean migration records
    DELETE FROM app_migration.changelog WHERE version LIKE l_prefix || '_%' OR filename LIKE l_prefix || '_%';
    DELETE FROM app_migration.rollback_scripts WHERE version LIKE l_prefix || '_%';
    DELETE FROM app_migration.rollback_history WHERE version LIKE l_prefix || '_%';

    PERFORM test.diag('=== Full Workflow Integration Test Complete ===');
END;
$$;

-- ============================================================================
-- RUN TEST
-- ============================================================================

SELECT test.run_test('test.test_integration_010_full_workflow');
CALL test.print_summary();
