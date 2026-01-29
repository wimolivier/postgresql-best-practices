-- ============================================================================
-- DATA TYPES TESTS - NUMERIC
-- ============================================================================
-- Tests for numeric/decimal precision handling.
-- ============================================================================

-- ============================================================================
-- TEST FUNCTIONS
-- ============================================================================

-- Test: numeric(p,s) stores exact precision
CREATE OR REPLACE FUNCTION test.test_numeric_030_exact_precision()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_value numeric(15,2);
    l_test_table text := 'test_num_' || to_char(clock_timestamp(), 'HH24MISS');
BEGIN
    PERFORM test.set_context('test_numeric_030_exact_precision');

    -- Create table with numeric(15,2) for money
    EXECUTE format('CREATE TABLE test.%I (amount numeric(15,2))', l_test_table);

    -- Insert and retrieve
    EXECUTE format('INSERT INTO test.%I VALUES ($1) RETURNING amount', l_test_table)
    INTO l_value
    USING 12345.67::numeric(15,2);

    PERFORM test.is(l_value, 12345.67::numeric, 'numeric should store exact value');

    -- Clean up
    EXECUTE format('DROP TABLE test.%I', l_test_table);
END;
$$;

-- Test: numeric rounds to specified scale
CREATE OR REPLACE FUNCTION test.test_numeric_031_rounding()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_value numeric(10,2);
BEGIN
    PERFORM test.set_context('test_numeric_031_rounding');

    -- Insert value with more decimal places
    l_value := 123.456::numeric(10,2);

    -- Should round to 2 decimal places
    PERFORM test.is(l_value, 123.46::numeric, 'numeric(10,2) should round to 2 decimals');
END;
$$;

-- Test: float/real has precision issues (why we avoid it)
CREATE OR REPLACE FUNCTION test.test_numeric_032_float_issues()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_float_sum float;
    l_numeric_sum numeric;
BEGIN
    PERFORM test.set_context('test_numeric_032_float_issues');

    -- Classic floating point issue: 0.1 + 0.2
    l_float_sum := 0.1::float + 0.2::float;
    l_numeric_sum := 0.1::numeric + 0.2::numeric;

    -- Float may not equal 0.3 exactly
    PERFORM test.ok(l_numeric_sum = 0.3, 'numeric 0.1 + 0.2 = 0.3 exactly');

    -- This documents the float issue (may or may not equal depending on representation)
    PERFORM test.is_not_null(l_float_sum, 'float sum calculated (may have precision issues)');
END;
$$;

-- Test: money type is NOT recommended
CREATE OR REPLACE FUNCTION test.test_numeric_033_money_not_recommended()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_money money;
    l_numeric numeric(15,2);
BEGIN
    PERFORM test.set_context('test_numeric_033_money_not_recommended');

    -- money type exists but is locale-dependent
    l_money := 12345.67::money;

    -- numeric is preferred for portability
    l_numeric := 12345.67::numeric(15,2);

    -- Both store the value, but numeric is more portable
    PERFORM test.is_not_null(l_numeric, 'numeric(15,2) is preferred for monetary values');
END;
$$;

-- Test: Arithmetic with numeric maintains precision
CREATE OR REPLACE FUNCTION test.test_numeric_034_arithmetic()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_price numeric(15,2) := 99.99;
    l_quantity integer := 3;
    l_tax_rate numeric(5,4) := 0.0875;
    l_subtotal numeric;
    l_tax numeric;
    l_total numeric;
BEGIN
    PERFORM test.set_context('test_numeric_034_arithmetic');

    l_subtotal := l_price * l_quantity;
    l_tax := l_subtotal * l_tax_rate;
    l_total := l_subtotal + l_tax;

    PERFORM test.is(l_subtotal, 299.97::numeric, 'multiplication should be exact');
    PERFORM test.ok(l_tax IS NOT NULL, 'tax calculation should work');
    PERFORM test.ok(l_total > l_subtotal, 'total should be greater than subtotal');
END;
$$;

-- Test: Division and rounding
CREATE OR REPLACE FUNCTION test.test_numeric_035_division()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_dividend numeric := 100;
    l_divisor numeric := 3;
    l_result numeric;
    l_rounded numeric(10,2);
BEGIN
    PERFORM test.set_context('test_numeric_035_division');

    l_result := l_dividend / l_divisor;

    -- Full precision
    PERFORM test.ok(l_result > 33.33, 'division result should be > 33.33');

    -- Rounded for display/storage
    l_rounded := round(l_result, 2);
    PERFORM test.is(l_rounded, 33.33::numeric, 'rounded result should be 33.33');
END;
$$;

-- Test: GENERATED column for calculated values
CREATE OR REPLACE FUNCTION test.test_numeric_036_generated_column()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_gen_' || to_char(clock_timestamp(), 'HH24MISS');
    l_total numeric;
BEGIN
    PERFORM test.set_context('test_numeric_036_generated_column');

    -- Create table with generated column
    EXECUTE format($tbl$
        CREATE TABLE test.%I (
            subtotal numeric(15,2) NOT NULL,
            tax_rate numeric(5,4) NOT NULL DEFAULT 0.0875,
            total numeric(15,2) GENERATED ALWAYS AS (subtotal * (1 + tax_rate)) STORED
        )
    $tbl$, l_test_table);

    -- Insert
    EXECUTE format('INSERT INTO test.%I (subtotal) VALUES ($1) RETURNING total', l_test_table)
    INTO l_total
    USING 100.00::numeric;

    -- Total should be calculated automatically
    PERFORM test.is(l_total, 108.75::numeric, 'generated column should calculate total');

    -- Clean up
    EXECUTE format('DROP TABLE test.%I', l_test_table);
END;
$$;

-- Test: Constraints with numeric
CREATE OR REPLACE FUNCTION test.test_numeric_037_constraints()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_constr_' || to_char(clock_timestamp(), 'HH24MISS');
BEGIN
    PERFORM test.set_context('test_numeric_037_constraints');

    -- Create table with constraints
    EXECUTE format($tbl$
        CREATE TABLE test.%I (
            price numeric(15,2) NOT NULL,
            quantity integer NOT NULL DEFAULT 1,
            CONSTRAINT price_positive CHECK (price >= 0),
            CONSTRAINT quantity_positive CHECK (quantity > 0)
        )
    $tbl$, l_test_table);

    -- Valid insert
    PERFORM test.lives_ok(
        format('INSERT INTO test.%I (price) VALUES (10.00)', l_test_table),
        'valid positive price should succeed'
    );

    -- Invalid: negative price
    PERFORM test.throws_ok(
        format('INSERT INTO test.%I (price) VALUES (-1.00)', l_test_table),
        '23514',  -- check_violation
        'negative price should violate constraint'
    );

    -- Clean up
    EXECUTE format('DROP TABLE test.%I', l_test_table);
END;
$$;

-- Test: Aggregate functions with numeric
CREATE OR REPLACE FUNCTION test.test_numeric_038_aggregates()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_test_table text := 'test_agg_' || to_char(clock_timestamp(), 'HH24MISS');
    l_sum numeric;
    l_avg numeric;
    l_min numeric;
    l_max numeric;
BEGIN
    PERFORM test.set_context('test_numeric_038_aggregates');

    -- Create and populate table
    EXECUTE format('CREATE TABLE test.%I (amount numeric(15,2))', l_test_table);
    EXECUTE format('INSERT INTO test.%I VALUES (10.00), (20.00), (30.00)', l_test_table);

    -- Test aggregates
    EXECUTE format('SELECT sum(amount), avg(amount), min(amount), max(amount) FROM test.%I', l_test_table)
    INTO l_sum, l_avg, l_min, l_max;

    PERFORM test.is(l_sum, 60.00::numeric, 'SUM should be 60.00');
    PERFORM test.is(l_avg, 20.00::numeric, 'AVG should be 20.00');
    PERFORM test.is(l_min, 10.00::numeric, 'MIN should be 10.00');
    PERFORM test.is(l_max, 30.00::numeric, 'MAX should be 30.00');

    -- Clean up
    EXECUTE format('DROP TABLE test.%I', l_test_table);
END;
$$;

-- ============================================================================
-- RUN TESTS
-- ============================================================================

SELECT test.run_module('numeric_03');
CALL test.print_run_summary();
