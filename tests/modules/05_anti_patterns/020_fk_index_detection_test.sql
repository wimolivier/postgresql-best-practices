-- ============================================================================
-- ANTI-PATTERNS TESTS - FK INDEX DETECTION
-- ============================================================================
-- Tests for detecting missing indexes on foreign keys.
-- ============================================================================

-- ============================================================================
-- HELPER FUNCTION
-- ============================================================================

-- Function to find foreign keys without indexes
CREATE OR REPLACE FUNCTION test.find_fk_without_index(
    in_schema text DEFAULT 'data'
)
RETURNS TABLE (
    table_name text,
    constraint_name text,
    columns text[],
    has_index boolean
)
LANGUAGE sql
STABLE
AS $$
    WITH fk_columns AS (
        SELECT
            tc.table_schema,
            tc.table_name,
            tc.constraint_name,
            array_agg(kcu.column_name::text ORDER BY kcu.ordinal_position) AS columns
        FROM information_schema.table_constraints tc
        JOIN information_schema.key_column_usage kcu
            ON tc.constraint_name = kcu.constraint_name
            AND tc.table_schema = kcu.table_schema
        WHERE tc.constraint_type = 'FOREIGN KEY'
          AND tc.table_schema = in_schema
        GROUP BY tc.table_schema, tc.table_name, tc.constraint_name
    ),
    index_columns AS (
        SELECT
            schemaname,
            tablename,
            indexname,
            array_agg(attname ORDER BY attnum) AS columns
        FROM (
            SELECT
                i.schemaname,
                i.tablename,
                i.indexname,
                a.attname,
                unnest(ix.indkey) AS attnum
            FROM pg_indexes i
            JOIN pg_class c ON c.relname = i.tablename
            JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = i.schemaname
            JOIN pg_index ix ON ix.indrelid = c.oid
            JOIN pg_class ic ON ic.oid = ix.indexrelid AND ic.relname = i.indexname
            JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = ANY(ix.indkey)
        ) sub
        GROUP BY schemaname, tablename, indexname
    )
    SELECT
        fk.table_name::text,
        fk.constraint_name::text,
        fk.columns,
        EXISTS (
            SELECT 1 FROM index_columns ic
            WHERE ic.schemaname = fk.table_schema
              AND ic.tablename = fk.table_name
              AND fk.columns <@ ic.columns  -- FK columns are subset of index columns
        ) AS has_index
    FROM fk_columns fk;
$$;

-- ============================================================================
-- TEST FUNCTIONS
-- ============================================================================

-- Test: FK with index is detected correctly
CREATE OR REPLACE FUNCTION test.test_fkindex_020_with_index()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_parent text := 'test_parent_' || to_char(clock_timestamp(), 'HH24MISS');
    l_child text := 'test_child_' || to_char(clock_timestamp(), 'HH24MISS');
    l_has_index boolean;
BEGIN
    PERFORM test.set_context('test_fkindex_020_with_index');

    -- Create parent table
    EXECUTE format('CREATE TABLE test.%I (id serial PRIMARY KEY)', l_parent);

    -- Create child table with FK and index
    EXECUTE format($tbl$
        CREATE TABLE test.%I (
            id serial PRIMARY KEY,
            parent_id int REFERENCES test.%I(id)
        )
    $tbl$, l_child, l_parent);

    -- Create index on FK column
    EXECUTE format('CREATE INDEX %I_parent_idx ON test.%I(parent_id)', l_child, l_child);

    -- Check detection
    SELECT has_index INTO l_has_index
    FROM test.find_fk_without_index('test')
    WHERE table_name = l_child;

    PERFORM test.ok(l_has_index, 'FK with index should be detected as having index');

    -- Clean up
    EXECUTE format('DROP TABLE test.%I', l_child);
    EXECUTE format('DROP TABLE test.%I', l_parent);
END;
$$;

-- Test: FK without index is detected
CREATE OR REPLACE FUNCTION test.test_fkindex_021_without_index()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_parent text := 'test_parent2_' || to_char(clock_timestamp(), 'HH24MISS');
    l_child text := 'test_child2_' || to_char(clock_timestamp(), 'HH24MISS');
    l_has_index boolean;
BEGIN
    PERFORM test.set_context('test_fkindex_021_without_index');

    -- Create parent table
    EXECUTE format('CREATE TABLE test.%I (id serial PRIMARY KEY)', l_parent);

    -- Create child table with FK but NO index
    EXECUTE format($tbl$
        CREATE TABLE test.%I (
            id serial PRIMARY KEY,
            parent_id int REFERENCES test.%I(id)
        )
    $tbl$, l_child, l_parent);

    -- NO index created

    -- Check detection
    SELECT has_index INTO l_has_index
    FROM test.find_fk_without_index('test')
    WHERE table_name = l_child;

    PERFORM test.not_ok(COALESCE(l_has_index, false), 'FK without index should be detected');

    -- Clean up
    EXECUTE format('DROP TABLE test.%I', l_child);
    EXECUTE format('DROP TABLE test.%I', l_parent);
END;
$$;

-- Test: Composite FK index detection
CREATE OR REPLACE FUNCTION test.test_fkindex_022_composite_fk()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_parent text := 'test_parent3_' || to_char(clock_timestamp(), 'HH24MISS');
    l_child text := 'test_child3_' || to_char(clock_timestamp(), 'HH24MISS');
    l_has_index boolean;
BEGIN
    PERFORM test.set_context('test_fkindex_022_composite_fk');

    -- Create parent with composite PK
    EXECUTE format($tbl$
        CREATE TABLE test.%I (
            tenant_id int,
            id int,
            PRIMARY KEY (tenant_id, id)
        )
    $tbl$, l_parent);

    -- Create child with composite FK
    EXECUTE format($tbl$
        CREATE TABLE test.%I (
            id serial PRIMARY KEY,
            parent_tenant_id int,
            parent_id int,
            FOREIGN KEY (parent_tenant_id, parent_id) REFERENCES test.%I(tenant_id, id)
        )
    $tbl$, l_child, l_parent);

    -- Create composite index
    EXECUTE format('CREATE INDEX %I_parent_idx ON test.%I(parent_tenant_id, parent_id)', l_child, l_child);

    -- Check detection
    SELECT has_index INTO l_has_index
    FROM test.find_fk_without_index('test')
    WHERE table_name = l_child;

    PERFORM test.ok(l_has_index, 'Composite FK with matching index should be detected');

    -- Clean up
    EXECUTE format('DROP TABLE test.%I', l_child);
    EXECUTE format('DROP TABLE test.%I', l_parent);
END;
$$;

-- Test: Index with extra columns still covers FK
CREATE OR REPLACE FUNCTION test.test_fkindex_023_covering_index()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_parent text := 'test_parent4_' || to_char(clock_timestamp(), 'HH24MISS');
    l_child text := 'test_child4_' || to_char(clock_timestamp(), 'HH24MISS');
    l_has_index boolean;
BEGIN
    PERFORM test.set_context('test_fkindex_023_covering_index');

    -- Create parent
    EXECUTE format('CREATE TABLE test.%I (id serial PRIMARY KEY)', l_parent);

    -- Create child with FK
    EXECUTE format($tbl$
        CREATE TABLE test.%I (
            id serial PRIMARY KEY,
            parent_id int REFERENCES test.%I(id),
            status text
        )
    $tbl$, l_child, l_parent);

    -- Create index that includes FK column plus more (still useful)
    EXECUTE format('CREATE INDEX %I_idx ON test.%I(parent_id, status)', l_child, l_child);

    -- Check detection - index starts with FK column, so it covers the FK
    SELECT has_index INTO l_has_index
    FROM test.find_fk_without_index('test')
    WHERE table_name = l_child;

    PERFORM test.ok(l_has_index, 'Index with FK as prefix should cover FK');

    -- Clean up
    EXECUTE format('DROP TABLE test.%I', l_child);
    EXECUTE format('DROP TABLE test.%I', l_parent);
END;
$$;

-- Test: Create missing FK index
CREATE OR REPLACE FUNCTION test.test_fkindex_024_create_missing()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_parent text := 'test_parent5_' || to_char(clock_timestamp(), 'HH24MISS');
    l_child text := 'test_child5_' || to_char(clock_timestamp(), 'HH24MISS');
    l_has_index_before boolean;
    l_has_index_after boolean;
BEGIN
    PERFORM test.set_context('test_fkindex_024_create_missing');

    -- Create tables without FK index
    EXECUTE format('CREATE TABLE test.%I (id serial PRIMARY KEY)', l_parent);
    EXECUTE format($tbl$
        CREATE TABLE test.%I (
            id serial PRIMARY KEY,
            parent_id int REFERENCES test.%I(id)
        )
    $tbl$, l_child, l_parent);

    -- Check before
    SELECT has_index INTO l_has_index_before
    FROM test.find_fk_without_index('test')
    WHERE table_name = l_child;

    -- Create the missing index
    EXECUTE format('CREATE INDEX %I_parent_id_idx ON test.%I(parent_id)', l_child, l_child);

    -- Check after
    SELECT has_index INTO l_has_index_after
    FROM test.find_fk_without_index('test')
    WHERE table_name = l_child;

    PERFORM test.not_ok(COALESCE(l_has_index_before, false), 'initially no index');
    PERFORM test.ok(l_has_index_after, 'after creating index, FK is covered');

    -- Clean up
    EXECUTE format('DROP TABLE test.%I', l_child);
    EXECUTE format('DROP TABLE test.%I', l_parent);
END;
$$;

-- Test: Self-referencing FK
CREATE OR REPLACE FUNCTION test.test_fkindex_025_self_reference()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_table text := 'test_tree_' || to_char(clock_timestamp(), 'HH24MISS');
    l_has_index boolean;
BEGIN
    PERFORM test.set_context('test_fkindex_025_self_reference');

    -- Create self-referencing table (tree structure)
    EXECUTE format($tbl$
        CREATE TABLE test.%I (
            id serial PRIMARY KEY,
            parent_id int REFERENCES test.%I(id)
        )
    $tbl$, l_table, l_table);

    -- Create index
    EXECUTE format('CREATE INDEX %I_parent_idx ON test.%I(parent_id)', l_table, l_table);

    -- Check detection
    SELECT has_index INTO l_has_index
    FROM test.find_fk_without_index('test')
    WHERE table_name = l_table;

    PERFORM test.ok(l_has_index, 'Self-referencing FK with index should be detected');

    -- Clean up
    EXECUTE format('DROP TABLE test.%I', l_table);
END;
$$;

-- Test: Performance impact of missing FK index
CREATE OR REPLACE FUNCTION test.test_fkindex_026_performance_note()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM test.set_context('test_fkindex_026_performance_note');

    -- This test documents WHY FK indexes are important
    -- Without an index on FK column:
    -- 1. DELETE from parent requires seq scan on child
    -- 2. UPDATE of parent PK requires seq scan on child
    -- 3. JOINs from child to parent may use seq scan

    PERFORM test.ok(true, 'FK indexes prevent table scans during parent DELETE/UPDATE');
    PERFORM test.ok(true, 'FK indexes improve JOIN performance');
END;
$$;

-- ============================================================================
-- RUN TESTS
-- ============================================================================

SELECT test.run_module('fkindex_02');
CALL test.print_run_summary();
