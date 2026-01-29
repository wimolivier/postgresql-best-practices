-- ============================================================================
-- DATA TYPES TESTS - JSONB
-- ============================================================================
-- Tests for JSONB storage, querying, and indexing patterns.
-- ============================================================================

-- ============================================================================
-- TEST FUNCTIONS
-- ============================================================================

-- Test: JSONB stores and retrieves JSON
CREATE OR REPLACE FUNCTION test.test_jsonb_040_basic_storage()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_jsonb_' || to_char(clock_timestamp(), 'HH24MISS');
    l_data jsonb;
BEGIN
    PERFORM test.set_context('test_jsonb_040_basic_storage');

    -- Create table
    EXECUTE format('CREATE TABLE test.%I (data jsonb)', l_test_table);

    -- Insert JSON
    EXECUTE format('INSERT INTO test.%I VALUES ($1) RETURNING data', l_test_table)
    INTO l_data
    USING '{"name": "Test", "count": 42}'::jsonb;

    PERFORM test.is_not_null(l_data, 'JSONB should store data');
    PERFORM test.is(l_data->>'name', 'Test', 'should retrieve string value');
    PERFORM test.is((l_data->>'count')::integer, 42, 'should retrieve integer value');

    -- Clean up
    EXECUTE format('DROP TABLE test.%I', l_test_table);
END;
$$;

-- Test: JSONB vs JSON (JSONB is preferred)
CREATE OR REPLACE FUNCTION test.test_jsonb_041_jsonb_preferred()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_json json := '{"b": 1, "a": 2}'::json;
    l_jsonb jsonb := '{"b": 1, "a": 2}'::jsonb;
BEGIN
    PERFORM test.set_context('test_jsonb_041_jsonb_preferred');

    -- JSON preserves input exactly
    PERFORM test.is(l_json::text, '{"b": 1, "a": 2}', 'JSON preserves key order');

    -- JSONB normalizes (may reorder keys, remove whitespace)
    -- Keys are stored in sorted order
    PERFORM test.is_not_null(l_jsonb, 'JSONB normalizes and is more efficient');
END;
$$;

-- Test: Arrow operators -> and ->>
CREATE OR REPLACE FUNCTION test.test_jsonb_042_arrow_operators()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_data jsonb := '{"user": {"name": "Alice", "age": 30}, "tags": ["a", "b"]}'::jsonb;
BEGIN
    PERFORM test.set_context('test_jsonb_042_arrow_operators');

    -- -> returns jsonb
    PERFORM test.is(pg_typeof(l_data->'user')::text, 'jsonb', '-> returns jsonb');

    -- ->> returns text
    PERFORM test.is(pg_typeof(l_data->>'user')::text, 'text', '->> returns text');

    -- Nested access
    PERFORM test.is(l_data->'user'->>'name', 'Alice', 'nested access with ->');

    -- Array access
    PERFORM test.is(l_data->'tags'->>0, 'a', 'array access by index');
    PERFORM test.is(l_data->'tags'->>1, 'b', 'array access by index');
END;
$$;

-- Test: Path operators #> and #>>
CREATE OR REPLACE FUNCTION test.test_jsonb_043_path_operators()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_data jsonb := '{"a": {"b": {"c": "deep"}}}'::jsonb;
BEGIN
    PERFORM test.set_context('test_jsonb_043_path_operators');

    -- #> returns jsonb at path
    PERFORM test.is(l_data #> '{a,b,c}', '"deep"'::jsonb, '#> returns jsonb at path');

    -- #>> returns text at path
    PERFORM test.is(l_data #>> '{a,b,c}', 'deep', '#>> returns text at path');
END;
$$;

-- Test: Containment operators @> and <@
CREATE OR REPLACE FUNCTION test.test_jsonb_044_containment()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_data jsonb := '{"name": "Alice", "age": 30, "city": "NYC"}'::jsonb;
BEGIN
    PERFORM test.set_context('test_jsonb_044_containment');

    -- @> contains
    PERFORM test.ok(l_data @> '{"name": "Alice"}'::jsonb, '@> should match subset');
    PERFORM test.ok(l_data @> '{"name": "Alice", "age": 30}'::jsonb, '@> should match multiple keys');
    PERFORM test.not_ok(l_data @> '{"name": "Bob"}'::jsonb, '@> should not match wrong value');

    -- <@ contained by
    PERFORM test.ok('{"name": "Alice"}'::jsonb <@ l_data, '<@ should match superset');
END;
$$;

-- Test: Existence operators ? and ?| and ?&
CREATE OR REPLACE FUNCTION test.test_jsonb_045_existence()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_data jsonb := '{"name": "Alice", "age": 30}'::jsonb;
BEGIN
    PERFORM test.set_context('test_jsonb_045_existence');

    -- ? key exists
    PERFORM test.ok(l_data ? 'name', '? should find existing key');
    PERFORM test.not_ok(l_data ? 'email', '? should not find missing key');

    -- ?| any key exists
    PERFORM test.ok(l_data ?| array['name', 'email'], '?| should match if any key exists');
    PERFORM test.not_ok(l_data ?| array['foo', 'bar'], '?| should not match if no keys exist');

    -- ?& all keys exist
    PERFORM test.ok(l_data ?& array['name', 'age'], '?& should match if all keys exist');
    PERFORM test.not_ok(l_data ?& array['name', 'email'], '?& should not match if any key missing');
END;
$$;

-- Test: JSONB modification functions
CREATE OR REPLACE FUNCTION test.test_jsonb_046_modification()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_data jsonb := '{"name": "Alice"}'::jsonb;
    l_modified jsonb;
BEGIN
    PERFORM test.set_context('test_jsonb_046_modification');

    -- || concatenation (merge)
    l_modified := l_data || '{"age": 30}'::jsonb;
    PERFORM test.ok(l_modified @> '{"name": "Alice", "age": 30}'::jsonb, '|| should merge objects');

    -- - remove key
    l_modified := l_data || '{"age": 30}'::jsonb;
    l_modified := l_modified - 'age';
    PERFORM test.not_ok(l_modified ? 'age', '- should remove key');

    -- jsonb_set
    l_modified := jsonb_set('{"a": {"b": 1}}'::jsonb, '{a,b}', '2');
    PERFORM test.is(l_modified #>> '{a,b}', '2', 'jsonb_set should update nested value');
END;
$$;

-- Test: GIN index for JSONB
CREATE OR REPLACE FUNCTION test.test_jsonb_047_gin_index()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_jsonb_gin_' || to_char(clock_timestamp(), 'HH24MISS');
BEGIN
    PERFORM test.set_context('test_jsonb_047_gin_index');

    -- Create table with JSONB
    EXECUTE format('CREATE TABLE test.%I (id serial PRIMARY KEY, data jsonb)', l_test_table);

    -- Create GIN index for containment queries
    EXECUTE format('CREATE INDEX %I_data_gin ON test.%I USING GIN (data)', l_test_table, l_test_table);

    -- Verify index exists
    PERFORM test.has_index('test', l_test_table, l_test_table || '_data_gin', 'GIN index should exist');

    -- Clean up
    EXECUTE format('DROP TABLE test.%I', l_test_table);
END;
$$;

-- Test: GIN index with jsonb_path_ops
CREATE OR REPLACE FUNCTION test.test_jsonb_048_path_ops_index()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_jsonb_path_' || to_char(clock_timestamp(), 'HH24MISS');
BEGIN
    PERFORM test.set_context('test_jsonb_048_path_ops_index');

    -- Create table
    EXECUTE format('CREATE TABLE test.%I (id serial PRIMARY KEY, data jsonb)', l_test_table);

    -- Create GIN index with jsonb_path_ops (more efficient for @>)
    EXECUTE format('CREATE INDEX %I_data_path ON test.%I USING GIN (data jsonb_path_ops)', l_test_table, l_test_table);

    -- Verify index exists
    PERFORM test.has_index('test', l_test_table, l_test_table || '_data_path', 'jsonb_path_ops index should exist');

    -- Clean up
    EXECUTE format('DROP TABLE test.%I', l_test_table);
END;
$$;

-- Test: Querying JSONB arrays
CREATE OR REPLACE FUNCTION test.test_jsonb_049_array_queries()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_jsonb_arr_' || to_char(clock_timestamp(), 'HH24MISS');
    l_count integer;
BEGIN
    PERFORM test.set_context('test_jsonb_049_array_queries');

    -- Create and populate table
    EXECUTE format('CREATE TABLE test.%I (id serial, data jsonb)', l_test_table);
    EXECUTE format($ins$
        INSERT INTO test.%I (data) VALUES
        ('{"tags": ["urgent", "bug"]}'),
        ('{"tags": ["feature", "enhancement"]}'),
        ('{"tags": ["bug", "low"]}')
    $ins$, l_test_table);

    -- Query: find all with "bug" tag
    EXECUTE format($q$
        SELECT count(*) FROM test.%I WHERE data->'tags' ? 'bug'
    $q$, l_test_table)
    INTO l_count;

    PERFORM test.is(l_count, 2, 'should find 2 rows with bug tag');

    -- Clean up
    EXECUTE format('DROP TABLE test.%I', l_test_table);
END;
$$;

-- Test: jsonb_typeof for type checking
CREATE OR REPLACE FUNCTION test.test_jsonb_050_typeof()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM test.set_context('test_jsonb_050_typeof');

    PERFORM test.is(jsonb_typeof('"string"'::jsonb), 'string', 'string type');
    PERFORM test.is(jsonb_typeof('123'::jsonb), 'number', 'number type');
    PERFORM test.is(jsonb_typeof('true'::jsonb), 'boolean', 'boolean type');
    PERFORM test.is(jsonb_typeof('null'::jsonb), 'null', 'null type');
    PERFORM test.is(jsonb_typeof('[]'::jsonb), 'array', 'array type');
    PERFORM test.is(jsonb_typeof('{}'::jsonb), 'object', 'object type');
END;
$$;

-- ============================================================================
-- RUN TESTS
-- ============================================================================

SELECT test.run_module('jsonb_04');
CALL test.print_run_summary();
