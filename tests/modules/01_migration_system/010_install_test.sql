-- ============================================================================
-- MIGRATION SYSTEM TESTS - INSTALLATION
-- ============================================================================
-- Tests for migration system installation and schema structure.
-- ============================================================================

-- Ensure migration system is installed
\i ../../../scripts/001_install_migration_system.sql
\i ../../../scripts/002_migration_runner_helpers.sql

-- ============================================================================
-- TEST FUNCTIONS
-- ============================================================================

-- Test: Migration schema exists
CREATE OR REPLACE FUNCTION test.test_migration_010_schema_exists()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM test.set_context('test_migration_010_schema_exists');

    PERFORM test.has_schema('app_migration', 'app_migration schema should exist');
END;
$$;

-- Test: Changelog table exists with correct structure
CREATE OR REPLACE FUNCTION test.test_migration_011_changelog_table()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM test.set_context('test_migration_011_changelog_table');

    -- Table exists
    PERFORM test.has_table('app_migration', 'changelog', 'changelog table should exist');

    -- Required columns
    PERFORM test.has_column('app_migration', 'changelog', 'id', 'changelog.id column exists');
    PERFORM test.has_column('app_migration', 'changelog', 'version', 'changelog.version column exists');
    PERFORM test.has_column('app_migration', 'changelog', 'description', 'changelog.description column exists');
    PERFORM test.has_column('app_migration', 'changelog', 'type', 'changelog.type column exists');
    PERFORM test.has_column('app_migration', 'changelog', 'filename', 'changelog.filename column exists');
    PERFORM test.has_column('app_migration', 'changelog', 'checksum', 'changelog.checksum column exists');
    PERFORM test.has_column('app_migration', 'changelog', 'execution_time_ms', 'changelog.execution_time_ms column exists');
    PERFORM test.has_column('app_migration', 'changelog', 'executed_at', 'changelog.executed_at column exists');
    PERFORM test.has_column('app_migration', 'changelog', 'executed_by', 'changelog.executed_by column exists');
    PERFORM test.has_column('app_migration', 'changelog', 'success', 'changelog.success column exists');
END;
$$;

-- Test: Lock config table exists
CREATE OR REPLACE FUNCTION test.test_migration_012_lock_config_table()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM test.set_context('test_migration_012_lock_config_table');

    -- Table exists
    PERFORM test.has_table('app_migration', 'lock_config', 'lock_config table should exist');

    -- Has default row
    PERFORM test.isnt_empty(
        'SELECT 1 FROM app_migration.lock_config WHERE id = 1',
        'lock_config should have default row'
    );
END;
$$;

-- Test: Rollback tables exist
CREATE OR REPLACE FUNCTION test.test_migration_013_rollback_tables()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM test.set_context('test_migration_013_rollback_tables');

    PERFORM test.has_table('app_migration', 'rollback_scripts', 'rollback_scripts table should exist');
    PERFORM test.has_table('app_migration', 'rollback_history', 'rollback_history table should exist');
END;
$$;

-- Test: Core functions exist
CREATE OR REPLACE FUNCTION test.test_migration_014_core_functions()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM test.set_context('test_migration_014_core_functions');

    -- Locking functions
    PERFORM test.has_function('app_migration', 'acquire_lock', 'acquire_lock function exists');
    PERFORM test.has_function('app_migration', 'acquire_lock_wait', 'acquire_lock_wait function exists');
    PERFORM test.has_function('app_migration', 'release_lock', 'release_lock function exists');
    PERFORM test.has_function('app_migration', 'is_locked', 'is_locked function exists');
    PERFORM test.has_function('app_migration', 'get_lock_holder', 'get_lock_holder function exists');

    -- Checksum functions
    PERFORM test.has_function('app_migration', 'calculate_checksum', 'calculate_checksum function exists');

    -- Version functions
    PERFORM test.has_function('app_migration', 'get_current_version', 'get_current_version function exists');
    PERFORM test.has_function('app_migration', 'is_version_applied', 'is_version_applied function exists');
    PERFORM test.has_function('app_migration', 'get_repeatable_checksum', 'get_repeatable_checksum function exists');
    PERFORM test.has_function('app_migration', 'repeatable_needs_run', 'repeatable_needs_run function exists');

    -- Info functions
    PERFORM test.has_function('app_migration', 'info', 'info function exists');
    PERFORM test.has_function('app_migration', 'get_history', 'get_history function exists');
    PERFORM test.has_function('app_migration', 'get_pending', 'get_pending function exists');
END;
$$;

-- Test: Core procedures exist
CREATE OR REPLACE FUNCTION test.test_migration_015_core_procedures()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM test.set_context('test_migration_015_core_procedures');

    -- Execution procedures
    PERFORM test.has_procedure('app_migration', 'execute', 'execute procedure exists');
    PERFORM test.has_procedure('app_migration', 'set_baseline', 'set_baseline procedure exists');

    -- Rollback procedures
    PERFORM test.has_procedure('app_migration', 'register_rollback', 'register_rollback procedure exists');
    PERFORM test.has_procedure('app_migration', 'rollback', 'rollback procedure exists');

    -- Maintenance procedures
    PERFORM test.has_procedure('app_migration', 'clear_failed', 'clear_failed procedure exists');
END;
$$;

-- Test: Helper functions exist (from 002 script)
CREATE OR REPLACE FUNCTION test.test_migration_016_helper_functions()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM test.set_context('test_migration_016_helper_functions');

    -- Batch procedures
    PERFORM test.has_procedure('app_migration', 'run_versioned_batch', 'run_versioned_batch procedure exists');
    PERFORM test.has_procedure('app_migration', 'run_repeatable_batch', 'run_repeatable_batch procedure exists');
    PERFORM test.has_procedure('app_migration', 'run_all', 'run_all procedure exists');

    -- Single migration helpers
    PERFORM test.has_procedure('app_migration', 'run_versioned', 'run_versioned procedure exists');
    PERFORM test.has_procedure('app_migration', 'run_repeatable', 'run_repeatable procedure exists');

    -- Status functions
    PERFORM test.has_function('app_migration', 'status', 'status function exists');
    PERFORM test.has_procedure('app_migration', 'print_status', 'print_status procedure exists');

    -- Rollback helpers
    PERFORM test.has_procedure('app_migration', 'rollback_to', 'rollback_to procedure exists');
    PERFORM test.has_function('app_migration', 'get_rollback_versions', 'get_rollback_versions function exists');
END;
$$;

-- Test: Indexes exist
CREATE OR REPLACE FUNCTION test.test_migration_017_indexes()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM test.set_context('test_migration_017_indexes');

    PERFORM test.has_index('app_migration', 'changelog', 'changelog_version_key',
        'changelog_version_key unique index exists');
    PERFORM test.has_index('app_migration', 'changelog', 'changelog_executed_idx',
        'changelog_executed_idx index exists');
    PERFORM test.has_index('app_migration', 'changelog', 'changelog_type_success_idx',
        'changelog_type_success_idx index exists');
END;
$$;

-- ============================================================================
-- RUN TESTS
-- ============================================================================

SELECT test.run_module('migration_01');
CALL test.print_run_summary();
