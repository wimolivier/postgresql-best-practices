-- ============================================================================
-- MIGRATION SYSTEM TESTS - BATCH EXECUTION
-- ============================================================================
-- Tests for batch migration execution functions.
-- ============================================================================

-- ============================================================================
-- TEST FUNCTIONS
-- ============================================================================

-- Test: run_versioned_batch executes multiple migrations
CREATE OR REPLACE FUNCTION test.test_migration_070_batch_versioned()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_prefix text := 'TEST_070_' || to_char(clock_timestamp(), 'HH24MISS');
    l_migrations jsonb;
    l_count integer;
BEGIN
    PERFORM test.set_context('test_migration_070_batch_versioned');

    -- Build batch of migrations
    l_migrations := jsonb_build_array(
        jsonb_build_object(
            'version', l_prefix || '_001',
            'description', 'Batch test 1',
            'filename', l_prefix || '_001.sql',
            'sql', 'SELECT 1'
        ),
        jsonb_build_object(
            'version', l_prefix || '_002',
            'description', 'Batch test 2',
            'filename', l_prefix || '_002.sql',
            'sql', 'SELECT 2'
        ),
        jsonb_build_object(
            'version', l_prefix || '_003',
            'description', 'Batch test 3',
            'filename', l_prefix || '_003.sql',
            'sql', 'SELECT 3'
        )
    );

    -- Acquire lock
    PERFORM app_migration.acquire_lock();

    -- Run batch
    CALL app_migration.run_versioned_batch(l_migrations);

    -- Count applied
    SELECT count(*) INTO l_count
    FROM app_migration.changelog
    WHERE version LIKE l_prefix || '_%' AND success = true;

    PERFORM test.is(l_count, 3, 'all 3 migrations should be applied');

    -- Clean up
    PERFORM app_migration.release_lock();
    DELETE FROM app_migration.changelog WHERE version LIKE l_prefix || '_%';
END;
$$;

-- Test: run_versioned_batch skips already applied
CREATE OR REPLACE FUNCTION test.test_migration_071_batch_skips_applied()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_prefix text := 'TEST_071_' || to_char(clock_timestamp(), 'HH24MISS');
    l_migrations jsonb;
    l_count integer;
BEGIN
    PERFORM test.set_context('test_migration_071_batch_skips_applied');

    -- Acquire lock
    PERFORM app_migration.acquire_lock();

    -- Run first migration individually
    CALL app_migration.run_versioned(
        in_version := l_prefix || '_001',
        in_description := 'Already applied',
        in_sql := 'SELECT 1'
    );

    -- Build batch including already applied
    l_migrations := jsonb_build_array(
        jsonb_build_object(
            'version', l_prefix || '_001',
            'description', 'Already applied',
            'filename', l_prefix || '_001.sql',
            'sql', 'SELECT 1'
        ),
        jsonb_build_object(
            'version', l_prefix || '_002',
            'description', 'New migration',
            'filename', l_prefix || '_002.sql',
            'sql', 'SELECT 2'
        )
    );

    -- Run batch
    CALL app_migration.run_versioned_batch(l_migrations);

    -- Count entries
    SELECT count(*) INTO l_count
    FROM app_migration.changelog
    WHERE version LIKE l_prefix || '_%' AND success = true;

    PERFORM test.is(l_count, 2, 'should have 2 entries (001 not duplicated)');

    -- Clean up
    PERFORM app_migration.release_lock();
    DELETE FROM app_migration.changelog WHERE version LIKE l_prefix || '_%';
END;
$$;

-- Test: run_versioned_batch requires lock
CREATE OR REPLACE FUNCTION test.test_migration_072_batch_requires_lock()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_migrations jsonb := '[]'::jsonb;
BEGIN
    PERFORM test.set_context('test_migration_072_batch_requires_lock');

    -- Ensure no lock held
    PERFORM app_migration.release_lock();

    -- Should fail without lock
    PERFORM test.throws_like(
        $$CALL app_migration.run_versioned_batch('[]'::jsonb)$$,
        'Migration lock not held',
        'batch should fail without lock'
    );
END;
$$;

-- Test: run_repeatable_batch executes multiple repeatables
CREATE OR REPLACE FUNCTION test.test_migration_073_batch_repeatable()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_prefix text := 'TEST_073_' || to_char(clock_timestamp(), 'HH24MISS');
    l_migrations jsonb;
    l_count integer;
BEGIN
    PERFORM test.set_context('test_migration_073_batch_repeatable');

    l_migrations := jsonb_build_array(
        jsonb_build_object(
            'filename', l_prefix || '_views.sql',
            'description', 'Test views',
            'sql', 'SELECT 1'
        ),
        jsonb_build_object(
            'filename', l_prefix || '_funcs.sql',
            'description', 'Test functions',
            'sql', 'SELECT 2'
        )
    );

    -- Acquire lock
    PERFORM app_migration.acquire_lock();

    CALL app_migration.run_repeatable_batch(l_migrations);

    SELECT count(*) INTO l_count
    FROM app_migration.changelog
    WHERE filename LIKE l_prefix || '_%' AND type = 'repeatable' AND success = true;

    PERFORM test.is(l_count, 2, 'both repeatable migrations should be applied');

    -- Clean up
    PERFORM app_migration.release_lock();
    DELETE FROM app_migration.changelog WHERE filename LIKE l_prefix || '_%';
END;
$$;

-- Test: run_repeatable_batch skips unchanged
CREATE OR REPLACE FUNCTION test.test_migration_074_batch_repeatable_skip()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_prefix text := 'TEST_074_' || to_char(clock_timestamp(), 'HH24MISS');
    l_migrations jsonb;
    l_count_before integer;
    l_count_after integer;
BEGIN
    PERFORM test.set_context('test_migration_074_batch_repeatable_skip');

    l_migrations := jsonb_build_array(
        jsonb_build_object(
            'filename', l_prefix || '_r1.sql',
            'description', 'Repeatable 1',
            'sql', 'SELECT 1'
        )
    );

    -- Acquire lock
    PERFORM app_migration.acquire_lock();

    -- First run
    CALL app_migration.run_repeatable_batch(l_migrations);

    SELECT count(*) INTO l_count_before
    FROM app_migration.changelog
    WHERE filename LIKE l_prefix || '_%';

    -- Second run with same content
    CALL app_migration.run_repeatable_batch(l_migrations);

    SELECT count(*) INTO l_count_after
    FROM app_migration.changelog
    WHERE filename LIKE l_prefix || '_%';

    PERFORM test.is(l_count_after, l_count_before, 'unchanged repeatable should not add entry');

    -- Clean up
    PERFORM app_migration.release_lock();
    DELETE FROM app_migration.changelog WHERE filename LIKE l_prefix || '_%';
END;
$$;

-- Test: run_all executes versioned then repeatable
CREATE OR REPLACE FUNCTION test.test_migration_075_run_all()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_prefix text := 'TEST_075_' || to_char(clock_timestamp(), 'HH24MISS');
    l_versioned jsonb;
    l_repeatable jsonb;
    l_versioned_count integer;
    l_repeatable_count integer;
BEGIN
    PERFORM test.set_context('test_migration_075_run_all');

    l_versioned := jsonb_build_array(
        jsonb_build_object(
            'version', l_prefix || '_001',
            'description', 'Versioned 1',
            'filename', l_prefix || '_001.sql',
            'sql', 'SELECT 1'
        )
    );

    l_repeatable := jsonb_build_array(
        jsonb_build_object(
            'filename', l_prefix || '_views.sql',
            'description', 'Views',
            'sql', 'SELECT 1'
        )
    );

    -- Run all (acquires and releases lock automatically)
    CALL app_migration.run_all(
        in_versioned_migrations := l_versioned,
        in_repeatable_migrations := l_repeatable
    );

    SELECT count(*) INTO l_versioned_count
    FROM app_migration.changelog
    WHERE version = l_prefix || '_001' AND type = 'versioned' AND success = true;

    SELECT count(*) INTO l_repeatable_count
    FROM app_migration.changelog
    WHERE filename = l_prefix || '_views.sql' AND type = 'repeatable' AND success = true;

    PERFORM test.is(l_versioned_count, 1, 'versioned migration should be applied');
    PERFORM test.is(l_repeatable_count, 1, 'repeatable migration should be applied');

    -- Clean up
    DELETE FROM app_migration.changelog WHERE version LIKE l_prefix || '_%' OR filename LIKE l_prefix || '_%';
END;
$$;

-- Test: run_all handles lock acquisition
CREATE OR REPLACE FUNCTION test.test_migration_076_run_all_lock_handling()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_is_locked boolean;
BEGIN
    PERFORM test.set_context('test_migration_076_run_all_lock_handling');

    -- Ensure clean state
    PERFORM app_migration.release_lock();

    -- Run all with acquire_lock=true, release_lock=true (defaults)
    CALL app_migration.run_all(
        in_versioned_migrations := '[]'::jsonb,
        in_repeatable_migrations := '[]'::jsonb
    );

    -- Lock should be released
    l_is_locked := app_migration.is_locked();
    PERFORM test.not_ok(l_is_locked, 'lock should be released after run_all');
END;
$$;

-- Test: run_all releases lock on error
CREATE OR REPLACE FUNCTION test.test_migration_077_run_all_error_cleanup()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_prefix text := 'TEST_077_' || to_char(clock_timestamp(), 'HH24MISS');
    l_bad_migrations jsonb;
    l_is_locked boolean;
BEGIN
    PERFORM test.set_context('test_migration_077_run_all_error_cleanup');

    -- Ensure clean state
    PERFORM app_migration.release_lock();

    l_bad_migrations := jsonb_build_array(
        jsonb_build_object(
            'version', l_prefix || '_001',
            'description', 'Bad migration',
            'filename', l_prefix || '_001.sql',
            'sql', 'SELECT * FROM nonexistent_xyz_table'
        )
    );

    -- Should fail
    BEGIN
        CALL app_migration.run_all(
            in_versioned_migrations := l_bad_migrations,
            in_repeatable_migrations := '[]'::jsonb
        );
    EXCEPTION WHEN OTHERS THEN
        NULL;  -- Expected
    END;

    -- Lock should still be released
    l_is_locked := app_migration.is_locked();
    PERFORM test.not_ok(l_is_locked, 'lock should be released even after error');

    -- Clean up
    DELETE FROM app_migration.changelog WHERE version LIKE l_prefix || '_%';
END;
$$;

-- Test: Batch executes in order
CREATE OR REPLACE FUNCTION test.test_migration_078_batch_order()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_prefix text := 'TEST_078_' || to_char(clock_timestamp(), 'HH24MISS');
    l_migrations jsonb;
    l_order text[];
BEGIN
    PERFORM test.set_context('test_migration_078_batch_order');

    -- Intentionally out of order
    l_migrations := jsonb_build_array(
        jsonb_build_object(
            'version', l_prefix || '_003',
            'description', 'Third',
            'filename', l_prefix || '_003.sql',
            'sql', 'SELECT 3'
        ),
        jsonb_build_object(
            'version', l_prefix || '_001',
            'description', 'First',
            'filename', l_prefix || '_001.sql',
            'sql', 'SELECT 1'
        ),
        jsonb_build_object(
            'version', l_prefix || '_002',
            'description', 'Second',
            'filename', l_prefix || '_002.sql',
            'sql', 'SELECT 2'
        )
    );

    -- Acquire lock
    PERFORM app_migration.acquire_lock();

    CALL app_migration.run_versioned_batch(l_migrations);

    -- Check execution order (by id which is sequential)
    SELECT array_agg(version ORDER BY id) INTO l_order
    FROM app_migration.changelog
    WHERE version LIKE l_prefix || '_%';

    -- Should be sorted by version, not input order
    PERFORM test.is(
        l_order[1], l_prefix || '_001',
        'migrations should execute in version order'
    );

    -- Clean up
    PERFORM app_migration.release_lock();
    DELETE FROM app_migration.changelog WHERE version LIKE l_prefix || '_%';
END;
$$;

-- ============================================================================
-- RUN TESTS
-- ============================================================================

SELECT test.run_module('migration_07');
CALL test.print_run_summary();
