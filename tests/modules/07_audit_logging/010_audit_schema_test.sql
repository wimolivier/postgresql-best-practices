-- ============================================================================
-- AUDIT LOGGING TESTS - SCHEMA STRUCTURE
-- ============================================================================
-- Tests for app_audit schema structure and table design.
-- Reference: references/audit-logging.md
-- ============================================================================

-- ============================================================================
-- SETUP: Create minimal audit schema for testing
-- ============================================================================

DO $$
BEGIN
    -- Create audit schema if not exists
    CREATE SCHEMA IF NOT EXISTS app_audit;
    COMMENT ON SCHEMA app_audit IS 'Audit logging for data changes';
END;
$$;

-- Create changelog table
CREATE TABLE IF NOT EXISTS app_audit.changelog (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,

    -- What changed
    schema_name     text NOT NULL,
    table_name      text NOT NULL,
    operation       text NOT NULL,  -- INSERT, UPDATE, DELETE

    -- Row identification
    row_id          text NOT NULL,

    -- Change data
    old_values      jsonb,
    new_values      jsonb,
    changed_columns text[],

    -- Context
    changed_at      timestamptz NOT NULL DEFAULT now(),
    changed_by      text NOT NULL DEFAULT current_user,

    -- Application context
    app_user_id     uuid,
    app_tenant_id   uuid,
    app_request_id  text,
    app_ip_address  inet,

    -- Transaction info
    transaction_id  bigint NOT NULL DEFAULT txid_current()
);

-- Create indexes
CREATE INDEX IF NOT EXISTS changelog_table_idx ON app_audit.changelog(schema_name, table_name);
CREATE INDEX IF NOT EXISTS changelog_row_idx ON app_audit.changelog(table_name, row_id);
CREATE INDEX IF NOT EXISTS changelog_time_idx ON app_audit.changelog(changed_at);
CREATE INDEX IF NOT EXISTS changelog_user_idx ON app_audit.changelog(app_user_id) WHERE app_user_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS changelog_tenant_idx ON app_audit.changelog(app_tenant_id) WHERE app_tenant_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS changelog_txn_idx ON app_audit.changelog(transaction_id);

-- Create excluded columns table
CREATE TABLE IF NOT EXISTS app_audit.excluded_columns (
    schema_name     text NOT NULL,
    table_name      text NOT NULL,
    column_name     text NOT NULL,
    reason          text,
    excluded_at     timestamptz NOT NULL DEFAULT now(),
    excluded_by     text NOT NULL DEFAULT current_user,
    PRIMARY KEY (schema_name, table_name, column_name)
);

-- ============================================================================
-- TEST FUNCTIONS
-- ============================================================================

-- Test: app_audit schema exists
CREATE OR REPLACE FUNCTION test.test_audit_010_schema_exists()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM test.set_context('test_audit_010_schema_exists');

    PERFORM test.has_schema('app_audit', 'app_audit schema should exist');
END;
$$;

-- Test: changelog table exists with correct structure
CREATE OR REPLACE FUNCTION test.test_audit_011_changelog_table()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM test.set_context('test_audit_011_changelog_table');

    -- Table exists
    PERFORM test.has_table('app_audit', 'changelog', 'changelog table should exist');

    -- Core columns
    PERFORM test.has_column('app_audit', 'changelog', 'id', 'changelog.id column exists');
    PERFORM test.has_column('app_audit', 'changelog', 'schema_name', 'changelog.schema_name column exists');
    PERFORM test.has_column('app_audit', 'changelog', 'table_name', 'changelog.table_name column exists');
    PERFORM test.has_column('app_audit', 'changelog', 'operation', 'changelog.operation column exists');
    PERFORM test.has_column('app_audit', 'changelog', 'row_id', 'changelog.row_id column exists');

    -- Change data columns
    PERFORM test.has_column('app_audit', 'changelog', 'old_values', 'changelog.old_values column exists');
    PERFORM test.has_column('app_audit', 'changelog', 'new_values', 'changelog.new_values column exists');
    PERFORM test.has_column('app_audit', 'changelog', 'changed_columns', 'changelog.changed_columns column exists');

    -- Context columns
    PERFORM test.has_column('app_audit', 'changelog', 'changed_at', 'changelog.changed_at column exists');
    PERFORM test.has_column('app_audit', 'changelog', 'changed_by', 'changelog.changed_by column exists');

    -- Application context columns
    PERFORM test.has_column('app_audit', 'changelog', 'app_user_id', 'changelog.app_user_id column exists');
    PERFORM test.has_column('app_audit', 'changelog', 'app_tenant_id', 'changelog.app_tenant_id column exists');
    PERFORM test.has_column('app_audit', 'changelog', 'app_request_id', 'changelog.app_request_id column exists');

    -- Transaction tracking
    PERFORM test.has_column('app_audit', 'changelog', 'transaction_id', 'changelog.transaction_id column exists');
END;
$$;

-- Test: changelog column types
CREATE OR REPLACE FUNCTION test.test_audit_012_changelog_types()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM test.set_context('test_audit_012_changelog_types');

    PERFORM test.col_type_is('app_audit', 'changelog', 'id', 'bigint', 'id should be bigint');
    PERFORM test.col_type_is('app_audit', 'changelog', 'schema_name', 'text', 'schema_name should be text');
    PERFORM test.col_type_is('app_audit', 'changelog', 'table_name', 'text', 'table_name should be text');
    PERFORM test.col_type_is('app_audit', 'changelog', 'operation', 'text', 'operation should be text');
    PERFORM test.col_type_is('app_audit', 'changelog', 'old_values', 'jsonb', 'old_values should be jsonb');
    PERFORM test.col_type_is('app_audit', 'changelog', 'new_values', 'jsonb', 'new_values should be jsonb');
    PERFORM test.col_type_is('app_audit', 'changelog', 'changed_at', 'timestamp with time zone', 'changed_at should be timestamptz');
    PERFORM test.col_type_is('app_audit', 'changelog', 'app_user_id', 'uuid', 'app_user_id should be uuid');
END;
$$;

-- Test: excluded_columns table exists
CREATE OR REPLACE FUNCTION test.test_audit_013_excluded_columns_table()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM test.set_context('test_audit_013_excluded_columns_table');

    PERFORM test.has_table('app_audit', 'excluded_columns', 'excluded_columns table should exist');
    PERFORM test.has_column('app_audit', 'excluded_columns', 'schema_name', 'excluded_columns.schema_name exists');
    PERFORM test.has_column('app_audit', 'excluded_columns', 'table_name', 'excluded_columns.table_name exists');
    PERFORM test.has_column('app_audit', 'excluded_columns', 'column_name', 'excluded_columns.column_name exists');
    PERFORM test.has_column('app_audit', 'excluded_columns', 'reason', 'excluded_columns.reason exists');
END;
$$;

-- Test: changelog indexes exist
CREATE OR REPLACE FUNCTION test.test_audit_014_changelog_indexes()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM test.set_context('test_audit_014_changelog_indexes');

    PERFORM test.has_index('app_audit', 'changelog', 'changelog_table_idx', 'changelog_table_idx should exist');
    PERFORM test.has_index('app_audit', 'changelog', 'changelog_row_idx', 'changelog_row_idx should exist');
    PERFORM test.has_index('app_audit', 'changelog', 'changelog_time_idx', 'changelog_time_idx should exist');
    PERFORM test.has_index('app_audit', 'changelog', 'changelog_txn_idx', 'changelog_txn_idx should exist');
END;
$$;

-- Test: Can insert audit record manually
CREATE OR REPLACE FUNCTION test.test_audit_015_manual_insert()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_id bigint;
    l_txn_id bigint;
BEGIN
    PERFORM test.set_context('test_audit_015_manual_insert');

    l_txn_id := txid_current();

    -- Insert audit record
    INSERT INTO app_audit.changelog (
        schema_name, table_name, operation, row_id,
        old_values, new_values, changed_columns
    ) VALUES (
        'data', 'test_table', 'INSERT', 'test-id-123',
        NULL, '{"name": "Test"}'::jsonb, NULL
    ) RETURNING id INTO l_id;

    PERFORM test.is_not_null(l_id, 'Should return inserted id');
    PERFORM test.cmp_ok(l_id, '>', 0::bigint, 'ID should be positive');

    -- Verify defaults
    PERFORM test.isnt_empty(
        format('SELECT 1 FROM app_audit.changelog WHERE id = %L AND transaction_id = %L', l_id, l_txn_id),
        'Transaction ID should be captured'
    );

    -- Cleanup
    DELETE FROM app_audit.changelog WHERE id = l_id;
END;
$$;

-- Test: Audit record with application context
CREATE OR REPLACE FUNCTION test.test_audit_016_app_context()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_id bigint;
    l_user_id uuid := gen_random_uuid();
    l_tenant_id uuid := gen_random_uuid();
    l_request_id text := 'req-' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_record RECORD;
BEGIN
    PERFORM test.set_context('test_audit_016_app_context');

    -- Insert audit record with context
    INSERT INTO app_audit.changelog (
        schema_name, table_name, operation, row_id,
        new_values, app_user_id, app_tenant_id, app_request_id
    ) VALUES (
        'data', 'test_table', 'INSERT', 'test-id-456',
        '{"name": "Context Test"}'::jsonb, l_user_id, l_tenant_id, l_request_id
    ) RETURNING id INTO l_id;

    -- Verify context stored
    SELECT * INTO l_record FROM app_audit.changelog WHERE id = l_id;

    PERFORM test.is(l_record.app_user_id, l_user_id, 'app_user_id should be stored');
    PERFORM test.is(l_record.app_tenant_id, l_tenant_id, 'app_tenant_id should be stored');
    PERFORM test.is(l_record.app_request_id, l_request_id, 'app_request_id should be stored');

    -- Cleanup
    DELETE FROM app_audit.changelog WHERE id = l_id;
END;
$$;

-- Test: Exclude column registration
CREATE OR REPLACE FUNCTION test.test_audit_017_exclude_column()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_count integer;
BEGIN
    PERFORM test.set_context('test_audit_017_exclude_column');

    -- Add exclusion
    INSERT INTO app_audit.excluded_columns (schema_name, table_name, column_name, reason)
    VALUES ('data', 'test_customers', 'password_hash', 'Sensitive authentication data')
    ON CONFLICT DO NOTHING;

    -- Verify exclusion exists
    SELECT COUNT(*) INTO l_count
    FROM app_audit.excluded_columns
    WHERE schema_name = 'data'
      AND table_name = 'test_customers'
      AND column_name = 'password_hash';

    PERFORM test.is(l_count, 1, 'Exclusion should be registered');

    -- Cleanup
    DELETE FROM app_audit.excluded_columns
    WHERE schema_name = 'data' AND table_name = 'test_customers';
END;
$$;

-- Test: Query audit by time range
CREATE OR REPLACE FUNCTION test.test_audit_018_query_by_time()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_table_name text := 'test_time_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_start_time timestamptz;
    l_id1 bigint;
    l_id2 bigint;
    l_count integer;
BEGIN
    PERFORM test.set_context('test_audit_018_query_by_time');

    -- Use now() for start time since changed_at defaults to now() (transaction time)
    l_start_time := now();

    -- Insert test records with unique table name to avoid collision
    INSERT INTO app_audit.changelog (schema_name, table_name, operation, row_id, new_values)
    VALUES ('data', l_table_name, 'INSERT', 'time-1', '{"seq": 1}'::jsonb)
    RETURNING id INTO l_id1;

    INSERT INTO app_audit.changelog (schema_name, table_name, operation, row_id, new_values)
    VALUES ('data', l_table_name, 'INSERT', 'time-2', '{"seq": 2}'::jsonb)
    RETURNING id INTO l_id2;

    -- Query by time range
    SELECT COUNT(*) INTO l_count
    FROM app_audit.changelog
    WHERE table_name = l_table_name
      AND changed_at >= l_start_time;

    PERFORM test.is(l_count, 2, 'Should find 2 records in time range');

    -- Cleanup
    DELETE FROM app_audit.changelog WHERE id IN (l_id1, l_id2);
END;
$$;

-- Test: Query audit by table and row
CREATE OR REPLACE FUNCTION test.test_audit_019_query_by_row()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_row_id text := 'row-' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_count integer;
BEGIN
    PERFORM test.set_context('test_audit_019_query_by_row');

    -- Insert multiple operations for same row
    INSERT INTO app_audit.changelog (schema_name, table_name, operation, row_id, old_values, new_values)
    VALUES
        ('data', 'test_row', 'INSERT', l_row_id, NULL, '{"name": "Original"}'::jsonb),
        ('data', 'test_row', 'UPDATE', l_row_id, '{"name": "Original"}'::jsonb, '{"name": "Updated"}'::jsonb),
        ('data', 'test_row', 'DELETE', l_row_id, '{"name": "Updated"}'::jsonb, NULL);

    -- Query by row
    SELECT COUNT(*) INTO l_count
    FROM app_audit.changelog
    WHERE table_name = 'test_row'
      AND row_id = l_row_id;

    PERFORM test.is(l_count, 3, 'Should find 3 operations for the row');

    -- Cleanup
    DELETE FROM app_audit.changelog WHERE table_name = 'test_row' AND row_id = l_row_id;
END;
$$;

-- ============================================================================
-- RUN TESTS
-- ============================================================================

SELECT test.run_module('audit_01');
CALL test.print_run_summary();
