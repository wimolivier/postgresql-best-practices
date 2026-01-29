-- ============================================================================
-- AUDIT LOGGING TESTS - APPLICATION CONTEXT
-- ============================================================================
-- Tests for application context tracking in audit logs.
-- Reference: references/audit-logging.md
-- ============================================================================

-- ============================================================================
-- TEST FUNCTIONS
-- ============================================================================

-- Test: App user context captured in audit
CREATE OR REPLACE FUNCTION test.test_audit_030_app_user_context()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_audit_030_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_user_id uuid := gen_random_uuid();
    l_audit_user_id uuid;
BEGIN
    PERFORM test.set_context('test_audit_030_app_user_context');

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

    -- Set app user context
    PERFORM set_config('app.current_user_id', l_user_id::text, true);

    -- Insert row
    EXECUTE format('INSERT INTO data.%I (name) VALUES (''User Context Test'')', l_test_table);

    -- Verify user context captured
    SELECT app_user_id INTO l_audit_user_id
    FROM app_audit.changelog
    WHERE table_name = l_test_table
      AND operation = 'INSERT'
    ORDER BY id DESC LIMIT 1;

    PERFORM test.is(l_audit_user_id, l_user_id, 'app_user_id should be captured from session');

    -- Clear context
    PERFORM set_config('app.current_user_id', '', true);

    -- Cleanup
    DELETE FROM app_audit.changelog WHERE table_name = l_test_table;
    EXECUTE format('DROP TABLE data.%I CASCADE', l_test_table);
END;
$$;

-- Test: App tenant context captured in audit
CREATE OR REPLACE FUNCTION test.test_audit_031_app_tenant_context()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_audit_031_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_tenant_id uuid := gen_random_uuid();
    l_audit_tenant_id uuid;
BEGIN
    PERFORM test.set_context('test_audit_031_app_tenant_context');

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

    -- Set app tenant context
    PERFORM set_config('app.current_tenant_id', l_tenant_id::text, true);

    -- Insert row
    EXECUTE format('INSERT INTO data.%I (name) VALUES (''Tenant Context Test'')', l_test_table);

    -- Verify tenant context captured
    SELECT app_tenant_id INTO l_audit_tenant_id
    FROM app_audit.changelog
    WHERE table_name = l_test_table
      AND operation = 'INSERT'
    ORDER BY id DESC LIMIT 1;

    PERFORM test.is(l_audit_tenant_id, l_tenant_id, 'app_tenant_id should be captured from session');

    -- Clear context
    PERFORM set_config('app.current_tenant_id', '', true);

    -- Cleanup
    DELETE FROM app_audit.changelog WHERE table_name = l_test_table;
    EXECUTE format('DROP TABLE data.%I CASCADE', l_test_table);
END;
$$;

-- Test: App request context captured in audit
CREATE OR REPLACE FUNCTION test.test_audit_032_app_request_context()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_audit_032_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_request_id text := 'req-' || gen_random_uuid()::text;
    l_audit_request_id text;
BEGIN
    PERFORM test.set_context('test_audit_032_app_request_context');

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

    -- Set app request context
    PERFORM set_config('app.request_id', l_request_id, true);

    -- Insert row
    EXECUTE format('INSERT INTO data.%I (name) VALUES (''Request Context Test'')', l_test_table);

    -- Verify request context captured
    SELECT app_request_id INTO l_audit_request_id
    FROM app_audit.changelog
    WHERE table_name = l_test_table
      AND operation = 'INSERT'
    ORDER BY id DESC LIMIT 1;

    PERFORM test.is(l_audit_request_id, l_request_id, 'app_request_id should be captured from session');

    -- Clear context
    PERFORM set_config('app.request_id', '', true);

    -- Cleanup
    DELETE FROM app_audit.changelog WHERE table_name = l_test_table;
    EXECUTE format('DROP TABLE data.%I CASCADE', l_test_table);
END;
$$;

-- Test: All context combined
CREATE OR REPLACE FUNCTION test.test_audit_033_combined_context()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_audit_033_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_user_id uuid := gen_random_uuid();
    l_tenant_id uuid := gen_random_uuid();
    l_request_id text := 'req-combined-' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_record RECORD;
BEGIN
    PERFORM test.set_context('test_audit_033_combined_context');

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

    -- Set all context
    PERFORM set_config('app.current_user_id', l_user_id::text, true);
    PERFORM set_config('app.current_tenant_id', l_tenant_id::text, true);
    PERFORM set_config('app.request_id', l_request_id, true);

    -- Insert row
    EXECUTE format('INSERT INTO data.%I (name) VALUES (''Combined Context Test'')', l_test_table);

    -- Verify all context captured
    SELECT * INTO l_record
    FROM app_audit.changelog
    WHERE table_name = l_test_table
      AND operation = 'INSERT'
    ORDER BY id DESC LIMIT 1;

    PERFORM test.is(l_record.app_user_id, l_user_id, 'app_user_id should be captured');
    PERFORM test.is(l_record.app_tenant_id, l_tenant_id, 'app_tenant_id should be captured');
    PERFORM test.is(l_record.app_request_id, l_request_id, 'app_request_id should be captured');

    -- Clear context
    PERFORM set_config('app.current_user_id', '', true);
    PERFORM set_config('app.current_tenant_id', '', true);
    PERFORM set_config('app.request_id', '', true);

    -- Cleanup
    DELETE FROM app_audit.changelog WHERE table_name = l_test_table;
    EXECUTE format('DROP TABLE data.%I CASCADE', l_test_table);
END;
$$;

-- Test: No context results in NULLs
CREATE OR REPLACE FUNCTION test.test_audit_034_no_context()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_audit_034_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_record RECORD;
BEGIN
    PERFORM test.set_context('test_audit_034_no_context');

    -- Ensure no context is set
    PERFORM set_config('app.current_user_id', '', true);
    PERFORM set_config('app.current_tenant_id', '', true);
    PERFORM set_config('app.request_id', '', true);

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

    -- Insert row without context
    EXECUTE format('INSERT INTO data.%I (name) VALUES (''No Context Test'')', l_test_table);

    -- Verify NULLs
    SELECT * INTO l_record
    FROM app_audit.changelog
    WHERE table_name = l_test_table
      AND operation = 'INSERT'
    ORDER BY id DESC LIMIT 1;

    PERFORM test.is_null(l_record.app_user_id, 'app_user_id should be NULL when not set');
    PERFORM test.is_null(l_record.app_tenant_id, 'app_tenant_id should be NULL when not set');
    PERFORM test.is_null(l_record.app_request_id, 'app_request_id should be NULL when not set');

    -- Cleanup
    DELETE FROM app_audit.changelog WHERE table_name = l_test_table;
    EXECUTE format('DROP TABLE data.%I CASCADE', l_test_table);
END;
$$;

-- Test: Query audit by user
CREATE OR REPLACE FUNCTION test.test_audit_035_query_by_user()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_audit_035_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_user_a uuid := gen_random_uuid();
    l_user_b uuid := gen_random_uuid();
    l_user_a_count integer;
    l_user_b_count integer;
BEGIN
    PERFORM test.set_context('test_audit_035_query_by_user');

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

    -- Insert as User A
    PERFORM set_config('app.current_user_id', l_user_a::text, true);
    EXECUTE format('INSERT INTO data.%I (name) VALUES (''User A Row 1''), (''User A Row 2'')', l_test_table);

    -- Insert as User B
    PERFORM set_config('app.current_user_id', l_user_b::text, true);
    EXECUTE format('INSERT INTO data.%I (name) VALUES (''User B Row'')', l_test_table);

    -- Query by user
    SELECT COUNT(*) INTO l_user_a_count
    FROM app_audit.changelog
    WHERE table_name = l_test_table
      AND app_user_id = l_user_a;

    SELECT COUNT(*) INTO l_user_b_count
    FROM app_audit.changelog
    WHERE table_name = l_test_table
      AND app_user_id = l_user_b;

    PERFORM test.is(l_user_a_count, 2, 'User A should have 2 audit records');
    PERFORM test.is(l_user_b_count, 1, 'User B should have 1 audit record');

    -- Cleanup
    PERFORM set_config('app.current_user_id', '', true);
    DELETE FROM app_audit.changelog WHERE table_name = l_test_table;
    EXECUTE format('DROP TABLE data.%I CASCADE', l_test_table);
END;
$$;

-- Test: Query audit by tenant
CREATE OR REPLACE FUNCTION test.test_audit_036_query_by_tenant()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_audit_036_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_tenant_a uuid := gen_random_uuid();
    l_tenant_b uuid := gen_random_uuid();
    l_tenant_a_count integer;
BEGIN
    PERFORM test.set_context('test_audit_036_query_by_tenant');

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

    -- Insert for Tenant A
    PERFORM set_config('app.current_tenant_id', l_tenant_a::text, true);
    EXECUTE format('INSERT INTO data.%I (name) VALUES (''Tenant A Data'')', l_test_table);

    -- Insert for Tenant B
    PERFORM set_config('app.current_tenant_id', l_tenant_b::text, true);
    EXECUTE format('INSERT INTO data.%I (name) VALUES (''Tenant B Data 1''), (''Tenant B Data 2'')', l_test_table);

    -- Query by tenant A
    SELECT COUNT(*) INTO l_tenant_a_count
    FROM app_audit.changelog
    WHERE table_name = l_test_table
      AND app_tenant_id = l_tenant_a;

    PERFORM test.is(l_tenant_a_count, 1, 'Tenant A should have 1 audit record');

    -- Cleanup
    PERFORM set_config('app.current_tenant_id', '', true);
    DELETE FROM app_audit.changelog WHERE table_name = l_test_table;
    EXECUTE format('DROP TABLE data.%I CASCADE', l_test_table);
END;
$$;

-- Test: Transaction ID grouping for related changes
CREATE OR REPLACE FUNCTION test.test_audit_037_transaction_grouping()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_audit_037_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_txn_id bigint;
    l_records_in_txn integer;
BEGIN
    PERFORM test.set_context('test_audit_037_transaction_grouping');

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

    -- All operations in same transaction
    l_txn_id := txid_current();

    EXECUTE format('INSERT INTO data.%I (name) VALUES (''Row 1'') ', l_test_table);
    EXECUTE format('INSERT INTO data.%I (name) VALUES (''Row 2'') ', l_test_table);
    EXECUTE format('UPDATE data.%I SET name = ''Updated'' WHERE name = ''Row 1''', l_test_table);

    -- All should have same transaction_id
    SELECT COUNT(*) INTO l_records_in_txn
    FROM app_audit.changelog
    WHERE table_name = l_test_table
      AND transaction_id = l_txn_id;

    PERFORM test.is(l_records_in_txn, 3, 'All 3 operations should share transaction_id');

    -- Cleanup
    DELETE FROM app_audit.changelog WHERE table_name = l_test_table;
    EXECUTE format('DROP TABLE data.%I CASCADE', l_test_table);
END;
$$;

-- Test: Changed_by captures database user
CREATE OR REPLACE FUNCTION test.test_audit_038_changed_by()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_audit_038_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_changed_by text;
    l_current_user text := current_user;
BEGIN
    PERFORM test.set_context('test_audit_038_changed_by');

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

    -- Insert row
    EXECUTE format('INSERT INTO data.%I (name) VALUES (''Test'')', l_test_table);

    -- Verify changed_by captures current user
    SELECT changed_by INTO l_changed_by
    FROM app_audit.changelog
    WHERE table_name = l_test_table
      AND operation = 'INSERT'
    ORDER BY id DESC LIMIT 1;

    PERFORM test.is(l_changed_by, l_current_user, 'changed_by should capture database user');

    -- Cleanup
    DELETE FROM app_audit.changelog WHERE table_name = l_test_table;
    EXECUTE format('DROP TABLE data.%I CASCADE', l_test_table);
END;
$$;

-- ============================================================================
-- RUN TESTS
-- ============================================================================

SELECT test.run_module('audit_03');
CALL test.print_run_summary();
