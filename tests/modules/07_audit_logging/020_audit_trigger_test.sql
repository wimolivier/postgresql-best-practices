-- ============================================================================
-- AUDIT LOGGING TESTS - TRIGGER BEHAVIOR
-- ============================================================================
-- Tests for generic audit trigger function behavior.
-- Reference: references/audit-logging.md
-- ============================================================================

-- ============================================================================
-- SETUP: Create audit trigger function
-- ============================================================================

CREATE OR REPLACE FUNCTION app_audit.log_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = app_audit, pg_temp
AS $$
DECLARE
    l_old_values    jsonb;
    l_new_values    jsonb;
    l_changed_cols  text[];
    l_row_id        text;
    l_excluded_cols text[];
    l_col           text;
    l_app_user_id   uuid;
    l_app_tenant_id uuid;
    l_app_request_id text;
BEGIN
    -- Get application context from session variables
    l_app_user_id := NULLIF(current_setting('app.current_user_id', true), '')::uuid;
    l_app_tenant_id := NULLIF(current_setting('app.current_tenant_id', true), '')::uuid;
    l_app_request_id := NULLIF(current_setting('app.request_id', true), '');

    -- Get excluded columns for this table
    SELECT array_agg(column_name)
    INTO l_excluded_cols
    FROM app_audit.excluded_columns
    WHERE schema_name = TG_TABLE_SCHEMA
      AND table_name = TG_TABLE_NAME;

    l_excluded_cols := COALESCE(l_excluded_cols, '{}');

    -- Build row ID
    IF TG_OP = 'DELETE' THEN
        l_row_id := OLD::text;
    ELSE
        l_row_id := NEW::text;
    END IF;

    -- Process based on operation
    CASE TG_OP
        WHEN 'INSERT' THEN
            l_new_values := to_jsonb(NEW);
            -- Remove excluded columns
            FOREACH l_col IN ARRAY l_excluded_cols LOOP
                l_new_values := l_new_values - l_col;
            END LOOP;

        WHEN 'UPDATE' THEN
            l_old_values := to_jsonb(OLD);
            l_new_values := to_jsonb(NEW);

            -- Find changed columns
            SELECT array_agg(key)
            INTO l_changed_cols
            FROM (
                SELECT o.key
                FROM jsonb_each(l_old_values) o
                JOIN jsonb_each(l_new_values) n ON o.key = n.key
                WHERE o.value IS DISTINCT FROM n.value
            ) changes;

            -- Skip if nothing actually changed
            IF l_changed_cols IS NULL OR array_length(l_changed_cols, 1) IS NULL THEN
                RETURN NEW;
            END IF;

            -- Remove excluded columns
            FOREACH l_col IN ARRAY l_excluded_cols LOOP
                l_old_values := l_old_values - l_col;
                l_new_values := l_new_values - l_col;
                l_changed_cols := array_remove(l_changed_cols, l_col);
            END LOOP;

        WHEN 'DELETE' THEN
            l_old_values := to_jsonb(OLD);
            -- Remove excluded columns
            FOREACH l_col IN ARRAY l_excluded_cols LOOP
                l_old_values := l_old_values - l_col;
            END LOOP;
    END CASE;

    -- Insert audit record
    INSERT INTO app_audit.changelog (
        schema_name,
        table_name,
        operation,
        row_id,
        old_values,
        new_values,
        changed_columns,
        app_user_id,
        app_tenant_id,
        app_request_id
    ) VALUES (
        TG_TABLE_SCHEMA,
        TG_TABLE_NAME,
        TG_OP,
        l_row_id,
        l_old_values,
        l_new_values,
        l_changed_cols,
        l_app_user_id,
        l_app_tenant_id,
        l_app_request_id
    );

    -- Return appropriate value
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    ELSE
        RETURN NEW;
    END IF;
END;
$$;

-- ============================================================================
-- TEST FUNCTIONS
-- ============================================================================

-- Test: Audit trigger function exists
CREATE OR REPLACE FUNCTION test.test_audit_020_trigger_function_exists()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM test.set_context('test_audit_020_trigger_function_exists');

    PERFORM test.has_function('app_audit', 'log_change', 'log_change trigger function should exist');
END;
$$;

-- Test: Audit INSERT operation
CREATE OR REPLACE FUNCTION test.test_audit_021_audit_insert()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_audit_021_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_row_id uuid;
    l_audit_count integer;
    l_audit_record RECORD;
BEGIN
    PERFORM test.set_context('test_audit_021_audit_insert');

    -- Create test table
    EXECUTE format('CREATE TABLE data.%I (
        id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        name text NOT NULL,
        email text
    )', l_test_table);

    -- Add audit trigger
    EXECUTE format('CREATE TRIGGER %I
        AFTER INSERT OR UPDATE OR DELETE ON data.%I
        FOR EACH ROW EXECUTE FUNCTION app_audit.log_change()',
        l_test_table || '_audit', l_test_table);

    -- Insert a row
    EXECUTE format('INSERT INTO data.%I (name, email) VALUES (''John Doe'', ''john@example.com'') RETURNING id', l_test_table)
        INTO l_row_id;

    -- Verify audit record created
    SELECT COUNT(*) INTO l_audit_count
    FROM app_audit.changelog
    WHERE table_name = l_test_table
      AND operation = 'INSERT';

    PERFORM test.is(l_audit_count, 1, 'Should create 1 audit record for INSERT');

    -- Verify audit content
    SELECT * INTO l_audit_record
    FROM app_audit.changelog
    WHERE table_name = l_test_table
      AND operation = 'INSERT'
    ORDER BY id DESC LIMIT 1;

    PERFORM test.is(l_audit_record.schema_name, 'data', 'Schema name should be data');
    PERFORM test.is_null(l_audit_record.old_values, 'old_values should be NULL for INSERT');
    PERFORM test.is_not_null(l_audit_record.new_values, 'new_values should be populated for INSERT');
    PERFORM test.ok((l_audit_record.new_values->>'name') = 'John Doe', 'new_values should contain name');

    -- Cleanup
    DELETE FROM app_audit.changelog WHERE table_name = l_test_table;
    EXECUTE format('DROP TABLE data.%I CASCADE', l_test_table);
END;
$$;

-- Test: Audit UPDATE operation
CREATE OR REPLACE FUNCTION test.test_audit_022_audit_update()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_audit_022_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_row_id uuid;
    l_audit_record RECORD;
BEGIN
    PERFORM test.set_context('test_audit_022_audit_update');

    -- Create test table
    EXECUTE format('CREATE TABLE data.%I (
        id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        name text NOT NULL,
        status text NOT NULL DEFAULT ''active''
    )', l_test_table);

    -- Add audit trigger
    EXECUTE format('CREATE TRIGGER %I
        AFTER INSERT OR UPDATE OR DELETE ON data.%I
        FOR EACH ROW EXECUTE FUNCTION app_audit.log_change()',
        l_test_table || '_audit', l_test_table);

    -- Insert then update
    EXECUTE format('INSERT INTO data.%I (name) VALUES (''Original Name'') RETURNING id', l_test_table)
        INTO l_row_id;

    EXECUTE format('UPDATE data.%I SET name = ''Updated Name'' WHERE id = %L', l_test_table, l_row_id);

    -- Verify UPDATE audit record
    SELECT * INTO l_audit_record
    FROM app_audit.changelog
    WHERE table_name = l_test_table
      AND operation = 'UPDATE'
    ORDER BY id DESC LIMIT 1;

    PERFORM test.is_not_null(l_audit_record.id, 'UPDATE audit record should exist');
    PERFORM test.is_not_null(l_audit_record.old_values, 'old_values should be populated for UPDATE');
    PERFORM test.is_not_null(l_audit_record.new_values, 'new_values should be populated for UPDATE');
    PERFORM test.ok((l_audit_record.old_values->>'name') = 'Original Name', 'old_values should contain original name');
    PERFORM test.ok((l_audit_record.new_values->>'name') = 'Updated Name', 'new_values should contain updated name');
    PERFORM test.ok('name' = ANY(l_audit_record.changed_columns), 'changed_columns should include name');

    -- Cleanup
    DELETE FROM app_audit.changelog WHERE table_name = l_test_table;
    EXECUTE format('DROP TABLE data.%I CASCADE', l_test_table);
END;
$$;

-- Test: Audit DELETE operation
CREATE OR REPLACE FUNCTION test.test_audit_023_audit_delete()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_audit_023_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_row_id uuid;
    l_audit_record RECORD;
BEGIN
    PERFORM test.set_context('test_audit_023_audit_delete');

    -- Create test table
    EXECUTE format('CREATE TABLE data.%I (
        id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        name text NOT NULL
    )', l_test_table);

    -- Add audit trigger
    EXECUTE format('CREATE TRIGGER %I
        AFTER INSERT OR UPDATE OR DELETE ON data.%I
        FOR EACH ROW EXECUTE FUNCTION app_audit.log_change()',
        l_test_table || '_audit', l_test_table);

    -- Insert then delete
    EXECUTE format('INSERT INTO data.%I (name) VALUES (''To Be Deleted'') RETURNING id', l_test_table)
        INTO l_row_id;

    EXECUTE format('DELETE FROM data.%I WHERE id = %L', l_test_table, l_row_id);

    -- Verify DELETE audit record
    SELECT * INTO l_audit_record
    FROM app_audit.changelog
    WHERE table_name = l_test_table
      AND operation = 'DELETE'
    ORDER BY id DESC LIMIT 1;

    PERFORM test.is_not_null(l_audit_record.id, 'DELETE audit record should exist');
    PERFORM test.is_not_null(l_audit_record.old_values, 'old_values should be populated for DELETE');
    PERFORM test.is_null(l_audit_record.new_values, 'new_values should be NULL for DELETE');
    PERFORM test.ok((l_audit_record.old_values->>'name') = 'To Be Deleted', 'old_values should contain deleted data');

    -- Cleanup
    DELETE FROM app_audit.changelog WHERE table_name = l_test_table;
    EXECUTE format('DROP TABLE data.%I CASCADE', l_test_table);
END;
$$;

-- Test: No-change UPDATE skipped
CREATE OR REPLACE FUNCTION test.test_audit_024_skip_no_change()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_audit_024_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_row_id uuid;
    l_update_count integer;
BEGIN
    PERFORM test.set_context('test_audit_024_skip_no_change');

    -- Create test table
    EXECUTE format('CREATE TABLE data.%I (
        id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        name text NOT NULL
    )', l_test_table);

    -- Add audit trigger
    EXECUTE format('CREATE TRIGGER %I
        AFTER INSERT OR UPDATE OR DELETE ON data.%I
        FOR EACH ROW EXECUTE FUNCTION app_audit.log_change()',
        l_test_table || '_audit', l_test_table);

    -- Insert
    EXECUTE format('INSERT INTO data.%I (name) VALUES (''Same Name'') RETURNING id', l_test_table)
        INTO l_row_id;

    -- Update with same values (no actual change)
    EXECUTE format('UPDATE data.%I SET name = ''Same Name'' WHERE id = %L', l_test_table, l_row_id);

    -- Should have no UPDATE audit record
    SELECT COUNT(*) INTO l_update_count
    FROM app_audit.changelog
    WHERE table_name = l_test_table
      AND operation = 'UPDATE';

    PERFORM test.is(l_update_count, 0, 'No-change UPDATE should not create audit record');

    -- Cleanup
    DELETE FROM app_audit.changelog WHERE table_name = l_test_table;
    EXECUTE format('DROP TABLE data.%I CASCADE', l_test_table);
END;
$$;

-- Test: Excluded columns not logged
CREATE OR REPLACE FUNCTION test.test_audit_025_excluded_columns()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_audit_025_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_row_id uuid;
    l_audit_record RECORD;
BEGIN
    PERFORM test.set_context('test_audit_025_excluded_columns');

    -- Create test table with sensitive column
    EXECUTE format('CREATE TABLE data.%I (
        id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        name text NOT NULL,
        password_hash text NOT NULL
    )', l_test_table);

    -- Register exclusion
    INSERT INTO app_audit.excluded_columns (schema_name, table_name, column_name, reason)
    VALUES ('data', l_test_table, 'password_hash', 'Sensitive data');

    -- Add audit trigger
    EXECUTE format('CREATE TRIGGER %I
        AFTER INSERT OR UPDATE OR DELETE ON data.%I
        FOR EACH ROW EXECUTE FUNCTION app_audit.log_change()',
        l_test_table || '_audit', l_test_table);

    -- Insert row with sensitive data
    EXECUTE format('INSERT INTO data.%I (name, password_hash) VALUES (''User'', ''hashed_secret'') RETURNING id', l_test_table)
        INTO l_row_id;

    -- Verify password_hash not in audit
    SELECT * INTO l_audit_record
    FROM app_audit.changelog
    WHERE table_name = l_test_table
      AND operation = 'INSERT'
    ORDER BY id DESC LIMIT 1;

    PERFORM test.ok(NOT (l_audit_record.new_values ? 'password_hash'), 'password_hash should not be in audit record');
    PERFORM test.ok((l_audit_record.new_values ? 'name'), 'name should be in audit record');

    -- Cleanup
    DELETE FROM app_audit.excluded_columns WHERE table_name = l_test_table;
    DELETE FROM app_audit.changelog WHERE table_name = l_test_table;
    EXECUTE format('DROP TABLE data.%I CASCADE', l_test_table);
END;
$$;

-- Test: Multiple rows in single transaction
CREATE OR REPLACE FUNCTION test.test_audit_026_multi_row_transaction()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_audit_026_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_txn_id bigint;
    l_audit_count integer;
BEGIN
    PERFORM test.set_context('test_audit_026_multi_row_transaction');

    -- Create test table
    EXECUTE format('CREATE TABLE data.%I (
        id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        name text NOT NULL
    )', l_test_table);

    -- Add audit trigger
    EXECUTE format('CREATE TRIGGER %I
        AFTER INSERT OR UPDATE OR DELETE ON data.%I
        FOR EACH ROW EXECUTE FUNCTION app_audit.log_change()',
        l_test_table || '_audit', l_test_table);

    -- Capture transaction ID
    l_txn_id := txid_current();

    -- Insert multiple rows
    EXECUTE format('INSERT INTO data.%I (name) VALUES (''Row 1''), (''Row 2''), (''Row 3'')', l_test_table);

    -- All should have same transaction ID
    SELECT COUNT(*) INTO l_audit_count
    FROM app_audit.changelog
    WHERE table_name = l_test_table
      AND transaction_id = l_txn_id;

    PERFORM test.is(l_audit_count, 3, 'All 3 rows should share same transaction_id');

    -- Cleanup
    DELETE FROM app_audit.changelog WHERE table_name = l_test_table;
    EXECUTE format('DROP TABLE data.%I CASCADE', l_test_table);
END;
$$;

-- Test: Audit with changed_columns tracking
CREATE OR REPLACE FUNCTION test.test_audit_027_changed_columns()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_audit_027_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_row_id uuid;
    l_changed_columns text[];
BEGIN
    PERFORM test.set_context('test_audit_027_changed_columns');

    -- Create test table with multiple columns
    EXECUTE format('CREATE TABLE data.%I (
        id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        name text NOT NULL,
        email text,
        status text DEFAULT ''active''
    )', l_test_table);

    -- Add audit trigger
    EXECUTE format('CREATE TRIGGER %I
        AFTER INSERT OR UPDATE OR DELETE ON data.%I
        FOR EACH ROW EXECUTE FUNCTION app_audit.log_change()',
        l_test_table || '_audit', l_test_table);

    -- Insert
    EXECUTE format('INSERT INTO data.%I (name, email) VALUES (''Test'', ''test@example.com'') RETURNING id', l_test_table)
        INTO l_row_id;

    -- Update only email
    EXECUTE format('UPDATE data.%I SET email = ''new@example.com'' WHERE id = %L', l_test_table, l_row_id);

    -- Verify only email in changed_columns
    SELECT changed_columns INTO l_changed_columns
    FROM app_audit.changelog
    WHERE table_name = l_test_table
      AND operation = 'UPDATE'
    ORDER BY id DESC LIMIT 1;

    PERFORM test.ok('email' = ANY(l_changed_columns), 'email should be in changed_columns');
    PERFORM test.ok(NOT ('name' = ANY(l_changed_columns)), 'name should not be in changed_columns');
    PERFORM test.ok(NOT ('status' = ANY(l_changed_columns)), 'status should not be in changed_columns');

    -- Cleanup
    DELETE FROM app_audit.changelog WHERE table_name = l_test_table;
    EXECUTE format('DROP TABLE data.%I CASCADE', l_test_table);
END;
$$;

-- ============================================================================
-- RUN TESTS
-- ============================================================================

SELECT test.run_module('audit_02');
CALL test.print_run_summary();
