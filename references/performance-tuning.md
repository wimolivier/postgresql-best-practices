# Performance Tuning Patterns

This document covers query optimization, EXPLAIN analysis, connection pooling, and partitioning strategies for PostgreSQL.

## Table of Contents

1. [EXPLAIN ANALYZE Guide](#explain-analyze-guide)
2. [Common Query Optimizations](#common-query-optimizations)
3. [Index Optimization](#index-optimization)
4. [Connection Pooling](#connection-pooling)
5. [Prepared Statements](#prepared-statements)
6. [Partitioning Strategies](#partitioning-strategies)
7. [Configuration Tuning](#configuration-tuning)
8. [Monitoring Queries](#monitoring-queries)

## EXPLAIN ANALYZE Guide

### Basic Usage

```sql
-- Always use ANALYZE for actual execution times
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT * FROM data.orders WHERE customer_id = 'uuid-here';

-- For production-safe analysis (no actual execution)
EXPLAIN (COSTS, FORMAT TEXT)
SELECT * FROM data.orders WHERE customer_id = 'uuid-here';
```

### Reading EXPLAIN Output

```
                                                          QUERY PLAN
------------------------------------------------------------------------------------------------------------------------------
 Index Scan using orders_customer_id_idx on orders  (cost=0.43..8.45 rows=1 width=100) (actual time=0.025..0.027 rows=1 loops=1)
   Index Cond: (customer_id = 'uuid-here'::uuid)
   Buffers: shared hit=3
 Planning Time: 0.085 ms
 Execution Time: 0.045 ms
```

### Key Metrics to Watch

| Metric | Meaning | Concern Level |
|--------|---------|---------------|
| `Seq Scan` | Full table scan | ⚠️ Bad for large tables |
| `Index Scan` | Using B-tree index | ✅ Good |
| `Index Only Scan` | Data from index alone | ✅ Excellent |
| `Bitmap Heap Scan` | Multiple index conditions | ✅ Good for OR conditions |
| `Nested Loop` | Row-by-row join | ⚠️ Watch row counts |
| `Hash Join` | Hash table for join | ✅ Good for larger datasets |
| `Merge Join` | Sorted merge | ✅ Good for sorted data |
| `rows=X` vs `actual rows=Y` | Estimate accuracy | ⚠️ If very different, run ANALYZE |

### Common Problems and Solutions

#### Problem: Sequential Scan on Large Table

```sql
-- Bad: Full table scan
EXPLAIN ANALYZE
SELECT * FROM data.orders WHERE status = 'pending';

-- Shows: Seq Scan on orders (cost=0.00..1234.00 rows=50000 ...)

-- Solution: Add index
CREATE INDEX orders_status_idx ON data.orders(status);

-- Or partial index if status has few values
CREATE INDEX orders_pending_idx ON data.orders(created_at)
    WHERE status = 'pending';
```

#### Problem: Wrong Index Being Used

```sql
-- Check which indexes exist
SELECT indexname, indexdef 
FROM pg_indexes 
WHERE tablename = 'orders';

-- Force index usage for testing (not for production)
SET enable_seqscan = off;
EXPLAIN ANALYZE SELECT ...;
SET enable_seqscan = on;

-- Update statistics if estimates are wrong
ANALYZE data.orders;
```

#### Problem: Slow Join

```sql
-- Bad: Nested loop on large tables
EXPLAIN ANALYZE
SELECT o.*, c.name
FROM data.orders o
JOIN data.customers c ON c.id = o.customer_id
WHERE o.created_at > '2024-01-01';

-- Solution 1: Ensure FK is indexed
CREATE INDEX orders_customer_id_idx ON data.orders(customer_id);

-- Solution 2: Use covering index
CREATE INDEX orders_created_customer_idx
    ON data.orders(created_at, customer_id);
```

### EXPLAIN Format Options

```sql
-- Text (default, human readable)
EXPLAIN (FORMAT TEXT) SELECT ...;

-- JSON (for programmatic analysis)
EXPLAIN (FORMAT JSON) SELECT ...;

-- YAML
EXPLAIN (FORMAT YAML) SELECT ...;

-- Full analysis with all options
EXPLAIN (
    ANALYZE,           -- Actually execute
    BUFFERS,          -- Show buffer usage
    COSTS,            -- Show cost estimates
    TIMING,           -- Show actual timing
    VERBOSE,          -- Show extra info
    FORMAT TEXT
) SELECT ...;
```

## Common Query Optimizations

### Pagination Optimization

```sql
-- Bad: OFFSET for deep pagination
SELECT * FROM data.orders 
ORDER BY created_at DESC 
LIMIT 20 OFFSET 10000;  -- Scans 10020 rows!

-- Good: Keyset pagination (cursor-based)
SELECT * FROM data.orders 
WHERE created_at < $last_seen_created_at
ORDER BY created_at DESC 
LIMIT 20;

-- API function with keyset pagination
CREATE FUNCTION api.select_orders_paginated(
    in_cursor timestamptz DEFAULT NULL,
    in_limit integer DEFAULT 20
)
RETURNS TABLE (
    id uuid,
    created_at timestamptz,
    total numeric,
    next_cursor timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data, private, pg_temp
AS $$
    WITH page AS (
        SELECT id, created_at, total
        FROM data.orders
        WHERE (in_cursor IS NULL OR created_at < in_cursor)
        ORDER BY created_at DESC
        LIMIT in_limit + 1  -- Fetch one extra to detect more pages
    )
    SELECT 
        id,
        created_at,
        total,
        CASE 
            WHEN ROW_NUMBER() OVER () > in_limit THEN created_at
            ELSE NULL
        END AS next_cursor
    FROM page
    LIMIT in_limit;
$$;
```

### Avoiding N+1 Queries

```sql
-- Bad: Called in a loop from application
SELECT * FROM data.orders WHERE customer_id = $1;

-- Good: Batch fetch
CREATE FUNCTION api.select_orders_by_customers(in_customer_ids uuid[])
RETURNS TABLE (
    customer_id uuid,
    order_id uuid,
    total numeric
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data, private, pg_temp
AS $$
    SELECT customer_id, id, total
    FROM data.orders
    WHERE customer_id = ANY(in_customer_ids)
    ORDER BY customer_id, created_at DESC;
$$;
```

### Optimizing COUNT Queries

```sql
-- Bad: Exact count on large table
SELECT COUNT(*) FROM data.orders WHERE status = 'pending';

-- Good: Approximate count (very fast)
SELECT reltuples::bigint AS estimate
FROM pg_class
WHERE relname = 'orders';

-- Good: Exact count with limit check
CREATE FUNCTION api.count_orders_limited(
    in_status text,
    in_max integer DEFAULT 1000
)
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data, private, pg_temp
AS $$
    SELECT COUNT(*)::integer
    FROM (
        SELECT 1 FROM data.orders 
        WHERE status = in_status 
        LIMIT in_max
    ) sub;
$$;
```

### Conditional Aggregation

```sql
-- Bad: Multiple queries
SELECT COUNT(*) FROM data.orders WHERE status = 'pending';
SELECT COUNT(*) FROM data.orders WHERE status = 'shipped';
SELECT COUNT(*) FROM data.orders WHERE status = 'delivered';

-- Good: Single query with conditional aggregation
SELECT 
    COUNT(*) FILTER (WHERE status = 'pending') AS pending_count,
    COUNT(*) FILTER (WHERE status = 'shipped') AS shipped_count,
    COUNT(*) FILTER (WHERE status = 'delivered') AS delivered_count,
    SUM(total) FILTER (WHERE status = 'delivered') AS delivered_total
FROM data.orders
WHERE created_at > now() - interval '30 days';
```

### EXISTS vs IN vs JOIN

```sql
-- Use EXISTS for existence checks (usually fastest)
SELECT * FROM data.customers c
WHERE EXISTS (
    SELECT 1 FROM data.orders o 
    WHERE o.customer_id = c.id 
      AND o.status = 'pending'
);

-- Use IN for small, known lists
SELECT * FROM data.orders
WHERE status IN ('pending', 'processing', 'shipped');

-- Avoid NOT IN with NULLs (use NOT EXISTS)
-- Bad: Returns no rows if subquery has NULLs
SELECT * FROM data.customers
WHERE id NOT IN (SELECT customer_id FROM data.orders);

-- Good: Handles NULLs correctly
SELECT * FROM data.customers c
WHERE NOT EXISTS (
    SELECT 1 FROM data.orders o WHERE o.customer_id = c.id
);
```

## Index Optimization

### Composite Index Column Order

```sql
-- Rule: Most selective column first, range/sort column last

-- Query: WHERE status = 'pending' AND created_at > '2024-01-01'
-- Good: equality column first
CREATE INDEX orders_status_created_idx
    ON data.orders(status, created_at);

-- Query: WHERE customer_id = $1 ORDER BY created_at DESC
-- Good: equality first, sort last
CREATE INDEX orders_customer_created_idx
    ON data.orders(customer_id, created_at DESC);
```

### Covering Indexes

```sql
-- Query frequently needs id, total, status
-- Include extra columns to avoid table lookup
CREATE INDEX orders_customer_covering_idx
    ON data.orders(customer_id)
    INCLUDE (total, status, created_at);

-- Results in "Index Only Scan" - much faster
```

### Partial Indexes

```sql
-- Index only active customers (90% of queries)
CREATE INDEX customers_email_active_idx
    ON data.customers(email)
    WHERE is_active = true;

-- Index only recent orders
CREATE INDEX orders_pending_recent_idx
    ON data.orders(created_at)
    WHERE status = 'pending'
      AND created_at > '2024-01-01';

-- Much smaller index, faster updates
```

### Expression Indexes

```sql
-- Query: WHERE lower(email) = lower($1)
CREATE INDEX customers_email_lower_idx
    ON data.customers(lower(email));

-- Query: WHERE date_trunc('day', created_at) = $1
CREATE INDEX orders_created_day_idx
    ON data.orders(date_trunc('day', created_at));

-- Query: WHERE (data->>'category') = $1
CREATE INDEX products_category_idx
    ON data.products((data->>'category'));
```

### Index Maintenance

```sql
-- Check index usage
SELECT 
    schemaname,
    tablename,
    indexname,
    idx_scan,
    idx_tup_read,
    idx_tup_fetch
FROM pg_stat_user_indexes
WHERE schemaname = 'data'
ORDER BY idx_scan;

-- Find unused indexes (candidates for removal)
SELECT 
    schemaname || '.' || tablename AS table,
    indexname,
    pg_size_pretty(pg_relation_size(indexrelid)) AS size
FROM pg_stat_user_indexes
WHERE idx_scan = 0
  AND schemaname = 'data'
ORDER BY pg_relation_size(indexrelid) DESC;

-- Rebuild bloated indexes
REINDEX INDEX CONCURRENTLY orders_customer_id_idx;

-- Or rebuild all indexes on a table
REINDEX TABLE CONCURRENTLY data.orders;
```

## Connection Pooling

### PgBouncer with SECURITY DEFINER

When using connection pooling with `SECURITY DEFINER` functions, the functions execute as the function owner, not the pooled connection user. This is actually ideal for the Table API pattern.

```ini
# pgbouncer.ini
[databases]
myapp = host=localhost dbname=myapp

[pgbouncer]
listen_addr = 127.0.0.1
listen_port = 6432
auth_type = md5
auth_file = /etc/pgbouncer/userlist.txt
pool_mode = transaction  # Best for SECURITY DEFINER
max_client_conn = 1000
default_pool_size = 20
```

### Session Variables with Pooling

```sql
-- Problem: SET variables don't persist across pooled connections

-- Solution: Pass context as parameters
CREATE FUNCTION api.get_my_orders(in_user_id uuid)
RETURNS TABLE (...)
AS $$ ... $$;

-- Or use transaction-local settings
CREATE FUNCTION api.set_context(in_user_id uuid)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM set_config('myapp.user_id', in_user_id::text, true);  -- true = local to transaction
END;
$$;

-- Application calls at start of each transaction:
-- BEGIN;
-- SELECT api.set_context('user-uuid');
-- SELECT * FROM api.get_my_orders();
-- COMMIT;
```

### Pool Mode Recommendations

| Pool Mode | Use Case | SECURITY DEFINER Compatible |
|-----------|----------|----------------------------|
| `session` | Long-lived connections, session variables | ✅ Yes |
| `transaction` | Short queries, web apps | ✅ Yes (recommended) |
| `statement` | Simple queries only | ⚠️ Limited |

## Prepared Statements

Prepared statements separate query parsing/planning from execution. They improve performance for frequently executed queries by reusing the query plan.

### Basic PREPARE / EXECUTE

```sql
-- Prepare a named statement
PREPARE get_customer_orders (uuid) AS
    SELECT id, total, created_at
    FROM data.orders
    WHERE customer_id = $1
    ORDER BY created_at DESC;

-- Execute with parameters (plan is reused)
EXECUTE get_customer_orders('550e8400-e29b-41d4-a716-446655440000');

-- Deallocate when done
DEALLOCATE get_customer_orders;

-- Deallocate all prepared statements
DEALLOCATE ALL;
```

### When to Use

Prepared statements help when:
- The same query structure is executed hundreds or thousands of times per session
- The query has a stable plan regardless of parameter values
- You are using session-mode pooling or persistent connections

They add overhead when:
- A query is executed only once (parsing + planning cost is paid regardless, plus the extra round trip)
- Parameter values cause dramatically different optimal plans (e.g., highly skewed distributions)

### Plan Caching: Generic vs Custom Plans

PostgreSQL creates **custom plans** (parameter-specific) for the first 5 executions, then switches to a **generic plan** if it performs comparably. You can control this behavior.

```sql
-- Force generic plans (skip the 5 custom-plan warm-up)
SET plan_cache_mode = 'force_generic_plan';

-- Force custom plans (always re-plan with actual parameter values)
SET plan_cache_mode = 'force_custom_plan';

-- Default: auto-select (recommended for most workloads)
SET plan_cache_mode = 'auto';
```

Use `force_custom_plan` when parameter values produce very different result set sizes (e.g., `status = 'active'` returns 95% of rows vs `status = 'deleted'` returns 0.1%).

### Connection Pooling Interaction

Prepared statements are **per-connection state**. In transaction-mode pooling (the recommended mode for the Table API pattern), the server connection changes between transactions, so prepared statements are lost.

```ini
# pgbouncer.ini — clean up prepared statements when connection returns to pool
server_reset_query = DEALLOCATE ALL; DISCARD ALL
```

**Best approach**: Prefer server-side functions (Table API) over client-side prepared statements. When your application calls `SELECT * FROM api.get_customer(in_id := $1)`, PostgreSQL caches the plan for the function body automatically — no client-side `PREPARE` needed, and it works with any pool mode.

```sql
-- Table API function — plan is cached server-side, pool-mode safe
CREATE FUNCTION api.get_customer(in_id uuid)
RETURNS TABLE (id uuid, email text, name text)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data, private, pg_temp
AS $$
    SELECT id, email, name FROM data.customers WHERE id = in_id;
$$;
```

If you must use client-side prepared statements with PgBouncer 1.21+, enable `protocol_query` mode which proxies the PostgreSQL extended query protocol (Parse/Bind/Execute) and handles prepared statement forwarding transparently.

### Monitoring Prepared Statements

```sql
-- View all prepared statements in the current session
SELECT name, statement, prepare_time, parameter_types, result_types
FROM pg_prepared_statements;

-- Check if generic or custom plan is in use
-- (generic_plans > 0 indicates the planner switched to generic)
SELECT name, generic_plans, custom_plans
FROM pg_prepared_statements;
```

## Partitioning Strategies

### Range Partitioning (Time-Based)

```sql
-- Create partitioned table
CREATE TABLE data.events (
    id          uuid NOT NULL DEFAULT uuidv7(),
    event_type  text NOT NULL,
    payload     jsonb,
    created_at  timestamptz NOT NULL DEFAULT now()
) PARTITION BY RANGE (created_at);

-- Create partitions
CREATE TABLE data.events_2024_01 PARTITION OF data.events
    FOR VALUES FROM ('2024-01-01') TO ('2024-02-01');
CREATE TABLE data.events_2024_02 PARTITION OF data.events
    FOR VALUES FROM ('2024-02-01') TO ('2024-03-01');
-- ... more partitions

-- Create default partition for unexpected dates
CREATE TABLE data.events_default PARTITION OF data.events DEFAULT;

-- Indexes are created per-partition
CREATE INDEX events_2024_01_type_idx ON data.events_2024_01(event_type);
CREATE INDEX events_2024_02_type_idx ON data.events_2024_02(event_type);
```

### Automatic Partition Management

```sql
-- Function to create next month's partition
CREATE OR REPLACE FUNCTION private.create_next_event_partition()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_start_date date;
    l_end_date date;
    l_partition_name text;
BEGIN
    l_start_date := date_trunc('month', now() + interval '1 month');
    l_end_date := l_start_date + interval '1 month';
    l_partition_name := 'events_' || to_char(l_start_date, 'YYYY_MM');
    
    -- Check if partition exists
    IF NOT EXISTS (
        SELECT 1 FROM pg_tables 
        WHERE schemaname = 'data' AND tablename = l_partition_name
    ) THEN
        EXECUTE format(
            'CREATE TABLE data.%I PARTITION OF data.events 
             FOR VALUES FROM (%L) TO (%L)',
            l_partition_name, l_start_date, l_end_date
        );
        
        EXECUTE format(
            'CREATE INDEX %s_type_idx ON data.%I(event_type)',
            l_partition_name, l_partition_name
        );
        
        RAISE NOTICE 'Created partition: %', l_partition_name;
    END IF;
END;
$$;

-- Schedule with pg_cron
SELECT cron.schedule('create-event-partitions', '0 0 25 * *', 
    'SELECT private.create_next_event_partition()');
```

### List Partitioning (By Category)

```sql
-- Partition by region
CREATE TABLE data.customers (
    id      uuid NOT NULL DEFAULT uuidv7(),
    email   text NOT NULL,
    region  text NOT NULL,
    name    text
) PARTITION BY LIST (region);

CREATE TABLE data.customers_us PARTITION OF data.customers
    FOR VALUES IN ('us-east', 'us-west', 'us-central');
CREATE TABLE data.customers_eu PARTITION OF data.customers
    FOR VALUES IN ('eu-west', 'eu-central', 'eu-north');
CREATE TABLE data.customers_apac PARTITION OF data.customers
    FOR VALUES IN ('apac-east', 'apac-south');
```

### Hash Partitioning (Even Distribution)

```sql
-- Distribute by customer_id hash
CREATE TABLE data.order_items (
    id          uuid NOT NULL DEFAULT uuidv7(),
    order_id    uuid NOT NULL,
    customer_id uuid NOT NULL,
    product_id  uuid NOT NULL,
    quantity    integer NOT NULL
) PARTITION BY HASH (customer_id);

-- Create 4 partitions
CREATE TABLE data.order_items_p0 PARTITION OF data.order_items
    FOR VALUES WITH (MODULUS 4, REMAINDER 0);
CREATE TABLE data.order_items_p1 PARTITION OF data.order_items
    FOR VALUES WITH (MODULUS 4, REMAINDER 1);
CREATE TABLE data.order_items_p2 PARTITION OF data.order_items
    FOR VALUES WITH (MODULUS 4, REMAINDER 2);
CREATE TABLE data.order_items_p3 PARTITION OF data.order_items
    FOR VALUES WITH (MODULUS 4, REMAINDER 3);
```

## Configuration Tuning

### Memory Settings

```sql
-- Check current settings
SHOW shared_buffers;      -- RAM for caching (25% of RAM typical)
SHOW effective_cache_size; -- Estimate of OS cache (50-75% of RAM)
SHOW work_mem;            -- Per-operation sort memory (4-64MB typical)
SHOW maintenance_work_mem; -- For VACUUM, CREATE INDEX (256MB-1GB)

-- Recommended starting points (adjust for your workload)
-- In postgresql.conf:
-- shared_buffers = 4GB           # 25% of 16GB RAM
-- effective_cache_size = 12GB    # 75% of 16GB RAM
-- work_mem = 64MB                # For complex queries
-- maintenance_work_mem = 512MB   # For VACUUM/REINDEX
```

### Write Performance

```sql
-- For write-heavy workloads
-- wal_buffers = 64MB
-- checkpoint_completion_target = 0.9
-- max_wal_size = 4GB

-- For batch inserts (temporarily)
SET synchronous_commit = off;  -- Caution: risk of data loss
SET wal_level = minimal;       -- Requires restart, reduces WAL
```

### Query Planner

```sql
-- Check planner settings
SHOW random_page_cost;     -- SSD: 1.1, HDD: 4.0
SHOW effective_io_concurrency; -- SSD: 200, HDD: 2

-- Update for SSD storage
ALTER SYSTEM SET random_page_cost = 1.1;
ALTER SYSTEM SET effective_io_concurrency = 200;
SELECT pg_reload_conf();
```

## JIT Compilation

### Overview

JIT (Just-In-Time) compilation can speed up CPU-intensive queries by compiling expressions and tuple deforming into native code. Available since PostgreSQL 11.

### When JIT Helps

```sql
-- JIT beneficial for:
-- - Complex expressions in WHERE, SELECT
-- - Large table scans with many columns
-- - Aggregations over many rows
-- - Queries spending significant time in expression evaluation

-- Check if JIT is available
SELECT name, setting FROM pg_settings WHERE name LIKE 'jit%';
```

### JIT Settings

```sql
-- Enable/disable JIT (default: on in PG12+)
SET jit = on;

-- Cost thresholds (query must exceed these costs)
SET jit_above_cost = 100000;           -- Enable JIT (default: 100000)
SET jit_inline_above_cost = 500000;    -- Inline functions (default: 500000)
SET jit_optimize_above_cost = 500000;  -- Full optimization (default: 500000)

-- For OLAP/analytics workloads, lower thresholds
ALTER SYSTEM SET jit_above_cost = 10000;
ALTER SYSTEM SET jit_inline_above_cost = 50000;
ALTER SYSTEM SET jit_optimize_above_cost = 50000;
SELECT pg_reload_conf();
```

### Monitoring JIT Usage

```sql
-- Check JIT in EXPLAIN
EXPLAIN (ANALYZE, BUFFERS)
SELECT sum(total), avg(total), count(*)
FROM data.large_orders
WHERE status = 'completed';

-- Look for:
-- JIT:
--   Functions: 5
--   Options: Inlining true, Optimization true, Expressions true, Deforming true
--   Timing: Generation 1.234 ms, Inlining 5.678 ms, Optimization 12.345 ms, Emission 23.456 ms, Total 42.713 ms
```

### When to Disable JIT

```sql
-- JIT adds overhead for compilation
-- Disable for short OLTP queries

-- Session level
SET jit = off;

-- Or raise thresholds for mixed workloads
SET jit_above_cost = 500000;

-- In application connection
-- postgresql://user:pass@host/db?options=-c%20jit=off
```

### JIT Troubleshooting

```sql
-- JIT not being used when expected?
-- 1. Check if enabled
SHOW jit;

-- 2. Check if LLVM is installed
SELECT pg_jit_available();

-- 3. Check query cost exceeds threshold
EXPLAIN (COSTS) SELECT ...;
-- Total cost must exceed jit_above_cost

-- JIT slowing down queries?
-- Compilation time can exceed execution savings for small result sets
-- Solution: Raise thresholds or disable for that query
SET LOCAL jit = off;
```

## Monitoring Queries

### Slow Query Detection

```sql
-- Enable slow query logging in postgresql.conf
-- log_min_duration_statement = 1000  # Log queries > 1 second

-- Find slow queries with pg_stat_statements
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

SELECT 
    round(total_exec_time::numeric, 2) AS total_time_ms,
    calls,
    round(mean_exec_time::numeric, 2) AS avg_time_ms,
    round((100 * total_exec_time / sum(total_exec_time) OVER ())::numeric, 2) AS percent_total,
    query
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 20;
```

### Table Statistics

```sql
-- Table sizes
SELECT 
    schemaname,
    tablename,
    pg_size_pretty(pg_total_relation_size(schemaname || '.' || tablename)) AS total_size,
    pg_size_pretty(pg_relation_size(schemaname || '.' || tablename)) AS table_size,
    pg_size_pretty(pg_indexes_size(schemaname || '.' || tablename)) AS index_size
FROM pg_tables
WHERE schemaname = 'data'
ORDER BY pg_total_relation_size(schemaname || '.' || tablename) DESC;

-- Table activity
SELECT 
    schemaname,
    relname,
    seq_scan,
    seq_tup_read,
    idx_scan,
    idx_tup_fetch,
    n_tup_ins,
    n_tup_upd,
    n_tup_del,
    n_live_tup,
    n_dead_tup,
    last_vacuum,
    last_autovacuum,
    last_analyze
FROM pg_stat_user_tables
WHERE schemaname = 'data'
ORDER BY seq_scan DESC;
```

### Lock Monitoring

```sql
-- Current locks
SELECT 
    l.pid,
    l.mode,
    l.granted,
    a.usename,
    a.query,
    a.state,
    a.wait_event_type,
    a.wait_event
FROM pg_locks l
JOIN pg_stat_activity a ON l.pid = a.pid
WHERE l.relation IS NOT NULL
ORDER BY l.granted, l.pid;

-- Blocking queries
SELECT 
    blocked_locks.pid AS blocked_pid,
    blocked_activity.usename AS blocked_user,
    blocking_locks.pid AS blocking_pid,
    blocking_activity.usename AS blocking_user,
    blocked_activity.query AS blocked_statement,
    blocking_activity.query AS blocking_statement
FROM pg_catalog.pg_locks blocked_locks
JOIN pg_catalog.pg_stat_activity blocked_activity ON blocked_activity.pid = blocked_locks.pid
JOIN pg_catalog.pg_locks blocking_locks 
    ON blocking_locks.locktype = blocked_locks.locktype
    AND blocking_locks.database IS NOT DISTINCT FROM blocked_locks.database
    AND blocking_locks.relation IS NOT DISTINCT FROM blocked_locks.relation
    AND blocking_locks.page IS NOT DISTINCT FROM blocked_locks.page
    AND blocking_locks.tuple IS NOT DISTINCT FROM blocked_locks.tuple
    AND blocking_locks.virtualxid IS NOT DISTINCT FROM blocked_locks.virtualxid
    AND blocking_locks.transactionid IS NOT DISTINCT FROM blocked_locks.transactionid
    AND blocking_locks.classid IS NOT DISTINCT FROM blocked_locks.classid
    AND blocking_locks.objid IS NOT DISTINCT FROM blocked_locks.objid
    AND blocking_locks.objsubid IS NOT DISTINCT FROM blocked_locks.objsubid
    AND blocking_locks.pid != blocked_locks.pid
JOIN pg_catalog.pg_stat_activity blocking_activity ON blocking_activity.pid = blocking_locks.pid
WHERE NOT blocked_locks.granted;
```

### Custom Performance Views

```sql
-- Create view for easy monitoring
CREATE OR REPLACE VIEW api.v_performance_stats AS
SELECT 
    'table_stats' AS category,
    jsonb_build_object(
        'total_tables', (SELECT COUNT(*) FROM pg_tables WHERE schemaname = 'data'),
        'largest_table', (
            SELECT tablename FROM pg_tables 
            WHERE schemaname = 'data'
            ORDER BY pg_total_relation_size(schemaname || '.' || tablename) DESC
            LIMIT 1
        )
    ) AS stats
UNION ALL
SELECT 
    'cache_stats',
    jsonb_build_object(
        'cache_hit_ratio', (
            SELECT round(100.0 * sum(heap_blks_hit) / nullif(sum(heap_blks_hit) + sum(heap_blks_read), 0), 2)
            FROM pg_statio_user_tables
        )
    )
UNION ALL
SELECT 
    'connection_stats',
    jsonb_build_object(
        'active_connections', (SELECT COUNT(*) FROM pg_stat_activity WHERE state = 'active'),
        'idle_connections', (SELECT COUNT(*) FROM pg_stat_activity WHERE state = 'idle'),
        'max_connections', current_setting('max_connections')::int
    );
```
