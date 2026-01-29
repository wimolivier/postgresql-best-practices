-- ============================================================================
-- PL/PGSQL PATTERNS TESTS - ERROR HANDLING
-- ============================================================================
-- Tests for error handling patterns with proper SQLSTATE codes.
-- ============================================================================

-- ============================================================================
-- TEST FUNCTIONS
-- ============================================================================

-- Test: RAISE EXCEPTION with SQLSTATE
CREATE OR REPLACE FUNCTION test.test_error_040_raise_sqlstate()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM test.set_context('test_error_040_raise_sqlstate');

    -- Test custom SQLSTATE
    PERFORM test.throws_ok(
        $sql$
            DO $$ BEGIN RAISE EXCEPTION 'Custom error' USING ERRCODE = 'P0001'; END; $$
        $sql$,
        'P0001',
        'RAISE EXCEPTION should use specified SQLSTATE'
    );
END;
$$;

-- Test: EXCEPTION block catches errors
CREATE OR REPLACE FUNCTION test.test_error_041_exception_block()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_caught boolean := false;
BEGIN
    PERFORM test.set_context('test_error_041_exception_block');

    BEGIN
        -- Cause division by zero
        PERFORM 1 / 0;
    EXCEPTION
        WHEN division_by_zero THEN
            l_caught := true;
    END;

    PERFORM test.ok(l_caught, 'EXCEPTION block should catch division_by_zero');
END;
$$;

-- Test: GET STACKED DIAGNOSTICS retrieves error details
CREATE OR REPLACE FUNCTION test.test_error_042_get_diagnostics()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_sqlstate text;
    l_message text;
BEGIN
    PERFORM test.set_context('test_error_042_get_diagnostics');

    BEGIN
        RAISE EXCEPTION 'Test error message' USING ERRCODE = 'P0002';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS
            l_sqlstate = RETURNED_SQLSTATE,
            l_message = MESSAGE_TEXT;
    END;

    PERFORM test.is(l_sqlstate, 'P0002', 'RETURNED_SQLSTATE should contain error code');
    PERFORM test.matches(l_message, 'Test error message', 'MESSAGE_TEXT should contain error message');
END;
$$;

-- Test: Re-raise exception with RAISE
CREATE OR REPLACE FUNCTION test.test_error_043_reraise()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM test.set_context('test_error_043_reraise');

    PERFORM test.throws_ok(
        $sql$
            DO $$
            BEGIN
                BEGIN
                    RAISE EXCEPTION 'Original error' USING ERRCODE = 'P0003';
                EXCEPTION WHEN OTHERS THEN
                    -- Log, then re-raise
                    RAISE;
                END;
            END;
            $$
        $sql$,
        'P0003',
        'RAISE without args should re-raise original exception'
    );
END;
$$;

-- Test: USING HINT provides helpful context
CREATE OR REPLACE FUNCTION test.test_error_044_using_hint()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_hint text;
BEGIN
    PERFORM test.set_context('test_error_044_using_hint');

    BEGIN
        RAISE EXCEPTION 'Error message'
            USING ERRCODE = 'P0004',
                  HINT = 'Try doing X instead';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS l_hint = PG_EXCEPTION_HINT;
    END;

    PERFORM test.is(l_hint, 'Try doing X instead', 'USING HINT should set hint message');
END;
$$;

-- Test: USING DETAIL provides additional information
CREATE OR REPLACE FUNCTION test.test_error_045_using_detail()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_detail text;
BEGIN
    PERFORM test.set_context('test_error_045_using_detail');

    BEGIN
        RAISE EXCEPTION 'Error message'
            USING ERRCODE = 'P0005',
                  DETAIL = 'Additional details here';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS l_detail = PG_EXCEPTION_DETAIL;
    END;

    PERFORM test.is(l_detail, 'Additional details here', 'USING DETAIL should set detail message');
END;
$$;

-- Test: Catching specific exception types
CREATE OR REPLACE FUNCTION test.test_error_046_specific_exceptions()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_caught_type text;
BEGIN
    PERFORM test.set_context('test_error_046_specific_exceptions');

    -- Test unique_violation
    BEGIN
        RAISE EXCEPTION 'test' USING ERRCODE = '23505';  -- unique_violation
    EXCEPTION
        WHEN unique_violation THEN
            l_caught_type := 'unique_violation';
        WHEN OTHERS THEN
            l_caught_type := 'others';
    END;

    PERFORM test.is(l_caught_type, 'unique_violation', 'should catch unique_violation specifically');

    -- Test foreign_key_violation
    BEGIN
        RAISE EXCEPTION 'test' USING ERRCODE = '23503';  -- foreign_key_violation
    EXCEPTION
        WHEN foreign_key_violation THEN
            l_caught_type := 'foreign_key_violation';
        WHEN OTHERS THEN
            l_caught_type := 'others';
    END;

    PERFORM test.is(l_caught_type, 'foreign_key_violation', 'should catch foreign_key_violation specifically');
END;
$$;

-- Test: Multiple exception handlers
CREATE OR REPLACE FUNCTION test.test_error_047_multiple_handlers()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_result text;
BEGIN
    PERFORM test.set_context('test_error_047_multiple_handlers');

    -- Test that most specific handler is used
    BEGIN
        RAISE EXCEPTION 'test' USING ERRCODE = '22012';  -- division_by_zero
    EXCEPTION
        WHEN division_by_zero THEN
            l_result := 'div_zero';
        WHEN numeric_value_out_of_range THEN
            l_result := 'out_of_range';
        WHEN data_exception THEN
            l_result := 'data_exception';
        WHEN OTHERS THEN
            l_result := 'others';
    END;

    PERFORM test.is(l_result, 'div_zero', 'most specific handler should catch exception');
END;
$$;

-- Test: Validation with meaningful errors
CREATE OR REPLACE FUNCTION test.test_error_048_validation_pattern()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_func text := 'validate_' || to_char(clock_timestamp(), 'HH24MISS');
BEGIN
    PERFORM test.set_context('test_error_048_validation_pattern');

    -- Create function with validation
    EXECUTE format($fn$
        CREATE FUNCTION test.%I(in_email text)
        RETURNS boolean
        LANGUAGE plpgsql
        AS $body$
        BEGIN
            IF in_email IS NULL OR in_email = '' THEN
                RAISE EXCEPTION 'Email is required'
                    USING ERRCODE = 'P0100',
                          HINT = 'Provide a valid email address';
            END IF;

            IF in_email !~ '@' THEN
                RAISE EXCEPTION 'Invalid email format: %%', in_email
                    USING ERRCODE = 'P0101',
                          DETAIL = 'Email must contain @ symbol';
            END IF;

            RETURN true;
        END;
        $body$
    $fn$, l_test_func);

    -- Test null validation
    PERFORM test.throws_ok(
        format('SELECT test.%I(NULL)', l_test_func),
        'P0100',
        'should throw P0100 for NULL email'
    );

    -- Test format validation
    PERFORM test.throws_ok(
        format('SELECT test.%I(''invalid'')', l_test_func),
        'P0101',
        'should throw P0101 for invalid format'
    );

    -- Test valid input
    PERFORM test.lives_ok(
        format('SELECT test.%I(''test@example.com'')', l_test_func),
        'should accept valid email'
    );

    -- Clean up
    EXECUTE format('DROP FUNCTION test.%I(text)', l_test_func);
END;
$$;

-- Test: ASSERT for internal invariants
CREATE OR REPLACE FUNCTION test.test_error_049_assert()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM test.set_context('test_error_049_assert');

    -- ASSERT that fails
    PERFORM test.throws_ok(
        $sql$
            DO $$ BEGIN ASSERT false, 'This should fail'; END; $$
        $sql$,
        'P0004',  -- assert_failure
        'ASSERT false should throw P0004'
    );

    -- ASSERT that passes
    PERFORM test.lives_ok(
        $sql$
            DO $$ BEGIN ASSERT true, 'This should pass'; END; $$
        $sql$,
        'ASSERT true should not throw'
    );
END;
$$;

-- ============================================================================
-- RUN TESTS
-- ============================================================================

SELECT test.run_module('error_04');
CALL test.print_run_summary();
