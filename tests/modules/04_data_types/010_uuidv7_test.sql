-- ============================================================================
-- DATA TYPES TESTS - UUIDv7
-- ============================================================================
-- Tests for UUIDv7 generation and properties.
-- ============================================================================

-- ============================================================================
-- TEST FUNCTIONS
-- ============================================================================

-- Test: uuidv7() function exists (PG17+)
CREATE OR REPLACE FUNCTION test.test_uuid_010_uuidv7_exists()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_has_uuidv7 boolean;
BEGIN
    PERFORM test.set_context('test_uuid_010_uuidv7_exists');

    SELECT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'uuidv7') INTO l_has_uuidv7;

    IF l_has_uuidv7 THEN
        PERFORM test.ok(true, 'uuidv7() function exists');
    ELSE
        PERFORM test.skip(1, 'uuidv7() not available (requires PG17+)');
    END IF;
END;
$$;

-- Test: uuidv7() generates valid UUID
CREATE OR REPLACE FUNCTION test.test_uuid_011_uuidv7_valid()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_uuid uuid;
    l_has_uuidv7 boolean;
BEGIN
    PERFORM test.set_context('test_uuid_011_uuidv7_valid');

    SELECT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'uuidv7') INTO l_has_uuidv7;

    IF l_has_uuidv7 THEN
        l_uuid := uuidv7();
        PERFORM test.is_not_null(l_uuid, 'uuidv7() should generate non-null UUID');
        PERFORM test.is(length(l_uuid::text), 36, 'UUID should be 36 characters with hyphens');
    ELSE
        PERFORM test.skip(2, 'uuidv7() not available');
    END IF;
END;
$$;

-- Test: uuidv7() has version 7 in correct position
CREATE OR REPLACE FUNCTION test.test_uuid_012_uuidv7_version()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_uuid uuid;
    l_version_char text;
    l_has_uuidv7 boolean;
BEGIN
    PERFORM test.set_context('test_uuid_012_uuidv7_version');

    SELECT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'uuidv7') INTO l_has_uuidv7;

    IF l_has_uuidv7 THEN
        l_uuid := uuidv7();
        -- UUID format: xxxxxxxx-xxxx-Vxxx-xxxx-xxxxxxxxxxxx (V is version)
        -- Position 15 (1-indexed in the string) is the version
        l_version_char := substring(l_uuid::text from 15 for 1);
        PERFORM test.is(l_version_char, '7', 'UUID version should be 7');
    ELSE
        PERFORM test.skip(1, 'uuidv7() not available');
    END IF;
END;
$$;

-- Test: uuidv7() has correct variant
CREATE OR REPLACE FUNCTION test.test_uuid_013_uuidv7_variant()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_uuid uuid;
    l_variant_char text;
    l_has_uuidv7 boolean;
BEGIN
    PERFORM test.set_context('test_uuid_013_uuidv7_variant');

    SELECT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'uuidv7') INTO l_has_uuidv7;

    IF l_has_uuidv7 THEN
        l_uuid := uuidv7();
        -- Variant bits are in position 20 (after third hyphen)
        -- Should be 8, 9, a, or b for RFC 4122 variant
        l_variant_char := substring(l_uuid::text from 20 for 1);
        PERFORM test.ok(
            l_variant_char IN ('8', '9', 'a', 'b'),
            'UUID variant should be RFC 4122 (8, 9, a, or b)'
        );
    ELSE
        PERFORM test.skip(1, 'uuidv7() not available');
    END IF;
END;
$$;

-- Test: uuidv7() is time-ordered (sortable)
CREATE OR REPLACE FUNCTION test.test_uuid_014_uuidv7_sortable()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_uuid1 uuid;
    l_uuid2 uuid;
    l_uuid3 uuid;
    l_has_uuidv7 boolean;
BEGIN
    PERFORM test.set_context('test_uuid_014_uuidv7_sortable');

    SELECT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'uuidv7') INTO l_has_uuidv7;

    IF l_has_uuidv7 THEN
        -- Generate UUIDs with small delays
        l_uuid1 := uuidv7();
        PERFORM pg_sleep(0.001);
        l_uuid2 := uuidv7();
        PERFORM pg_sleep(0.001);
        l_uuid3 := uuidv7();

        -- When sorted, they should maintain order
        PERFORM test.ok(l_uuid1 < l_uuid2, 'uuid1 should be less than uuid2');
        PERFORM test.ok(l_uuid2 < l_uuid3, 'uuid2 should be less than uuid3');
    ELSE
        PERFORM test.skip(2, 'uuidv7() not available');
    END IF;
END;
$$;

-- Test: uuidv7() as default for primary key
CREATE OR REPLACE FUNCTION test.test_uuid_015_uuidv7_pk_default()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_uuid_pk_' || to_char(clock_timestamp(), 'HH24MISS');
    l_has_uuidv7 boolean;
    l_id uuid;
BEGIN
    PERFORM test.set_context('test_uuid_015_uuidv7_pk_default');

    SELECT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'uuidv7') INTO l_has_uuidv7;

    IF l_has_uuidv7 THEN
        -- Create table with uuidv7() default
        EXECUTE format($tbl$
            CREATE TABLE test.%I (
                id uuid PRIMARY KEY DEFAULT uuidv7(),
                name text
            )
        $tbl$, l_test_table);

        -- Insert without providing id
        EXECUTE format('INSERT INTO test.%I (name) VALUES ($1) RETURNING id', l_test_table)
        INTO l_id
        USING 'Test';

        PERFORM test.is_not_null(l_id, 'id should be auto-generated');
        PERFORM test.ok(test.is_uuidv7(l_id), 'generated id should be UUIDv7 format');

        -- Clean up
        EXECUTE format('DROP TABLE test.%I', l_test_table);
    ELSE
        PERFORM test.skip(2, 'uuidv7() not available');
    END IF;
END;
$$;

-- Test: is_uuidv7() helper function works
CREATE OR REPLACE FUNCTION test.test_uuid_016_is_uuidv7_helper()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_has_uuidv7 boolean;
    l_v7_uuid uuid;
    l_v4_uuid uuid;
BEGIN
    PERFORM test.set_context('test_uuid_016_is_uuidv7_helper');

    SELECT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'uuidv7') INTO l_has_uuidv7;

    IF l_has_uuidv7 THEN
        l_v7_uuid := uuidv7();
        l_v4_uuid := gen_random_uuid();

        PERFORM test.ok(test.is_uuidv7(l_v7_uuid), 'is_uuidv7 should return true for v7 UUID');
        PERFORM test.not_ok(test.is_uuidv7(l_v4_uuid), 'is_uuidv7 should return false for v4 UUID');
    ELSE
        PERFORM test.skip(2, 'uuidv7() not available');
    END IF;
END;
$$;

-- Test: gen_random_uuid() as fallback
CREATE OR REPLACE FUNCTION test.test_uuid_017_fallback()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_uuid uuid;
BEGIN
    PERFORM test.set_context('test_uuid_017_fallback');

    -- gen_random_uuid() should always be available
    l_uuid := gen_random_uuid();

    PERFORM test.is_not_null(l_uuid, 'gen_random_uuid() should generate UUID');
    PERFORM test.is(length(l_uuid::text), 36, 'UUID should be standard format');
END;
$$;

-- Test: UUID indexing performance characteristics
CREATE OR REPLACE FUNCTION test.test_uuid_018_index_creation()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_uuid_idx_' || to_char(clock_timestamp(), 'HH24MISS');
    l_has_uuidv7 boolean;
BEGIN
    PERFORM test.set_context('test_uuid_018_index_creation');

    SELECT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'uuidv7') INTO l_has_uuidv7;

    -- Create table
    IF l_has_uuidv7 THEN
        EXECUTE format($tbl$
            CREATE TABLE test.%I (
                id uuid PRIMARY KEY DEFAULT uuidv7(),
                created_at timestamptz DEFAULT now()
            )
        $tbl$, l_test_table);
    ELSE
        EXECUTE format($tbl$
            CREATE TABLE test.%I (
                id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
                created_at timestamptz DEFAULT now()
            )
        $tbl$, l_test_table);
    END IF;

    -- Insert sample data
    EXECUTE format('INSERT INTO test.%I SELECT FROM generate_series(1, 100)', l_test_table);

    -- Verify index exists (PK creates index)
    PERFORM test.has_index('test', l_test_table, l_test_table || '_pkey', 'PK should create index');

    -- Clean up
    EXECUTE format('DROP TABLE test.%I', l_test_table);
END;
$$;

-- ============================================================================
-- RUN TESTS
-- ============================================================================

SELECT test.run_module('uuid_01');
CALL test.print_run_summary();
