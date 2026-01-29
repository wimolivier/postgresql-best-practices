# Audit Logging Implementation

This document provides a complete implementation of the `app_audit` schema mentioned throughout the skill, including generic audit triggers, change data capture patterns, and audit table design.

## Table of Contents

1. [Audit Schema Setup](#audit-schema-setup)
2. [Audit Table Design](#audit-table-design)
3. [Generic Audit Trigger](#generic-audit-trigger)
4. [Applying Audit to Tables](#applying-audit-to-tables)
5. [Querying Audit Logs](#querying-audit-logs)
6. [Retention and Archival](#retention-and-archival)
7. [Performance Considerations](#performance-considerations)

## Audit Schema Setup

```sql
-- Create audit schema
CREATE SCHEMA IF NOT EXISTS app_audit;
COMMENT ON SCHEMA app_audit IS 'Audit logging for data changes';

-- Grant read-only to admin role
GRANT USAGE ON SCHEMA app_audit TO app_admin;
```

## Audit Table Design

### Main Changelog Table

```sql
CREATE TABLE app_audit.changelog (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    
    -- What changed
    schema_name     text NOT NULL,
    table_name      text NOT NULL,
    operation       text NOT NULL,  -- INSERT, UPDATE, DELETE
    
    -- Row identification
    row_id          text NOT NULL,  -- Primary key value(s) as text
    
    -- Change data
    old_values      jsonb,          -- Previous values (UPDATE, DELETE)
    new_values      jsonb,          -- New values (INSERT, UPDATE)
    changed_columns text[],         -- Columns that changed (UPDATE only)
    
    -- Context
    changed_at      timestamptz NOT NULL DEFAULT now(),
    changed_by      text NOT NULL DEFAULT current_user,
    
    -- Application context (from session variables)
    app_user_id     uuid,
    app_tenant_id   uuid,
    app_request_id  text,
    app_ip_address  inet,
    
    -- Transaction info
    transaction_id  bigint NOT NULL DEFAULT txid_current(),
    statement_id    bigint NOT NULL DEFAULT pg_current_snapshot()::text::bigint
);

-- Indexes for common queries
CREATE INDEX idx_changelog_table ON app_audit.changelog(schema_name, table_name);
CREATE INDEX idx_changelog_row ON app_audit.changelog(table_name, row_id);
CREATE INDEX idx_changelog_time ON app_audit.changelog(changed_at);
CREATE INDEX idx_changelog_user ON app_audit.changelog(app_user_id) WHERE app_user_id IS NOT NULL;
CREATE INDEX idx_changelog_tenant ON app_audit.changelog(app_tenant_id) WHERE app_tenant_id IS NOT NULL;
CREATE INDEX idx_changelog_txn ON app_audit.changelog(transaction_id);

-- Partition by time for large-scale deployments
-- See "Retention and Archival" section

COMMENT ON TABLE app_audit.changelog IS 'Tracks all data changes for auditing';
```

### Sensitive Data Exclusion Table

```sql
-- Track which columns should be excluded from audit (e.g., passwords)
CREATE TABLE app_audit.excluded_columns (
    schema_name     text NOT NULL,
    table_name      text NOT NULL,
    column_name     text NOT NULL,
    reason          text,
    excluded_at     timestamptz NOT NULL DEFAULT now(),
    excluded_by     text NOT NULL DEFAULT current_user,
    PRIMARY KEY (schema_name, table_name, column_name)
);

-- Pre-populate with sensitive columns
INSERT INTO app_audit.excluded_columns (schema_name, table_name, column_name, reason) VALUES
    ('data', 'customers', 'password_hash', 'Sensitive authentication data'),
    ('data', 'users', 'password_hash', 'Sensitive authentication data'),
    ('data', 'api_keys', 'key_hash', 'Sensitive API credentials');
```

## Generic Audit Trigger

### Core Trigger Function

```sql
CREATE OR REPLACE FUNCTION app_audit.log_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER  -- Runs as function owner to write to audit schema
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
    l_app_ip        inet;
BEGIN
    -- Get application context from session variables
    l_app_user_id := NULLIF(current_setting('app.current_user_id', true), '')::uuid;
    l_app_tenant_id := NULLIF(current_setting('app.current_tenant_id', true), '')::uuid;
    l_app_request_id := NULLIF(current_setting('app.request_id', true), '');
    l_app_ip := NULLIF(current_setting('app.client_ip', true), '')::inet;
    
    -- Get excluded columns for this table
    SELECT array_agg(column_name)
    INTO l_excluded_cols
    FROM app_audit.excluded_columns
    WHERE schema_name = TG_TABLE_SCHEMA
      AND table_name = TG_TABLE_NAME;
    
    l_excluded_cols := COALESCE(l_excluded_cols, '{}');
    
    -- Build row ID (handle composite PKs)
    IF TG_OP = 'DELETE' THEN
        l_row_id := OLD::text;  -- Simple version; see below for PK extraction
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
                SELECT key FROM jsonb_each(l_old_values)
                EXCEPT
                SELECT key FROM jsonb_each(l_new_values)
                UNION
                SELECT key FROM jsonb_each(l_new_values)
                EXCEPT
                SELECT key FROM jsonb_each(l_old_values)
                UNION
                SELECT o.key
                FROM jsonb_each(l_old_values) o
                JOIN jsonb_each(l_new_values) n ON o.key = n.key
                WHERE o.value IS DISTINCT FROM n.value
            ) changes;
            
            -- Skip if nothing actually changed
            IF l_changed_cols IS NULL OR array_length(l_changed_cols, 1) = 0 THEN
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
        app_request_id,
        app_ip_address
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
        l_app_request_id,
        l_app_ip
    );
    
    -- Return appropriate value
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    ELSE
        RETURN NEW;
    END IF;
END;
$$;
```

### Enhanced Version with Primary Key Extraction

```sql
CREATE OR REPLACE FUNCTION app_audit.extract_pk_value(
    in_record anyelement,
    in_schema text,
    in_table text
)
RETURNS text
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    l_pk_cols text[];
    l_pk_vals text[];
    l_col text;
    l_record jsonb;
BEGIN
    -- Get primary key columns
    SELECT array_agg(a.attname ORDER BY array_position(i.indkey, a.attnum))
    INTO l_pk_cols
    FROM pg_index i
    JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
    WHERE i.indrelid = (in_schema || '.' || in_table)::regclass
      AND i.indisprimary;
    
    IF l_pk_cols IS NULL THEN
        -- No PK, use ctid
        RETURN 'ctid:' || in_record::text;
    END IF;
    
    -- Extract PK values
    l_record := to_jsonb(in_record);
    FOREACH l_col IN ARRAY l_pk_cols LOOP
        l_pk_vals := array_append(l_pk_vals, l_record->>l_col);
    END LOOP;
    
    RETURN array_to_string(l_pk_vals, ',');
END;
$$;
```

## Applying Audit to Tables

### Enable Audit on a Table

```sql
-- Function to enable auditing on a table
CREATE OR REPLACE FUNCTION app_audit.enable_audit(
    in_schema text,
    in_table text
)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_trigger_name text;
BEGIN
    l_trigger_name := in_table || '_audit_trg';
    
    EXECUTE format(
        'CREATE TRIGGER %I
         AFTER INSERT OR UPDATE OR DELETE ON %I.%I
         FOR EACH ROW
         EXECUTE FUNCTION app_audit.log_change()',
        l_trigger_name,
        in_schema,
        in_table
    );
    
    RAISE NOTICE 'Audit enabled on %.%', in_schema, in_table;
END;
$$;

-- Function to disable auditing
CREATE OR REPLACE FUNCTION app_audit.disable_audit(
    in_schema text,
    in_table text
)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_trigger_name text;
BEGIN
    l_trigger_name := in_table || '_audit_trg';
    
    EXECUTE format(
        'DROP TRIGGER IF EXISTS %I ON %I.%I',
        l_trigger_name,
        in_schema,
        in_table
    );
    
    RAISE NOTICE 'Audit disabled on %.%', in_schema, in_table;
END;
$$;

-- Enable audit on all tables in data schema
DO $$
DECLARE
    l_table record;
BEGIN
    FOR l_table IN
        SELECT tablename
        FROM pg_tables
        WHERE schemaname = 'data'
    LOOP
        PERFORM app_audit.enable_audit('data', l_table.tablename);
    END LOOP;
END;
$$;
```

### Excluding Sensitive Columns

```sql
-- Add column to exclusion list
CREATE PROCEDURE app_audit.exclude_column(
    in_schema text,
    in_table text,
    in_column text,
    in_reason text DEFAULT NULL
)
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO app_audit.excluded_columns (schema_name, table_name, column_name, reason)
    VALUES (in_schema, in_table, in_column, in_reason)
    ON CONFLICT (schema_name, table_name, column_name) DO UPDATE
    SET reason = EXCLUDED.reason,
        excluded_at = now(),
        excluded_by = current_user;
END;
$$;

-- Usage
CALL app_audit.exclude_column('data', 'customers', 'password_hash', 'Sensitive data');
CALL app_audit.exclude_column('data', 'customers', 'ssn', 'PII');
```

## Querying Audit Logs

### API Functions for Audit Access

```sql
-- Get history for a specific row
CREATE FUNCTION api.get_row_history(
    in_table_name text,
    in_row_id text,
    in_limit integer DEFAULT 50
)
RETURNS TABLE (
    id bigint,
    operation text,
    changed_at timestamptz,
    changed_by text,
    app_user_id uuid,
    old_values jsonb,
    new_values jsonb,
    changed_columns text[]
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = app_audit, data, private, pg_temp
AS $$
    SELECT 
        c.id,
        c.operation,
        c.changed_at,
        c.changed_by,
        c.app_user_id,
        c.old_values,
        c.new_values,
        c.changed_columns
    FROM app_audit.changelog c
    WHERE c.table_name = in_table_name
      AND c.row_id LIKE '%' || in_row_id || '%'
    ORDER BY c.changed_at DESC
    LIMIT in_limit;
$$;

-- Get row state at a point in time
CREATE FUNCTION api.get_row_at_time(
    in_table_name text,
    in_row_id text,
    in_as_of timestamptz
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = app_audit, data, private, pg_temp
AS $$
DECLARE
    l_result jsonb;
    l_change record;
BEGIN
    -- Start with current state (or NULL if deleted)
    EXECUTE format(
        'SELECT to_jsonb(t) FROM data.%I t WHERE t::text LIKE $1',
        in_table_name
    ) INTO l_result USING '%' || in_row_id || '%';
    
    -- Walk backwards through changes, undoing each one
    FOR l_change IN
        SELECT operation, old_values, new_values
        FROM app_audit.changelog
        WHERE table_name = in_table_name
          AND row_id LIKE '%' || in_row_id || '%'
          AND changed_at > in_as_of
        ORDER BY changed_at DESC
    LOOP
        CASE l_change.operation
            WHEN 'INSERT' THEN
                -- Row didn't exist, return NULL
                l_result := NULL;
                EXIT;
            WHEN 'UPDATE' THEN
                -- Restore old values
                l_result := l_result || l_change.old_values;
            WHEN 'DELETE' THEN
                -- Row existed with these values
                l_result := l_change.old_values;
        END CASE;
    END LOOP;
    
    RETURN l_result;
END;
$$;

-- Get all changes by a user
CREATE FUNCTION api.get_user_changes(
    in_user_id uuid,
    in_start_time timestamptz DEFAULT now() - interval '7 days',
    in_end_time timestamptz DEFAULT now(),
    in_limit integer DEFAULT 100
)
RETURNS TABLE (
    id bigint,
    table_name text,
    operation text,
    row_id text,
    changed_at timestamptz,
    changed_columns text[]
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = app_audit, data, private, pg_temp
AS $$
    SELECT 
        id,
        table_name,
        operation,
        row_id,
        changed_at,
        changed_columns
    FROM app_audit.changelog
    WHERE app_user_id = in_user_id
      AND changed_at BETWEEN in_start_time AND in_end_time
    ORDER BY changed_at DESC
    LIMIT in_limit;
$$;

-- Summary of changes by table
CREATE FUNCTION api.get_change_summary(
    in_start_time timestamptz DEFAULT now() - interval '1 day',
    in_end_time timestamptz DEFAULT now()
)
RETURNS TABLE (
    table_name text,
    inserts bigint,
    updates bigint,
    deletes bigint,
    total_changes bigint
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = app_audit, data, private, pg_temp
AS $$
    SELECT 
        table_name,
        COUNT(*) FILTER (WHERE operation = 'INSERT') AS inserts,
        COUNT(*) FILTER (WHERE operation = 'UPDATE') AS updates,
        COUNT(*) FILTER (WHERE operation = 'DELETE') AS deletes,
        COUNT(*) AS total_changes
    FROM app_audit.changelog
    WHERE changed_at BETWEEN in_start_time AND in_end_time
    GROUP BY table_name
    ORDER BY total_changes DESC;
$$;
```

### Advanced Queries

```sql
-- Find who changed a specific field
SELECT 
    c.changed_at,
    c.app_user_id,
    c.old_values->>'status' AS old_status,
    c.new_values->>'status' AS new_status
FROM app_audit.changelog c
WHERE c.table_name = 'orders'
  AND 'status' = ANY(c.changed_columns)
ORDER BY c.changed_at DESC;

-- Find all changes in a transaction
SELECT *
FROM app_audit.changelog
WHERE transaction_id = 12345678
ORDER BY id;

-- Find suspicious activity (many changes in short time)
SELECT 
    app_user_id,
    COUNT(*) AS changes,
    MIN(changed_at) AS first_change,
    MAX(changed_at) AS last_change
FROM app_audit.changelog
WHERE changed_at > now() - interval '1 hour'
GROUP BY app_user_id
HAVING COUNT(*) > 100
ORDER BY changes DESC;
```

## Retention and Archival

### Partitioned Audit Table

```sql
-- Create partitioned version
CREATE TABLE app_audit.changelog_partitioned (
    id              bigint GENERATED ALWAYS AS IDENTITY,
    schema_name     text NOT NULL,
    table_name      text NOT NULL,
    operation       text NOT NULL,
    row_id          text NOT NULL,
    old_values      jsonb,
    new_values      jsonb,
    changed_columns text[],
    changed_at      timestamptz NOT NULL DEFAULT now(),
    changed_by      text NOT NULL DEFAULT current_user,
    app_user_id     uuid,
    app_tenant_id   uuid,
    app_request_id  text,
    app_ip_address  inet,
    transaction_id  bigint NOT NULL DEFAULT txid_current(),
    PRIMARY KEY (id, changed_at)
) PARTITION BY RANGE (changed_at);

-- Create monthly partitions
CREATE TABLE app_audit.changelog_2024_01 
    PARTITION OF app_audit.changelog_partitioned
    FOR VALUES FROM ('2024-01-01') TO ('2024-02-01');

CREATE TABLE app_audit.changelog_2024_02 
    PARTITION OF app_audit.changelog_partitioned
    FOR VALUES FROM ('2024-02-01') TO ('2024-03-01');
-- Continue for each month...

-- Default partition for future data
CREATE TABLE app_audit.changelog_default 
    PARTITION OF app_audit.changelog_partitioned
    DEFAULT;
```

### Automatic Partition Creation

```sql
CREATE OR REPLACE FUNCTION app_audit.create_next_partition()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_start_date date;
    l_end_date date;
    l_partition_name text;
BEGIN
    l_start_date := date_trunc('month', now() + interval '1 month');
    l_end_date := l_start_date + interval '1 month';
    l_partition_name := 'changelog_' || to_char(l_start_date, 'YYYY_MM');
    
    IF NOT EXISTS (
        SELECT 1 FROM pg_tables 
        WHERE schemaname = 'app_audit' AND tablename = l_partition_name
    ) THEN
        EXECUTE format(
            'CREATE TABLE app_audit.%I PARTITION OF app_audit.changelog_partitioned
             FOR VALUES FROM (%L) TO (%L)',
            l_partition_name, l_start_date, l_end_date
        );
        
        -- Create indexes on new partition
        EXECUTE format(
            'CREATE INDEX idx_%s_table ON app_audit.%I(table_name)',
            l_partition_name, l_partition_name
        );
        
        RAISE NOTICE 'Created partition: %', l_partition_name;
    END IF;
END;
$$;

-- Schedule with pg_cron
-- SELECT cron.schedule('create-audit-partition', '0 0 25 * *', 
--     'SELECT app_audit.create_next_partition()');
```

### Archival and Cleanup

```sql
-- Archive old partitions to separate tablespace or external storage
CREATE OR REPLACE FUNCTION app_audit.archive_old_partitions(
    in_months_to_keep integer DEFAULT 12
)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_partition record;
    l_cutoff_date date;
BEGIN
    l_cutoff_date := date_trunc('month', now() - (in_months_to_keep || ' months')::interval);
    
    FOR l_partition IN
        SELECT tablename
        FROM pg_tables
        WHERE schemaname = 'app_audit'
          AND tablename LIKE 'changelog_20%'
          AND to_date(substring(tablename from 11 for 7), 'YYYY_MM') < l_cutoff_date
    LOOP
        -- Option 1: Drop old partitions
        -- EXECUTE format('DROP TABLE app_audit.%I', l_partition.tablename);
        
        -- Option 2: Detach and archive
        EXECUTE format(
            'ALTER TABLE app_audit.changelog_partitioned DETACH PARTITION app_audit.%I',
            l_partition.tablename
        );
        
        -- Move to archive schema
        EXECUTE format(
            'ALTER TABLE app_audit.%I SET SCHEMA app_audit_archive',
            l_partition.tablename
        );
        
        RAISE NOTICE 'Archived partition: %', l_partition.tablename;
    END LOOP;
END;
$$;

-- Simple cleanup for non-partitioned table
CREATE OR REPLACE FUNCTION app_audit.cleanup_old_logs(
    in_days_to_keep integer DEFAULT 365
)
RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
    l_deleted bigint;
BEGIN
    DELETE FROM app_audit.changelog
    WHERE changed_at < now() - (in_days_to_keep || ' days')::interval;
    
    GET DIAGNOSTICS l_deleted = ROW_COUNT;
    
    RAISE NOTICE 'Deleted % old audit records', l_deleted;
    RETURN l_deleted;
END;
$$;
```

## Performance Considerations

### Async Audit Logging (High-Volume Systems)

```sql
-- Queue table for async processing
CREATE UNLOGGED TABLE app_audit.changelog_queue (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    schema_name     text NOT NULL,
    table_name      text NOT NULL,
    operation       text NOT NULL,
    row_id          text NOT NULL,
    old_values      jsonb,
    new_values      jsonb,
    changed_columns text[],
    changed_at      timestamptz NOT NULL DEFAULT now(),
    changed_by      text NOT NULL DEFAULT current_user,
    app_user_id     uuid,
    app_tenant_id   uuid,
    app_request_id  text,
    app_ip_address  inet,
    transaction_id  bigint NOT NULL DEFAULT txid_current()
);

-- Async trigger writes to queue instead
CREATE OR REPLACE FUNCTION app_audit.log_change_async()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = app_audit, pg_temp
AS $$
BEGIN
    -- Same logic as log_change, but INSERT INTO changelog_queue
    -- ...
    RETURN COALESCE(NEW, OLD);
END;
$$;

-- Background worker moves from queue to main table
CREATE OR REPLACE FUNCTION app_audit.process_queue()
RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE
    l_processed integer;
BEGIN
    WITH moved AS (
        DELETE FROM app_audit.changelog_queue
        WHERE id IN (
            SELECT id FROM app_audit.changelog_queue
            ORDER BY id
            LIMIT 1000
            FOR UPDATE SKIP LOCKED
        )
        RETURNING *
    )
    INSERT INTO app_audit.changelog
    SELECT 
        schema_name, table_name, operation, row_id,
        old_values, new_values, changed_columns,
        changed_at, changed_by, app_user_id, app_tenant_id,
        app_request_id, app_ip_address, transaction_id,
        nextval('app_audit.changelog_id_seq')
    FROM moved;
    
    GET DIAGNOSTICS l_processed = ROW_COUNT;
    RETURN l_processed;
END;
$$;
```

### Conditional Auditing

```sql
-- Only audit if significant change
CREATE OR REPLACE FUNCTION app_audit.log_change_conditional()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = app_audit, pg_temp
AS $$
BEGIN
    -- Skip audit for certain conditions
    IF TG_OP = 'UPDATE' THEN
        -- Skip if only updated_at changed
        IF (to_jsonb(OLD) - 'updated_at') = (to_jsonb(NEW) - 'updated_at') THEN
            RETURN NEW;
        END IF;
    END IF;
    
    -- Continue with normal audit logging
    -- ...
    
    RETURN COALESCE(NEW, OLD);
END;
$$;
```

### Index Recommendations

```sql
-- Essential indexes
CREATE INDEX idx_changelog_table_time ON app_audit.changelog(table_name, changed_at DESC);
CREATE INDEX idx_changelog_row_time ON app_audit.changelog(table_name, row_id, changed_at DESC);

-- For user activity queries
CREATE INDEX idx_changelog_user_time ON app_audit.changelog(app_user_id, changed_at DESC)
    WHERE app_user_id IS NOT NULL;

-- For tenant isolation
CREATE INDEX idx_changelog_tenant_time ON app_audit.changelog(app_tenant_id, changed_at DESC)
    WHERE app_tenant_id IS NOT NULL;

-- BRIN index for time-ordered data (very efficient for append-only)
CREATE INDEX idx_changelog_time_brin ON app_audit.changelog USING brin(changed_at);
```
