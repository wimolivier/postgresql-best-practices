-- ============================================================================
-- BULK OPERATIONS TESTS - UPSERT (ON CONFLICT)
-- ============================================================================
-- Tests for INSERT ... ON CONFLICT (upsert) patterns.
-- Reference: references/bulk-operations.md
-- ============================================================================

-- ============================================================================
-- TEST FUNCTIONS
-- ============================================================================

-- Test: Basic ON CONFLICT DO UPDATE
CREATE OR REPLACE FUNCTION test.test_upsert_130_basic_update()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_upsert_130_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_count integer;
    l_name text;
BEGIN
    PERFORM test.set_context('test_upsert_130_basic_update');

    -- Create table with unique constraint
    EXECUTE format('CREATE TABLE data.%I (
        id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        code text NOT NULL UNIQUE,
        name text NOT NULL,
        updated_count integer NOT NULL DEFAULT 0
    )', l_test_table);

    -- Insert initial row
    EXECUTE format('INSERT INTO data.%I (code, name) VALUES (''ABC'', ''Original Name'')', l_test_table);

    -- Upsert with same code - should update
    EXECUTE format('INSERT INTO data.%I (code, name) VALUES (''ABC'', ''Updated Name'')
        ON CONFLICT (code) DO UPDATE SET
            name = EXCLUDED.name,
            updated_count = data.%I.updated_count + 1', l_test_table, l_test_table);

    -- Verify update happened
    EXECUTE format('SELECT name, updated_count FROM data.%I WHERE code = ''ABC''', l_test_table) INTO l_name, l_count;
    PERFORM test.is(l_name, 'Updated Name', 'Name should be updated');
    PERFORM test.is(l_count, 1, 'Updated count should be 1');

    -- Count total rows (should be 1)
    EXECUTE format('SELECT COUNT(*) FROM data.%I', l_test_table) INTO l_count;
    PERFORM test.is(l_count, 1, 'Should have exactly 1 row');

    -- Cleanup
    EXECUTE format('DROP TABLE data.%I', l_test_table);
END;
$$;

-- Test: ON CONFLICT DO NOTHING
CREATE OR REPLACE FUNCTION test.test_upsert_131_do_nothing()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_upsert_131_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_count integer;
    l_name text;
BEGIN
    PERFORM test.set_context('test_upsert_131_do_nothing');

    -- Create table
    EXECUTE format('CREATE TABLE data.%I (
        id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        code text NOT NULL UNIQUE,
        name text NOT NULL
    )', l_test_table);

    -- Insert initial row
    EXECUTE format('INSERT INTO data.%I (code, name) VALUES (''XYZ'', ''Original'')', l_test_table);

    -- Try to insert duplicate - should do nothing
    EXECUTE format('INSERT INTO data.%I (code, name) VALUES (''XYZ'', ''Duplicate'')
        ON CONFLICT DO NOTHING', l_test_table);

    -- Verify original unchanged
    EXECUTE format('SELECT name FROM data.%I WHERE code = ''XYZ''', l_test_table) INTO l_name;
    PERFORM test.is(l_name, 'Original', 'Original name should be preserved');

    -- Insert new row - should succeed
    EXECUTE format('INSERT INTO data.%I (code, name) VALUES (''NEW'', ''New Row'')
        ON CONFLICT DO NOTHING', l_test_table);

    EXECUTE format('SELECT COUNT(*) FROM data.%I', l_test_table) INTO l_count;
    PERFORM test.is(l_count, 2, 'Should have 2 rows');

    -- Cleanup
    EXECUTE format('DROP TABLE data.%I', l_test_table);
END;
$$;

-- Test: ON CONFLICT with composite unique key
CREATE OR REPLACE FUNCTION test.test_upsert_132_composite_key()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_upsert_132_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_value integer;
BEGIN
    PERFORM test.set_context('test_upsert_132_composite_key');

    -- Create table with composite unique constraint
    EXECUTE format('CREATE TABLE data.%I (
        id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        tenant_id uuid NOT NULL,
        user_id uuid NOT NULL,
        score integer NOT NULL DEFAULT 0,
        UNIQUE (tenant_id, user_id)
    )', l_test_table);

    -- Insert initial row
    EXECUTE format('INSERT INTO data.%I (tenant_id, user_id, score)
        VALUES (''11111111-1111-1111-1111-111111111111'', ''22222222-2222-2222-2222-222222222222'', 100)', l_test_table);

    -- Upsert with same composite key
    EXECUTE format('INSERT INTO data.%I (tenant_id, user_id, score)
        VALUES (''11111111-1111-1111-1111-111111111111'', ''22222222-2222-2222-2222-222222222222'', 50)
        ON CONFLICT (tenant_id, user_id) DO UPDATE SET
            score = data.%I.score + EXCLUDED.score', l_test_table, l_test_table);

    -- Verify score was added
    EXECUTE format('SELECT score FROM data.%I WHERE tenant_id = ''11111111-1111-1111-1111-111111111111''', l_test_table) INTO l_value;
    PERFORM test.is(l_value, 150, 'Score should be sum of both inserts');

    -- Cleanup
    EXECUTE format('DROP TABLE data.%I', l_test_table);
END;
$$;

-- Test: ON CONFLICT with named constraint
CREATE OR REPLACE FUNCTION test.test_upsert_133_named_constraint()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_upsert_133_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_constraint_name text;
    l_count integer;
BEGIN
    PERFORM test.set_context('test_upsert_133_named_constraint');

    l_constraint_name := l_test_table || '_email_uniq';

    -- Create table with named constraint
    EXECUTE format('CREATE TABLE data.%I (
        id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        email text NOT NULL,
        name text NOT NULL,
        CONSTRAINT %I UNIQUE (email)
    )', l_test_table, l_constraint_name);

    -- Insert initial row
    EXECUTE format('INSERT INTO data.%I (email, name) VALUES (''test@example.com'', ''Original'')', l_test_table);

    -- Upsert using constraint name
    EXECUTE format('INSERT INTO data.%I (email, name) VALUES (''test@example.com'', ''Updated'')
        ON CONFLICT ON CONSTRAINT %I DO UPDATE SET name = EXCLUDED.name', l_test_table, l_constraint_name);

    -- Verify update
    EXECUTE format('SELECT COUNT(*) FROM data.%I WHERE name = ''Updated''', l_test_table) INTO l_count;
    PERFORM test.is(l_count, 1, 'Should have updated row');

    -- Cleanup
    EXECUTE format('DROP TABLE data.%I', l_test_table);
END;
$$;

-- Test: ON CONFLICT with WHERE clause (partial unique index)
CREATE OR REPLACE FUNCTION test.test_upsert_134_partial_index()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_upsert_134_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_index_name text;
    l_count integer;
BEGIN
    PERFORM test.set_context('test_upsert_134_partial_index');

    l_index_name := l_test_table || '_active_email_idx';

    -- Create table with partial unique index
    EXECUTE format('CREATE TABLE data.%I (
        id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        email text NOT NULL,
        is_active boolean NOT NULL DEFAULT true
    )', l_test_table);

    EXECUTE format('CREATE UNIQUE INDEX %I ON data.%I (email) WHERE is_active = true', l_index_name, l_test_table);

    -- Insert active user
    EXECUTE format('INSERT INTO data.%I (email, is_active) VALUES (''user@example.com'', true)', l_test_table);

    -- Upsert with partial index predicate
    EXECUTE format('INSERT INTO data.%I (email, is_active) VALUES (''user@example.com'', true)
        ON CONFLICT (email) WHERE is_active = true DO UPDATE SET email = EXCLUDED.email', l_test_table);

    -- Should still have 1 active row
    EXECUTE format('SELECT COUNT(*) FROM data.%I WHERE is_active = true', l_test_table) INTO l_count;
    PERFORM test.is(l_count, 1, 'Should have 1 active row');

    -- Can insert same email as inactive (no conflict)
    EXECUTE format('INSERT INTO data.%I (email, is_active) VALUES (''user@example.com'', false)', l_test_table);

    EXECUTE format('SELECT COUNT(*) FROM data.%I', l_test_table) INTO l_count;
    PERFORM test.is(l_count, 2, 'Should have 2 rows total (active + inactive)');

    -- Cleanup
    EXECUTE format('DROP TABLE data.%I', l_test_table);
END;
$$;

-- Test: RETURNING clause with upsert
CREATE OR REPLACE FUNCTION test.test_upsert_135_returning()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_upsert_135_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_id bigint;
    l_was_inserted boolean;
BEGIN
    PERFORM test.set_context('test_upsert_135_returning');

    -- Create table
    EXECUTE format('CREATE TABLE data.%I (
        id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        code text NOT NULL UNIQUE,
        name text NOT NULL
    )', l_test_table);

    -- Insert and get returned ID
    EXECUTE format('INSERT INTO data.%I (code, name) VALUES (''TEST'', ''Test Name'')
        ON CONFLICT (code) DO UPDATE SET name = EXCLUDED.name
        RETURNING id', l_test_table) INTO l_id;

    PERFORM test.is_not_null(l_id, 'Insert should return ID');

    -- Second upsert should return same ID
    DECLARE
        l_id2 bigint;
    BEGIN
        EXECUTE format('INSERT INTO data.%I (code, name) VALUES (''TEST'', ''Updated Name'')
            ON CONFLICT (code) DO UPDATE SET name = EXCLUDED.name
            RETURNING id', l_test_table) INTO l_id2;

        PERFORM test.is(l_id2, l_id, 'Update should return same ID');
    END;

    -- Cleanup
    EXECUTE format('DROP TABLE data.%I', l_test_table);
END;
$$;

-- Test: Bulk upsert with multiple rows
CREATE OR REPLACE FUNCTION test.test_upsert_136_bulk()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_upsert_136_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_count integer;
    l_sum integer;
BEGIN
    PERFORM test.set_context('test_upsert_136_bulk');

    -- Create table
    EXECUTE format('CREATE TABLE data.%I (
        id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        product_code text NOT NULL UNIQUE,
        quantity integer NOT NULL DEFAULT 0
    )', l_test_table);

    -- Insert initial data
    EXECUTE format('INSERT INTO data.%I (product_code, quantity) VALUES
        (''PROD-A'', 10),
        (''PROD-B'', 20),
        (''PROD-C'', 30)', l_test_table);

    -- Bulk upsert: update existing, insert new
    EXECUTE format('INSERT INTO data.%I (product_code, quantity) VALUES
        (''PROD-A'', 5),   -- exists: add 5
        (''PROD-B'', 10),  -- exists: add 10
        (''PROD-D'', 100)  -- new: insert
        ON CONFLICT (product_code) DO UPDATE SET
            quantity = data.%I.quantity + EXCLUDED.quantity', l_test_table, l_test_table);

    -- Verify counts
    EXECUTE format('SELECT COUNT(*) FROM data.%I', l_test_table) INTO l_count;
    PERFORM test.is(l_count, 4, 'Should have 4 rows total');

    EXECUTE format('SELECT SUM(quantity) FROM data.%I', l_test_table) INTO l_sum;
    PERFORM test.is(l_sum, 175, 'Sum should be 175 (15+30+30+100)');

    -- Cleanup
    EXECUTE format('DROP TABLE data.%I', l_test_table);
END;
$$;

-- Test: Upsert with EXCLUDED values
CREATE OR REPLACE FUNCTION test.test_upsert_137_excluded()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_upsert_137_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_record RECORD;
BEGIN
    PERFORM test.set_context('test_upsert_137_excluded');

    -- Create table with audit columns
    EXECUTE format('CREATE TABLE data.%I (
        id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        key text NOT NULL UNIQUE,
        value text NOT NULL,
        created_at timestamptz NOT NULL DEFAULT now(),
        updated_at timestamptz NOT NULL DEFAULT now(),
        version integer NOT NULL DEFAULT 1
    )', l_test_table);

    -- Insert initial row
    EXECUTE format('INSERT INTO data.%I (key, value) VALUES (''config'', ''initial'')', l_test_table);

    -- Small delay to ensure timestamp difference
    PERFORM pg_sleep(0.05);

    -- Upsert using EXCLUDED
    EXECUTE format('INSERT INTO data.%I (key, value) VALUES (''config'', ''updated'')
        ON CONFLICT (key) DO UPDATE SET
            value = EXCLUDED.value,
            updated_at = now(),
            version = data.%I.version + 1
        -- Note: created_at is NOT updated (preserves original)', l_test_table, l_test_table);

    -- Verify
    EXECUTE format('SELECT * FROM data.%I WHERE key = ''config''', l_test_table) INTO l_record;
    PERFORM test.is(l_record.value, 'updated', 'Value should be updated');
    PERFORM test.is(l_record.version, 2, 'Version should be incremented');
    PERFORM test.ok(l_record.updated_at >= l_record.created_at, 'updated_at should be >= created_at');

    -- Cleanup
    EXECUTE format('DROP TABLE data.%I', l_test_table);
END;
$$;

-- Test: Upsert with conditional update
CREATE OR REPLACE FUNCTION test.test_upsert_138_conditional()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_upsert_138_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_value text;
BEGIN
    PERFORM test.set_context('test_upsert_138_conditional');

    -- Create table
    EXECUTE format('CREATE TABLE data.%I (
        id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        key text NOT NULL UNIQUE,
        value text NOT NULL,
        priority integer NOT NULL DEFAULT 0
    )', l_test_table);

    -- Insert with priority 10
    EXECUTE format('INSERT INTO data.%I (key, value, priority) VALUES (''item'', ''high-priority'', 10)', l_test_table);

    -- Try to upsert with lower priority - should not update value
    EXECUTE format('INSERT INTO data.%I (key, value, priority) VALUES (''item'', ''low-priority'', 5)
        ON CONFLICT (key) DO UPDATE SET
            value = EXCLUDED.value,
            priority = EXCLUDED.priority
        WHERE EXCLUDED.priority > data.%I.priority', l_test_table, l_test_table);

    -- Verify value unchanged (lower priority was ignored)
    EXECUTE format('SELECT value FROM data.%I WHERE key = ''item''', l_test_table) INTO l_value;
    PERFORM test.is(l_value, 'high-priority', 'Value should not change for lower priority');

    -- Try with higher priority - should update
    EXECUTE format('INSERT INTO data.%I (key, value, priority) VALUES (''item'', ''highest-priority'', 20)
        ON CONFLICT (key) DO UPDATE SET
            value = EXCLUDED.value,
            priority = EXCLUDED.priority
        WHERE EXCLUDED.priority > data.%I.priority', l_test_table, l_test_table);

    EXECUTE format('SELECT value FROM data.%I WHERE key = ''item''', l_test_table) INTO l_value;
    PERFORM test.is(l_value, 'highest-priority', 'Value should update for higher priority');

    -- Cleanup
    EXECUTE format('DROP TABLE data.%I', l_test_table);
END;
$$;

-- Test: Upsert counting inserted vs updated
CREATE OR REPLACE FUNCTION test.test_upsert_139_xmax_detection()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_upsert_139_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_inserted integer;
    l_updated integer;
BEGIN
    PERFORM test.set_context('test_upsert_139_xmax_detection');

    -- Create table
    EXECUTE format('CREATE TABLE data.%I (
        id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        code text NOT NULL UNIQUE,
        name text NOT NULL
    )', l_test_table);

    -- Insert initial data
    EXECUTE format('INSERT INTO data.%I (code, name) VALUES
        (''A'', ''Alpha''),
        (''B'', ''Beta'')', l_test_table);

    -- Bulk upsert and detect what was inserted vs updated using xmax
    -- xmax = 0 means newly inserted, xmax <> 0 means updated
    EXECUTE format('WITH upserted AS (
        INSERT INTO data.%I (code, name) VALUES
            (''A'', ''Alpha Updated''),  -- update
            (''C'', ''Charlie''),        -- insert
            (''D'', ''Delta'')           -- insert
        ON CONFLICT (code) DO UPDATE SET name = EXCLUDED.name
        RETURNING xmax
    )
    SELECT
        COUNT(*) FILTER (WHERE xmax::text::bigint = 0),
        COUNT(*) FILTER (WHERE xmax::text::bigint <> 0)
    FROM upserted', l_test_table) INTO l_inserted, l_updated;

    PERFORM test.is(l_inserted, 2, 'Should have inserted 2 rows');
    PERFORM test.is(l_updated, 1, 'Should have updated 1 row');

    -- Cleanup
    EXECUTE format('DROP TABLE data.%I', l_test_table);
END;
$$;

-- ============================================================================
-- RUN TESTS
-- ============================================================================

SELECT test.run_module('upsert_13');
CALL test.print_run_summary();
