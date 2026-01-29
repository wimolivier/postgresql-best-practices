-- ============================================================================
-- PL/PGSQL PATTERNS TESTS - TRIGGERS
-- ============================================================================
-- Tests for trigger patterns including updated_at and audit logging.
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

-- Test: updated_at trigger function pattern
CREATE OR REPLACE FUNCTION test.test_trigger_030_updated_at_function()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_func text := 'set_updated_at_' || to_char(clock_timestamp(), 'HH24MISS');
BEGIN
    PERFORM test.set_context('test_trigger_030_updated_at_function');

    -- Create trigger function in private schema
    EXECUTE format($fn$
        CREATE FUNCTION private.%I()
        RETURNS trigger
        LANGUAGE plpgsql
        AS $body$
        BEGIN
            NEW.updated_at := now();
            RETURN NEW;
        END;
        $body$
    $fn$, l_test_func);

    PERFORM test.has_function('private', l_test_func, 'updated_at trigger function should exist in private schema');

    -- Clean up
    EXECUTE format('DROP FUNCTION private.%I()', l_test_func);
END;
$$;

-- Test: Trigger updates updated_at on INSERT
CREATE OR REPLACE FUNCTION test.test_trigger_031_updated_at_insert()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_upd_ins_' || to_char(clock_timestamp(), 'HH24MISS');
    l_inserted_at timestamptz;
BEGIN
    PERFORM test.set_context('test_trigger_031_updated_at_insert');

    -- Create table and trigger
    EXECUTE format($tbl$
        CREATE TABLE data.%I (
            id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
            name text NOT NULL,
            updated_at timestamptz
        )
    $tbl$, l_test_table);

    EXECUTE format($fn$
        CREATE FUNCTION private.%I_set_updated()
        RETURNS trigger
        LANGUAGE plpgsql
        AS $body$ BEGIN NEW.updated_at := now(); RETURN NEW; END; $body$
    $fn$, l_test_table);

    EXECUTE format($trg$
        CREATE TRIGGER %I_biu_updated_trg
        BEFORE INSERT OR UPDATE ON data.%I
        FOR EACH ROW EXECUTE FUNCTION private.%I_set_updated()
    $trg$, l_test_table, l_test_table, l_test_table);

    -- Insert row (updated_at not provided)
    EXECUTE format('INSERT INTO data.%I (name) VALUES ($1) RETURNING updated_at', l_test_table)
    INTO l_inserted_at
    USING 'Test';

    PERFORM test.is_not_null(l_inserted_at, 'updated_at should be set on INSERT');

    -- Clean up
    EXECUTE format('DROP TABLE data.%I CASCADE', l_test_table);
    EXECUTE format('DROP FUNCTION private.%I_set_updated()', l_test_table);
END;
$$;

-- Test: Trigger updates updated_at on UPDATE
CREATE OR REPLACE FUNCTION test.test_trigger_032_updated_at_update()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_upd_upd_' || to_char(clock_timestamp(), 'HH24MISS');
    l_test_id uuid;
    l_original_at timestamptz;
    l_updated_at timestamptz;
BEGIN
    PERFORM test.set_context('test_trigger_032_updated_at_update');

    -- Create table and trigger
    EXECUTE format($tbl$
        CREATE TABLE data.%I (
            id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
            name text NOT NULL,
            updated_at timestamptz
        )
    $tbl$, l_test_table);

    EXECUTE format($fn$
        CREATE FUNCTION private.%I_set_updated()
        RETURNS trigger
        LANGUAGE plpgsql
        AS $body$ BEGIN NEW.updated_at := clock_timestamp(); RETURN NEW; END; $body$
    $fn$, l_test_table);

    EXECUTE format($trg$
        CREATE TRIGGER %I_biu_updated_trg
        BEFORE INSERT OR UPDATE ON data.%I
        FOR EACH ROW EXECUTE FUNCTION private.%I_set_updated()
    $trg$, l_test_table, l_test_table, l_test_table);

    -- Insert row
    EXECUTE format('INSERT INTO data.%I (name) VALUES ($1) RETURNING id, updated_at', l_test_table)
    INTO l_test_id, l_original_at
    USING 'Test';

    -- Small delay
    PERFORM pg_sleep(0.01);

    -- Update row
    EXECUTE format('UPDATE data.%I SET name = $1 WHERE id = $2 RETURNING updated_at', l_test_table)
    INTO l_updated_at
    USING 'Updated', l_test_id;

    PERFORM test.ok(l_updated_at > l_original_at, 'updated_at should be newer after UPDATE');

    -- Clean up
    EXECUTE format('DROP TABLE data.%I CASCADE', l_test_table);
    EXECUTE format('DROP FUNCTION private.%I_set_updated()', l_test_table);
END;
$$;

-- Test: BEFORE trigger modifies NEW
CREATE OR REPLACE FUNCTION test.test_trigger_033_before_trigger()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_before_' || to_char(clock_timestamp(), 'HH24MISS');
    l_result_name text;
BEGIN
    PERFORM test.set_context('test_trigger_033_before_trigger');

    -- Create table with trigger that uppercases name
    EXECUTE format($tbl$
        CREATE TABLE data.%I (
            id serial PRIMARY KEY,
            name text NOT NULL
        )
    $tbl$, l_test_table);

    EXECUTE format($fn$
        CREATE FUNCTION private.%I_uppercase()
        RETURNS trigger
        LANGUAGE plpgsql
        AS $body$
        BEGIN
            NEW.name := upper(NEW.name);
            RETURN NEW;
        END;
        $body$
    $fn$, l_test_table);

    EXECUTE format($trg$
        CREATE TRIGGER %I_bi_uppercase_trg
        BEFORE INSERT ON data.%I
        FOR EACH ROW EXECUTE FUNCTION private.%I_uppercase()
    $trg$, l_test_table, l_test_table, l_test_table);

    -- Insert lowercase name
    EXECUTE format('INSERT INTO data.%I (name) VALUES ($1) RETURNING name', l_test_table)
    INTO l_result_name
    USING 'lowercase';

    PERFORM test.is(l_result_name, 'LOWERCASE', 'BEFORE trigger should modify NEW.name');

    -- Clean up
    EXECUTE format('DROP TABLE data.%I CASCADE', l_test_table);
    EXECUTE format('DROP FUNCTION private.%I_uppercase()', l_test_table);
END;
$$;

-- Test: Trigger timing - BEFORE vs AFTER
CREATE OR REPLACE FUNCTION test.test_trigger_034_trigger_timing()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_timing_' || to_char(clock_timestamp(), 'HH24MISS');
    l_log_table text := l_test_table || '_log';
    l_log_count integer;
BEGIN
    PERFORM test.set_context('test_trigger_034_trigger_timing');

    -- Create main table
    EXECUTE format('CREATE TABLE data.%I (id serial PRIMARY KEY, name text)', l_test_table);

    -- Create log table for AFTER trigger
    EXECUTE format('CREATE TABLE data.%I (logged_at timestamptz DEFAULT now(), action text)', l_log_table);

    -- Create AFTER trigger that logs
    EXECUTE format($fn$
        CREATE FUNCTION private.%I_log()
        RETURNS trigger
        LANGUAGE plpgsql
        AS $body$
        BEGIN
            INSERT INTO data.%I (action) VALUES (TG_OP);
            RETURN NULL;  -- AFTER triggers return NULL
        END;
        $body$
    $fn$, l_test_table, l_log_table);

    EXECUTE format($trg$
        CREATE TRIGGER %I_ai_log_trg
        AFTER INSERT ON data.%I
        FOR EACH ROW EXECUTE FUNCTION private.%I_log()
    $trg$, l_test_table, l_test_table, l_test_table);

    -- Insert row
    EXECUTE format('INSERT INTO data.%I (name) VALUES ($1)', l_test_table)
    USING 'Test';

    -- Check log
    EXECUTE format('SELECT count(*) FROM data.%I WHERE action = $1', l_log_table)
    INTO l_log_count
    USING 'INSERT';

    PERFORM test.is(l_log_count, 1, 'AFTER INSERT trigger should log action');

    -- Clean up
    EXECUTE format('DROP TABLE data.%I CASCADE', l_test_table);
    EXECUTE format('DROP TABLE data.%I CASCADE', l_log_table);
    EXECUTE format('DROP FUNCTION private.%I_log()', l_test_table);
END;
$$;

-- Test: Trigger on multiple events
CREATE OR REPLACE FUNCTION test.test_trigger_035_multiple_events()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_multi_' || to_char(clock_timestamp(), 'HH24MISS');
    l_insert_op text;
    l_update_op text;
BEGIN
    PERFORM test.set_context('test_trigger_035_multiple_events');

    -- Create table
    EXECUTE format('CREATE TABLE data.%I (id serial PRIMARY KEY, name text, last_op text)', l_test_table);

    -- Create trigger function that records TG_OP
    EXECUTE format($fn$
        CREATE FUNCTION private.%I_record_op()
        RETURNS trigger
        LANGUAGE plpgsql
        AS $body$
        BEGIN
            NEW.last_op := TG_OP;
            RETURN NEW;
        END;
        $body$
    $fn$, l_test_table);

    -- Create trigger for INSERT OR UPDATE
    EXECUTE format($trg$
        CREATE TRIGGER %I_biu_op_trg
        BEFORE INSERT OR UPDATE ON data.%I
        FOR EACH ROW EXECUTE FUNCTION private.%I_record_op()
    $trg$, l_test_table, l_test_table, l_test_table);

    -- Test INSERT - capture the last_op immediately after insert
    EXECUTE format('INSERT INTO data.%I (name) VALUES ($1) RETURNING last_op', l_test_table)
    USING 'Test'
    INTO l_insert_op;

    -- Test UPDATE - insert a new row to update
    EXECUTE format('INSERT INTO data.%I (name) VALUES ($1)', l_test_table)
    USING 'Test2';

    EXECUTE format('UPDATE data.%I SET name = $1 WHERE name = $2 RETURNING last_op', l_test_table)
    USING 'Updated', 'Test2'
    INTO l_update_op;

    -- Check operations were recorded correctly
    PERFORM test.is(l_insert_op, 'INSERT', 'trigger should fire on INSERT');
    PERFORM test.is(l_update_op, 'UPDATE', 'trigger should fire on UPDATE');

    -- Clean up
    EXECUTE format('DROP TABLE data.%I CASCADE', l_test_table);
    EXECUTE format('DROP FUNCTION private.%I_record_op()', l_test_table);
END;
$$;

-- Test: Trigger with condition (WHEN clause)
CREATE OR REPLACE FUNCTION test.test_trigger_036_conditional()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_cond_' || to_char(clock_timestamp(), 'HH24MISS');
    l_trigger_fired boolean;
BEGIN
    PERFORM test.set_context('test_trigger_036_conditional');

    -- Create table
    EXECUTE format($tbl$
        CREATE TABLE data.%I (
            id serial PRIMARY KEY,
            status text,
            trigger_ran boolean DEFAULT false
        )
    $tbl$, l_test_table);

    -- Create conditional trigger (only when status changes to 'active')
    EXECUTE format($fn$
        CREATE FUNCTION private.%I_on_active()
        RETURNS trigger
        LANGUAGE plpgsql
        AS $body$
        BEGIN
            NEW.trigger_ran := true;
            RETURN NEW;
        END;
        $body$
    $fn$, l_test_table);

    EXECUTE format($trg$
        CREATE TRIGGER %I_bu_active_trg
        BEFORE UPDATE ON data.%I
        FOR EACH ROW
        WHEN (OLD.status IS DISTINCT FROM 'active' AND NEW.status = 'active')
        EXECUTE FUNCTION private.%I_on_active()
    $trg$, l_test_table, l_test_table, l_test_table);

    -- Insert row
    EXECUTE format('INSERT INTO data.%I (status) VALUES ($1)', l_test_table)
    USING 'pending';

    -- Update to non-active (trigger should NOT fire)
    EXECUTE format('UPDATE data.%I SET status = $1 RETURNING trigger_ran', l_test_table)
    INTO l_trigger_fired
    USING 'processing';

    PERFORM test.not_ok(l_trigger_fired, 'trigger should NOT fire for non-active status');

    -- Update to active (trigger SHOULD fire)
    EXECUTE format('UPDATE data.%I SET status = $1 RETURNING trigger_ran', l_test_table)
    INTO l_trigger_fired
    USING 'active';

    PERFORM test.ok(l_trigger_fired, 'trigger SHOULD fire when status becomes active');

    -- Clean up
    EXECUTE format('DROP TABLE data.%I CASCADE', l_test_table);
    EXECUTE format('DROP FUNCTION private.%I_on_active()', l_test_table);
END;
$$;

-- ============================================================================
-- RUN TESTS
-- ============================================================================

SELECT test.run_module('trigger_03');
CALL test.print_run_summary();
