# Advanced Window Functions

This document covers PostgreSQL window functions including frame specifications, ranking, running calculations, and gap/island analysis.

## Table of Contents

1. [Overview](#overview)
2. [Window Function Syntax](#window-function-syntax)
3. [Frame Specifications](#frame-specifications)
4. [Ranking Functions](#ranking-functions)
5. [Aggregate Window Functions](#aggregate-window-functions)
6. [Value Functions](#value-functions)
7. [Common Patterns](#common-patterns)
8. [Performance Considerations](#performance-considerations)

## Overview

### When to Use Window Functions

| Use Case | Window Function | Alternative |
|----------|----------------|-------------|
| Running total | `SUM() OVER` | Subquery (slower) |
| Ranking | `ROW_NUMBER()`, `RANK()` | Subquery |
| Moving average | `AVG() OVER` | Application code |
| Comparing to previous | `LAG()`, `LEAD()` | Self-join |
| First/last in group | `FIRST_VALUE()` | `DISTINCT ON` |
| Percentiles | `PERCENT_RANK()` | Subquery |

### Window vs Aggregate Functions

```sql
-- Aggregate: Collapses rows into one
SELECT customer_id, SUM(total) AS total_sales
FROM data.orders
GROUP BY customer_id;

-- Window: Keeps all rows, adds calculated column
SELECT
    id,
    customer_id,
    total,
    SUM(total) OVER (PARTITION BY customer_id) AS customer_total
FROM data.orders;
```

## Window Function Syntax

### Basic Syntax

```sql
function_name(arguments) OVER (
    [PARTITION BY partition_expression, ...]
    [ORDER BY sort_expression [ASC | DESC] [NULLS {FIRST | LAST}], ...]
    [frame_clause]
)
```

### PARTITION BY

```sql
-- Without PARTITION BY: All rows in one partition
SELECT id, total, SUM(total) OVER () AS grand_total
FROM data.orders;

-- With PARTITION BY: Separate calculation per group
SELECT
    id,
    customer_id,
    total,
    SUM(total) OVER (PARTITION BY customer_id) AS customer_total,
    SUM(total) OVER () AS grand_total
FROM data.orders;
```

### ORDER BY

```sql
-- Running total (cumulative sum)
SELECT
    id,
    created_at,
    total,
    SUM(total) OVER (ORDER BY created_at) AS running_total
FROM data.orders;

-- Running total per customer
SELECT
    id,
    customer_id,
    created_at,
    total,
    SUM(total) OVER (PARTITION BY customer_id ORDER BY created_at) AS customer_running_total
FROM data.orders;
```

### Named Windows (WINDOW Clause)

```sql
-- Define window once, reuse multiple times
SELECT
    id,
    customer_id,
    total,
    SUM(total) OVER w AS running_total,
    AVG(total) OVER w AS running_avg,
    COUNT(*) OVER w AS running_count
FROM data.orders
WINDOW w AS (PARTITION BY customer_id ORDER BY created_at);
```

## Frame Specifications

### Frame Types

```sql
-- ROWS: Physical rows
-- RANGE: Logical range based on ORDER BY value
-- GROUPS: Groups of peers (same ORDER BY value)

-- Frame bounds:
-- UNBOUNDED PRECEDING: First row of partition
-- N PRECEDING: N rows/value before current
-- CURRENT ROW: Current row
-- N FOLLOWING: N rows/value after current
-- UNBOUNDED FOLLOWING: Last row of partition
```

### ROWS Frame

```sql
-- Last 3 rows (physical)
SELECT
    id,
    value,
    AVG(value) OVER (
        ORDER BY created_at
        ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
    ) AS moving_avg_3
FROM data.metrics;

-- 5-row centered window
SELECT
    id,
    value,
    AVG(value) OVER (
        ORDER BY created_at
        ROWS BETWEEN 2 PRECEDING AND 2 FOLLOWING
    ) AS centered_avg_5
FROM data.metrics;
```

### RANGE Frame

```sql
-- Values within ±10 of current value
SELECT
    id,
    score,
    COUNT(*) OVER (
        ORDER BY score
        RANGE BETWEEN 10 PRECEDING AND 10 FOLLOWING
    ) AS nearby_count
FROM data.scores;

-- Time-based: last 5 minutes
SELECT
    id,
    recorded_at,
    value,
    AVG(value) OVER (
        ORDER BY recorded_at
        RANGE BETWEEN interval '5 minutes' PRECEDING AND CURRENT ROW
    ) AS avg_last_5min
FROM data.events;
```

### GROUPS Frame

```sql
-- Include N groups of peers
SELECT
    id,
    category,
    value,
    SUM(value) OVER (
        ORDER BY category
        GROUPS BETWEEN 1 PRECEDING AND 1 FOLLOWING
    ) AS sum_adjacent_categories
FROM data.items;
```

### Default Frames

```sql
-- Without ORDER BY: entire partition
-- RANGE BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING

-- With ORDER BY: up to current row
-- RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW

-- Explicit full partition
SUM(total) OVER (PARTITION BY customer_id ORDER BY created_at
    ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING)
```

## Ranking Functions

### ROW_NUMBER, RANK, DENSE_RANK

```sql
SELECT
    id,
    customer_id,
    total,
    -- ROW_NUMBER: Unique sequential numbers (1, 2, 3, 4, 5)
    ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY total DESC) AS row_num,

    -- RANK: Same rank for ties, gaps after (1, 2, 2, 4, 5)
    RANK() OVER (PARTITION BY customer_id ORDER BY total DESC) AS rank,

    -- DENSE_RANK: Same rank for ties, no gaps (1, 2, 2, 3, 4)
    DENSE_RANK() OVER (PARTITION BY customer_id ORDER BY total DESC) AS dense_rank
FROM data.orders;
```

### NTILE

```sql
-- Divide into N buckets
SELECT
    id,
    total,
    NTILE(4) OVER (ORDER BY total) AS quartile,
    NTILE(10) OVER (ORDER BY total) AS decile,
    NTILE(100) OVER (ORDER BY total) AS percentile_bucket
FROM data.orders;
```

### PERCENT_RANK and CUME_DIST

```sql
SELECT
    id,
    total,
    -- PERCENT_RANK: Relative rank (0 to 1)
    -- (rank - 1) / (total rows - 1)
    PERCENT_RANK() OVER (ORDER BY total) AS percent_rank,

    -- CUME_DIST: Cumulative distribution
    -- rows with value <= current / total rows
    CUME_DIST() OVER (ORDER BY total) AS cumulative_dist
FROM data.orders;
```

### Top N per Group

```sql
-- Top 3 orders per customer
SELECT *
FROM (
    SELECT
        *,
        ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY total DESC) AS rn
    FROM data.orders
) sub
WHERE rn <= 3;

-- Using LATERAL (alternative)
SELECT o.*
FROM data.customers c
CROSS JOIN LATERAL (
    SELECT *
    FROM data.orders
    WHERE customer_id = c.id
    ORDER BY total DESC
    LIMIT 3
) o;
```

## Aggregate Window Functions

### Running Totals

```sql
-- Running sum
SELECT
    id,
    created_at,
    amount,
    SUM(amount) OVER (ORDER BY created_at) AS running_total
FROM data.transactions;

-- Running sum per account
SELECT
    id,
    account_id,
    created_at,
    amount,
    SUM(amount) OVER (PARTITION BY account_id ORDER BY created_at) AS account_balance
FROM data.transactions;
```

### Moving Averages

```sql
-- Simple moving average (last 7 rows)
SELECT
    date,
    value,
    AVG(value) OVER (ORDER BY date ROWS BETWEEN 6 PRECEDING AND CURRENT ROW) AS sma_7
FROM data.daily_metrics;

-- Exponential moving average (approximation)
-- True EMA requires recursive CTE or custom aggregate
SELECT
    date,
    value,
    AVG(value) OVER (ORDER BY date ROWS BETWEEN 6 PRECEDING AND CURRENT ROW) *
        (2.0 / 8) + LAG(value) OVER (ORDER BY date) * (1 - 2.0 / 8) AS ema_approx
FROM data.daily_metrics;
```

### Running Count and Statistics

```sql
SELECT
    id,
    created_at,
    value,
    COUNT(*) OVER (ORDER BY created_at) AS running_count,
    AVG(value) OVER (ORDER BY created_at) AS running_avg,
    MIN(value) OVER (ORDER BY created_at) AS running_min,
    MAX(value) OVER (ORDER BY created_at) AS running_max,
    STDDEV(value) OVER (ORDER BY created_at) AS running_stddev
FROM data.measurements;
```

## Value Functions

### LAG and LEAD

```sql
SELECT
    id,
    created_at,
    value,
    -- Previous value
    LAG(value) OVER (ORDER BY created_at) AS prev_value,

    -- Next value
    LEAD(value) OVER (ORDER BY created_at) AS next_value,

    -- N rows back (default if null)
    LAG(value, 3, 0) OVER (ORDER BY created_at) AS value_3_back,

    -- Change from previous
    value - LAG(value) OVER (ORDER BY created_at) AS change
FROM data.metrics;
```

### FIRST_VALUE, LAST_VALUE, NTH_VALUE

```sql
SELECT
    id,
    customer_id,
    created_at,
    total,
    -- First order total for customer
    FIRST_VALUE(total) OVER (
        PARTITION BY customer_id ORDER BY created_at
    ) AS first_order_total,

    -- Last order total (need full frame!)
    LAST_VALUE(total) OVER (
        PARTITION BY customer_id ORDER BY created_at
        ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
    ) AS last_order_total,

    -- Third order total
    NTH_VALUE(total, 3) OVER (
        PARTITION BY customer_id ORDER BY created_at
    ) AS third_order_total
FROM data.orders;
```

## Common Patterns

### Gap and Island Detection

```sql
-- Identify consecutive sequences (islands)
WITH numbered AS (
    SELECT
        id,
        status,
        created_at,
        ROW_NUMBER() OVER (ORDER BY created_at) AS rn,
        ROW_NUMBER() OVER (PARTITION BY status ORDER BY created_at) AS status_rn
    FROM data.events
),
islands AS (
    SELECT
        id,
        status,
        created_at,
        rn - status_rn AS island_id
    FROM numbered
)
SELECT
    status,
    island_id,
    MIN(created_at) AS island_start,
    MAX(created_at) AS island_end,
    COUNT(*) AS island_size
FROM islands
GROUP BY status, island_id
ORDER BY island_start;
```

### Year-over-Year Comparison

```sql
SELECT
    date_trunc('month', created_at) AS month,
    SUM(total) AS revenue,
    LAG(SUM(total), 12) OVER (ORDER BY date_trunc('month', created_at)) AS revenue_last_year,
    ROUND(
        100.0 * (SUM(total) - LAG(SUM(total), 12) OVER (ORDER BY date_trunc('month', created_at)))
        / NULLIF(LAG(SUM(total), 12) OVER (ORDER BY date_trunc('month', created_at)), 0),
        2
    ) AS yoy_growth_pct
FROM data.orders
GROUP BY date_trunc('month', created_at)
ORDER BY month;
```

### Running Percentage of Total

```sql
SELECT
    id,
    category,
    total,
    ROUND(
        100.0 * SUM(total) OVER (ORDER BY total DESC) /
        SUM(total) OVER (),
        2
    ) AS cumulative_pct,
    ROUND(
        100.0 * total / SUM(total) OVER (),
        2
    ) AS pct_of_total
FROM data.orders;
```

### Sessionization

```sql
-- Group events into sessions based on time gaps
WITH event_gaps AS (
    SELECT
        id,
        user_id,
        created_at,
        created_at - LAG(created_at) OVER (PARTITION BY user_id ORDER BY created_at) AS gap
    FROM data.events
),
session_markers AS (
    SELECT
        *,
        CASE
            WHEN gap IS NULL OR gap > interval '30 minutes'
            THEN 1
            ELSE 0
        END AS new_session
    FROM event_gaps
)
SELECT
    id,
    user_id,
    created_at,
    SUM(new_session) OVER (PARTITION BY user_id ORDER BY created_at) AS session_id
FROM session_markers;
```

### Percentile Calculations

```sql
SELECT
    category,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY value) AS median,
    PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY value) AS p25,
    PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY value) AS p75,
    PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY value) AS p95,
    PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY value) AS p99
FROM data.metrics
GROUP BY category;

-- Per-row percentile (window mode)
SELECT
    id,
    value,
    PERCENT_RANK() OVER (ORDER BY value) AS percentile,
    NTILE(100) OVER (ORDER BY value) AS percentile_bucket
FROM data.metrics;
```

### Delta Encoding

```sql
-- Store differences instead of absolute values
SELECT
    id,
    created_at,
    value,
    value - COALESCE(LAG(value) OVER (ORDER BY created_at), 0) AS delta
FROM data.time_series;
```

## Performance Considerations

### Index Support

```sql
-- Window functions benefit from indexes on:
-- 1. PARTITION BY columns
-- 2. ORDER BY columns
-- 3. Combined (partition, order)

CREATE INDEX orders_customer_created_idx
    ON data.orders (customer_id, created_at);

-- Query uses index for both partitioning and ordering
SELECT
    customer_id,
    created_at,
    total,
    SUM(total) OVER (PARTITION BY customer_id ORDER BY created_at) AS running_total
FROM data.orders;
```

### Memory Usage

```sql
-- Large partitions consume more memory
-- Check work_mem setting
SHOW work_mem;

-- Increase for complex window operations
SET work_mem = '256MB';

-- Or per-session
SET LOCAL work_mem = '256MB';
```

### Avoiding Multiple Passes

```sql
-- ❌ Bad: Multiple window calculations with different partitions
SELECT
    *,
    SUM(total) OVER (PARTITION BY customer_id) AS customer_total,
    SUM(total) OVER (PARTITION BY product_id) AS product_total
FROM data.order_items;

-- ✅ Better: Use named window or pre-compute
WITH customer_totals AS (
    SELECT customer_id, SUM(total) AS total
    FROM data.order_items
    GROUP BY customer_id
),
product_totals AS (
    SELECT product_id, SUM(total) AS total
    FROM data.order_items
    GROUP BY product_id
)
SELECT
    oi.*,
    ct.total AS customer_total,
    pt.total AS product_total
FROM data.order_items oi
JOIN customer_totals ct ON oi.customer_id = ct.customer_id
JOIN product_totals pt ON oi.product_id = pt.product_id;
```

### EXPLAIN ANALYZE

```sql
-- Check window function execution
EXPLAIN (ANALYZE, BUFFERS)
SELECT
    customer_id,
    created_at,
    total,
    SUM(total) OVER (PARTITION BY customer_id ORDER BY created_at) AS running_total
FROM data.orders
WHERE created_at >= '2024-01-01';

-- Look for: WindowAgg, Sort, Index Scan
```
