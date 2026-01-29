-- ============================================================================
-- MIGRATION SYSTEM TESTS - REPEATABLE MIGRATIONS
-- ============================================================================
-- Tests for repeatable migration execution and change detection.
-- ============================================================================

-- ============================================================================
-- TEST FUNCTIONS
-- ============================================================================

-- Test: Repeatable migration executes
CREATE OR REPLACE FUNCTION test.test_migration_040_repeatable_execute()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_filename text := 'TEST_040_R__test_' || to_char(clock_timestamp(), 'HH24MISS') || '.sql';
BEGIN
    PERFORM test.set_context('test_migration_040_repeatable_execute');

    -- Acquire lock
    PERFORM app_migration.acquire_lock();

    CALL app_migration.run_repeatable(
        in_filename := l_filename,
        in_description := 'Test repeatable migration',
        in_sql := 'SELECT 1'
    );

    -- Should be recorded
    PERFORM test.isnt_empty(
        format('SELECT 1 FROM app_migration.changelog WHERE filename = %L AND type = ''repeatable''', l_filename),
        'repeatable migration should be recorded'
    );

    -- Clean up
    PERFORM app_migration.release_lock();
    DELETE FROM app_migration.changelog WHERE filename = l_filename;
END;
$$;

-- Test: Repeatable migration skipped if unchanged
CREATE OR REPLACE FUNCTION test.test_migration_041_repeatable_skip_unchanged()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_filename text := 'TEST_041_R__test_' || to_char(clock_timestamp(), 'HH24MISS') || '.sql';
    l_sql text := 'SELECT 1';
    l_count_before integer;
    l_count_after integer;
BEGIN
    PERFORM test.set_context('test_migration_041_repeatable_skip_unchanged');

    -- Acquire lock
    PERFORM app_migration.acquire_lock();

    -- Run first time
    CALL app_migration.run_repeatable(
        in_filename := l_filename,
        in_description := 'Test unchanged',
        in_sql := l_sql
    );

    SELECT count(*) INTO l_count_before
    FROM app_migration.changelog WHERE filename = l_filename;

    -- Run second time with same content
    CALL app_migration.run_repeatable(
        in_filename := l_filename,
        in_description := 'Test unchanged',
        in_sql := l_sql
    );

    SELECT count(*) INTO l_count_after
    FROM app_migration.changelog WHERE filename = l_filename;

    PERFORM test.is(l_count_after, l_count_before, 'unchanged repeatable should not add new entry');

    -- Clean up
    PERFORM app_migration.release_lock();
    DELETE FROM app_migration.changelog WHERE filename = l_filename;
END;
$$;

-- Test: Repeatable migration runs when changed
CREATE OR REPLACE FUNCTION test.test_migration_042_repeatable_runs_on_change()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_filename text := 'TEST_042_R__test_' || to_char(clock_timestamp(), 'HH24MISS') || '.sql';
    l_count_before integer;
    l_count_after integer;
BEGIN
    PERFORM test.set_context('test_migration_042_repeatable_runs_on_change');

    -- Acquire lock
    PERFORM app_migration.acquire_lock();

    -- Run first time
    CALL app_migration.run_repeatable(
        in_filename := l_filename,
        in_description := 'Version 1',
        in_sql := 'SELECT 1'
    );

    SELECT count(*) INTO l_count_before
    FROM app_migration.changelog WHERE filename = l_filename;

    -- Run with changed content
    CALL app_migration.run_repeatable(
        in_filename := l_filename,
        in_description := 'Version 2',
        in_sql := 'SELECT 2'  -- Changed
    );

    SELECT count(*) INTO l_count_after
    FROM app_migration.changelog WHERE filename = l_filename;

    PERFORM test.is(l_count_after, l_count_before + 1, 'changed repeatable should add new entry');

    -- Clean up
    PERFORM app_migration.release_lock();
    DELETE FROM app_migration.changelog WHERE filename = l_filename;
END;
$$;

-- Test: get_repeatable_checksum returns stored checksum
CREATE OR REPLACE FUNCTION test.test_migration_043_get_repeatable_checksum()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_filename text := 'TEST_043_R__test_' || to_char(clock_timestamp(), 'HH24MISS') || '.sql';
    l_sql text := 'SELECT 123';
    l_stored_checksum text;
    l_expected_checksum text;
BEGIN
    PERFORM test.set_context('test_migration_043_get_repeatable_checksum');

    -- Acquire lock
    PERFORM app_migration.acquire_lock();

    CALL app_migration.run_repeatable(
        in_filename := l_filename,
        in_description := 'Test checksum retrieval',
        in_sql := l_sql
    );

    -- Get stored checksum
    l_stored_checksum := app_migration.get_repeatable_checksum(l_filename);

    -- Calculate expected checksum
    l_expected_checksum := app_migration.calculate_checksum(l_sql);

    PERFORM test.is(l_stored_checksum, l_expected_checksum, 'get_repeatable_checksum should return correct checksum');

    -- Clean up
    PERFORM app_migration.release_lock();
    DELETE FROM app_migration.changelog WHERE filename = l_filename;
END;
$$;

-- Test: repeatable_needs_run returns true for new migration
CREATE OR REPLACE FUNCTION test.test_migration_044_repeatable_needs_run_new()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_filename text := 'TEST_044_R__never_run_' || to_char(clock_timestamp(), 'HH24MISS') || '.sql';
    l_needs_run boolean;
BEGIN
    PERFORM test.set_context('test_migration_044_repeatable_needs_run_new');

    -- Check for migration that was never run
    l_needs_run := app_migration.repeatable_needs_run(l_filename, 'SELECT 1');

    PERFORM test.ok(l_needs_run, 'repeatable_needs_run should return true for new migration');
END;
$$;

-- Test: repeatable_needs_run returns false for unchanged
CREATE OR REPLACE FUNCTION test.test_migration_045_repeatable_needs_run_unchanged()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_filename text := 'TEST_045_R__unchanged_' || to_char(clock_timestamp(), 'HH24MISS') || '.sql';
    l_sql text := 'SELECT 999';
    l_needs_run boolean;
BEGIN
    PERFORM test.set_context('test_migration_045_repeatable_needs_run_unchanged');

    -- Acquire lock and run
    PERFORM app_migration.acquire_lock();

    CALL app_migration.run_repeatable(
        in_filename := l_filename,
        in_description := 'Test needs_run unchanged',
        in_sql := l_sql
    );

    -- Check if needs to run with same content
    l_needs_run := app_migration.repeatable_needs_run(l_filename, l_sql);

    PERFORM test.not_ok(l_needs_run, 'repeatable_needs_run should return false when unchanged');

    -- Clean up
    PERFORM app_migration.release_lock();
    DELETE FROM app_migration.changelog WHERE filename = l_filename;
END;
$$;

-- Test: repeatable_needs_run returns true for changed content
CREATE OR REPLACE FUNCTION test.test_migration_046_repeatable_needs_run_changed()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_filename text := 'TEST_046_R__changed_' || to_char(clock_timestamp(), 'HH24MISS') || '.sql';
    l_needs_run boolean;
BEGIN
    PERFORM test.set_context('test_migration_046_repeatable_needs_run_changed');

    -- Acquire lock and run
    PERFORM app_migration.acquire_lock();

    CALL app_migration.run_repeatable(
        in_filename := l_filename,
        in_description := 'Original version',
        in_sql := 'SELECT 1'
    );

    -- Check if needs to run with different content
    l_needs_run := app_migration.repeatable_needs_run(l_filename, 'SELECT 2');

    PERFORM test.ok(l_needs_run, 'repeatable_needs_run should return true when changed');

    -- Clean up
    PERFORM app_migration.release_lock();
    DELETE FROM app_migration.changelog WHERE filename = l_filename;
END;
$$;

-- Test: Repeatable type is recorded correctly
CREATE OR REPLACE FUNCTION test.test_migration_047_repeatable_type()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_filename text := 'TEST_047_R__type_' || to_char(clock_timestamp(), 'HH24MISS') || '.sql';
    l_type text;
BEGIN
    PERFORM test.set_context('test_migration_047_repeatable_type');

    -- Acquire lock
    PERFORM app_migration.acquire_lock();

    CALL app_migration.run_repeatable(
        in_filename := l_filename,
        in_description := 'Test type recording',
        in_sql := 'SELECT 1'
    );

    SELECT type INTO l_type
    FROM app_migration.changelog
    WHERE filename = l_filename
    ORDER BY id DESC
    LIMIT 1;

    PERFORM test.is(l_type, 'repeatable', 'type should be recorded as repeatable');

    -- Clean up
    PERFORM app_migration.release_lock();
    DELETE FROM app_migration.changelog WHERE filename = l_filename;
END;
$$;

-- ============================================================================
-- RUN TESTS
-- ============================================================================

SELECT test.run_module('migration_04');
CALL test.print_run_summary();
