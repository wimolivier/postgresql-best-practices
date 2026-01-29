-- ============================================================================
-- DATA TYPES TESTS - TIMESTAMPTZ
-- ============================================================================
-- Tests for timestamp with time zone handling.
-- ============================================================================

-- ============================================================================
-- TEST FUNCTIONS
-- ============================================================================

-- Test: timestamptz preserves time zone information
CREATE OR REPLACE FUNCTION test.test_timestamp_020_preserves_tz()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_original timestamptz;
    l_retrieved timestamptz;
    l_test_table text := 'test_tz_' || to_char(clock_timestamp(), 'HH24MISS');
BEGIN
    PERFORM test.set_context('test_timestamp_020_preserves_tz');

    -- Create table
    EXECUTE format('CREATE TABLE test.%I (ts timestamptz)', l_test_table);

    -- Insert with specific timezone
    l_original := '2024-01-15 10:30:00-08'::timestamptz;
    EXECUTE format('INSERT INTO test.%I VALUES ($1)', l_test_table) USING l_original;

    -- Retrieve
    EXECUTE format('SELECT ts FROM test.%I', l_test_table) INTO l_retrieved;

    -- Values should be equal (same instant in time)
    PERFORM test.is(l_retrieved, l_original, 'timestamptz should preserve instant');

    -- Clean up
    EXECUTE format('DROP TABLE test.%I', l_test_table);
END;
$$;

-- Test: timestamp without timezone is NOT recommended
CREATE OR REPLACE FUNCTION test.test_timestamp_021_without_tz_issues()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_no_tz_' || to_char(clock_timestamp(), 'HH24MISS');
    l_ts timestamp;
    l_tstz timestamptz;
BEGIN
    PERFORM test.set_context('test_timestamp_021_without_tz_issues');

    -- Create table with timestamp (without tz) - NOT RECOMMENDED
    EXECUTE format('CREATE TABLE test.%I (ts timestamp)', l_test_table);

    -- Insert
    EXECUTE format('INSERT INTO test.%I VALUES ($1)', l_test_table)
    USING '2024-01-15 10:30:00'::timestamp;

    -- Retrieve
    EXECUTE format('SELECT ts FROM test.%I', l_test_table) INTO l_ts;

    -- Convert to timestamptz - uses session timezone (potentially wrong!)
    l_tstz := l_ts::timestamptz;

    -- This test documents the problem - not an actual pass/fail
    PERFORM test.is_not_null(l_ts, 'timestamp (without tz) stores value but loses timezone context');

    -- Clean up
    EXECUTE format('DROP TABLE test.%I', l_test_table);
END;
$$;

-- Test: now() returns timestamptz
CREATE OR REPLACE FUNCTION test.test_timestamp_022_now_is_timestamptz()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_type text;
BEGIN
    PERFORM test.set_context('test_timestamp_022_now_is_timestamptz');

    SELECT pg_typeof(now())::text INTO l_type;

    PERFORM test.is(l_type, 'timestamp with time zone', 'now() should return timestamptz');
END;
$$;

-- Test: clock_timestamp() returns timestamptz and advances
CREATE OR REPLACE FUNCTION test.test_timestamp_023_clock_timestamp()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_ts1 timestamptz;
    l_ts2 timestamptz;
BEGIN
    PERFORM test.set_context('test_timestamp_023_clock_timestamp');

    l_ts1 := clock_timestamp();
    PERFORM pg_sleep(0.01);
    l_ts2 := clock_timestamp();

    PERFORM test.ok(l_ts2 > l_ts1, 'clock_timestamp() should advance during execution');
END;
$$;

-- Test: Timezone conversion with AT TIME ZONE
CREATE OR REPLACE FUNCTION test.test_timestamp_024_at_time_zone()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_utc timestamptz := '2024-01-15 18:00:00+00'::timestamptz;
    l_pacific timestamp;  -- AT TIME ZONE returns timestamp (no tz)
BEGIN
    PERFORM test.set_context('test_timestamp_024_at_time_zone');

    -- Convert UTC to Pacific time
    l_pacific := l_utc AT TIME ZONE 'America/Los_Angeles';

    -- In January (PST), Pacific is UTC-8
    PERFORM test.is(
        l_pacific::text,
        '2024-01-15 10:00:00',
        'AT TIME ZONE should convert correctly'
    );
END;
$$;

-- Test: BETWEEN with timestamps (avoid, use >= AND <)
CREATE OR REPLACE FUNCTION test.test_timestamp_025_between_warning()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_between_' || to_char(clock_timestamp(), 'HH24MISS');
    l_count_between integer;
    l_count_range integer;
BEGIN
    PERFORM test.set_context('test_timestamp_025_between_warning');

    -- Create table with test data
    EXECUTE format($tbl$
        CREATE TABLE test.%I (
            id serial PRIMARY KEY,
            created_at timestamptz NOT NULL
        )
    $tbl$, l_test_table);

    -- Insert test data
    EXECUTE format('INSERT INTO test.%I (created_at) VALUES ($1), ($2), ($3)', l_test_table)
    USING
        '2024-01-15 00:00:00+00'::timestamptz,
        '2024-01-15 12:00:00+00'::timestamptz,
        '2024-01-16 00:00:00+00'::timestamptz;  -- Exactly at end boundary

    -- BETWEEN includes both endpoints (can cause off-by-one)
    EXECUTE format($q$
        SELECT count(*) FROM test.%I
        WHERE created_at BETWEEN '2024-01-15 00:00:00+00' AND '2024-01-16 00:00:00+00'
    $q$, l_test_table)
    INTO l_count_between;

    -- Recommended: >= AND < excludes end boundary
    EXECUTE format($q$
        SELECT count(*) FROM test.%I
        WHERE created_at >= '2024-01-15 00:00:00+00'
          AND created_at < '2024-01-16 00:00:00+00'
    $q$, l_test_table)
    INTO l_count_range;

    -- BETWEEN includes the boundary row, >= AND < excludes it
    PERFORM test.is(l_count_between, 3, 'BETWEEN includes both endpoints');
    PERFORM test.is(l_count_range, 2, '>= AND < excludes end boundary (recommended)');

    -- Clean up
    EXECUTE format('DROP TABLE test.%I', l_test_table);
END;
$$;

-- Test: Default value with now()
-- Note: now() returns transaction start time, not statement execution time
CREATE OR REPLACE FUNCTION test.test_timestamp_026_default_now()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_def_now_' || to_char(clock_timestamp(), 'HH24MISS');
    l_transaction_time timestamptz;
    l_created_at timestamptz;
BEGIN
    PERFORM test.set_context('test_timestamp_026_default_now');

    -- Get current transaction time (what now() returns)
    l_transaction_time := now();

    -- Create table with now() default
    EXECUTE format($tbl$
        CREATE TABLE test.%I (
            id serial PRIMARY KEY,
            created_at timestamptz NOT NULL DEFAULT now()
        )
    $tbl$, l_test_table);

    -- Insert without specifying created_at
    EXECUTE format('INSERT INTO test.%I DEFAULT VALUES RETURNING created_at', l_test_table)
    INTO l_created_at;

    -- Default should be set - now() returns transaction start time
    PERFORM test.is_not_null(l_created_at, 'created_at should have default value');
    PERFORM test.is(l_created_at, l_transaction_time, 'created_at should equal transaction start time (now() behavior)');

    -- Clean up
    EXECUTE format('DROP TABLE test.%I', l_test_table);
END;
$$;

-- Test: Timestamp arithmetic
CREATE OR REPLACE FUNCTION test.test_timestamp_027_arithmetic()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_base timestamptz := '2024-01-15 12:00:00+00'::timestamptz;
    l_plus_hour timestamptz;
    l_plus_day timestamptz;
    l_diff interval;
BEGIN
    PERFORM test.set_context('test_timestamp_027_arithmetic');

    -- Add interval
    l_plus_hour := l_base + interval '1 hour';
    l_plus_day := l_base + interval '1 day';

    PERFORM test.is(
        l_plus_hour::text,
        '2024-01-15 13:00:00+00',
        'adding 1 hour should work'
    );

    PERFORM test.is(
        l_plus_day::text,
        '2024-01-16 12:00:00+00',
        'adding 1 day should work'
    );

    -- Subtract timestamps to get interval
    l_diff := l_plus_day - l_base;
    PERFORM test.is(l_diff, interval '1 day', 'subtracting timestamps gives interval');
END;
$$;

-- Test: Extract parts from timestamp
CREATE OR REPLACE FUNCTION test.test_timestamp_028_extract()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_ts timestamptz := '2024-06-15 14:30:45.123+00'::timestamptz;
BEGIN
    PERFORM test.set_context('test_timestamp_028_extract');

    PERFORM test.is(extract(year from l_ts)::integer, 2024, 'extract year');
    PERFORM test.is(extract(month from l_ts)::integer, 6, 'extract month');
    PERFORM test.is(extract(day from l_ts)::integer, 15, 'extract day');
    PERFORM test.is(extract(hour from l_ts)::integer, 14, 'extract hour');
    PERFORM test.is(extract(minute from l_ts)::integer, 30, 'extract minute');
    PERFORM test.is(floor(extract(second from l_ts))::integer, 45, 'extract second');
END;
$$;

-- ============================================================================
-- RUN TESTS
-- ============================================================================

SELECT test.run_module('timestamp_02');
CALL test.print_run_summary();
