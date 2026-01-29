-- ============================================================================
-- PL/PGSQL PATTERNS TESTS - TABLE API
-- ============================================================================
-- Tests for the Table API pattern (functions for reads, procedures for writes).
-- ============================================================================

-- ============================================================================
-- SETUP
-- ============================================================================

DO $$
BEGIN
    CREATE SCHEMA IF NOT EXISTS data;
    CREATE SCHEMA IF NOT EXISTS private;
    CREATE SCHEMA IF NOT EXISTS api;
END;
$$;

-- ============================================================================
-- TEST FUNCTIONS
-- ============================================================================

-- Test: Read functions should use RETURNS TABLE
CREATE OR REPLACE FUNCTION test.test_tableapi_020_returns_table()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_func text := 'test_rt_' || to_char(clock_timestamp(), 'HH24MISS');
BEGIN
    PERFORM test.set_context('test_tableapi_020_returns_table');

    -- Create function with RETURNS TABLE
    EXECUTE format($fn$
        CREATE FUNCTION api.select_%I(in_status text DEFAULT NULL)
        RETURNS TABLE (id uuid, name text, status text)
        LANGUAGE sql
        STABLE
        SECURITY DEFINER
        SET search_path = data, private, pg_temp
        AS $$
            SELECT gen_random_uuid(), 'test'::text, 'active'::text
        $$
    $fn$, l_test_func);

    -- Test it returns rows
    PERFORM test.isnt_empty(
        format('SELECT * FROM api.select_%I()', l_test_func),
        'RETURNS TABLE function should return rows'
    );

    -- Clean up
    EXECUTE format('DROP FUNCTION api.select_%I(text)', l_test_func);
END;
$$;

-- Test: Read functions should be STABLE
CREATE OR REPLACE FUNCTION test.test_tableapi_021_stable_volatility()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_func text := 'test_stable_' || to_char(clock_timestamp(), 'HH24MISS');
    l_volatility text;
BEGIN
    PERFORM test.set_context('test_tableapi_021_stable_volatility');

    -- Create STABLE function
    EXECUTE format($fn$
        CREATE FUNCTION api.select_%I()
        RETURNS TABLE (id int)
        LANGUAGE sql
        STABLE
        AS $$ SELECT 1 $$
    $fn$, l_test_func);

    -- Check volatility
    SELECT p.provolatile INTO l_volatility
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'api' AND p.proname = 'select_' || l_test_func;

    PERFORM test.is(l_volatility, 's', 'read function should be STABLE (s)');

    -- Clean up
    EXECUTE format('DROP FUNCTION api.select_%I()', l_test_func);
END;
$$;

-- Test: Write procedures should use INOUT for return value
CREATE OR REPLACE FUNCTION test.test_tableapi_022_procedure_inout()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_proc text := 'test_inout_' || to_char(clock_timestamp(), 'HH24MISS');
    l_result_id uuid;
BEGIN
    PERFORM test.set_context('test_tableapi_022_procedure_inout');

    -- Create procedure with INOUT parameter
    EXECUTE format($fn$
        CREATE PROCEDURE api.insert_%I(
            in_name text,
            INOUT io_id uuid DEFAULT NULL
        )
        LANGUAGE plpgsql
        SECURITY DEFINER
        SET search_path = data, private, pg_temp
        AS $$
        BEGIN
            io_id := gen_random_uuid();
        END;
        $$
    $fn$, l_test_proc);

    -- Call and check INOUT works
    EXECUTE format('CALL api.insert_%I($1, $2)', l_test_proc)
    USING 'test', l_result_id;

    PERFORM test.is_not_null(l_result_id, 'INOUT parameter should return value');

    -- Clean up
    EXECUTE format('DROP PROCEDURE api.insert_%I(text, uuid)', l_test_proc);
END;
$$;

-- Test: Write procedures should handle INSERT
CREATE OR REPLACE FUNCTION test.test_tableapi_023_insert_procedure()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_ins_' || to_char(clock_timestamp(), 'HH24MISS');
    l_test_proc text := l_test_table;
    l_result_id uuid;
    l_row_count integer;
BEGIN
    PERFORM test.set_context('test_tableapi_023_insert_procedure');

    -- Create test table
    EXECUTE format($tbl$
        CREATE TABLE data.%I (
            id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
            name text NOT NULL
        )
    $tbl$, l_test_table);

    -- Create insert procedure
    EXECUTE format($fn$
        CREATE PROCEDURE api.insert_%I(
            in_name text,
            INOUT io_id uuid DEFAULT NULL
        )
        LANGUAGE plpgsql
        SECURITY DEFINER
        SET search_path = data, private, pg_temp
        AS $$
        BEGIN
            INSERT INTO %I (name)
            VALUES (in_name)
            RETURNING id INTO io_id;
        END;
        $$
    $fn$, l_test_proc, l_test_table);

    -- Test insert
    EXECUTE format('CALL api.insert_%I($1, $2)', l_test_proc)
    USING 'Test Name', l_result_id;

    -- Verify row was inserted
    EXECUTE format('SELECT count(*) FROM data.%I WHERE id = $1', l_test_table)
    INTO l_row_count
    USING l_result_id;

    PERFORM test.is(l_row_count, 1, 'INSERT procedure should create row');

    -- Clean up
    EXECUTE format('DROP TABLE data.%I CASCADE', l_test_table);
    EXECUTE format('DROP PROCEDURE api.insert_%I(text, uuid)', l_test_proc);
END;
$$;

-- Test: Write procedures should handle UPDATE
CREATE OR REPLACE FUNCTION test.test_tableapi_024_update_procedure()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_upd_' || to_char(clock_timestamp(), 'HH24MISS');
    l_test_proc text := l_test_table;
    l_test_id uuid;
    l_new_name text;
BEGIN
    PERFORM test.set_context('test_tableapi_024_update_procedure');

    -- Create test table with data
    EXECUTE format($tbl$
        CREATE TABLE data.%I (
            id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
            name text NOT NULL
        )
    $tbl$, l_test_table);

    EXECUTE format('INSERT INTO data.%I (name) VALUES ($1) RETURNING id', l_test_table)
    INTO l_test_id
    USING 'Original';

    -- Create update procedure
    EXECUTE format($fn$
        CREATE PROCEDURE api.update_%I(
            in_id uuid,
            in_name text
        )
        LANGUAGE plpgsql
        SECURITY DEFINER
        SET search_path = data, private, pg_temp
        AS $$
        BEGIN
            UPDATE %I SET name = in_name WHERE id = in_id;
        END;
        $$
    $fn$, l_test_proc, l_test_table);

    -- Test update
    EXECUTE format('CALL api.update_%I($1, $2)', l_test_proc)
    USING l_test_id, 'Updated';

    -- Verify update
    EXECUTE format('SELECT name FROM data.%I WHERE id = $1', l_test_table)
    INTO l_new_name
    USING l_test_id;

    PERFORM test.is(l_new_name, 'Updated', 'UPDATE procedure should modify row');

    -- Clean up
    EXECUTE format('DROP TABLE data.%I CASCADE', l_test_table);
    EXECUTE format('DROP PROCEDURE api.update_%I(uuid, text)', l_test_proc);
END;
$$;

-- Test: Write procedures should handle DELETE
CREATE OR REPLACE FUNCTION test.test_tableapi_025_delete_procedure()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_del_' || to_char(clock_timestamp(), 'HH24MISS');
    l_test_proc text := l_test_table;
    l_test_id uuid;
    l_row_count integer;
BEGIN
    PERFORM test.set_context('test_tableapi_025_delete_procedure');

    -- Create test table with data
    EXECUTE format($tbl$
        CREATE TABLE data.%I (
            id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
            name text NOT NULL
        )
    $tbl$, l_test_table);

    EXECUTE format('INSERT INTO data.%I (name) VALUES ($1) RETURNING id', l_test_table)
    INTO l_test_id
    USING 'To Delete';

    -- Create delete procedure
    EXECUTE format($fn$
        CREATE PROCEDURE api.delete_%I(in_id uuid)
        LANGUAGE plpgsql
        SECURITY DEFINER
        SET search_path = data, private, pg_temp
        AS $$
        BEGIN
            DELETE FROM %I WHERE id = in_id;
        END;
        $$
    $fn$, l_test_proc, l_test_table);

    -- Test delete
    EXECUTE format('CALL api.delete_%I($1)', l_test_proc)
    USING l_test_id;

    -- Verify deletion
    EXECUTE format('SELECT count(*) FROM data.%I WHERE id = $1', l_test_table)
    INTO l_row_count
    USING l_test_id;

    PERFORM test.is(l_row_count, 0, 'DELETE procedure should remove row');

    -- Clean up
    EXECUTE format('DROP TABLE data.%I CASCADE', l_test_table);
    EXECUTE format('DROP PROCEDURE api.delete_%I(uuid)', l_test_proc);
END;
$$;

-- Test: Read function with filtering parameters
CREATE OR REPLACE FUNCTION test.test_tableapi_026_filter_parameters()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_filt_' || to_char(clock_timestamp(), 'HH24MISS');
    l_test_func text := l_test_table;
    l_count integer;
BEGIN
    PERFORM test.set_context('test_tableapi_026_filter_parameters');

    -- Create test table
    EXECUTE format($tbl$
        CREATE TABLE data.%I (
            id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
            status text NOT NULL
        )
    $tbl$, l_test_table);

    -- Insert test data
    EXECUTE format('INSERT INTO data.%I (status) VALUES ($1), ($2), ($3)', l_test_table)
    USING 'active', 'active', 'inactive';

    -- Create filter function
    EXECUTE format($fn$
        CREATE FUNCTION api.select_%I(in_status text DEFAULT NULL)
        RETURNS TABLE (id uuid, status text)
        LANGUAGE sql
        STABLE
        SECURITY DEFINER
        SET search_path = data, private, pg_temp
        AS $$
            SELECT id, status FROM %I
            WHERE in_status IS NULL OR status = in_status
        $$
    $fn$, l_test_func, l_test_table);

    -- Test filter - all
    EXECUTE format('SELECT count(*) FROM api.select_%I()', l_test_func)
    INTO l_count;
    PERFORM test.is(l_count, 3, 'NULL filter should return all rows');

    -- Test filter - active only
    EXECUTE format('SELECT count(*) FROM api.select_%I($1)', l_test_func)
    INTO l_count
    USING 'active';
    PERFORM test.is(l_count, 2, 'Status filter should return matching rows');

    -- Clean up
    EXECUTE format('DROP TABLE data.%I CASCADE', l_test_table);
    EXECUTE format('DROP FUNCTION api.select_%I(text)', l_test_func);
END;
$$;

-- Test: get_by_id pattern for single record
CREATE OR REPLACE FUNCTION test.test_tableapi_027_get_by_id()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_get_' || to_char(clock_timestamp(), 'HH24MISS');
    l_test_func text := l_test_table;
    l_test_id uuid;
    l_found_name text;
BEGIN
    PERFORM test.set_context('test_tableapi_027_get_by_id');

    -- Create test table
    EXECUTE format($tbl$
        CREATE TABLE data.%I (
            id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
            name text NOT NULL
        )
    $tbl$, l_test_table);

    -- Insert test data
    EXECUTE format('INSERT INTO data.%I (name) VALUES ($1) RETURNING id', l_test_table)
    INTO l_test_id
    USING 'Test Record';

    -- Create get_by_id function
    EXECUTE format($fn$
        CREATE FUNCTION api.get_%I(in_id uuid)
        RETURNS TABLE (id uuid, name text)
        LANGUAGE sql
        STABLE
        SECURITY DEFINER
        SET search_path = data, private, pg_temp
        AS $$
            SELECT id, name FROM %I WHERE id = in_id
        $$
    $fn$, l_test_func, l_test_table);

    -- Test get
    EXECUTE format('SELECT name FROM api.get_%I($1)', l_test_func)
    INTO l_found_name
    USING l_test_id;

    PERFORM test.is(l_found_name, 'Test Record', 'get_by_id should return correct record');

    -- Clean up
    EXECUTE format('DROP TABLE data.%I CASCADE', l_test_table);
    EXECUTE format('DROP FUNCTION api.get_%I(uuid)', l_test_func);
END;
$$;

-- ============================================================================
-- RUN TESTS
-- ============================================================================

SELECT test.run_module('tableapi_02');
CALL test.print_run_summary();
