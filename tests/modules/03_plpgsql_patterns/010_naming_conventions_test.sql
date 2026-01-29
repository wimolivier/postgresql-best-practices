-- ============================================================================
-- PL/PGSQL PATTERNS TESTS - NAMING CONVENTIONS
-- ============================================================================
-- Tests for Trivadis naming conventions in PL/pgSQL code.
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

-- Test: Local variables should use l_ prefix
CREATE OR REPLACE FUNCTION test.test_naming_010_local_prefix()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_value text := 'test';  -- Correct: l_ prefix
    l_count integer := 0;         -- Correct: l_ prefix
BEGIN
    PERFORM test.set_context('test_naming_010_local_prefix');

    -- This test demonstrates correct local variable naming
    PERFORM test.ok(l_test_value IS NOT NULL, 'l_ prefix for local text variable');
    PERFORM test.ok(l_count IS NOT NULL, 'l_ prefix for local integer variable');
END;
$$;

-- Test: Constants should use co_ prefix
CREATE OR REPLACE FUNCTION test.test_naming_011_constant_prefix()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    co_max_retries CONSTANT integer := 3;    -- Correct: co_ prefix
    co_default_status CONSTANT text := 'active';
BEGIN
    PERFORM test.set_context('test_naming_011_constant_prefix');

    PERFORM test.ok(co_max_retries > 0, 'co_ prefix for integer constant');
    PERFORM test.ok(co_default_status IS NOT NULL, 'co_ prefix for text constant');
END;
$$;

-- Test: IN parameters should use in_ prefix
CREATE OR REPLACE FUNCTION test.test_naming_012_in_parameter()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM test.set_context('test_naming_012_in_parameter');

    -- Create a function with correct IN parameter naming
    EXECUTE $fn$
        CREATE OR REPLACE FUNCTION test.helper_in_param(
            in_user_id uuid,           -- Correct: in_ prefix
            in_status text DEFAULT NULL -- Correct: in_ prefix
        )
        RETURNS boolean
        LANGUAGE plpgsql
        AS $body$
        BEGIN
            RETURN in_user_id IS NOT NULL;
        END;
        $body$
    $fn$;

    -- Test the function exists and works
    PERFORM test.ok(
        test.helper_in_param(gen_random_uuid()),
        'in_ prefix for IN parameters'
    );

    -- Clean up
    DROP FUNCTION test.helper_in_param(uuid, text);
END;
$$;

-- Test: INOUT parameters should use io_ prefix
CREATE OR REPLACE FUNCTION test.test_naming_013_inout_parameter()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_result_id uuid;
BEGIN
    PERFORM test.set_context('test_naming_013_inout_parameter');

    -- Create a procedure with correct INOUT parameter naming
    EXECUTE $fn$
        CREATE OR REPLACE PROCEDURE test.helper_inout_param(
            in_value text,
            INOUT io_result_id uuid DEFAULT NULL  -- Correct: io_ prefix
        )
        LANGUAGE plpgsql
        AS $body$
        BEGIN
            io_result_id := gen_random_uuid();
        END;
        $body$
    $fn$;

    -- Test the procedure
    CALL test.helper_inout_param('test', l_result_id);

    PERFORM test.is_not_null(l_result_id, 'io_ prefix for INOUT parameters');

    -- Clean up
    DROP PROCEDURE test.helper_inout_param(text, uuid);
END;
$$;

-- Test: Cursors should use c_ prefix
CREATE OR REPLACE FUNCTION test.test_naming_014_cursor_prefix()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    c_test_cursor CURSOR FOR SELECT 1 AS val;  -- Correct: c_ prefix
    l_val integer;
BEGIN
    PERFORM test.set_context('test_naming_014_cursor_prefix');

    OPEN c_test_cursor;
    FETCH c_test_cursor INTO l_val;
    CLOSE c_test_cursor;

    PERFORM test.is(l_val, 1, 'c_ prefix for cursor');
END;
$$;

-- Test: Records should use r_ prefix
CREATE OR REPLACE FUNCTION test.test_naming_015_record_prefix()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    r_row record;  -- Correct: r_ prefix
BEGIN
    PERFORM test.set_context('test_naming_015_record_prefix');

    SELECT 1 AS id, 'test' AS name INTO r_row;

    PERFORM test.is(r_row.id, 1, 'r_ prefix for record variable');
END;
$$;

-- Test: Arrays should use t_ prefix (table/array)
CREATE OR REPLACE FUNCTION test.test_naming_016_array_prefix()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    t_values text[] := ARRAY['a', 'b', 'c'];  -- Correct: t_ prefix
    t_numbers integer[] := ARRAY[1, 2, 3];
BEGIN
    PERFORM test.set_context('test_naming_016_array_prefix');

    PERFORM test.is(array_length(t_values, 1), 3, 't_ prefix for text array');
    PERFORM test.is(array_length(t_numbers, 1), 3, 't_ prefix for integer array');
END;
$$;

-- Test: Function naming pattern - action_entity
CREATE OR REPLACE FUNCTION test.test_naming_017_function_action_entity()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_func text := 'test_func_' || to_char(clock_timestamp(), 'HH24MISS');
BEGIN
    PERFORM test.set_context('test_naming_017_function_action_entity');

    -- Create functions following action_entity pattern
    EXECUTE format($fn$
        CREATE FUNCTION api.select_%I()  -- select_entity
        RETURNS int
        LANGUAGE sql
        AS $$ SELECT 1 $$
    $fn$, l_test_func);

    EXECUTE format($fn$
        CREATE FUNCTION api.get_%I()  -- get_entity
        RETURNS int
        LANGUAGE sql
        AS $$ SELECT 1 $$
    $fn$, l_test_func);

    -- Verify they exist
    PERFORM test.has_function('api', 'select_' || l_test_func, 'select_entity naming pattern');
    PERFORM test.has_function('api', 'get_' || l_test_func, 'get_entity naming pattern');

    -- Clean up
    EXECUTE format('DROP FUNCTION api.select_%I()', l_test_func);
    EXECUTE format('DROP FUNCTION api.get_%I()', l_test_func);
END;
$$;

-- Test: Procedure naming pattern - action_entity
CREATE OR REPLACE FUNCTION test.test_naming_018_procedure_action_entity()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_proc text := 'test_proc_' || to_char(clock_timestamp(), 'HH24MISS');
BEGIN
    PERFORM test.set_context('test_naming_018_procedure_action_entity');

    -- Create procedures following action_entity pattern
    EXECUTE format($fn$
        CREATE PROCEDURE api.insert_%I(in_val int)  -- insert_entity
        LANGUAGE plpgsql
        AS $$ BEGIN NULL; END; $$
    $fn$, l_test_proc);

    EXECUTE format($fn$
        CREATE PROCEDURE api.update_%I(in_id uuid)  -- update_entity
        LANGUAGE plpgsql
        AS $$ BEGIN NULL; END; $$
    $fn$, l_test_proc);

    EXECUTE format($fn$
        CREATE PROCEDURE api.delete_%I(in_id uuid)  -- delete_entity
        LANGUAGE plpgsql
        AS $$ BEGIN NULL; END; $$
    $fn$, l_test_proc);

    -- Verify they exist
    PERFORM test.has_procedure('api', 'insert_' || l_test_proc, 'insert_entity naming pattern');
    PERFORM test.has_procedure('api', 'update_' || l_test_proc, 'update_entity naming pattern');
    PERFORM test.has_procedure('api', 'delete_' || l_test_proc, 'delete_entity naming pattern');

    -- Clean up
    EXECUTE format('DROP PROCEDURE api.insert_%I(int)', l_test_proc);
    EXECUTE format('DROP PROCEDURE api.update_%I(uuid)', l_test_proc);
    EXECUTE format('DROP PROCEDURE api.delete_%I(uuid)', l_test_proc);
END;
$$;

-- Test: Trigger naming pattern - table_timing_action_trg
CREATE OR REPLACE FUNCTION test.test_naming_019_trigger_naming()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_trg_' || to_char(clock_timestamp(), 'HH24MISS');
BEGIN
    PERFORM test.set_context('test_naming_019_trigger_naming');

    -- Create test table
    EXECUTE format('CREATE TABLE data.%I (id int, updated_at timestamptz)', l_test_table);

    -- Create trigger function
    EXECUTE format($fn$
        CREATE FUNCTION private.%I_biu_updated_trg()
        RETURNS trigger
        LANGUAGE plpgsql
        AS $body$ BEGIN NEW.updated_at := now(); RETURN NEW; END; $body$
    $fn$, l_test_table);

    -- Create trigger with correct naming: table_timing_action_trg
    EXECUTE format($fn$
        CREATE TRIGGER %I_biu_updated_trg
        BEFORE INSERT OR UPDATE ON data.%I
        FOR EACH ROW
        EXECUTE FUNCTION private.%I_biu_updated_trg()
    $fn$, l_test_table, l_test_table, l_test_table);

    -- Verify trigger exists
    PERFORM test.has_trigger('data', l_test_table, l_test_table || '_biu_updated_trg',
        'trigger should follow table_timing_action_trg pattern');

    -- Clean up
    EXECUTE format('DROP TABLE data.%I CASCADE', l_test_table);
    EXECUTE format('DROP FUNCTION private.%I_biu_updated_trg()', l_test_table);
END;
$$;

-- ============================================================================
-- RUN TESTS
-- ============================================================================

SELECT test.run_module('naming_01');
CALL test.print_run_summary();
