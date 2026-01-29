-- ============================================================================
-- MEDALLION ARCHITECTURE TESTS - DATA LINEAGE
-- ============================================================================
-- Tests for data lineage tracking across layers.
-- Reference: references/data-warehousing-medallion.md
-- ============================================================================

-- ============================================================================
-- SETUP: Create lineage schema
-- ============================================================================

DO $$
BEGIN
    CREATE SCHEMA IF NOT EXISTS dwh_lineage;
    COMMENT ON SCHEMA dwh_lineage IS 'Data lineage tracking and pipeline metadata';
END;
$$;

-- Create pipeline_runs table
CREATE TABLE IF NOT EXISTS dwh_lineage.pipeline_runs (
    run_id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    batch_id        uuid NOT NULL UNIQUE DEFAULT gen_random_uuid(),
    pipeline_name   text NOT NULL,
    started_at      timestamptz NOT NULL DEFAULT now(),
    completed_at    timestamptz,
    status          text NOT NULL DEFAULT 'running'
                    CHECK (status IN ('running', 'completed', 'failed', 'cancelled')),
    parameters      jsonb DEFAULT '{}',
    error_message   text,
    metrics         jsonb DEFAULT '{}'
);

-- Create table_lineage table
CREATE TABLE IF NOT EXISTS dwh_lineage.table_lineage (
    lineage_id      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_id          bigint REFERENCES dwh_lineage.pipeline_runs(run_id),
    batch_id        uuid NOT NULL,
    source_table    text NOT NULL,
    target_table    text NOT NULL,
    operation       text NOT NULL CHECK (operation IN (
        'ingest', 'transform', 'aggregate', 'refresh', 'delete'
    )),
    rows_read       bigint,
    rows_inserted   bigint,
    rows_updated    bigint,
    rows_deleted    bigint,
    started_at      timestamptz NOT NULL DEFAULT now(),
    completed_at    timestamptz
);

-- Create table_dependencies table
CREATE TABLE IF NOT EXISTS dwh_lineage.table_dependencies (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    upstream_table  text NOT NULL,
    downstream_table text NOT NULL,
    dependency_type text NOT NULL DEFAULT 'data'
                    CHECK (dependency_type IN ('data', 'reference', 'optional')),
    created_at      timestamptz NOT NULL DEFAULT now(),
    UNIQUE (upstream_table, downstream_table)
);

-- ============================================================================
-- TEST FUNCTIONS
-- ============================================================================

-- Test: Lineage schema exists
CREATE OR REPLACE FUNCTION test.test_lineage_040_schema_exists()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM test.set_context('test_lineage_040_schema_exists');

    PERFORM test.has_schema('dwh_lineage', 'dwh_lineage schema should exist');
END;
$$;

-- Test: Pipeline runs table structure
CREATE OR REPLACE FUNCTION test.test_lineage_041_pipeline_runs_table()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM test.set_context('test_lineage_041_pipeline_runs_table');

    PERFORM test.has_table('dwh_lineage', 'pipeline_runs', 'pipeline_runs table should exist');
    PERFORM test.has_column('dwh_lineage', 'pipeline_runs', 'run_id', 'run_id exists');
    PERFORM test.has_column('dwh_lineage', 'pipeline_runs', 'batch_id', 'batch_id exists');
    PERFORM test.has_column('dwh_lineage', 'pipeline_runs', 'pipeline_name', 'pipeline_name exists');
    PERFORM test.has_column('dwh_lineage', 'pipeline_runs', 'status', 'status exists');
    PERFORM test.has_column('dwh_lineage', 'pipeline_runs', 'started_at', 'started_at exists');
    PERFORM test.has_column('dwh_lineage', 'pipeline_runs', 'completed_at', 'completed_at exists');
END;
$$;

-- Test: Table lineage table structure
CREATE OR REPLACE FUNCTION test.test_lineage_042_table_lineage_table()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM test.set_context('test_lineage_042_table_lineage_table');

    PERFORM test.has_table('dwh_lineage', 'table_lineage', 'table_lineage table should exist');
    PERFORM test.has_column('dwh_lineage', 'table_lineage', 'source_table', 'source_table exists');
    PERFORM test.has_column('dwh_lineage', 'table_lineage', 'target_table', 'target_table exists');
    PERFORM test.has_column('dwh_lineage', 'table_lineage', 'operation', 'operation exists');
    PERFORM test.has_column('dwh_lineage', 'table_lineage', 'rows_inserted', 'rows_inserted exists');
END;
$$;

-- Test: Start pipeline run
CREATE OR REPLACE FUNCTION test.test_lineage_043_start_pipeline()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_run_id bigint;
    l_batch_id uuid := gen_random_uuid();
    l_record RECORD;
BEGIN
    PERFORM test.set_context('test_lineage_043_start_pipeline');

    -- Insert pipeline run
    INSERT INTO dwh_lineage.pipeline_runs (batch_id, pipeline_name, parameters)
    VALUES (l_batch_id, 'test_pipeline', '{"date": "2024-01-01"}'::jsonb)
    RETURNING run_id INTO l_run_id;

    -- Verify
    SELECT * INTO l_record FROM dwh_lineage.pipeline_runs WHERE run_id = l_run_id;

    PERFORM test.is(l_record.pipeline_name, 'test_pipeline', 'Pipeline name should match');
    PERFORM test.is(l_record.status, 'running', 'Initial status should be running');
    PERFORM test.is_null(l_record.completed_at, 'completed_at should be NULL');

    -- Cleanup
    DELETE FROM dwh_lineage.pipeline_runs WHERE run_id = l_run_id;
END;
$$;

-- Test: Complete pipeline run
CREATE OR REPLACE FUNCTION test.test_lineage_044_complete_pipeline()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_run_id bigint;
    l_record RECORD;
BEGIN
    PERFORM test.set_context('test_lineage_044_complete_pipeline');

    -- Start pipeline
    INSERT INTO dwh_lineage.pipeline_runs (pipeline_name)
    VALUES ('test_complete')
    RETURNING run_id INTO l_run_id;

    -- Complete pipeline
    UPDATE dwh_lineage.pipeline_runs
    SET status = 'completed',
        completed_at = now(),
        metrics = '{"rows_processed": 1000}'::jsonb
    WHERE run_id = l_run_id;

    -- Verify
    SELECT * INTO l_record FROM dwh_lineage.pipeline_runs WHERE run_id = l_run_id;

    PERFORM test.is(l_record.status, 'completed', 'Status should be completed');
    PERFORM test.is_not_null(l_record.completed_at, 'completed_at should be set');
    PERFORM test.ok((l_record.metrics->>'rows_processed')::int = 1000, 'Metrics should be recorded');

    -- Cleanup
    DELETE FROM dwh_lineage.pipeline_runs WHERE run_id = l_run_id;
END;
$$;

-- Test: Failed pipeline run
CREATE OR REPLACE FUNCTION test.test_lineage_045_failed_pipeline()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_run_id bigint;
    l_record RECORD;
BEGIN
    PERFORM test.set_context('test_lineage_045_failed_pipeline');

    -- Start pipeline
    INSERT INTO dwh_lineage.pipeline_runs (pipeline_name)
    VALUES ('test_fail')
    RETURNING run_id INTO l_run_id;

    -- Mark as failed
    UPDATE dwh_lineage.pipeline_runs
    SET status = 'failed',
        completed_at = now(),
        error_message = 'Connection timeout'
    WHERE run_id = l_run_id;

    -- Verify
    SELECT * INTO l_record FROM dwh_lineage.pipeline_runs WHERE run_id = l_run_id;

    PERFORM test.is(l_record.status, 'failed', 'Status should be failed');
    PERFORM test.is(l_record.error_message, 'Connection timeout', 'Error message should be recorded');

    -- Cleanup
    DELETE FROM dwh_lineage.pipeline_runs WHERE run_id = l_run_id;
END;
$$;

-- Test: Log table lineage
CREATE OR REPLACE FUNCTION test.test_lineage_046_log_table_lineage()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_batch_id uuid := gen_random_uuid();
    l_lineage_id bigint;
    l_record RECORD;
BEGIN
    PERFORM test.set_context('test_lineage_046_log_table_lineage');

    -- Log transformation
    INSERT INTO dwh_lineage.table_lineage (
        batch_id, source_table, target_table, operation,
        rows_read, rows_inserted, rows_updated, completed_at
    ) VALUES (
        l_batch_id, 'bronze.raw_customers', 'silver.customers', 'transform',
        1000, 950, 50, now()
    ) RETURNING lineage_id INTO l_lineage_id;

    -- Verify
    SELECT * INTO l_record FROM dwh_lineage.table_lineage WHERE lineage_id = l_lineage_id;

    PERFORM test.is(l_record.source_table, 'bronze.raw_customers', 'Source should match');
    PERFORM test.is(l_record.target_table, 'silver.customers', 'Target should match');
    PERFORM test.is(l_record.operation, 'transform', 'Operation should match');
    PERFORM test.is(l_record.rows_read::integer, 1000, 'Rows read should match');
    PERFORM test.is(l_record.rows_inserted::integer, 950, 'Rows inserted should match');

    -- Cleanup
    DELETE FROM dwh_lineage.table_lineage WHERE lineage_id = l_lineage_id;
END;
$$;

-- Test: Table dependencies
CREATE OR REPLACE FUNCTION test.test_lineage_047_table_dependencies()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_dep_id bigint;
    l_count integer;
BEGIN
    PERFORM test.set_context('test_lineage_047_table_dependencies');

    -- Create dependency chain: bronze -> silver -> gold
    INSERT INTO dwh_lineage.table_dependencies (upstream_table, downstream_table, dependency_type)
    VALUES
        ('bronze.raw_customers', 'silver.customers', 'data'),
        ('silver.customers', 'gold.dim_customer', 'data')
    ON CONFLICT DO NOTHING;

    -- Query downstream dependencies
    SELECT COUNT(*) INTO l_count
    FROM dwh_lineage.table_dependencies
    WHERE upstream_table = 'silver.customers';

    PERFORM test.cmp_ok(l_count, '>=', 1, 'Should find downstream dependency for silver.customers');

    -- Cleanup
    DELETE FROM dwh_lineage.table_dependencies
    WHERE upstream_table IN ('bronze.raw_customers', 'silver.customers');
END;
$$;

-- Test: Query upstream lineage (what feeds this table?)
CREATE OR REPLACE FUNCTION test.test_lineage_048_upstream_query()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_upstream_count integer;
BEGIN
    PERFORM test.set_context('test_lineage_048_upstream_query');

    -- Create dependency chain
    INSERT INTO dwh_lineage.table_dependencies (upstream_table, downstream_table)
    VALUES
        ('bronze.raw_orders', 'silver.orders'),
        ('silver.orders', 'gold.fact_sales'),
        ('silver.customers', 'gold.fact_sales')
    ON CONFLICT DO NOTHING;

    -- Query all upstream tables for gold.fact_sales
    WITH RECURSIVE upstream AS (
        SELECT 1 AS level, upstream_table
        FROM dwh_lineage.table_dependencies
        WHERE downstream_table = 'gold.fact_sales'

        UNION ALL

        SELECT u.level + 1, d.upstream_table
        FROM upstream u
        JOIN dwh_lineage.table_dependencies d ON d.downstream_table = u.upstream_table
        WHERE u.level < 5
    )
    SELECT COUNT(DISTINCT upstream_table) INTO l_upstream_count FROM upstream;

    PERFORM test.cmp_ok(l_upstream_count, '>=', 2, 'gold.fact_sales should have multiple upstream tables');

    -- Cleanup
    DELETE FROM dwh_lineage.table_dependencies
    WHERE downstream_table IN ('silver.orders', 'gold.fact_sales');
END;
$$;

-- Test: Pipeline with linked lineage
CREATE OR REPLACE FUNCTION test.test_lineage_049_pipeline_with_lineage()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_run_id bigint;
    l_batch_id uuid := gen_random_uuid();
    l_lineage_count integer;
BEGIN
    PERFORM test.set_context('test_lineage_049_pipeline_with_lineage');

    -- Create pipeline run
    INSERT INTO dwh_lineage.pipeline_runs (batch_id, pipeline_name)
    VALUES (l_batch_id, 'daily_etl')
    RETURNING run_id INTO l_run_id;

    -- Log multiple lineage entries for same pipeline
    INSERT INTO dwh_lineage.table_lineage (run_id, batch_id, source_table, target_table, operation, rows_inserted)
    VALUES
        (l_run_id, l_batch_id, 'source.api', 'bronze.raw_data', 'ingest', 500),
        (l_run_id, l_batch_id, 'bronze.raw_data', 'silver.clean_data', 'transform', 480),
        (l_run_id, l_batch_id, 'silver.clean_data', 'gold.dim_data', 'transform', 450);

    -- Query all lineage for this pipeline run
    SELECT COUNT(*) INTO l_lineage_count
    FROM dwh_lineage.table_lineage
    WHERE run_id = l_run_id;

    PERFORM test.is(l_lineage_count, 3, 'Pipeline should have 3 lineage entries');

    -- Cleanup
    DELETE FROM dwh_lineage.table_lineage WHERE run_id = l_run_id;
    DELETE FROM dwh_lineage.pipeline_runs WHERE run_id = l_run_id;
END;
$$;

-- Test: Lineage metrics summary
CREATE OR REPLACE FUNCTION test.test_lineage_050_metrics_summary()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_batch_id uuid := gen_random_uuid();
    l_total_inserted bigint;
    l_total_updated bigint;
BEGIN
    PERFORM test.set_context('test_lineage_050_metrics_summary');

    -- Log multiple operations
    INSERT INTO dwh_lineage.table_lineage (batch_id, source_table, target_table, operation, rows_inserted, rows_updated)
    VALUES
        (l_batch_id, 'src1', 'tgt1', 'transform', 100, 10),
        (l_batch_id, 'src2', 'tgt2', 'transform', 200, 20),
        (l_batch_id, 'src3', 'tgt3', 'transform', 150, 5);

    -- Calculate summary
    SELECT
        SUM(COALESCE(rows_inserted, 0)),
        SUM(COALESCE(rows_updated, 0))
    INTO l_total_inserted, l_total_updated
    FROM dwh_lineage.table_lineage
    WHERE batch_id = l_batch_id;

    PERFORM test.is(l_total_inserted::integer, 450, 'Total inserted should be 450');
    PERFORM test.is(l_total_updated::integer, 35, 'Total updated should be 35');

    -- Cleanup
    DELETE FROM dwh_lineage.table_lineage WHERE batch_id = l_batch_id;
END;
$$;

-- ============================================================================
-- RUN TESTS
-- ============================================================================

SELECT test.run_module('lineage_04');
CALL test.print_run_summary();
