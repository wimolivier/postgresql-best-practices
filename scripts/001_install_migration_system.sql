-- ============================================================================
-- POSTGRESQL MIGRATION SYSTEM - INSTALLATION SCRIPT
-- ============================================================================
-- Run this script once to install the migration system in your database.
-- Creates the app_migration schema with all required tables and functions.
-- ============================================================================

BEGIN;

-- ============================================================================
-- SCHEMA
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS app_migration;

COMMENT ON SCHEMA app_migration IS 'Database migration management system';

-- ============================================================================
-- TABLES
-- ============================================================================

-- Migration changelog: tracks all executed migrations
CREATE TABLE IF NOT EXISTS app_migration.changelog (
    id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    version             text NOT NULL,
    description         text NOT NULL,
    type                text NOT NULL DEFAULT 'versioned',
    filename            text NOT NULL,
    checksum            text NOT NULL,
    execution_time_ms   integer,
    executed_at         timestamptz NOT NULL DEFAULT now(),
    executed_by         text NOT NULL DEFAULT current_user,
    success             boolean NOT NULL DEFAULT true,
    
    CONSTRAINT changelog_type_check 
        CHECK (type IN ('versioned', 'repeatable', 'baseline'))
);

-- Unique version for successful versioned migrations
CREATE UNIQUE INDEX IF NOT EXISTS changelog_version_key 
    ON app_migration.changelog(version) 
    WHERE type = 'versioned' AND success = true;

-- Index for ordering and queries
CREATE INDEX IF NOT EXISTS idx_changelog_executed 
    ON app_migration.changelog(executed_at DESC);

CREATE INDEX IF NOT EXISTS idx_changelog_type_success 
    ON app_migration.changelog(type, success);

COMMENT ON TABLE app_migration.changelog IS 'Records all migration executions';
COMMENT ON COLUMN app_migration.changelog.version IS 'Migration version identifier (e.g., 001, 002, or timestamp)';
COMMENT ON COLUMN app_migration.changelog.type IS 'Migration type: versioned (run once), repeatable (run on change), baseline';
COMMENT ON COLUMN app_migration.changelog.checksum IS 'MD5 checksum of migration content for change detection';

-- Lock configuration: stores the advisory lock ID
CREATE TABLE IF NOT EXISTS app_migration.lock_config (
    id              integer PRIMARY KEY DEFAULT 1,
    lock_id         bigint NOT NULL DEFAULT 8675309,  -- Advisory lock identifier
    lock_timeout_s  integer NOT NULL DEFAULT 30,       -- Default lock timeout in seconds
    
    CONSTRAINT lock_config_single_row CHECK (id = 1)
);

-- Insert default lock config if not exists
INSERT INTO app_migration.lock_config (id, lock_id, lock_timeout_s)
VALUES (1, 8675309, 30)
ON CONFLICT (id) DO NOTHING;

COMMENT ON TABLE app_migration.lock_config IS 'Configuration for migration locking';

-- Rollback scripts: optional storage for rollback SQL
CREATE TABLE IF NOT EXISTS app_migration.rollback_scripts (
    version         text PRIMARY KEY,
    rollback_sql    text NOT NULL,
    created_at      timestamptz NOT NULL DEFAULT now(),
    created_by      text NOT NULL DEFAULT current_user
);

COMMENT ON TABLE app_migration.rollback_scripts IS 'Optional rollback scripts for versioned migrations';

-- Rollback history: tracks all rollback executions
CREATE TABLE IF NOT EXISTS app_migration.rollback_history (
    id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    changelog_id        bigint NOT NULL,
    version             text NOT NULL,
    rollback_sql        text,
    rolled_back_at      timestamptz NOT NULL DEFAULT now(),
    rolled_back_by      text NOT NULL DEFAULT current_user,
    execution_time_ms   integer,
    success             boolean NOT NULL DEFAULT true,
    error_message       text
);

CREATE INDEX IF NOT EXISTS idx_rollback_history_version 
    ON app_migration.rollback_history(version);

COMMENT ON TABLE app_migration.rollback_history IS 'History of all rollback executions';

-- ============================================================================
-- LOCKING FUNCTIONS
-- ============================================================================

-- Acquire migration lock (non-blocking)
CREATE OR REPLACE FUNCTION app_migration.acquire_lock()
RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
    v_lock_id bigint;
    v_acquired boolean;
BEGIN
    SELECT lock_id INTO v_lock_id FROM app_migration.lock_config WHERE id = 1;
    
    -- Try to acquire advisory lock (non-blocking)
    v_acquired := pg_try_advisory_lock(v_lock_id);
    
    IF v_acquired THEN
        RAISE NOTICE 'Migration lock acquired';
    ELSE
        RAISE NOTICE 'Migration lock not available - another migration is running';
    END IF;
    
    RETURN v_acquired;
END;
$$;

COMMENT ON FUNCTION app_migration.acquire_lock() IS 'Acquire migration lock (non-blocking, returns false if unavailable)';

-- Acquire migration lock with wait/timeout
CREATE OR REPLACE FUNCTION app_migration.acquire_lock_wait(
    in_timeout_seconds integer DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
    v_lock_id bigint;
    v_timeout integer;
    v_start_time timestamptz := clock_timestamp();
BEGIN
    SELECT lock_id, lock_timeout_s INTO v_lock_id, v_timeout 
    FROM app_migration.lock_config WHERE id = 1;
    
    -- Use provided timeout or default from config
    v_timeout := COALESCE(in_timeout_seconds, v_timeout);
    
    -- Try to acquire, with timeout
    LOOP
        IF pg_try_advisory_lock(v_lock_id) THEN
            RAISE NOTICE 'Migration lock acquired';
            RETURN true;
        END IF;
        
        IF clock_timestamp() > v_start_time + make_interval(secs := v_timeout) THEN
            RAISE EXCEPTION 'Timeout acquiring migration lock after % seconds', v_timeout
                USING HINT = 'Another migration may be running. Check app_migration.is_locked()';
        END IF;
        
        -- Wait 100ms before retry
        PERFORM pg_sleep(0.1);
    END LOOP;
END;
$$;

COMMENT ON FUNCTION app_migration.acquire_lock_wait(integer) IS 'Acquire migration lock with timeout (blocks until acquired or timeout)';

-- Release migration lock
CREATE OR REPLACE FUNCTION app_migration.release_lock()
RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
    v_lock_id bigint;
    v_released boolean;
BEGIN
    SELECT lock_id INTO v_lock_id FROM app_migration.lock_config WHERE id = 1;
    v_released := pg_advisory_unlock(v_lock_id);
    
    IF v_released THEN
        RAISE NOTICE 'Migration lock released';
    ELSE
        RAISE NOTICE 'Migration lock was not held';
    END IF;
    
    RETURN v_released;
END;
$$;

COMMENT ON FUNCTION app_migration.release_lock() IS 'Release migration lock';

-- Check if migration lock is currently held
CREATE OR REPLACE FUNCTION app_migration.is_locked()
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
    SELECT EXISTS (
        SELECT 1 FROM pg_locks l
        JOIN app_migration.lock_config c ON c.id = 1
        WHERE l.locktype = 'advisory' 
          AND l.objid = (c.lock_id & x'FFFFFFFF'::bigint)::integer
          AND l.classid = (c.lock_id >> 32)::integer
    );
$$;

COMMENT ON FUNCTION app_migration.is_locked() IS 'Check if migration lock is currently held by any session';

-- Get lock holder information
CREATE OR REPLACE FUNCTION app_migration.get_lock_holder()
RETURNS TABLE (
    pid integer,
    usename name,
    application_name text,
    client_addr inet,
    backend_start timestamptz,
    query text
)
LANGUAGE sql
STABLE
AS $$
    SELECT 
        a.pid,
        a.usename,
        a.application_name,
        a.client_addr,
        a.backend_start,
        a.query
    FROM pg_locks l
    JOIN app_migration.lock_config c ON c.id = 1
    JOIN pg_stat_activity a ON a.pid = l.pid
    WHERE l.locktype = 'advisory' 
      AND l.objid = (c.lock_id & x'FFFFFFFF'::bigint)::integer
      AND l.classid = (c.lock_id >> 32)::integer
      AND l.granted = true;
$$;

COMMENT ON FUNCTION app_migration.get_lock_holder() IS 'Get information about the session holding the migration lock';

-- ============================================================================
-- CHECKSUM FUNCTIONS
-- ============================================================================

-- Calculate checksum for migration content
CREATE OR REPLACE FUNCTION app_migration.calculate_checksum(in_content text)
RETURNS text
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
    SELECT md5(
        -- Normalize whitespace for consistent checksums
        regexp_replace(
            regexp_replace(
                regexp_replace(in_content, '--[^\n]*', '', 'g'),  -- Remove single-line comments
                '\s+', ' ', 'g'  -- Normalize whitespace
            ),
            '^\s+|\s+$', '', 'g'  -- Trim
        )
    );
$$;

COMMENT ON FUNCTION app_migration.calculate_checksum(text) IS 'Calculate normalized MD5 checksum for migration content';

-- ============================================================================
-- VERSION QUERY FUNCTIONS
-- ============================================================================

-- Get current schema version
CREATE OR REPLACE FUNCTION app_migration.get_current_version()
RETURNS text
LANGUAGE sql
STABLE
AS $$
    SELECT COALESCE(
        (SELECT version 
         FROM app_migration.changelog 
         WHERE type IN ('versioned', 'baseline') 
           AND success = true
         ORDER BY executed_at DESC, id DESC
         LIMIT 1),
        '0'
    );
$$;

COMMENT ON FUNCTION app_migration.get_current_version() IS 'Get the current schema version';

-- Check if a version has been applied
CREATE OR REPLACE FUNCTION app_migration.is_version_applied(in_version text)
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
    SELECT EXISTS (
        SELECT 1 FROM app_migration.changelog 
        WHERE version = in_version 
          AND type = 'versioned' 
          AND success = true
    );
$$;

COMMENT ON FUNCTION app_migration.is_version_applied(text) IS 'Check if a versioned migration has been applied';

-- Get stored checksum for a repeatable migration
CREATE OR REPLACE FUNCTION app_migration.get_repeatable_checksum(in_filename text)
RETURNS text
LANGUAGE sql
STABLE
AS $$
    SELECT checksum
    FROM app_migration.changelog
    WHERE filename = in_filename
      AND type = 'repeatable'
      AND success = true
    ORDER BY executed_at DESC
    LIMIT 1;
$$;

COMMENT ON FUNCTION app_migration.get_repeatable_checksum(text) IS 'Get the last checksum for a repeatable migration';

-- Check if repeatable migration needs to run
CREATE OR REPLACE FUNCTION app_migration.repeatable_needs_run(
    in_filename text,
    in_content text
)
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
    SELECT COALESCE(
        app_migration.get_repeatable_checksum(in_filename) 
            != app_migration.calculate_checksum(in_content),
        true  -- Never run before = needs to run
    );
$$;

COMMENT ON FUNCTION app_migration.repeatable_needs_run(text, text) IS 'Check if a repeatable migration needs to run based on checksum';

-- ============================================================================
-- MIGRATION INFO FUNCTIONS
-- ============================================================================

-- Get migration system status
CREATE OR REPLACE FUNCTION app_migration.info()
RETURNS TABLE (
    current_version text,
    total_migrations bigint,
    successful_migrations bigint,
    failed_migrations bigint,
    last_migration_at timestamptz,
    last_migration_version text,
    is_locked boolean,
    schema_exists boolean
)
LANGUAGE sql
STABLE
AS $$
    SELECT
        app_migration.get_current_version(),
        (SELECT count(*) FROM app_migration.changelog),
        (SELECT count(*) FROM app_migration.changelog WHERE success = true),
        (SELECT count(*) FROM app_migration.changelog WHERE success = false),
        (SELECT max(executed_at) FROM app_migration.changelog WHERE success = true),
        (SELECT version FROM app_migration.changelog WHERE success = true ORDER BY executed_at DESC LIMIT 1),
        app_migration.is_locked(),
        true;
$$;

COMMENT ON FUNCTION app_migration.info() IS 'Get migration system status summary';

-- Get migration history
CREATE OR REPLACE FUNCTION app_migration.get_history(
    in_limit integer DEFAULT 50,
    in_include_failed boolean DEFAULT false
)
RETURNS TABLE (
    id bigint,
    version text,
    description text,
    type text,
    filename text,
    checksum text,
    execution_time_ms integer,
    executed_at timestamptz,
    executed_by text,
    success boolean
)
LANGUAGE sql
STABLE
AS $$
    SELECT 
        c.id, c.version, c.description, c.type, c.filename, c.checksum,
        c.execution_time_ms, c.executed_at, c.executed_by, c.success
    FROM app_migration.changelog c
    WHERE in_include_failed OR c.success = true
    ORDER BY c.executed_at DESC, c.id DESC
    LIMIT in_limit;
$$;

COMMENT ON FUNCTION app_migration.get_history(integer, boolean) IS 'Get migration execution history';

-- Get pending versions (requires list of available versions)
CREATE OR REPLACE FUNCTION app_migration.get_pending(in_available_versions text[])
RETURNS TABLE (
    version text,
    is_new boolean
)
LANGUAGE sql
STABLE
AS $$
    SELECT 
        v.version,
        true as is_new
    FROM unnest(in_available_versions) AS v(version)
    WHERE NOT app_migration.is_version_applied(v.version)
    ORDER BY v.version;
$$;

COMMENT ON FUNCTION app_migration.get_pending(text[]) IS 'Get list of pending versions from provided available versions';

-- ============================================================================
-- MIGRATION EXECUTION
-- ============================================================================

-- Register a migration execution (internal use)
CREATE OR REPLACE FUNCTION app_migration.register_execution(
    in_version text,
    in_description text,
    in_type text,
    in_filename text,
    in_checksum text,
    in_execution_time_ms integer DEFAULT NULL,
    in_success boolean DEFAULT true
)
RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
    v_id bigint;
BEGIN
    INSERT INTO app_migration.changelog (
        version, description, type, filename, checksum, 
        execution_time_ms, success
    ) VALUES (
        in_version, in_description, in_type, in_filename,
        in_checksum, in_execution_time_ms, in_success
    )
    RETURNING id INTO v_id;
    
    RETURN v_id;
END;
$$;

-- Execute a single migration
CREATE OR REPLACE PROCEDURE app_migration.execute(
    in_version text,
    in_description text,
    in_type text,
    in_filename text,
    in_sql text,
    in_validate_checksum boolean DEFAULT true
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_checksum text;
    v_stored_checksum text;
    v_start_time timestamptz;
    v_execution_time_ms integer;
    v_log_id bigint;
BEGIN
    -- Calculate checksum
    v_checksum := app_migration.calculate_checksum(in_sql);
    
    -- Handle versioned migrations
    IF in_type = 'versioned' THEN
        IF app_migration.is_version_applied(in_version) THEN
            -- Verify checksum hasn't changed
            SELECT checksum INTO v_stored_checksum
            FROM app_migration.changelog
            WHERE version = in_version AND type = 'versioned' AND success = true
            ORDER BY executed_at DESC LIMIT 1;
            
            IF in_validate_checksum AND v_stored_checksum IS DISTINCT FROM v_checksum THEN
                RAISE EXCEPTION 'Checksum mismatch for version %: stored=%, current=%',
                    in_version, v_stored_checksum, v_checksum
                    USING HINT = 'Migration has been modified after execution. Use validate_checksum := false to skip this check.';
            END IF;
            
            RAISE NOTICE 'Migration % already applied, skipping', in_version;
            RETURN;
        END IF;
    END IF;
    
    -- Handle repeatable migrations
    IF in_type = 'repeatable' THEN
        IF NOT app_migration.repeatable_needs_run(in_filename, in_sql) THEN
            RAISE NOTICE 'Repeatable migration % unchanged, skipping', in_filename;
            RETURN;
        END IF;
    END IF;
    
    -- Execute migration
    RAISE NOTICE 'Executing % migration: % - %', in_type, in_version, in_description;
    v_start_time := clock_timestamp();
    
    BEGIN
        EXECUTE in_sql;
        
        v_execution_time_ms := extract(milliseconds from clock_timestamp() - v_start_time)::integer;
        
        -- Register successful execution
        v_log_id := app_migration.register_execution(
            in_version, in_description, in_type, in_filename,
            v_checksum, v_execution_time_ms, true
        );
        
        RAISE NOTICE 'Applied % migration: % (% ms)', in_type, in_version, v_execution_time_ms;
        
    EXCEPTION WHEN OTHERS THEN
        -- Register failed execution
        v_log_id := app_migration.register_execution(
            in_version, in_description, in_type, in_filename,
            v_checksum, NULL, false
        );
        
        RAISE EXCEPTION 'Migration % failed: %', in_version, SQLERRM
            USING DETAIL = 'Migration has been logged as failed in changelog';
    END;
END;
$$;

COMMENT ON PROCEDURE app_migration.execute(text, text, text, text, text, boolean) IS 'Execute a single migration with logging and checksum validation';

-- ============================================================================
-- BASELINE
-- ============================================================================

-- Set baseline version (marks existing database state)
CREATE OR REPLACE PROCEDURE app_migration.set_baseline(
    in_version text,
    in_description text DEFAULT 'Baseline'
)
LANGUAGE plpgsql
AS $$
BEGIN
    -- Check for existing migrations
    IF EXISTS (SELECT 1 FROM app_migration.changelog WHERE type = 'versioned' AND success = true) THEN
        RAISE EXCEPTION 'Cannot set baseline: versioned migrations already exist'
            USING HINT = 'Baseline should only be set on a fresh migration system or after clearing history';
    END IF;
    
    -- Insert baseline marker
    INSERT INTO app_migration.changelog (
        version, description, type, filename, checksum
    ) VALUES (
        in_version, 
        in_description, 
        'baseline', 
        'BASELINE',
        'BASELINE'
    );
    
    RAISE NOTICE 'Baseline set to version %', in_version;
END;
$$;

COMMENT ON PROCEDURE app_migration.set_baseline(text, text) IS 'Set baseline version for existing database';

-- ============================================================================
-- ROLLBACK
-- ============================================================================

-- Register a rollback script
CREATE OR REPLACE PROCEDURE app_migration.register_rollback(
    in_version text,
    in_rollback_sql text
)
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO app_migration.rollback_scripts (version, rollback_sql)
    VALUES (in_version, in_rollback_sql)
    ON CONFLICT (version) DO UPDATE 
    SET rollback_sql = EXCLUDED.rollback_sql,
        created_at = now(),
        created_by = current_user;
        
    RAISE NOTICE 'Rollback script registered for version %', in_version;
END;
$$;

COMMENT ON PROCEDURE app_migration.register_rollback(text, text) IS 'Register or update rollback script for a version';

-- Execute rollback for a version
CREATE OR REPLACE PROCEDURE app_migration.rollback(in_version text)
LANGUAGE plpgsql
AS $$
DECLARE
    v_rollback_sql text;
    v_changelog_id bigint;
    v_start_time timestamptz;
    v_execution_time_ms integer;
BEGIN
    -- Get changelog entry
    SELECT id INTO v_changelog_id
    FROM app_migration.changelog
    WHERE version = in_version AND type = 'versioned' AND success = true
    ORDER BY executed_at DESC
    LIMIT 1;
    
    IF v_changelog_id IS NULL THEN
        RAISE EXCEPTION 'Version % not found in changelog or already rolled back', in_version;
    END IF;
    
    -- Get rollback SQL
    SELECT rollback_sql INTO v_rollback_sql
    FROM app_migration.rollback_scripts
    WHERE version = in_version;
    
    IF v_rollback_sql IS NULL THEN
        RAISE EXCEPTION 'No rollback script registered for version %', in_version
            USING HINT = 'Register a rollback script with app_migration.register_rollback()';
    END IF;
    
    -- Execute rollback
    RAISE NOTICE 'Rolling back version %', in_version;
    v_start_time := clock_timestamp();
    
    BEGIN
        EXECUTE v_rollback_sql;
        
        v_execution_time_ms := extract(milliseconds from clock_timestamp() - v_start_time)::integer;
        
        -- Log successful rollback
        INSERT INTO app_migration.rollback_history (
            changelog_id, version, rollback_sql, execution_time_ms, success
        ) VALUES (
            v_changelog_id, in_version, v_rollback_sql, v_execution_time_ms, true
        );
        
        -- Mark original migration as rolled back
        UPDATE app_migration.changelog
        SET success = false
        WHERE id = v_changelog_id;
        
        RAISE NOTICE 'Rolled back version % (% ms)', in_version, v_execution_time_ms;
        
    EXCEPTION WHEN OTHERS THEN
        -- Log failed rollback
        INSERT INTO app_migration.rollback_history (
            changelog_id, version, rollback_sql, success, error_message
        ) VALUES (
            v_changelog_id, in_version, v_rollback_sql, false, SQLERRM
        );
        
        RAISE EXCEPTION 'Rollback of version % failed: %', in_version, SQLERRM;
    END;
END;
$$;

COMMENT ON PROCEDURE app_migration.rollback(text) IS 'Rollback a specific version using its registered rollback script';

-- ============================================================================
-- REPAIR / MAINTENANCE
-- ============================================================================

-- Clear failed migrations (allows re-running)
CREATE OR REPLACE PROCEDURE app_migration.clear_failed()
LANGUAGE plpgsql
AS $$
DECLARE
    v_count integer;
BEGIN
    DELETE FROM app_migration.changelog WHERE success = false;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    
    RAISE NOTICE 'Cleared % failed migration records', v_count;
END;
$$;

COMMENT ON PROCEDURE app_migration.clear_failed() IS 'Clear failed migration records to allow re-running';

-- Validate all checksums
CREATE OR REPLACE FUNCTION app_migration.validate_checksums(
    in_migrations jsonb  -- Array of {version, content} objects
)
RETURNS TABLE (
    version text,
    filename text,
    status text,
    stored_checksum text,
    current_checksum text
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_migration jsonb;
    v_version text;
    v_content text;
    v_stored text;
    v_current text;
BEGIN
    FOR v_migration IN SELECT * FROM jsonb_array_elements(in_migrations)
    LOOP
        v_version := v_migration->>'version';
        v_content := v_migration->>'content';
        v_current := app_migration.calculate_checksum(v_content);
        
        SELECT c.checksum, c.filename INTO v_stored, filename
        FROM app_migration.changelog c
        WHERE c.version = v_version AND c.type = 'versioned' AND c.success = true
        ORDER BY c.executed_at DESC LIMIT 1;
        
        IF v_stored IS NULL THEN
            status := 'PENDING';
        ELSIF v_stored = v_current THEN
            status := 'OK';
        ELSE
            status := 'MODIFIED';
        END IF;
        
        version := v_version;
        stored_checksum := v_stored;
        current_checksum := v_current;
        
        RETURN NEXT;
    END LOOP;
END;
$$;

COMMENT ON FUNCTION app_migration.validate_checksums(jsonb) IS 'Validate checksums for provided migrations';

-- ============================================================================
-- COMPLETION
-- ============================================================================

COMMIT;

-- Show installation summary
DO $$
BEGIN
    RAISE NOTICE '';
    RAISE NOTICE '============================================================';
    RAISE NOTICE 'Migration system installed successfully!';
    RAISE NOTICE '============================================================';
    RAISE NOTICE '';
    RAISE NOTICE 'Quick start:';
    RAISE NOTICE '  1. Acquire lock:    SELECT app_migration.acquire_lock();';
    RAISE NOTICE '  2. Run migration:   CALL app_migration.execute(...);';
    RAISE NOTICE '  3. Check status:    SELECT * FROM app_migration.info();';
    RAISE NOTICE '  4. Release lock:    SELECT app_migration.release_lock();';
    RAISE NOTICE '';
    RAISE NOTICE 'See app_migration schema for all available functions.';
    RAISE NOTICE '============================================================';
END;
$$;
