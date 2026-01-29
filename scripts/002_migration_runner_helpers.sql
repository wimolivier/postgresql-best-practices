-- ============================================================================
-- MIGRATION RUNNER HELPERS
-- ============================================================================
-- Additional helper functions for running migrations from various sources.
-- Run after 001_install_migration_system.sql
-- ============================================================================

BEGIN;

-- ============================================================================
-- BATCH MIGRATION EXECUTION
-- ============================================================================

-- Execute multiple versioned migrations in order
CREATE OR REPLACE PROCEDURE app_migration.run_versioned_batch(
    in_migrations jsonb  -- Array of {version, description, filename, sql} objects
)
LANGUAGE plpgsql
AS $$
DECLARE
    l_migration jsonb;
    l_count integer := 0;
    l_skipped integer := 0;
BEGIN
    -- Ensure lock is held
    IF NOT app_migration.is_locked() THEN
        RAISE EXCEPTION 'Migration lock not held. Call app_migration.acquire_lock() first.';
    END IF;

    RAISE NOTICE 'Processing % versioned migrations...', jsonb_array_length(in_migrations);

    -- Process migrations in order (assumes array is sorted)
    FOR l_migration IN SELECT * FROM jsonb_array_elements(in_migrations) ORDER BY value->>'version'
    LOOP
        IF app_migration.is_version_applied(l_migration->>'version') THEN
            l_skipped := l_skipped + 1;
        ELSE
            CALL app_migration.execute(
                in_version := l_migration->>'version',
                in_description := l_migration->>'description',
                in_type := 'versioned',
                in_filename := l_migration->>'filename',
                in_sql := l_migration->>'sql'
            );
            l_count := l_count + 1;
        END IF;
    END LOOP;

    RAISE NOTICE 'Batch complete: % applied, % skipped', l_count, l_skipped;
END;
$$;

COMMENT ON PROCEDURE app_migration.run_versioned_batch(jsonb) IS 'Execute multiple versioned migrations from JSON array';

-- Execute multiple repeatable migrations
CREATE OR REPLACE PROCEDURE app_migration.run_repeatable_batch(
    in_migrations jsonb  -- Array of {description, filename, sql} objects
)
LANGUAGE plpgsql
AS $$
DECLARE
    l_migration jsonb;
    l_count integer := 0;
    l_skipped integer := 0;
BEGIN
    -- Ensure lock is held
    IF NOT app_migration.is_locked() THEN
        RAISE EXCEPTION 'Migration lock not held. Call app_migration.acquire_lock() first.';
    END IF;

    RAISE NOTICE 'Processing % repeatable migrations...', jsonb_array_length(in_migrations);

    FOR l_migration IN SELECT * FROM jsonb_array_elements(in_migrations) ORDER BY value->>'filename'
    LOOP
        IF app_migration.repeatable_needs_run(l_migration->>'filename', l_migration->>'sql') THEN
            CALL app_migration.execute(
                in_version := l_migration->>'filename',  -- Use filename as version for repeatables
                in_description := l_migration->>'description',
                in_type := 'repeatable',
                in_filename := l_migration->>'filename',
                in_sql := l_migration->>'sql'
            );
            l_count := l_count + 1;
        ELSE
            l_skipped := l_skipped + 1;
        END IF;
    END LOOP;

    RAISE NOTICE 'Batch complete: % applied, % skipped (unchanged)', l_count, l_skipped;
END;
$$;

COMMENT ON PROCEDURE app_migration.run_repeatable_batch(jsonb) IS 'Execute multiple repeatable migrations from JSON array';

-- ============================================================================
-- FULL MIGRATION RUN
-- ============================================================================

-- Run all pending migrations (versioned first, then repeatable)
CREATE OR REPLACE PROCEDURE app_migration.run_all(
    in_versioned_migrations jsonb DEFAULT '[]'::jsonb,
    in_repeatable_migrations jsonb DEFAULT '[]'::jsonb,
    in_acquire_lock boolean DEFAULT true,
    in_release_lock boolean DEFAULT true
)
LANGUAGE plpgsql
AS $$
DECLARE
    l_lock_acquired boolean := false;
BEGIN
    -- Acquire lock if requested
    IF in_acquire_lock THEN
        l_lock_acquired := app_migration.acquire_lock();
        IF NOT l_lock_acquired THEN
            RAISE EXCEPTION 'Could not acquire migration lock';
        END IF;
    END IF;

    BEGIN
        -- Run versioned migrations first
        IF jsonb_array_length(in_versioned_migrations) > 0 THEN
            CALL app_migration.run_versioned_batch(in_versioned_migrations);
        END IF;

        -- Run repeatable migrations after versioned
        IF jsonb_array_length(in_repeatable_migrations) > 0 THEN
            CALL app_migration.run_repeatable_batch(in_repeatable_migrations);
        END IF;

        -- Release lock if requested
        IF in_release_lock AND l_lock_acquired THEN
            PERFORM app_migration.release_lock();
        END IF;

    EXCEPTION WHEN OTHERS THEN
        -- Release lock on error if we acquired it
        IF l_lock_acquired THEN
            PERFORM app_migration.release_lock();
        END IF;
        RAISE;
    END;
END;
$$;

COMMENT ON PROCEDURE app_migration.run_all(jsonb, jsonb, boolean, boolean) IS 'Run all pending versioned and repeatable migrations';

-- ============================================================================
-- SINGLE MIGRATION HELPERS
-- ============================================================================

-- Quick versioned migration execution
CREATE OR REPLACE PROCEDURE app_migration.run_versioned(
    in_version text,
    in_description text,
    in_sql text,
    in_filename text DEFAULT NULL,
    in_rollback_sql text DEFAULT NULL
)
LANGUAGE plpgsql
AS $$
BEGIN
    -- Use version as filename if not provided
    CALL app_migration.execute(
        in_version := in_version,
        in_description := in_description,
        in_type := 'versioned',
        in_filename := COALESCE(in_filename, 'V' || in_version || '__' || 
            regexp_replace(lower(in_description), '\s+', '_', 'g') || '.sql'),
        in_sql := in_sql
    );
    
    -- Register rollback if provided
    IF in_rollback_sql IS NOT NULL THEN
        CALL app_migration.register_rollback(in_version, in_rollback_sql);
    END IF;
END;
$$;

COMMENT ON PROCEDURE app_migration.run_versioned(text, text, text, text, text) IS 'Quick helper to run a single versioned migration';

-- Quick repeatable migration execution
CREATE OR REPLACE PROCEDURE app_migration.run_repeatable(
    in_filename text,
    in_description text,
    in_sql text
)
LANGUAGE plpgsql
AS $$
BEGIN
    CALL app_migration.execute(
        in_version := in_filename,
        in_description := in_description,
        in_type := 'repeatable',
        in_filename := in_filename,
        in_sql := in_sql
    );
END;
$$;

COMMENT ON PROCEDURE app_migration.run_repeatable(text, text, text) IS 'Quick helper to run a single repeatable migration';

-- ============================================================================
-- MIGRATION STATUS HELPERS
-- ============================================================================

-- Get detailed status of all migrations
CREATE OR REPLACE FUNCTION app_migration.status()
RETURNS TABLE (
    version text,
    description text,
    type text,
    state text,
    executed_at timestamptz,
    execution_time text,
    checksum text
)
LANGUAGE sql
STABLE
AS $$
    SELECT 
        c.version,
        c.description,
        c.type,
        CASE 
            WHEN c.success THEN 'SUCCESS'
            ELSE 'FAILED'
        END as state,
        c.executed_at,
        CASE 
            WHEN c.execution_time_ms IS NOT NULL 
            THEN c.execution_time_ms || 'ms'
            ELSE '-'
        END as execution_time,
        left(c.checksum, 8) || '...' as checksum
    FROM app_migration.changelog c
    ORDER BY c.executed_at DESC, c.id DESC;
$$;

COMMENT ON FUNCTION app_migration.status() IS 'Get formatted status of all migrations';

-- Print migration status summary
CREATE OR REPLACE PROCEDURE app_migration.print_status()
LANGUAGE plpgsql
AS $$
DECLARE
    r_info record;
    r_row record;
BEGIN
    SELECT * INTO r_info FROM app_migration.info();

    RAISE NOTICE '';
    RAISE NOTICE '=== Migration Status ===';
    RAISE NOTICE 'Current version: %', r_info.current_version;
    RAISE NOTICE 'Total migrations: % (% successful, % failed)',
        r_info.total_migrations, r_info.successful_migrations, r_info.failed_migrations;
    RAISE NOTICE 'Last migration: % at %', r_info.last_migration_version, r_info.last_migration_at;
    RAISE NOTICE 'Lock status: %', CASE WHEN r_info.is_locked THEN 'LOCKED' ELSE 'unlocked' END;
    RAISE NOTICE '';
    RAISE NOTICE '=== Recent Migrations ===';

    FOR r_row IN SELECT * FROM app_migration.status() LIMIT 10
    LOOP
        RAISE NOTICE '% | % | % | % | %',
            rpad(r_row.version, 10),
            rpad(r_row.type, 10),
            rpad(r_row.state, 7),
            rpad(COALESCE(r_row.execution_time, '-'), 8),
            left(r_row.description, 40);
    END LOOP;

    RAISE NOTICE '';
END;
$$;

COMMENT ON PROCEDURE app_migration.print_status() IS 'Print formatted migration status to notices';

-- ============================================================================
-- ROLLBACK HELPERS
-- ============================================================================

-- Rollback to a specific version (rolls back all versions after target)
CREATE OR REPLACE PROCEDURE app_migration.rollback_to(in_target_version text)
LANGUAGE plpgsql
AS $$
DECLARE
    l_version text;
    l_count integer := 0;
BEGIN
    -- Get versions to rollback in reverse order
    FOR l_version IN
        SELECT version
        FROM app_migration.changelog
        WHERE type = 'versioned'
          AND success = true
          AND version > in_target_version
        ORDER BY version DESC
    LOOP
        CALL app_migration.rollback(l_version);
        l_count := l_count + 1;
    END LOOP;

    IF l_count = 0 THEN
        RAISE NOTICE 'No migrations to rollback (already at or before version %)', in_target_version;
    ELSE
        RAISE NOTICE 'Rolled back % migrations to version %', l_count, in_target_version;
    END IF;
END;
$$;

COMMENT ON PROCEDURE app_migration.rollback_to(text) IS 'Rollback all migrations after the target version';

-- Get available rollback versions
CREATE OR REPLACE FUNCTION app_migration.get_rollback_versions()
RETURNS TABLE (
    version text,
    description text,
    executed_at timestamptz,
    has_rollback_script boolean
)
LANGUAGE sql
STABLE
AS $$
    SELECT 
        c.version,
        c.description,
        c.executed_at,
        EXISTS (SELECT 1 FROM app_migration.rollback_scripts r WHERE r.version = c.version) as has_rollback_script
    FROM app_migration.changelog c
    WHERE c.type = 'versioned' AND c.success = true
    ORDER BY c.version DESC;
$$;

COMMENT ON FUNCTION app_migration.get_rollback_versions() IS 'Get list of versions that can be rolled back';

COMMIT;

-- Show completion message
DO $$
BEGIN
    RAISE NOTICE '';
    RAISE NOTICE 'Migration runner helpers installed!';
    RAISE NOTICE '';
    RAISE NOTICE 'Quick commands:';
    RAISE NOTICE '  app_migration.run_versioned(version, description, sql)';
    RAISE NOTICE '  app_migration.run_repeatable(filename, description, sql)';
    RAISE NOTICE '  app_migration.print_status()';
    RAISE NOTICE '';
END;
$$;
