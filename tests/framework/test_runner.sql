-- ============================================================================
-- TEST FRAMEWORK - TEST RUNNER
-- ============================================================================
-- Test discovery and execution engine.
-- Finds and runs test functions, collects results, outputs TAP format.
-- ============================================================================

BEGIN;

-- ============================================================================
-- TEST EXECUTION TABLES
-- ============================================================================

CREATE TABLE IF NOT EXISTS test.runs (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_name        text NOT NULL,
    started_at      timestamptz NOT NULL DEFAULT clock_timestamp(),
    completed_at    timestamptz,
    total_tests     integer NOT NULL DEFAULT 0,
    passed          integer NOT NULL DEFAULT 0,
    failed          integer NOT NULL DEFAULT 0,
    skipped         integer NOT NULL DEFAULT 0,
    duration_ms     integer
);

CREATE INDEX IF NOT EXISTS runs_started_at_idx ON test.runs(started_at DESC);

COMMENT ON TABLE test.runs IS 'Test run summary records';

CREATE TABLE IF NOT EXISTS test.run_details (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_id          bigint NOT NULL REFERENCES test.runs(id),
    test_function   text NOT NULL,
    passed          boolean NOT NULL,
    assertions      integer NOT NULL DEFAULT 0,
    passed_count    integer NOT NULL DEFAULT 0,
    failed_count    integer NOT NULL DEFAULT 0,
    duration_ms     integer,
    error_message   text,
    executed_at     timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE INDEX IF NOT EXISTS run_details_run_id_idx ON test.run_details(run_id);

COMMENT ON TABLE test.run_details IS 'Individual test function results within a run';

-- ============================================================================
-- TEST DISCOVERY
-- ============================================================================

-- Find all test functions matching a pattern
CREATE OR REPLACE FUNCTION test.discover_tests(
    in_schema text DEFAULT 'test',
    in_pattern text DEFAULT '^test_'
)
RETURNS TABLE (
    schema_name text,
    function_name text,
    full_name text
)
LANGUAGE sql
STABLE
AS $$
    SELECT
        n.nspname::text AS schema_name,
        p.proname::text AS function_name,
        n.nspname || '.' || p.proname AS full_name
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = in_schema
      AND p.proname ~ in_pattern
      AND p.pronargs = 0  -- No arguments
      AND p.prorettype = 'void'::regtype  -- Returns void
    ORDER BY p.proname;
$$;

COMMENT ON FUNCTION test.discover_tests(text, text) IS 'Find test functions matching pattern';

-- ============================================================================
-- SINGLE TEST EXECUTION
-- ============================================================================

-- Run a single test function
CREATE OR REPLACE FUNCTION test.run_test(
    in_function_name text,
    in_run_id bigint DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
    l_start_time timestamptz;
    l_duration_ms integer;
    l_assertions integer;
    l_passed integer;
    l_failed integer;
    l_error text;
    l_success boolean := true;
BEGIN
    -- Set context
    PERFORM test.set_context(in_function_name, in_function_name);

    RAISE NOTICE '';
    RAISE NOTICE '# Running: %', in_function_name;

    l_start_time := clock_timestamp();

    BEGIN
        -- Execute test function
        EXECUTE 'SELECT ' || in_function_name || '()';
    EXCEPTION WHEN OTHERS THEN
        l_error := SQLERRM;
        l_success := false;
        RAISE NOTICE 'not ok - % threw exception: %', in_function_name, l_error;
    END;

    l_duration_ms := extract(milliseconds from clock_timestamp() - l_start_time)::integer;

    -- Get assertion counts
    SELECT assertion_count, pass_count, fail_count
    INTO l_assertions, l_passed, l_failed
    FROM test.context WHERE id = 1;

    -- Determine overall success
    IF l_failed > 0 OR NOT l_success THEN
        l_success := false;
    END IF;

    -- Record run details if run_id provided
    IF in_run_id IS NOT NULL THEN
        INSERT INTO test.run_details (
            run_id, test_function, passed, assertions,
            passed_count, failed_count, duration_ms, error_message
        ) VALUES (
            in_run_id, in_function_name, l_success, l_assertions,
            l_passed, l_failed, l_duration_ms, l_error
        );
    END IF;

    RAISE NOTICE '# Completed: % (%ms) - % assertions, % passed, % failed',
        in_function_name, l_duration_ms, l_assertions, l_passed, l_failed;

    RETURN l_success;
END;
$$;

COMMENT ON FUNCTION test.run_test(text, bigint) IS 'Run a single test function';

-- ============================================================================
-- BATCH TEST EXECUTION
-- ============================================================================

-- Run all tests in a schema matching pattern
CREATE OR REPLACE FUNCTION test.run_all(
    in_schema text DEFAULT 'test',
    in_pattern text DEFAULT '^test_'
)
RETURNS TABLE (
    run_id bigint,
    total_tests integer,
    passed integer,
    failed integer,
    duration_ms integer
)
LANGUAGE plpgsql
AS $$
DECLARE
    l_run_id bigint;
    l_start_time timestamptz;
    l_test record;
    l_test_passed boolean;
    l_total integer := 0;
    l_passed integer := 0;
    l_failed integer := 0;
BEGIN
    -- Create run record
    INSERT INTO test.runs (run_name, started_at)
    VALUES (in_schema || ':' || in_pattern, clock_timestamp())
    RETURNING id INTO l_run_id;

    l_start_time := clock_timestamp();

    RAISE NOTICE '';
    RAISE NOTICE '============================================================';
    RAISE NOTICE 'TEST RUN: % (pattern: %)', in_schema, in_pattern;
    RAISE NOTICE '============================================================';

    -- Clear previous results for clean run
    DELETE FROM test.results WHERE test_name IN (
        SELECT full_name FROM test.discover_tests(in_schema, in_pattern)
    );

    -- Run each discovered test
    FOR l_test IN SELECT * FROM test.discover_tests(in_schema, in_pattern)
    LOOP
        l_test_passed := test.run_test(l_test.full_name, l_run_id);
        l_total := l_total + 1;

        IF l_test_passed THEN
            l_passed := l_passed + 1;
        ELSE
            l_failed := l_failed + 1;
        END IF;
    END LOOP;

    -- Update run record
    UPDATE test.runs
    SET completed_at = clock_timestamp(),
        total_tests = l_total,
        passed = l_passed,
        failed = l_failed,
        duration_ms = extract(milliseconds from clock_timestamp() - l_start_time)::integer
    WHERE id = l_run_id;

    -- Return summary
    run_id := l_run_id;
    total_tests := l_total;
    passed := l_passed;
    failed := l_failed;
    duration_ms := extract(milliseconds from clock_timestamp() - l_start_time)::integer;

    RETURN NEXT;
END;
$$;

COMMENT ON FUNCTION test.run_all(text, text) IS 'Run all tests matching pattern in schema';

-- Run tests from a specific module (by file pattern)
CREATE OR REPLACE FUNCTION test.run_module(
    in_module text,
    in_schema text DEFAULT 'test'
)
RETURNS TABLE (
    run_id bigint,
    total_tests integer,
    passed integer,
    failed integer,
    duration_ms integer
)
LANGUAGE plpgsql
AS $$
BEGIN
    -- Module pattern: test_{module}
    RETURN QUERY SELECT * FROM test.run_all(in_schema, '^test_' || in_module);
END;
$$;

COMMENT ON FUNCTION test.run_module(text, text) IS 'Run all tests for a specific module';

-- ============================================================================
-- RESULTS SUMMARY
-- ============================================================================

-- Get summary of current test context
CREATE OR REPLACE FUNCTION test.summary()
RETURNS TABLE (
    test_name text,
    total_assertions integer,
    passed integer,
    failed integer,
    success_rate numeric
)
LANGUAGE sql
STABLE
AS $$
    SELECT
        current_test,
        assertion_count,
        pass_count,
        fail_count,
        CASE WHEN assertion_count > 0
            THEN round(100.0 * pass_count / assertion_count, 1)
            ELSE 0
        END
    FROM test.context WHERE id = 1;
$$;

COMMENT ON FUNCTION test.summary() IS 'Get summary of current test context';

-- Print formatted test summary
CREATE OR REPLACE PROCEDURE test.print_summary()
LANGUAGE plpgsql
AS $$
DECLARE
    l_total integer;
    l_passed integer;
    l_failed integer;
    r_row record;
BEGIN
    -- Get totals from most recent results
    SELECT
        count(*),
        count(*) FILTER (WHERE passed),
        count(*) FILTER (WHERE NOT passed)
    INTO l_total, l_passed, l_failed
    FROM test.results
    WHERE executed_at > (SELECT started_at FROM test.context WHERE id = 1);

    RAISE NOTICE '';
    RAISE NOTICE '============================================================';
    RAISE NOTICE 'TEST SUMMARY';
    RAISE NOTICE '============================================================';
    RAISE NOTICE 'Total assertions: %', l_total;
    RAISE NOTICE 'Passed: %', l_passed;
    RAISE NOTICE 'Failed: %', l_failed;

    IF l_total > 0 THEN
        RAISE NOTICE 'Success rate: %', round(100.0 * l_passed / l_total, 1) || '%';
    END IF;

    -- Show failed tests
    IF l_failed > 0 THEN
        RAISE NOTICE '';
        RAISE NOTICE 'FAILED ASSERTIONS:';
        FOR r_row IN
            SELECT test_name, assertion_num, description, got, expected
            FROM test.results
            WHERE NOT passed
              AND executed_at > (SELECT started_at FROM test.context WHERE id = 1)
            ORDER BY id
        LOOP
            RAISE NOTICE '  [%] #% - %', r_row.test_name, r_row.assertion_num, r_row.description;
            RAISE NOTICE '    got: %', r_row.got;
            RAISE NOTICE '    expected: %', r_row.expected;
        END LOOP;
    END IF;

    RAISE NOTICE '============================================================';

    IF l_failed > 0 THEN
        RAISE NOTICE 'RESULT: FAILED';
    ELSE
        RAISE NOTICE 'RESULT: PASSED';
    END IF;

    RAISE NOTICE '============================================================';
END;
$$;

COMMENT ON PROCEDURE test.print_summary() IS 'Print formatted test summary';

-- Print run summary
CREATE OR REPLACE PROCEDURE test.print_run_summary(in_run_id bigint DEFAULT NULL)
LANGUAGE plpgsql
AS $$
DECLARE
    r_run record;
    r_detail record;
BEGIN
    -- Get run (latest if not specified)
    IF in_run_id IS NULL THEN
        SELECT * INTO r_run FROM test.runs ORDER BY started_at DESC LIMIT 1;
    ELSE
        SELECT * INTO r_run FROM test.runs WHERE id = in_run_id;
    END IF;

    IF r_run IS NULL THEN
        RAISE NOTICE 'No test runs found';
        RETURN;
    END IF;

    RAISE NOTICE '';
    RAISE NOTICE '============================================================';
    RAISE NOTICE 'TEST RUN SUMMARY (Run #%)', r_run.id;
    RAISE NOTICE '============================================================';
    RAISE NOTICE 'Run name: %', r_run.run_name;
    RAISE NOTICE 'Started: %', r_run.started_at;
    RAISE NOTICE 'Completed: %', r_run.completed_at;
    RAISE NOTICE 'Duration: %ms', r_run.duration_ms;
    RAISE NOTICE '';
    RAISE NOTICE 'Tests: % total, % passed, % failed',
        r_run.total_tests, r_run.passed, r_run.failed;

    IF r_run.total_tests > 0 THEN
        RAISE NOTICE 'Success rate: %', round(100.0 * r_run.passed / r_run.total_tests, 1) || '%';
    END IF;

    -- Show failed tests
    IF r_run.failed > 0 THEN
        RAISE NOTICE '';
        RAISE NOTICE 'FAILED TESTS:';
        FOR r_detail IN
            SELECT * FROM test.run_details
            WHERE run_id = r_run.id AND NOT passed
            ORDER BY executed_at
        LOOP
            RAISE NOTICE '  % - % assertions, % failed',
                r_detail.test_function, r_detail.assertions, r_detail.failed_count;
            IF r_detail.error_message IS NOT NULL THEN
                RAISE NOTICE '    Error: %', r_detail.error_message;
            END IF;
        END LOOP;
    END IF;

    RAISE NOTICE '============================================================';

    IF r_run.failed > 0 THEN
        RAISE NOTICE 'RESULT: FAILED';
    ELSE
        RAISE NOTICE 'RESULT: PASSED';
    END IF;

    RAISE NOTICE '============================================================';
END;
$$;

COMMENT ON PROCEDURE test.print_run_summary(bigint) IS 'Print formatted run summary';

-- ============================================================================
-- CLEANUP FUNCTIONS
-- ============================================================================

-- Clear all test results
CREATE OR REPLACE PROCEDURE test.clear_results()
LANGUAGE plpgsql
AS $$
BEGIN
    TRUNCATE test.results;
    TRUNCATE test.run_details CASCADE;
    TRUNCATE test.runs CASCADE;

    UPDATE test.context
    SET current_test = 'unknown',
        current_function = NULL,
        assertion_count = 0,
        pass_count = 0,
        fail_count = 0,
        started_at = clock_timestamp()
    WHERE id = 1;

    RAISE NOTICE 'Test results cleared';
END;
$$;

COMMENT ON PROCEDURE test.clear_results() IS 'Clear all test results';

-- Get last run exit code (0 = success, 1 = failure)
CREATE OR REPLACE FUNCTION test.get_exit_code(in_run_id bigint DEFAULT NULL)
RETURNS integer
LANGUAGE sql
STABLE
AS $$
    SELECT CASE WHEN r.failed > 0 THEN 1 ELSE 0 END
    FROM test.runs r
    WHERE r.id = COALESCE(in_run_id, (SELECT max(id) FROM test.runs));
$$;

COMMENT ON FUNCTION test.get_exit_code(bigint) IS 'Get exit code for a run (0=success, 1=failure)';

COMMIT;
