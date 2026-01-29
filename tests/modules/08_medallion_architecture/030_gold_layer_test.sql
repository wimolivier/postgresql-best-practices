-- ============================================================================
-- MEDALLION ARCHITECTURE TESTS - GOLD LAYER
-- ============================================================================
-- Tests for star schema patterns (dimensions, facts, aggregates).
-- Reference: references/data-warehousing-medallion.md
-- ============================================================================

-- ============================================================================
-- SETUP: Create gold schema
-- ============================================================================

DO $$
BEGIN
    CREATE SCHEMA IF NOT EXISTS gold;
    COMMENT ON SCHEMA gold IS 'Business-ready data - star schemas and aggregates';
END;
$$;

-- ============================================================================
-- TEST FUNCTIONS
-- ============================================================================

-- Test: Gold schema exists
CREATE OR REPLACE FUNCTION test.test_medallion_030_gold_schema()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM test.set_context('test_medallion_030_gold_schema');

    PERFORM test.has_schema('gold', 'gold schema should exist');
END;
$$;

-- Test: Gold dimension table structure
CREATE OR REPLACE FUNCTION test.test_medallion_031_dim_table_structure()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'dim_test_031_' || to_char(clock_timestamp(), 'HH24MISSUS');
BEGIN
    PERFORM test.set_context('test_medallion_031_dim_table_structure');

    -- Create dimension table
    EXECUTE format('CREATE TABLE gold.%I (
        -- Surrogate key
        customer_key        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,

        -- Natural key
        customer_id         uuid NOT NULL,

        -- Dimension attributes
        email               text NOT NULL,
        name                text NOT NULL,
        customer_segment    text,

        -- SCD Type 2
        valid_from          timestamptz NOT NULL,
        valid_to            timestamptz,
        is_current          boolean NOT NULL DEFAULT true,

        -- Lineage
        _silver_sk          bigint,
        _batch_id           uuid NOT NULL,
        _loaded_at          timestamptz NOT NULL DEFAULT now()
    )', l_test_table);

    -- Verify dimension columns
    PERFORM test.has_column('gold', l_test_table, 'customer_key', 'Surrogate key exists');
    PERFORM test.has_column('gold', l_test_table, 'customer_id', 'Natural key exists');
    PERFORM test.has_column('gold', l_test_table, 'is_current', 'SCD is_current exists');
    PERFORM test.has_column('gold', l_test_table, '_silver_sk', 'Silver lineage exists');

    -- Cleanup
    EXECUTE format('DROP TABLE gold.%I', l_test_table);
END;
$$;

-- Test: Gold dimension business key unique index
CREATE OR REPLACE FUNCTION test.test_medallion_032_dim_bk_index()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'dim_test_032_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_index_name text;
BEGIN
    PERFORM test.set_context('test_medallion_032_dim_bk_index');

    -- Create dimension table
    EXECUTE format('CREATE TABLE gold.%I (
        customer_key        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        customer_id         uuid NOT NULL,
        name                text NOT NULL,
        is_current          boolean NOT NULL DEFAULT true,
        _batch_id           uuid NOT NULL
    )', l_test_table);

    -- Create business key index for current records
    l_index_name := l_test_table || '_bk_idx';
    EXECUTE format('CREATE UNIQUE INDEX %I ON gold.%I(customer_id) WHERE is_current = true', l_index_name, l_test_table);

    PERFORM test.has_index('gold', l_test_table, l_index_name, 'Business key index should exist');

    -- Cleanup
    EXECUTE format('DROP TABLE gold.%I', l_test_table);
END;
$$;

-- Test: Gold date dimension structure
CREATE OR REPLACE FUNCTION test.test_medallion_033_dim_date()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'dim_date_test_033_' || to_char(clock_timestamp(), 'HH24MISSUS');
BEGIN
    PERFORM test.set_context('test_medallion_033_dim_date');

    -- Create date dimension
    EXECUTE format('CREATE TABLE gold.%I (
        date_key            integer PRIMARY KEY,  -- YYYYMMDD
        full_date           date NOT NULL UNIQUE,

        -- Date parts
        year                smallint NOT NULL,
        quarter             smallint NOT NULL,
        month               smallint NOT NULL,
        day_of_month        smallint NOT NULL,
        day_of_week         smallint NOT NULL,

        -- Names
        month_name          text NOT NULL,
        day_name            text NOT NULL,

        -- Flags
        is_weekend          boolean NOT NULL,
        is_holiday          boolean NOT NULL DEFAULT false
    )', l_test_table);

    -- Verify structure
    PERFORM test.has_column('gold', l_test_table, 'date_key', 'date_key exists');
    PERFORM test.has_column('gold', l_test_table, 'full_date', 'full_date exists');
    PERFORM test.has_column('gold', l_test_table, 'year', 'year exists');
    PERFORM test.has_column('gold', l_test_table, 'month_name', 'month_name exists');
    PERFORM test.has_column('gold', l_test_table, 'is_weekend', 'is_weekend exists');

    -- Cleanup
    EXECUTE format('DROP TABLE gold.%I', l_test_table);
END;
$$;

-- Test: Gold date dimension generation
CREATE OR REPLACE FUNCTION test.test_medallion_034_dim_date_generation()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'dim_date_test_034_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_count integer;
    l_sample RECORD;
BEGIN
    PERFORM test.set_context('test_medallion_034_dim_date_generation');

    -- Create date dimension
    EXECUTE format('CREATE TABLE gold.%I (
        date_key            integer PRIMARY KEY,
        full_date           date NOT NULL UNIQUE,
        year                smallint NOT NULL,
        quarter             smallint NOT NULL,
        month               smallint NOT NULL,
        day_of_month        smallint NOT NULL,
        day_of_week         smallint NOT NULL,
        month_name          text NOT NULL,
        is_weekend          boolean NOT NULL
    )', l_test_table);

    -- Generate dates for January 2024
    EXECUTE format('INSERT INTO gold.%I (date_key, full_date, year, quarter, month, day_of_month, day_of_week, month_name, is_weekend)
        SELECT
            to_char(d, ''YYYYMMDD'')::integer,
            d,
            EXTRACT(year FROM d),
            EXTRACT(quarter FROM d),
            EXTRACT(month FROM d),
            EXTRACT(day FROM d),
            EXTRACT(dow FROM d),
            to_char(d, ''Month''),
            EXTRACT(dow FROM d) IN (0, 6)
        FROM generate_series(''2024-01-01''::date, ''2024-01-31''::date, ''1 day''::interval) AS d',
        l_test_table);

    -- Verify count
    EXECUTE format('SELECT COUNT(*) FROM gold.%I', l_test_table) INTO l_count;
    PERFORM test.is(l_count, 31, 'Should have 31 dates for January');

    -- Verify specific date
    EXECUTE format('SELECT * FROM gold.%I WHERE date_key = 20240115', l_test_table) INTO l_sample;
    PERFORM test.is(l_sample.year::integer, 2024, 'Year should be 2024');
    PERFORM test.is(l_sample.month::integer, 1, 'Month should be 1');

    -- Cleanup
    EXECUTE format('DROP TABLE gold.%I', l_test_table);
END;
$$;

-- Test: Gold fact table structure
CREATE OR REPLACE FUNCTION test.test_medallion_035_fact_table_structure()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'fact_test_035_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_dim_date text := 'dim_date_test_035_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_dim_customer text := 'dim_customer_test_035_' || to_char(clock_timestamp(), 'HH24MISSUS');
BEGIN
    PERFORM test.set_context('test_medallion_035_fact_table_structure');

    -- Create mini dimensions for FK testing
    EXECUTE format('CREATE TABLE gold.%I (date_key integer PRIMARY KEY)', l_dim_date);
    EXECUTE format('CREATE TABLE gold.%I (customer_key bigint PRIMARY KEY)', l_dim_customer);
    EXECUTE format('INSERT INTO gold.%I VALUES (20240101)', l_dim_date);
    EXECUTE format('INSERT INTO gold.%I VALUES (1)', l_dim_customer);

    -- Create fact table
    EXECUTE format('CREATE TABLE gold.%I (
        -- Surrogate key
        sales_key           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,

        -- Dimension keys (FK references)
        customer_key        bigint NOT NULL REFERENCES gold.%I(customer_key),
        date_key            integer NOT NULL REFERENCES gold.%I(date_key),

        -- Degenerate dimensions
        order_id            uuid NOT NULL,
        line_number         smallint NOT NULL,

        -- Measures
        quantity            integer NOT NULL,
        unit_price          numeric(10,2) NOT NULL,
        discount_amount     numeric(10,2) NOT NULL DEFAULT 0,
        line_total          numeric(10,2) NOT NULL,

        -- Lineage
        _batch_id           uuid NOT NULL,
        _loaded_at          timestamptz NOT NULL DEFAULT now()
    )', l_test_table, l_dim_customer, l_dim_date);

    -- Verify columns
    PERFORM test.has_column('gold', l_test_table, 'sales_key', 'Surrogate key exists');
    PERFORM test.has_column('gold', l_test_table, 'customer_key', 'Dimension FK exists');
    PERFORM test.has_column('gold', l_test_table, 'date_key', 'Date FK exists');
    PERFORM test.has_column('gold', l_test_table, 'quantity', 'Measure quantity exists');
    PERFORM test.has_column('gold', l_test_table, 'line_total', 'Measure line_total exists');

    -- Cleanup
    EXECUTE format('DROP TABLE gold.%I CASCADE', l_test_table);
    EXECUTE format('DROP TABLE gold.%I CASCADE', l_dim_customer);
    EXECUTE format('DROP TABLE gold.%I CASCADE', l_dim_date);
END;
$$;

-- Test: Gold fact with generated column for computed measure
CREATE OR REPLACE FUNCTION test.test_medallion_036_fact_generated_measure()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'fact_test_036_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_computed_total numeric;
BEGIN
    PERFORM test.set_context('test_medallion_036_fact_generated_measure');

    -- Create fact table with generated column
    EXECUTE format('CREATE TABLE gold.%I (
        sales_key           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        quantity            integer NOT NULL,
        unit_price          numeric(10,2) NOT NULL,
        discount_amount     numeric(10,2) NOT NULL DEFAULT 0,
        tax_amount          numeric(10,2) NOT NULL DEFAULT 0,
        line_total          numeric(10,2) GENERATED ALWAYS AS (
            quantity * unit_price - discount_amount + tax_amount
        ) STORED,
        _batch_id           uuid NOT NULL
    )', l_test_table);

    -- Insert and verify computation
    EXECUTE format('INSERT INTO gold.%I (quantity, unit_price, discount_amount, tax_amount, _batch_id)
        VALUES (5, 10.00, 2.50, 3.75, gen_random_uuid())', l_test_table);

    EXECUTE format('SELECT line_total FROM gold.%I LIMIT 1', l_test_table) INTO l_computed_total;

    -- 5 * 10.00 - 2.50 + 3.75 = 51.25
    PERFORM test.is(l_computed_total, 51.25::numeric, 'line_total should be auto-computed');

    -- Cleanup
    EXECUTE format('DROP TABLE gold.%I', l_test_table);
END;
$$;

-- Test: Gold aggregate table structure
CREATE OR REPLACE FUNCTION test.test_medallion_037_aggregate_table()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'agg_test_037_' || to_char(clock_timestamp(), 'HH24MISSUS');
BEGIN
    PERFORM test.set_context('test_medallion_037_aggregate_table');

    -- Create aggregate table
    EXECUTE format('CREATE TABLE gold.%I (
        date_key            integer NOT NULL,
        customer_segment    text,
        product_category    text,

        -- Pre-computed aggregates
        order_count         integer NOT NULL,
        item_count          integer NOT NULL,
        gross_revenue       numeric(12,2) NOT NULL,
        net_revenue         numeric(12,2) NOT NULL,
        avg_order_value     numeric(10,2) NOT NULL,

        -- Lineage
        _batch_id           uuid NOT NULL,
        _loaded_at          timestamptz NOT NULL DEFAULT now(),

        PRIMARY KEY (date_key, customer_segment, product_category)
    )', l_test_table);

    -- Verify structure
    PERFORM test.has_column('gold', l_test_table, 'order_count', 'order_count aggregate exists');
    PERFORM test.has_column('gold', l_test_table, 'gross_revenue', 'gross_revenue aggregate exists');
    PERFORM test.has_column('gold', l_test_table, 'avg_order_value', 'avg_order_value aggregate exists');

    -- Cleanup
    EXECUTE format('DROP TABLE gold.%I', l_test_table);
END;
$$;

-- Test: Gold aggregate computation
CREATE OR REPLACE FUNCTION test.test_medallion_038_aggregate_computation()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_fact_table text := 'fact_test_038_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_agg_table text := 'agg_test_038_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_total_revenue numeric;
    l_order_count integer;
BEGIN
    PERFORM test.set_context('test_medallion_038_aggregate_computation');

    -- Create fact table
    EXECUTE format('CREATE TABLE gold.%I (
        sales_key           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        date_key            integer NOT NULL,
        customer_segment    text NOT NULL,
        order_id            uuid NOT NULL,
        amount              numeric(10,2) NOT NULL
    )', l_fact_table);

    -- Create aggregate table
    EXECUTE format('CREATE TABLE gold.%I (
        date_key            integer NOT NULL,
        customer_segment    text NOT NULL,
        order_count         integer NOT NULL,
        total_revenue       numeric(12,2) NOT NULL,
        PRIMARY KEY (date_key, customer_segment)
    )', l_agg_table);

    -- Insert fact data
    EXECUTE format('INSERT INTO gold.%I (date_key, customer_segment, order_id, amount) VALUES
        (20240101, ''premium'', gen_random_uuid(), 100.00),
        (20240101, ''premium'', gen_random_uuid(), 150.00),
        (20240101, ''standard'', gen_random_uuid(), 50.00)',
        l_fact_table);

    -- Compute aggregates
    EXECUTE format('INSERT INTO gold.%I (date_key, customer_segment, order_count, total_revenue)
        SELECT
            date_key,
            customer_segment,
            COUNT(DISTINCT order_id),
            SUM(amount)
        FROM gold.%I
        GROUP BY date_key, customer_segment',
        l_agg_table, l_fact_table);

    -- Verify premium segment
    EXECUTE format('SELECT order_count, total_revenue FROM gold.%I WHERE customer_segment = ''premium''', l_agg_table)
        INTO l_order_count, l_total_revenue;

    PERFORM test.is(l_order_count, 2, 'Premium should have 2 orders');
    PERFORM test.is(l_total_revenue, 250.00::numeric, 'Premium total should be 250.00');

    -- Cleanup
    EXECUTE format('DROP TABLE gold.%I', l_agg_table);
    EXECUTE format('DROP TABLE gold.%I', l_fact_table);
END;
$$;

-- Test: Gold materialized view
CREATE OR REPLACE FUNCTION test.test_medallion_039_materialized_view()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_fact_table text := 'fact_test_039_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_mv_name text := 'mv_test_039_' || to_char(clock_timestamp(), 'HH24MISSUS');
    l_total numeric;
BEGIN
    PERFORM test.set_context('test_medallion_039_materialized_view');

    -- Create fact table
    EXECUTE format('CREATE TABLE gold.%I (
        sales_key           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        customer_id         uuid NOT NULL,
        amount              numeric(10,2) NOT NULL
    )', l_fact_table);

    -- Insert data
    EXECUTE format('INSERT INTO gold.%I (customer_id, amount) VALUES
        (gen_random_uuid(), 100.00),
        (gen_random_uuid(), 200.00)',
        l_fact_table);

    -- Create materialized view
    EXECUTE format('CREATE MATERIALIZED VIEW gold.%I AS
        SELECT
            customer_id,
            SUM(amount) AS total_spent,
            COUNT(*) AS order_count
        FROM gold.%I
        GROUP BY customer_id',
        l_mv_name, l_fact_table);

    -- Create unique index for REFRESH CONCURRENTLY
    EXECUTE format('CREATE UNIQUE INDEX ON gold.%I(customer_id)', l_mv_name);

    -- Verify MV exists and has data
    PERFORM test.isnt_empty(
        format('SELECT 1 FROM gold.%I', l_mv_name),
        'Materialized view should have data'
    );

    -- Test refresh
    EXECUTE format('REFRESH MATERIALIZED VIEW gold.%I', l_mv_name);

    -- Cleanup
    EXECUTE format('DROP MATERIALIZED VIEW gold.%I', l_mv_name);
    EXECUTE format('DROP TABLE gold.%I', l_fact_table);
END;
$$;

-- ============================================================================
-- RUN TESTS
-- ============================================================================

SELECT test.run_module('medallion_03');
CALL test.print_run_summary();
