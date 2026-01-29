-- ============================================================================
-- MIGRATION SYSTEM TESTS - CHECKSUM
-- ============================================================================
-- Tests for checksum calculation and validation.
-- ============================================================================

-- ============================================================================
-- TEST FUNCTIONS
-- ============================================================================

-- Test: calculate_checksum returns consistent value
CREATE OR REPLACE FUNCTION test.test_migration_050_checksum_consistent()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_sql text := 'SELECT * FROM users WHERE id = 1';
    l_checksum1 text;
    l_checksum2 text;
BEGIN
    PERFORM test.set_context('test_migration_050_checksum_consistent');

    l_checksum1 := app_migration.calculate_checksum(l_sql);
    l_checksum2 := app_migration.calculate_checksum(l_sql);

    PERFORM test.is(l_checksum1, l_checksum2, 'checksum should be consistent for same input');
END;
$$;

-- Test: calculate_checksum is MD5 format
CREATE OR REPLACE FUNCTION test.test_migration_051_checksum_format()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_checksum text;
BEGIN
    PERFORM test.set_context('test_migration_051_checksum_format');

    l_checksum := app_migration.calculate_checksum('SELECT 1');

    -- MD5 is 32 hex characters
    PERFORM test.is(length(l_checksum), 32, 'checksum should be 32 characters (MD5)');
    PERFORM test.matches(l_checksum, '^[0-9a-f]+$', 'checksum should be hex characters');
END;
$$;

-- Test: calculate_checksum normalizes whitespace
CREATE OR REPLACE FUNCTION test.test_migration_052_checksum_whitespace()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_sql1 text := 'SELECT 1';
    l_sql2 text := 'SELECT    1';  -- Extra spaces
    l_sql3 text := E'SELECT\n1';   -- Newline
    l_sql4 text := E'SELECT\t1';   -- Tab
    l_checksum1 text;
    l_checksum2 text;
    l_checksum3 text;
    l_checksum4 text;
BEGIN
    PERFORM test.set_context('test_migration_052_checksum_whitespace');

    l_checksum1 := app_migration.calculate_checksum(l_sql1);
    l_checksum2 := app_migration.calculate_checksum(l_sql2);
    l_checksum3 := app_migration.calculate_checksum(l_sql3);
    l_checksum4 := app_migration.calculate_checksum(l_sql4);

    -- All should be equal after normalization
    PERFORM test.is(l_checksum1, l_checksum2, 'extra spaces should be normalized');
    PERFORM test.is(l_checksum1, l_checksum3, 'newlines should be normalized');
    PERFORM test.is(l_checksum1, l_checksum4, 'tabs should be normalized');
END;
$$;

-- Test: calculate_checksum removes comments
CREATE OR REPLACE FUNCTION test.test_migration_053_checksum_comments()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_sql1 text := 'SELECT 1';
    l_sql2 text := 'SELECT 1 -- this is a comment';
    l_sql3 text := E'-- header comment\nSELECT 1';
    l_checksum1 text;
    l_checksum2 text;
    l_checksum3 text;
BEGIN
    PERFORM test.set_context('test_migration_053_checksum_comments');

    l_checksum1 := app_migration.calculate_checksum(l_sql1);
    l_checksum2 := app_migration.calculate_checksum(l_sql2);
    l_checksum3 := app_migration.calculate_checksum(l_sql3);

    -- All should be equal after comment removal
    PERFORM test.is(l_checksum1, l_checksum2, 'inline comments should be removed');
    PERFORM test.is(l_checksum1, l_checksum3, 'header comments should be removed');
END;
$$;

-- Test: calculate_checksum trims leading/trailing whitespace
CREATE OR REPLACE FUNCTION test.test_migration_054_checksum_trim()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_sql1 text := 'SELECT 1';
    l_sql2 text := '  SELECT 1  ';
    l_sql3 text := E'\n\nSELECT 1\n\n';
    l_checksum1 text;
    l_checksum2 text;
    l_checksum3 text;
BEGIN
    PERFORM test.set_context('test_migration_054_checksum_trim');

    l_checksum1 := app_migration.calculate_checksum(l_sql1);
    l_checksum2 := app_migration.calculate_checksum(l_sql2);
    l_checksum3 := app_migration.calculate_checksum(l_sql3);

    PERFORM test.is(l_checksum1, l_checksum2, 'leading/trailing spaces should be trimmed');
    PERFORM test.is(l_checksum1, l_checksum3, 'leading/trailing newlines should be trimmed');
END;
$$;

-- Test: Different content produces different checksum
CREATE OR REPLACE FUNCTION test.test_migration_055_checksum_different()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_checksum1 text;
    l_checksum2 text;
BEGIN
    PERFORM test.set_context('test_migration_055_checksum_different');

    l_checksum1 := app_migration.calculate_checksum('SELECT 1');
    l_checksum2 := app_migration.calculate_checksum('SELECT 2');

    PERFORM test.isnt(l_checksum1, l_checksum2, 'different content should produce different checksum');
END;
$$;

-- Test: Checksum mismatch detection for versioned migrations
CREATE OR REPLACE FUNCTION test.test_migration_056_checksum_mismatch_detection()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_version text := 'TEST_056_' || to_char(clock_timestamp(), 'HH24MISS');
BEGIN
    PERFORM test.set_context('test_migration_056_checksum_mismatch_detection');

    -- Acquire lock
    PERFORM app_migration.acquire_lock();

    -- Run original migration
    CALL app_migration.run_versioned(
        in_version := l_version,
        in_description := 'Original content',
        in_sql := 'SELECT 1'
    );

    -- Try to run with modified content (should fail with checksum mismatch)
    PERFORM test.throws_like(
        format($$
            CALL app_migration.execute(
                in_version := %L,
                in_description := 'Modified content',
                in_type := 'versioned',
                in_filename := 'test.sql',
                in_sql := 'SELECT 999',
                in_validate_checksum := true
            )
        $$, l_version),
        'Checksum mismatch',
        'should detect checksum mismatch for modified migration'
    );

    -- Clean up
    PERFORM app_migration.release_lock();
    DELETE FROM app_migration.changelog WHERE version = l_version;
END;
$$;

-- Test: validate_checksums function
CREATE OR REPLACE FUNCTION test.test_migration_057_validate_checksums()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_version text := 'TEST_057_' || to_char(clock_timestamp(), 'HH24MISS');
    l_result record;
BEGIN
    PERFORM test.set_context('test_migration_057_validate_checksums');

    -- Acquire lock
    PERFORM app_migration.acquire_lock();

    -- Run a migration
    CALL app_migration.run_versioned(
        in_version := l_version,
        in_description := 'Test validate checksums',
        in_sql := 'SELECT 42'
    );

    -- Validate with correct content
    SELECT * INTO l_result
    FROM app_migration.validate_checksums(
        jsonb_build_array(
            jsonb_build_object('version', l_version, 'content', 'SELECT 42')
        )
    );

    PERFORM test.is(l_result.status, 'OK', 'status should be OK for matching content');

    -- Validate with modified content
    SELECT * INTO l_result
    FROM app_migration.validate_checksums(
        jsonb_build_array(
            jsonb_build_object('version', l_version, 'content', 'SELECT 99')
        )
    );

    PERFORM test.is(l_result.status, 'MODIFIED', 'status should be MODIFIED for changed content');

    -- Validate pending version
    SELECT * INTO l_result
    FROM app_migration.validate_checksums(
        jsonb_build_array(
            jsonb_build_object('version', 'NEVER_APPLIED_VERSION', 'content', 'SELECT 1')
        )
    );

    PERFORM test.is(l_result.status, 'PENDING', 'status should be PENDING for new version');

    -- Clean up
    PERFORM app_migration.release_lock();
    DELETE FROM app_migration.changelog WHERE version = l_version;
END;
$$;

-- Test: Checksum validation can be disabled
CREATE OR REPLACE FUNCTION test.test_migration_058_checksum_validation_disabled()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_version text := 'TEST_058_' || to_char(clock_timestamp(), 'HH24MISS');
BEGIN
    PERFORM test.set_context('test_migration_058_checksum_validation_disabled');

    -- Acquire lock
    PERFORM app_migration.acquire_lock();

    -- Run original migration
    CALL app_migration.run_versioned(
        in_version := l_version,
        in_description := 'Original',
        in_sql := 'SELECT 1'
    );

    -- Run with modified content but validation disabled (should not throw)
    PERFORM test.lives_ok(
        format($$
            CALL app_migration.execute(
                in_version := %L,
                in_description := 'Modified',
                in_type := 'versioned',
                in_filename := 'test.sql',
                in_sql := 'SELECT 999',
                in_validate_checksum := false
            )
        $$, l_version),
        'should skip checksum validation when disabled'
    );

    -- Clean up
    PERFORM app_migration.release_lock();
    DELETE FROM app_migration.changelog WHERE version = l_version;
END;
$$;

-- ============================================================================
-- RUN TESTS
-- ============================================================================

SELECT test.run_module('migration_05');
CALL test.print_run_summary();
