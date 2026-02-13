-- ============================================================================
-- MIGRATION SYSTEM TESTS - IDEMPOTENT CONSTRAINT CREATION
-- ============================================================================
-- Tests for idempotent constraint creation patterns documented in
-- migrations.md §Idempotent Constraint Creation:
-- 1. Idempotent UNIQUE constraint via pg_constraint check
-- 2. Idempotent FOREIGN KEY constraint
-- 3. Idempotent CHECK constraint
-- 4. Constraint inspection query
-- Reference: references/migrations.md §Idempotent Constraint Creation
-- ============================================================================

-- ============================================================================
-- TEST FUNCTIONS
-- ============================================================================

-- Test: Idempotent UNIQUE constraint can be run twice without error
CREATE OR REPLACE FUNCTION test.test_migration_090_idempotent_unique()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_idem_uk_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_constraint_name text;
    l_constraint_count integer;
BEGIN
    PERFORM test.set_context('test_migration_090_idempotent_unique');

    -- Create table
    EXECUTE format('CREATE TABLE data.%I (
        id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        email text NOT NULL
    )', l_test_table);

    l_constraint_name := l_test_table || '_email_uk';

    -- Run idempotent UNIQUE constraint creation (first time — creates it)
    -- Note: use $idem$...$idem$ to avoid dollar-quote collision with outer $$
    EXECUTE format($do$
        DO $idem$
        BEGIN
            IF NOT EXISTS (
                SELECT 1 FROM pg_constraint
                WHERE conname = %L
                  AND conrelid = %L::regclass
            ) THEN
                ALTER TABLE data.%I
                    ADD CONSTRAINT %I UNIQUE (email);
            END IF;
        END $idem$;
    $do$, l_constraint_name, 'data.' || l_test_table, l_test_table, l_constraint_name);

    -- Verify constraint exists
    SELECT count(*) INTO l_constraint_count
    FROM pg_constraint
    WHERE conname = l_constraint_name
      AND conrelid = ('data.' || l_test_table)::regclass;

    PERFORM test.is(l_constraint_count, 1, 'UNIQUE constraint should exist after first run');

    -- Run same idempotent block again (second time — should skip without error)
    PERFORM test.lives_ok(
        format($do$
            DO $idem$
            BEGIN
                IF NOT EXISTS (
                    SELECT 1 FROM pg_constraint
                    WHERE conname = %L
                      AND conrelid = %L::regclass
                ) THEN
                    ALTER TABLE data.%I
                        ADD CONSTRAINT %I UNIQUE (email);
                END IF;
            END $idem$;
        $do$, l_constraint_name, 'data.' || l_test_table, l_test_table, l_constraint_name),
        'Idempotent UNIQUE should not error on second run'
    );

    -- Still exactly 1 constraint
    SELECT count(*) INTO l_constraint_count
    FROM pg_constraint
    WHERE conname = l_constraint_name
      AND conrelid = ('data.' || l_test_table)::regclass;

    PERFORM test.is(l_constraint_count, 1, 'Should still have exactly 1 UNIQUE constraint');

    -- Clean up
    EXECUTE format('DROP TABLE data.%I CASCADE', l_test_table);
END;
$$;

-- Test: Idempotent FOREIGN KEY constraint can be run twice without error
CREATE OR REPLACE FUNCTION test.test_migration_091_idempotent_fk()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_parent_table text := 'test_idem_fk_p_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_child_table text := 'test_idem_fk_c_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_constraint_name text;
    l_constraint_count integer;
    l_contype text;
BEGIN
    PERFORM test.set_context('test_migration_091_idempotent_fk');

    -- Create parent and child tables
    EXECUTE format('CREATE TABLE data.%I (
        id uuid PRIMARY KEY DEFAULT gen_random_uuid()
    )', l_parent_table);

    EXECUTE format('CREATE TABLE data.%I (
        id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        parent_id uuid NOT NULL
    )', l_child_table);

    l_constraint_name := l_child_table || '_parent_fk';

    -- First run: create FK
    EXECUTE format($do$
        DO $idem$
        BEGIN
            IF NOT EXISTS (
                SELECT 1 FROM pg_constraint
                WHERE conname = %L
                  AND conrelid = %L::regclass
            ) THEN
                ALTER TABLE data.%I
                    ADD CONSTRAINT %I
                    FOREIGN KEY (parent_id) REFERENCES data.%I(id);
            END IF;
        END $idem$;
    $do$, l_constraint_name, 'data.' || l_child_table, l_child_table, l_constraint_name, l_parent_table);

    -- Verify FK exists and is type 'f'
    SELECT contype::text INTO l_contype
    FROM pg_constraint
    WHERE conname = l_constraint_name
      AND conrelid = ('data.' || l_child_table)::regclass;

    PERFORM test.is(l_contype, 'f', 'Constraint should be FOREIGN KEY type');

    -- Second run: should skip without error
    PERFORM test.lives_ok(
        format($do$
            DO $idem$
            BEGIN
                IF NOT EXISTS (
                    SELECT 1 FROM pg_constraint
                    WHERE conname = %L
                      AND conrelid = %L::regclass
                ) THEN
                    ALTER TABLE data.%I
                        ADD CONSTRAINT %I
                        FOREIGN KEY (parent_id) REFERENCES data.%I(id);
                END IF;
            END $idem$;
        $do$, l_constraint_name, 'data.' || l_child_table, l_child_table, l_constraint_name, l_parent_table),
        'Idempotent FK should not error on second run'
    );

    -- Clean up
    EXECUTE format('DROP TABLE data.%I CASCADE', l_child_table);
    EXECUTE format('DROP TABLE data.%I CASCADE', l_parent_table);
END;
$$;

-- Test: Idempotent CHECK constraint can be run twice without error
CREATE OR REPLACE FUNCTION test.test_migration_092_idempotent_check()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_idem_ck_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_constraint_name text;
    l_contype text;
BEGIN
    PERFORM test.set_context('test_migration_092_idempotent_check');

    -- Create table
    EXECUTE format('CREATE TABLE data.%I (
        id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        total numeric(12,2) NOT NULL
    )', l_test_table);

    l_constraint_name := l_test_table || '_total_ck';

    -- First run: create CHECK constraint
    EXECUTE format($do$
        DO $idem$
        BEGIN
            IF NOT EXISTS (
                SELECT 1 FROM pg_constraint
                WHERE conname = %L
            ) THEN
                ALTER TABLE data.%I
                    ADD CONSTRAINT %I CHECK (total >= 0);
            END IF;
        END $idem$;
    $do$, l_constraint_name, l_test_table, l_constraint_name);

    -- Verify CHECK exists and is type 'c'
    SELECT contype::text INTO l_contype
    FROM pg_constraint
    WHERE conname = l_constraint_name;

    PERFORM test.is(l_contype, 'c', 'Constraint should be CHECK type');

    -- Verify constraint actually works
    PERFORM test.throws_ok(
        format('INSERT INTO data.%I (total) VALUES (-1)', l_test_table),
        '23514',  -- check_violation
        'CHECK constraint should reject negative totals'
    );

    -- Second run: should skip without error
    PERFORM test.lives_ok(
        format($do$
            DO $idem$
            BEGIN
                IF NOT EXISTS (
                    SELECT 1 FROM pg_constraint
                    WHERE conname = %L
                ) THEN
                    ALTER TABLE data.%I
                        ADD CONSTRAINT %I CHECK (total >= 0);
                END IF;
            END $idem$;
        $do$, l_constraint_name, l_test_table, l_constraint_name),
        'Idempotent CHECK should not error on second run'
    );

    -- Clean up
    EXECUTE format('DROP TABLE data.%I CASCADE', l_test_table);
END;
$$;

-- Test: Constraint inspection query returns correct types
CREATE OR REPLACE FUNCTION test.test_migration_093_constraint_inspection()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_idem_insp_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_pk_count integer;
    l_uk_count integer;
    l_ck_count integer;
    l_total_count integer;
BEGIN
    PERFORM test.set_context('test_migration_093_constraint_inspection');

    -- Create table with multiple constraint types
    EXECUTE format('CREATE TABLE data.%I (
        id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        email text NOT NULL,
        total numeric(12,2) NOT NULL,
        CONSTRAINT %I UNIQUE (email),
        CONSTRAINT %I CHECK (total >= 0)
    )', l_test_table, l_test_table || '_email_uk', l_test_table || '_total_ck');

    -- Inspect constraints using the documented query pattern
    SELECT count(*) INTO l_pk_count
    FROM pg_constraint
    WHERE conrelid = ('data.' || l_test_table)::regclass AND contype = 'p';

    SELECT count(*) INTO l_uk_count
    FROM pg_constraint
    WHERE conrelid = ('data.' || l_test_table)::regclass AND contype = 'u';

    SELECT count(*) INTO l_ck_count
    FROM pg_constraint
    WHERE conrelid = ('data.' || l_test_table)::regclass AND contype = 'c';

    SELECT count(*) INTO l_total_count
    FROM pg_constraint
    WHERE conrelid = ('data.' || l_test_table)::regclass;

    PERFORM test.is(l_pk_count, 1, 'Should find 1 PRIMARY KEY (contype=p)');
    PERFORM test.is(l_uk_count, 1, 'Should find 1 UNIQUE (contype=u)');
    PERFORM test.is(l_ck_count, 1, 'Should find 1 CHECK (contype=c)');
    -- PG18+ creates explicit NOT NULL constraints (contype=n) for each NOT NULL column
    -- so total = 1 PK + 1 UNIQUE + 1 CHECK + 3 NOT NULL (id, email, total) = 6
    PERFORM test.is(l_total_count, 6, 'Should find 6 total constraints (incl. PG18 NOT NULL)');

    -- Verify pg_get_constraintdef returns readable definition
    PERFORM test.isnt_empty(
        format('SELECT pg_get_constraintdef(oid) FROM pg_constraint
            WHERE conrelid = %L::regclass AND contype = ''c''', 'data.' || l_test_table),
        'pg_get_constraintdef should return CHECK definition'
    );

    -- Clean up
    EXECUTE format('DROP TABLE data.%I CASCADE', l_test_table);
END;
$$;

-- Test: Non-idempotent ADD CONSTRAINT fails on second run (demonstrates the problem)
CREATE OR REPLACE FUNCTION test.test_migration_094_non_idempotent_fails()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_idem_fail_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_constraint_name text;
BEGIN
    PERFORM test.set_context('test_migration_094_non_idempotent_fails');

    -- Create table
    EXECUTE format('CREATE TABLE data.%I (
        id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        email text NOT NULL
    )', l_test_table);

    l_constraint_name := l_test_table || '_email_uk';

    -- First run succeeds
    EXECUTE format('ALTER TABLE data.%I ADD CONSTRAINT %I UNIQUE (email)',
        l_test_table, l_constraint_name);

    -- Second run FAILS (this is the problem the idempotent pattern solves)
    -- PG18 raises 42P07 (duplicate_table) because the underlying index already exists
    PERFORM test.throws_ok(
        format('ALTER TABLE data.%I ADD CONSTRAINT %I UNIQUE (email)',
            l_test_table, l_constraint_name),
        '42P07',  -- duplicate_table (underlying index already exists)
        'Non-idempotent ADD CONSTRAINT should fail on duplicate'
    );

    -- Clean up
    EXECUTE format('DROP TABLE data.%I CASCADE', l_test_table);
END;
$$;

-- ============================================================================
-- RUN TESTS
-- ============================================================================

SELECT test.run_module('migration_09');
CALL test.print_run_summary();
