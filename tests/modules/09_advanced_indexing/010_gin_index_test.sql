-- ============================================================================
-- ADVANCED INDEXING TESTS - GIN INDEXES
-- ============================================================================
-- Tests for GIN (Generalized Inverted Index) on arrays, JSONB, and full-text.
-- Reference: references/indexes-constraints.md
-- ============================================================================

-- ============================================================================
-- TEST FUNCTIONS
-- ============================================================================

-- Test: GIN index on array column
CREATE OR REPLACE FUNCTION test.test_gin_090_array_index()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_gin_090_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_index_name text;
BEGIN
    PERFORM test.set_context('test_gin_090_array_index');

    -- Create table with array column
    EXECUTE format('CREATE TABLE data.%I (
        id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        tags text[] NOT NULL DEFAULT ''{}''
    )', l_test_table);

    -- Create GIN index on array
    l_index_name := l_test_table || '_tags_gin_idx';
    EXECUTE format('CREATE INDEX %I ON data.%I USING gin (tags)', l_index_name, l_test_table);

    -- Verify index exists and is GIN type
    PERFORM test.has_index('data', l_test_table, l_index_name, 'GIN index on tags should exist');

    -- Cleanup
    EXECUTE format('DROP TABLE data.%I', l_test_table);
END;
$$;

-- Test: GIN index supports array containment queries
CREATE OR REPLACE FUNCTION test.test_gin_091_array_containment()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_gin_091_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_count integer;
BEGIN
    PERFORM test.set_context('test_gin_091_array_containment');

    -- Create table with array column and GIN index
    EXECUTE format('CREATE TABLE data.%I (
        id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        tags text[] NOT NULL DEFAULT ''{}''
    )', l_test_table);
    EXECUTE format('CREATE INDEX ON data.%I USING gin (tags)', l_test_table);

    -- Insert test data
    EXECUTE format('INSERT INTO data.%I (tags) VALUES
        (ARRAY[''postgres'', ''database'']),
        (ARRAY[''mysql'', ''database'']),
        (ARRAY[''postgres'', ''timescaledb'']),
        (ARRAY[''redis'', ''cache''])', l_test_table);

    -- Test @> (contains)
    EXECUTE format('SELECT COUNT(*) FROM data.%I WHERE tags @> ARRAY[''postgres'']', l_test_table) INTO l_count;
    PERFORM test.is(l_count, 2, '@> should find rows containing postgres');

    -- Test && (overlaps)
    EXECUTE format('SELECT COUNT(*) FROM data.%I WHERE tags && ARRAY[''database'', ''cache'']', l_test_table) INTO l_count;
    PERFORM test.is(l_count, 3, '&& should find rows with any matching tag');

    -- Test <@ (is contained by)
    EXECUTE format('SELECT COUNT(*) FROM data.%I WHERE tags <@ ARRAY[''postgres'', ''database'', ''extra'']', l_test_table) INTO l_count;
    PERFORM test.is(l_count, 1, '<@ should find rows fully contained');

    -- Cleanup
    EXECUTE format('DROP TABLE data.%I', l_test_table);
END;
$$;

-- Test: GIN index on JSONB column
CREATE OR REPLACE FUNCTION test.test_gin_092_jsonb_index()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_gin_092_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_index_name text;
BEGIN
    PERFORM test.set_context('test_gin_092_jsonb_index');

    -- Create table with JSONB column
    EXECUTE format('CREATE TABLE data.%I (
        id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        attributes jsonb NOT NULL DEFAULT ''{}''
    )', l_test_table);

    -- Create GIN index on JSONB
    l_index_name := l_test_table || '_attrs_gin_idx';
    EXECUTE format('CREATE INDEX %I ON data.%I USING gin (attributes)', l_index_name, l_test_table);

    -- Verify index exists
    PERFORM test.has_index('data', l_test_table, l_index_name, 'GIN index on JSONB should exist');

    -- Cleanup
    EXECUTE format('DROP TABLE data.%I', l_test_table);
END;
$$;

-- Test: GIN JSONB containment queries
CREATE OR REPLACE FUNCTION test.test_gin_093_jsonb_containment()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_gin_093_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_count integer;
BEGIN
    PERFORM test.set_context('test_gin_093_jsonb_containment');

    -- Create table with JSONB and GIN index
    EXECUTE format('CREATE TABLE data.%I (
        id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        data jsonb NOT NULL DEFAULT ''{}''
    )', l_test_table);
    EXECUTE format('CREATE INDEX ON data.%I USING gin (data)', l_test_table);

    -- Insert test data using parameterized values
    EXECUTE format('INSERT INTO data.%I (data) VALUES ($1), ($2), ($3), ($4)', l_test_table)
    USING
        '{"type": "user", "status": "active", "roles": ["admin", "editor"]}'::jsonb,
        '{"type": "user", "status": "inactive", "roles": ["viewer"]}'::jsonb,
        '{"type": "service", "status": "active", "roles": []}'::jsonb,
        '{"type": "user", "status": "active", "region": "us-east"}'::jsonb;

    -- Test @> (contains)
    EXECUTE format('SELECT COUNT(*) FROM data.%I WHERE data @> $1', l_test_table)
        INTO l_count USING '{"type": "user"}'::jsonb;
    PERFORM test.is(l_count, 3, '@> should find all users');

    EXECUTE format('SELECT COUNT(*) FROM data.%I WHERE data @> $1', l_test_table)
        INTO l_count USING '{"type": "user", "status": "active"}'::jsonb;
    PERFORM test.is(l_count, 2, '@> should find active users');

    -- Test ? (key exists)
    EXECUTE format('SELECT COUNT(*) FROM data.%I WHERE data ? ''region''', l_test_table) INTO l_count;
    PERFORM test.is(l_count, 1, '? should find rows with region key');

    -- Cleanup
    EXECUTE format('DROP TABLE data.%I', l_test_table);
END;
$$;

-- Test: GIN jsonb_path_ops for containment-only queries
CREATE OR REPLACE FUNCTION test.test_gin_094_jsonb_path_ops()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_gin_094_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_index_name text;
    l_count integer;
BEGIN
    PERFORM test.set_context('test_gin_094_jsonb_path_ops');

    -- Create table with JSONB
    EXECUTE format('CREATE TABLE data.%I (
        id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        config jsonb NOT NULL DEFAULT ''{}''
    )', l_test_table);

    -- Create GIN index with jsonb_path_ops (smaller, faster for @> only)
    l_index_name := l_test_table || '_config_pathops_idx';
    EXECUTE format('CREATE INDEX %I ON data.%I USING gin (config jsonb_path_ops)', l_index_name, l_test_table);

    -- Insert test data using parameterized values
    EXECUTE format('INSERT INTO data.%I (config) VALUES ($1), ($2), ($3)', l_test_table)
    USING
        '{"database": {"host": "localhost", "port": 5432}}'::jsonb,
        '{"database": {"host": "remote", "port": 5432}}'::jsonb,
        '{"cache": {"host": "localhost", "port": 6379}}'::jsonb;

    -- Test @> containment (supported)
    EXECUTE format('SELECT COUNT(*) FROM data.%I WHERE config @> $1', l_test_table)
        INTO l_count USING '{"database": {"port": 5432}}'::jsonb;
    PERFORM test.is(l_count, 2, 'jsonb_path_ops should support nested containment');

    -- Verify index exists
    PERFORM test.has_index('data', l_test_table, l_index_name, 'jsonb_path_ops index should exist');

    -- Cleanup
    EXECUTE format('DROP TABLE data.%I', l_test_table);
END;
$$;

-- Test: GIN index on tsvector for full-text search
CREATE OR REPLACE FUNCTION test.test_gin_095_tsvector_index()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_gin_095_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_index_name text;
BEGIN
    PERFORM test.set_context('test_gin_095_tsvector_index');

    -- Create table with tsvector column
    EXECUTE format('CREATE TABLE data.%I (
        id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        title text NOT NULL,
        body text,
        search_vector tsvector GENERATED ALWAYS AS (
            setweight(to_tsvector(''english'', coalesce(title, '''')), ''A'') ||
            setweight(to_tsvector(''english'', coalesce(body, '''')), ''B'')
        ) STORED
    )', l_test_table);

    -- Create GIN index on tsvector
    l_index_name := l_test_table || '_search_gin_idx';
    EXECUTE format('CREATE INDEX %I ON data.%I USING gin (search_vector)', l_index_name, l_test_table);

    -- Verify index exists
    PERFORM test.has_index('data', l_test_table, l_index_name, 'GIN index on tsvector should exist');

    -- Cleanup
    EXECUTE format('DROP TABLE data.%I', l_test_table);
END;
$$;

-- Test: Full-text search queries with GIN
CREATE OR REPLACE FUNCTION test.test_gin_096_fulltext_search()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_gin_096_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_count integer;
BEGIN
    PERFORM test.set_context('test_gin_096_fulltext_search');

    -- Create table with tsvector and GIN index
    EXECUTE format('CREATE TABLE data.%I (
        id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        title text NOT NULL,
        body text,
        search_vector tsvector GENERATED ALWAYS AS (
            to_tsvector(''english'', coalesce(title, '''') || '' '' || coalesce(body, ''''))
        ) STORED
    )', l_test_table);
    EXECUTE format('CREATE INDEX ON data.%I USING gin (search_vector)', l_test_table);

    -- Insert test data
    EXECUTE format('INSERT INTO data.%I (title, body) VALUES
        (''PostgreSQL Performance Tuning'', ''Learn how to optimize your database queries for better performance''),
        (''MySQL vs PostgreSQL'', ''A comparison of two popular database systems''),
        (''Redis Caching Strategies'', ''How to implement caching with Redis''),
        (''PostgreSQL Full-Text Search'', ''Using tsvector and tsquery for text search'')', l_test_table);

    -- Test @@ operator with to_tsquery
    EXECUTE format('SELECT COUNT(*) FROM data.%I WHERE search_vector @@ to_tsquery(''english'', ''postgresql'')', l_test_table) INTO l_count;
    PERFORM test.is(l_count, 3, 'Should find 3 rows mentioning PostgreSQL');

    -- Test with AND operator
    EXECUTE format('SELECT COUNT(*) FROM data.%I WHERE search_vector @@ to_tsquery(''english'', ''postgresql & performance'')', l_test_table) INTO l_count;
    PERFORM test.is(l_count, 1, 'Should find 1 row with both terms');

    -- Test with OR operator
    EXECUTE format('SELECT COUNT(*) FROM data.%I WHERE search_vector @@ to_tsquery(''english'', ''redis | caching'')', l_test_table) INTO l_count;
    PERFORM test.is(l_count, 1, 'Should find 1 row with either term');

    -- Test phrase search with websearch_to_tsquery
    EXECUTE format('SELECT COUNT(*) FROM data.%I WHERE search_vector @@ websearch_to_tsquery(''english'', ''"full-text search"'')', l_test_table) INTO l_count;
    PERFORM test.is(l_count, 1, 'Should find phrase match');

    -- Cleanup
    EXECUTE format('DROP TABLE data.%I', l_test_table);
END;
$$;

-- Test: GIN index on multiple columns
CREATE OR REPLACE FUNCTION test.test_gin_097_multicolumn()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_gin_097_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_index_name text;
    l_count integer;
BEGIN
    PERFORM test.set_context('test_gin_097_multicolumn');

    -- Create table with multiple array columns
    EXECUTE format('CREATE TABLE data.%I (
        id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        tags text[] NOT NULL DEFAULT ''{}'',
        categories text[] NOT NULL DEFAULT ''{}''
    )', l_test_table);

    -- Create separate GIN indexes (multicolumn GIN not always beneficial)
    EXECUTE format('CREATE INDEX ON data.%I USING gin (tags)', l_test_table);
    EXECUTE format('CREATE INDEX ON data.%I USING gin (categories)', l_test_table);

    -- Insert test data
    EXECUTE format('INSERT INTO data.%I (tags, categories) VALUES
        (ARRAY[''tech'', ''database''], ARRAY[''tutorial'']),
        (ARRAY[''tech'', ''web''], ARRAY[''news'']),
        (ARRAY[''business''], ARRAY[''tutorial'', ''news''])', l_test_table);

    -- Query using both columns
    EXECUTE format('SELECT COUNT(*) FROM data.%I WHERE tags @> ARRAY[''tech''] AND categories @> ARRAY[''tutorial'']', l_test_table) INTO l_count;
    PERFORM test.is(l_count, 1, 'Should find row matching both array conditions');

    -- Cleanup
    EXECUTE format('DROP TABLE data.%I', l_test_table);
END;
$$;

-- Test: GIN index with fastupdate option
CREATE OR REPLACE FUNCTION test.test_gin_098_fastupdate()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_gin_098_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_index_name text;
    l_fastupdate boolean;
BEGIN
    PERFORM test.set_context('test_gin_098_fastupdate');

    -- Create table
    EXECUTE format('CREATE TABLE data.%I (
        id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        tags text[] NOT NULL DEFAULT ''{}''
    )', l_test_table);

    -- Create GIN index with fastupdate disabled (better for read-heavy workloads)
    l_index_name := l_test_table || '_tags_nofastupdate_idx';
    EXECUTE format('CREATE INDEX %I ON data.%I USING gin (tags) WITH (fastupdate = off)', l_index_name, l_test_table);

    -- Verify index setting
    SELECT (reloptions @> ARRAY['fastupdate=off'])
    INTO l_fastupdate
    FROM pg_class
    WHERE relname = l_index_name;

    PERFORM test.ok(l_fastupdate, 'GIN index should have fastupdate=off');

    -- Cleanup
    EXECUTE format('DROP TABLE data.%I', l_test_table);
END;
$$;

-- ============================================================================
-- RUN TESTS
-- ============================================================================

SELECT test.run_module('gin_09');
CALL test.print_run_summary();
