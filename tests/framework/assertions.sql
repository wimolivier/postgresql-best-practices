-- ============================================================================
-- TEST FRAMEWORK - ASSERTIONS
-- ============================================================================
-- pgTAP-compatible assertion functions without external dependencies.
-- Provides a complete set of testing primitives for PostgreSQL.
-- ============================================================================

BEGIN;

-- ============================================================================
-- TEST SCHEMA
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS test;

COMMENT ON SCHEMA test IS 'Test framework schema - assertions and test runner';

-- ============================================================================
-- TEST RESULTS TABLE
-- ============================================================================

CREATE TABLE IF NOT EXISTS test.results (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    test_name       text NOT NULL,
    test_function   text,
    assertion_num   integer NOT NULL DEFAULT 1,
    description     text,
    passed          boolean NOT NULL,
    got             text,
    expected        text,
    error_message   text,
    executed_at     timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE INDEX IF NOT EXISTS results_test_name_idx ON test.results(test_name);
CREATE INDEX IF NOT EXISTS results_passed_idx ON test.results(passed);
CREATE INDEX IF NOT EXISTS results_executed_at_idx ON test.results(executed_at DESC);

COMMENT ON TABLE test.results IS 'Stores all test assertion results';

-- ============================================================================
-- TEST CONTEXT
-- ============================================================================

CREATE TABLE IF NOT EXISTS test.context (
    id              integer PRIMARY KEY DEFAULT 1,
    current_test    text NOT NULL DEFAULT 'unknown',
    current_function text,
    assertion_count integer NOT NULL DEFAULT 0,
    pass_count      integer NOT NULL DEFAULT 0,
    fail_count      integer NOT NULL DEFAULT 0,
    started_at      timestamptz NOT NULL DEFAULT clock_timestamp(),

    CONSTRAINT context_single_row CHECK (id = 1)
);

INSERT INTO test.context (id, current_test)
VALUES (1, 'unknown')
ON CONFLICT (id) DO NOTHING;

COMMENT ON TABLE test.context IS 'Current test execution context';

-- ============================================================================
-- CONTEXT MANAGEMENT
-- ============================================================================

-- Set the current test context
CREATE OR REPLACE FUNCTION test.set_context(
    in_test_name text,
    in_function_name text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE test.context
    SET current_test = in_test_name,
        current_function = in_function_name,
        assertion_count = 0,
        pass_count = 0,
        fail_count = 0,
        started_at = clock_timestamp()
    WHERE id = 1;
END;
$$;

COMMENT ON FUNCTION test.set_context(text, text) IS 'Initialize test context for a new test';

-- Get the current test name
CREATE OR REPLACE FUNCTION test.get_context()
RETURNS text
LANGUAGE sql
STABLE
AS $$
    SELECT current_test FROM test.context WHERE id = 1;
$$;

-- Increment assertion counter and return the new value
CREATE OR REPLACE FUNCTION test.next_assertion()
RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE
    l_num integer;
BEGIN
    UPDATE test.context
    SET assertion_count = assertion_count + 1
    WHERE id = 1
    RETURNING assertion_count INTO l_num;

    RETURN l_num;
END;
$$;

-- ============================================================================
-- CORE ASSERTION RECORDING
-- ============================================================================

-- Record an assertion result (internal)
CREATE OR REPLACE FUNCTION test._record(
    in_passed boolean,
    in_description text,
    in_got text DEFAULT NULL,
    in_expected text DEFAULT NULL,
    in_error_message text DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
    l_assertion_num integer;
    l_test_name text;
    l_function_name text;
BEGIN
    -- Get context
    SELECT current_test, current_function
    INTO l_test_name, l_function_name
    FROM test.context WHERE id = 1;

    -- Get next assertion number
    l_assertion_num := test.next_assertion();

    -- Update pass/fail counts
    IF in_passed THEN
        UPDATE test.context SET pass_count = pass_count + 1 WHERE id = 1;
    ELSE
        UPDATE test.context SET fail_count = fail_count + 1 WHERE id = 1;
    END IF;

    -- Record result
    INSERT INTO test.results (
        test_name, test_function, assertion_num, description,
        passed, got, expected, error_message
    ) VALUES (
        l_test_name, l_function_name, l_assertion_num, in_description,
        in_passed, in_got, in_expected, in_error_message
    );

    -- Output TAP format
    IF in_passed THEN
        RAISE NOTICE 'ok % - %', l_assertion_num, COALESCE(in_description, '');
    ELSE
        RAISE NOTICE 'not ok % - %', l_assertion_num, COALESCE(in_description, '');
        IF in_got IS NOT NULL OR in_expected IS NOT NULL THEN
            RAISE NOTICE '#   got: %', COALESCE(in_got, 'NULL');
            RAISE NOTICE '#   expected: %', COALESCE(in_expected, 'NULL');
        END IF;
        IF in_error_message IS NOT NULL THEN
            RAISE NOTICE '#   error: %', in_error_message;
        END IF;
    END IF;

    RETURN in_passed;
END;
$$;

-- ============================================================================
-- BASIC ASSERTIONS
-- ============================================================================

-- ok(condition, description) - Pass if condition is true
CREATE OR REPLACE FUNCTION test.ok(
    in_condition boolean,
    in_description text DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN test._record(
        COALESCE(in_condition, false),
        in_description,
        CASE WHEN in_condition THEN 'true' ELSE 'false' END,
        'true'
    );
END;
$$;

COMMENT ON FUNCTION test.ok(boolean, text) IS 'Pass if condition is true';

-- not_ok(condition, description) - Pass if condition is false
CREATE OR REPLACE FUNCTION test.not_ok(
    in_condition boolean,
    in_description text DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN test._record(
        NOT COALESCE(in_condition, true),
        in_description,
        CASE WHEN in_condition THEN 'true' ELSE 'false' END,
        'false'
    );
END;
$$;

COMMENT ON FUNCTION test.not_ok(boolean, text) IS 'Pass if condition is false';

-- ============================================================================
-- EQUALITY ASSERTIONS
-- ============================================================================

-- is(got, expected, description) - Pass if values match
CREATE OR REPLACE FUNCTION test.is(
    in_got anyelement,
    in_expected anyelement,
    in_description text DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
    l_passed boolean;
BEGIN
    -- Handle NULL comparison
    l_passed := (in_got IS NOT DISTINCT FROM in_expected);

    RETURN test._record(
        l_passed,
        in_description,
        COALESCE(in_got::text, 'NULL'),
        COALESCE(in_expected::text, 'NULL')
    );
END;
$$;

COMMENT ON FUNCTION test.is(anyelement, anyelement, text) IS 'Pass if values match (NULL-safe)';

-- isnt(got, unexpected, description) - Pass if values differ
CREATE OR REPLACE FUNCTION test.isnt(
    in_got anyelement,
    in_unexpected anyelement,
    in_description text DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
    l_passed boolean;
BEGIN
    l_passed := (in_got IS DISTINCT FROM in_unexpected);

    RETURN test._record(
        l_passed,
        in_description,
        COALESCE(in_got::text, 'NULL'),
        'NOT ' || COALESCE(in_unexpected::text, 'NULL')
    );
END;
$$;

COMMENT ON FUNCTION test.isnt(anyelement, anyelement, text) IS 'Pass if values differ (NULL-safe)';

-- is_null(value, description) - Pass if value is NULL
CREATE OR REPLACE FUNCTION test.is_null(
    in_value anyelement,
    in_description text DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN test._record(
        in_value IS NULL,
        in_description,
        COALESCE(in_value::text, 'NULL'),
        'NULL'
    );
END;
$$;

COMMENT ON FUNCTION test.is_null(anyelement, text) IS 'Pass if value is NULL';

-- is_not_null(value, description) - Pass if value is not NULL
CREATE OR REPLACE FUNCTION test.is_not_null(
    in_value anyelement,
    in_description text DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN test._record(
        in_value IS NOT NULL,
        in_description,
        COALESCE(in_value::text, 'NULL'),
        'NOT NULL'
    );
END;
$$;

COMMENT ON FUNCTION test.is_not_null(anyelement, text) IS 'Pass if value is not NULL';

-- ============================================================================
-- COMPARISON ASSERTIONS
-- ============================================================================

-- cmp_ok(got, op, expected, description) - Compare using operator
CREATE OR REPLACE FUNCTION test.cmp_ok(
    in_got anyelement,
    in_op text,
    in_expected anyelement,
    in_description text DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
    l_passed boolean;
    l_sql text;
BEGIN
    -- Build dynamic comparison
    l_sql := format('SELECT %L::%s %s %L::%s',
        in_got, pg_typeof(in_got), in_op, in_expected, pg_typeof(in_expected));

    EXECUTE l_sql INTO l_passed;

    RETURN test._record(
        COALESCE(l_passed, false),
        in_description,
        COALESCE(in_got::text, 'NULL'),
        in_op || ' ' || COALESCE(in_expected::text, 'NULL')
    );
EXCEPTION WHEN OTHERS THEN
    RETURN test._record(
        false,
        in_description,
        COALESCE(in_got::text, 'NULL'),
        in_op || ' ' || COALESCE(in_expected::text, 'NULL'),
        SQLERRM
    );
END;
$$;

COMMENT ON FUNCTION test.cmp_ok(anyelement, text, anyelement, text) IS 'Compare values using specified operator';

-- matches(got, pattern, description) - Pass if got matches regex
CREATE OR REPLACE FUNCTION test.matches(
    in_got text,
    in_pattern text,
    in_description text DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN test._record(
        in_got ~ in_pattern,
        in_description,
        COALESCE(in_got, 'NULL'),
        '~' || in_pattern
    );
END;
$$;

COMMENT ON FUNCTION test.matches(text, text, text) IS 'Pass if value matches regex pattern';

-- doesnt_match(got, pattern, description) - Pass if got doesn't match regex
CREATE OR REPLACE FUNCTION test.doesnt_match(
    in_got text,
    in_pattern text,
    in_description text DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN test._record(
        NOT (in_got ~ in_pattern),
        in_description,
        COALESCE(in_got, 'NULL'),
        'NOT ~' || in_pattern
    );
END;
$$;

COMMENT ON FUNCTION test.doesnt_match(text, text, text) IS 'Pass if value does not match regex pattern';

-- ============================================================================
-- EXCEPTION ASSERTIONS
-- ============================================================================

-- throws_ok(sql, errcode, description) - Pass if SQL throws expected error
CREATE OR REPLACE FUNCTION test.throws_ok(
    in_sql text,
    in_errcode text DEFAULT NULL,
    in_description text DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
    l_errcode text;
    l_errmsg text;
BEGIN
    BEGIN
        EXECUTE in_sql;
        -- If we get here, no exception was thrown
        RETURN test._record(
            false,
            in_description,
            'no exception',
            COALESCE('exception ' || in_errcode, 'any exception')
        );
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS
            l_errcode = RETURNED_SQLSTATE,
            l_errmsg = MESSAGE_TEXT;

        IF in_errcode IS NULL THEN
            -- Any exception is OK
            RETURN test._record(
                true,
                in_description,
                l_errcode || ': ' || l_errmsg,
                'any exception'
            );
        ELSIF l_errcode = in_errcode THEN
            RETURN test._record(
                true,
                in_description,
                l_errcode,
                in_errcode
            );
        ELSE
            RETURN test._record(
                false,
                in_description,
                l_errcode || ': ' || l_errmsg,
                in_errcode
            );
        END IF;
    END;
END;
$$;

COMMENT ON FUNCTION test.throws_ok(text, text, text) IS 'Pass if SQL throws expected error code';

-- throws_like(sql, pattern, description) - Pass if error message matches pattern
CREATE OR REPLACE FUNCTION test.throws_like(
    in_sql text,
    in_pattern text,
    in_description text DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
    l_errcode text;
    l_errmsg text;
BEGIN
    BEGIN
        EXECUTE in_sql;
        RETURN test._record(
            false,
            in_description,
            'no exception',
            'exception matching: ' || in_pattern
        );
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS
            l_errcode = RETURNED_SQLSTATE,
            l_errmsg = MESSAGE_TEXT;

        RETURN test._record(
            l_errmsg ~ in_pattern,
            in_description,
            l_errmsg,
            '~' || in_pattern
        );
    END;
END;
$$;

COMMENT ON FUNCTION test.throws_like(text, text, text) IS 'Pass if error message matches pattern';

-- lives_ok(sql, description) - Pass if SQL executes without error
CREATE OR REPLACE FUNCTION test.lives_ok(
    in_sql text,
    in_description text DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
    l_errcode text;
    l_errmsg text;
BEGIN
    BEGIN
        EXECUTE in_sql;
        RETURN test._record(true, in_description, 'no exception', 'no exception');
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS
            l_errcode = RETURNED_SQLSTATE,
            l_errmsg = MESSAGE_TEXT;

        RETURN test._record(
            false,
            in_description,
            l_errcode || ': ' || l_errmsg,
            'no exception'
        );
    END;
END;
$$;

COMMENT ON FUNCTION test.lives_ok(text, text) IS 'Pass if SQL executes without error';

-- ============================================================================
-- SCHEMA OBJECT ASSERTIONS
-- ============================================================================

-- has_schema(schema_name, description) - Pass if schema exists
CREATE OR REPLACE FUNCTION test.has_schema(
    in_schema text,
    in_description text DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
    l_exists boolean;
BEGIN
    SELECT EXISTS (
        SELECT 1 FROM information_schema.schemata
        WHERE schema_name = in_schema
    ) INTO l_exists;

    RETURN test._record(
        l_exists,
        COALESCE(in_description, 'Schema ' || in_schema || ' should exist'),
        CASE WHEN l_exists THEN 'exists' ELSE 'not found' END,
        'exists'
    );
END;
$$;

COMMENT ON FUNCTION test.has_schema(text, text) IS 'Pass if schema exists';

-- has_table(schema, table, description) - Pass if table exists
CREATE OR REPLACE FUNCTION test.has_table(
    in_schema text,
    in_table text,
    in_description text DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
    l_exists boolean;
BEGIN
    SELECT EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = in_schema AND table_name = in_table
    ) INTO l_exists;

    RETURN test._record(
        l_exists,
        COALESCE(in_description, 'Table ' || in_schema || '.' || in_table || ' should exist'),
        CASE WHEN l_exists THEN 'exists' ELSE 'not found' END,
        'exists'
    );
END;
$$;

COMMENT ON FUNCTION test.has_table(text, text, text) IS 'Pass if table exists';

-- hasnt_table(schema, table, description) - Pass if table doesn't exist
CREATE OR REPLACE FUNCTION test.hasnt_table(
    in_schema text,
    in_table text,
    in_description text DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
    l_exists boolean;
BEGIN
    SELECT EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = in_schema AND table_name = in_table
    ) INTO l_exists;

    RETURN test._record(
        NOT l_exists,
        COALESCE(in_description, 'Table ' || in_schema || '.' || in_table || ' should not exist'),
        CASE WHEN l_exists THEN 'exists' ELSE 'not found' END,
        'not found'
    );
END;
$$;

COMMENT ON FUNCTION test.hasnt_table(text, text, text) IS 'Pass if table does not exist';

-- has_column(schema, table, column, description) - Pass if column exists
CREATE OR REPLACE FUNCTION test.has_column(
    in_schema text,
    in_table text,
    in_column text,
    in_description text DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
    l_exists boolean;
BEGIN
    SELECT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = in_schema
          AND table_name = in_table
          AND column_name = in_column
    ) INTO l_exists;

    RETURN test._record(
        l_exists,
        COALESCE(in_description, 'Column ' || in_schema || '.' || in_table || '.' || in_column || ' should exist'),
        CASE WHEN l_exists THEN 'exists' ELSE 'not found' END,
        'exists'
    );
END;
$$;

COMMENT ON FUNCTION test.has_column(text, text, text, text) IS 'Pass if column exists';

-- col_type_is(schema, table, column, type, description) - Pass if column has expected type
CREATE OR REPLACE FUNCTION test.col_type_is(
    in_schema text,
    in_table text,
    in_column text,
    in_type text,
    in_description text DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
    l_type text;
BEGIN
    SELECT data_type INTO l_type
    FROM information_schema.columns
    WHERE table_schema = in_schema
      AND table_name = in_table
      AND column_name = in_column;

    -- Normalize common type aliases
    l_type := COALESCE(l_type, 'NOT FOUND');

    RETURN test._record(
        lower(l_type) = lower(in_type) OR l_type ~ in_type,
        COALESCE(in_description, 'Column ' || in_column || ' should be type ' || in_type),
        l_type,
        in_type
    );
END;
$$;

COMMENT ON FUNCTION test.col_type_is(text, text, text, text, text) IS 'Pass if column has expected data type';

-- has_function(schema, function_name, description) - Pass if function exists
CREATE OR REPLACE FUNCTION test.has_function(
    in_schema text,
    in_function text,
    in_description text DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
    l_exists boolean;
BEGIN
    SELECT EXISTS (
        SELECT 1 FROM information_schema.routines
        WHERE routine_schema = in_schema
          AND routine_name = in_function
          AND routine_type = 'FUNCTION'
    ) INTO l_exists;

    RETURN test._record(
        l_exists,
        COALESCE(in_description, 'Function ' || in_schema || '.' || in_function || ' should exist'),
        CASE WHEN l_exists THEN 'exists' ELSE 'not found' END,
        'exists'
    );
END;
$$;

COMMENT ON FUNCTION test.has_function(text, text, text) IS 'Pass if function exists';

-- has_procedure(schema, procedure_name, description) - Pass if procedure exists
CREATE OR REPLACE FUNCTION test.has_procedure(
    in_schema text,
    in_procedure text,
    in_description text DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
    l_exists boolean;
BEGIN
    SELECT EXISTS (
        SELECT 1 FROM information_schema.routines
        WHERE routine_schema = in_schema
          AND routine_name = in_procedure
          AND routine_type = 'PROCEDURE'
    ) INTO l_exists;

    RETURN test._record(
        l_exists,
        COALESCE(in_description, 'Procedure ' || in_schema || '.' || in_procedure || ' should exist'),
        CASE WHEN l_exists THEN 'exists' ELSE 'not found' END,
        'exists'
    );
END;
$$;

COMMENT ON FUNCTION test.has_procedure(text, text, text) IS 'Pass if procedure exists';

-- has_index(schema, table, index_name, description) - Pass if index exists
CREATE OR REPLACE FUNCTION test.has_index(
    in_schema text,
    in_table text,
    in_index text,
    in_description text DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
    l_exists boolean;
BEGIN
    SELECT EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE schemaname = in_schema
          AND tablename = in_table
          AND indexname = in_index
    ) INTO l_exists;

    RETURN test._record(
        l_exists,
        COALESCE(in_description, 'Index ' || in_index || ' should exist on ' || in_schema || '.' || in_table),
        CASE WHEN l_exists THEN 'exists' ELSE 'not found' END,
        'exists'
    );
END;
$$;

COMMENT ON FUNCTION test.has_index(text, text, text, text) IS 'Pass if index exists';

-- has_trigger(schema, table, trigger_name, description) - Pass if trigger exists
CREATE OR REPLACE FUNCTION test.has_trigger(
    in_schema text,
    in_table text,
    in_trigger text,
    in_description text DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
    l_exists boolean;
BEGIN
    SELECT EXISTS (
        SELECT 1 FROM information_schema.triggers
        WHERE event_object_schema = in_schema
          AND event_object_table = in_table
          AND trigger_name = in_trigger
    ) INTO l_exists;

    RETURN test._record(
        l_exists,
        COALESCE(in_description, 'Trigger ' || in_trigger || ' should exist on ' || in_schema || '.' || in_table),
        CASE WHEN l_exists THEN 'exists' ELSE 'not found' END,
        'exists'
    );
END;
$$;

COMMENT ON FUNCTION test.has_trigger(text, text, text, text) IS 'Pass if trigger exists';

-- ============================================================================
-- ROW COUNT ASSERTIONS
-- ============================================================================

-- row_count_is(query, count, description) - Pass if query returns expected count
CREATE OR REPLACE FUNCTION test.row_count_is(
    in_query text,
    in_expected bigint,
    in_description text DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
    l_count bigint;
BEGIN
    EXECUTE 'SELECT count(*) FROM (' || in_query || ') q' INTO l_count;

    RETURN test._record(
        l_count = in_expected,
        in_description,
        l_count::text,
        in_expected::text
    );
END;
$$;

COMMENT ON FUNCTION test.row_count_is(text, bigint, text) IS 'Pass if query returns expected row count';

-- table_count_is(schema, table, count, description) - Pass if table has expected rows
CREATE OR REPLACE FUNCTION test.table_count_is(
    in_schema text,
    in_table text,
    in_expected bigint,
    in_description text DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN test.row_count_is(
        format('SELECT 1 FROM %I.%I', in_schema, in_table),
        in_expected,
        COALESCE(in_description, 'Table ' || in_schema || '.' || in_table || ' should have ' || in_expected || ' rows')
    );
END;
$$;

COMMENT ON FUNCTION test.table_count_is(text, text, bigint, text) IS 'Pass if table has expected row count';

-- is_empty(query, description) - Pass if query returns no rows
CREATE OR REPLACE FUNCTION test.is_empty(
    in_query text,
    in_description text DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN test.row_count_is(in_query, 0, in_description);
END;
$$;

COMMENT ON FUNCTION test.is_empty(text, text) IS 'Pass if query returns no rows';

-- isnt_empty(query, description) - Pass if query returns at least one row
CREATE OR REPLACE FUNCTION test.isnt_empty(
    in_query text,
    in_description text DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
    l_count bigint;
BEGIN
    EXECUTE 'SELECT count(*) FROM (' || in_query || ') q' INTO l_count;

    RETURN test._record(
        l_count > 0,
        in_description,
        l_count::text || ' rows',
        '> 0 rows'
    );
END;
$$;

COMMENT ON FUNCTION test.isnt_empty(text, text) IS 'Pass if query returns at least one row';

-- ============================================================================
-- SKIP AND TODO
-- ============================================================================

-- skip(count, reason) - Skip a number of tests
CREATE OR REPLACE FUNCTION test.skip(
    in_count integer,
    in_reason text DEFAULT 'skipped'
)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    i integer;
BEGIN
    FOR i IN 1..in_count LOOP
        PERFORM test._record(true, 'SKIP: ' || in_reason);
    END LOOP;
END;
$$;

COMMENT ON FUNCTION test.skip(integer, text) IS 'Skip a number of tests with a reason';

-- todo(reason) - Mark following tests as TODO
CREATE OR REPLACE FUNCTION test.todo(in_reason text DEFAULT 'TODO')
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE NOTICE '# TODO: %', in_reason;
END;
$$;

COMMENT ON FUNCTION test.todo(text) IS 'Mark following tests as TODO';

-- ============================================================================
-- UTILITY FUNCTIONS
-- ============================================================================

-- plan(count) - Declare expected test count
CREATE OR REPLACE FUNCTION test.plan(in_count integer)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE NOTICE '1..%', in_count;
END;
$$;

COMMENT ON FUNCTION test.plan(integer) IS 'Declare expected number of tests';

-- no_plan() - No planned test count
CREATE OR REPLACE FUNCTION test.no_plan()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    -- Nothing to do, will output count at end
    NULL;
END;
$$;

COMMENT ON FUNCTION test.no_plan() IS 'Indicate no planned test count';

-- diag(message) - Output diagnostic message
CREATE OR REPLACE FUNCTION test.diag(in_message text)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE NOTICE '# %', in_message;
END;
$$;

COMMENT ON FUNCTION test.diag(text) IS 'Output diagnostic message';

-- note(message) - Output note (same as diag)
CREATE OR REPLACE FUNCTION test.note(in_message text)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM test.diag(in_message);
END;
$$;

COMMENT ON FUNCTION test.note(text) IS 'Output note message';

COMMIT;
