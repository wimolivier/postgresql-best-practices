# Time-Series Data Patterns

This document covers time-series data optimization in native PostgreSQL, including table design, partitioning, indexing strategies, and efficient querying patterns.

## Table of Contents

1. [Overview](#overview)
2. [Table Design](#table-design)
3. [Partitioning for Time-Series](#partitioning-for-time-series)
4. [Indexing Strategies](#indexing-strategies)
5. [Query Patterns](#query-patterns)
6. [Downsampling & Aggregation](#downsampling--aggregation)
7. [Retention Management](#retention-management)
8. [Performance Optimization](#performance-optimization)

## Overview

### Time-Series Characteristics

| Characteristic | Description | Impact |
|---------------|-------------|--------|
| Append-heavy | Mostly INSERTs, rare UPDATEs | Optimize for writes |
| Time-ordered | Data arrives in time order | Use BRIN indexes |
| Range queries | Query by time windows | Partition by time |
| High cardinality | Many unique time points | Consider aggregation |
| Retention | Old data less valuable | Drop old partitions |

### When to Use Native PostgreSQL vs TimescaleDB

| Scenario | Native PostgreSQL | TimescaleDB |
|----------|-------------------|-------------|
| < 100M rows | ✅ Sufficient | Good |
| Simple queries | ✅ Sufficient | Good |
| Automatic partitioning | Manual | ✅ Automatic |
| Compression | ❌ Limited | ✅ Excellent |
| Continuous aggregates | Manual | ✅ Built-in |
| Already using PG | ✅ No extra setup | Requires extension |

## Table Design

### Basic Time-Series Table

```sql
CREATE TABLE data.metrics (
    id              uuid DEFAULT uuidv7(),
    device_id       uuid NOT NULL,
    metric_name     text NOT NULL,
    value           double precision NOT NULL,
    recorded_at     timestamptz NOT NULL DEFAULT now(),

    -- Composite primary key including time for partitioning
    PRIMARY KEY (device_id, recorded_at, id)
);

-- Comment on design decisions
COMMENT ON TABLE data.metrics IS 'Time-series metrics data, partitioned by month';
```

### Wide Table Design (Multiple Metrics)

```sql
-- Wide table: one row per timestamp with multiple values
CREATE TABLE data.sensor_readings (
    id              uuid DEFAULT uuidv7(),
    sensor_id       uuid NOT NULL,
    recorded_at     timestamptz NOT NULL DEFAULT now(),

    -- Multiple metrics per row
    temperature     double precision,
    humidity        double precision,
    pressure        double precision,
    battery_level   smallint,

    PRIMARY KEY (sensor_id, recorded_at)
);
```

### Narrow Table Design (EAV-Style)

```sql
-- Narrow table: one row per metric per timestamp
CREATE TABLE data.measurements (
    id              uuid DEFAULT uuidv7(),
    entity_id       uuid NOT NULL,
    metric_name     text NOT NULL,
    recorded_at     timestamptz NOT NULL DEFAULT now(),
    value           double precision NOT NULL,

    PRIMARY KEY (entity_id, metric_name, recorded_at)
);

-- Use when metrics are dynamic or sparse
```

### Optimized Columnar Layout

```sql
-- Ordered columns for better compression
CREATE TABLE data.events (
    -- High cardinality, frequently filtered
    recorded_at     timestamptz NOT NULL,
    event_type      text NOT NULL,

    -- Foreign key
    device_id       uuid NOT NULL,

    -- Payload (larger, variable)
    value           double precision,
    metadata        jsonb DEFAULT '{}',

    -- Primary key last (for TOAST ordering)
    id              uuid DEFAULT uuidv7(),

    PRIMARY KEY (recorded_at, device_id, id)
) WITH (fillfactor = 90);  -- Allow for some updates
```

## Partitioning for Time-Series

### Monthly Partitioning

```sql
-- Create partitioned table
CREATE TABLE data.events (
    id              uuid NOT NULL DEFAULT uuidv7(),
    event_type      text NOT NULL,
    device_id       uuid NOT NULL,
    value           double precision,
    recorded_at     timestamptz NOT NULL DEFAULT now(),

    PRIMARY KEY (id, recorded_at)
) PARTITION BY RANGE (recorded_at);

-- Create monthly partitions
CREATE TABLE data.events_2024_01 PARTITION OF data.events
    FOR VALUES FROM ('2024-01-01') TO ('2024-02-01');
CREATE TABLE data.events_2024_02 PARTITION OF data.events
    FOR VALUES FROM ('2024-02-01') TO ('2024-03-01');
-- ... continue for each month

-- Default partition for out-of-range data
CREATE TABLE data.events_default PARTITION OF data.events DEFAULT;
```

### Daily Partitioning (High Volume)

```sql
-- For very high volume data
CREATE TABLE data.logs (
    id              uuid NOT NULL DEFAULT uuidv7(),
    level           text NOT NULL,
    message         text NOT NULL,
    recorded_at     timestamptz NOT NULL DEFAULT now(),

    PRIMARY KEY (id, recorded_at)
) PARTITION BY RANGE (recorded_at);

-- Automated daily partition creation
CREATE FUNCTION private.create_daily_partition(
    in_table_name text,
    in_date date
)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
    l_partition_name text;
    l_start_date date := in_date;
    l_end_date date := in_date + 1;
BEGIN
    l_partition_name := in_table_name || '_' || to_char(in_date, 'YYYY_MM_DD');

    EXECUTE format(
        'CREATE TABLE IF NOT EXISTS data.%I PARTITION OF data.%I FOR VALUES FROM (%L) TO (%L)',
        l_partition_name, in_table_name, l_start_date, l_end_date
    );

    RETURN l_partition_name;
END;
$$;

-- Create next 7 days of partitions
SELECT private.create_daily_partition('logs', current_date + i)
FROM generate_series(0, 7) AS i;
```

### Partition Maintenance Automation

```sql
-- Create upcoming partitions and drop old ones
CREATE PROCEDURE private.maintain_time_series_partitions(
    in_table_name text,
    in_partition_interval interval,
    in_create_ahead integer,
    in_retention_periods integer
)
LANGUAGE plpgsql
AS $$
DECLARE
    l_current_period date;
    l_i integer;
BEGIN
    -- Create upcoming partitions
    FOR l_i IN 0..in_create_ahead LOOP
        l_current_period := date_trunc(
            CASE
                WHEN in_partition_interval = '1 month' THEN 'month'
                WHEN in_partition_interval = '1 day' THEN 'day'
                WHEN in_partition_interval = '1 week' THEN 'week'
            END,
            now() + (l_i * in_partition_interval)
        );

        PERFORM private.create_partition(in_table_name, l_current_period, in_partition_interval);
    END LOOP;

    -- Drop old partitions
    PERFORM private.drop_old_partitions(
        in_table_name,
        now() - (in_retention_periods * in_partition_interval)
    );
END;
$$;

-- Schedule with pg_cron
SELECT cron.schedule(
    'maintain-events-partitions',
    '0 1 * * *',
    $$CALL private.maintain_time_series_partitions('events', '1 month', 3, 12)$$
);
```

## Indexing Strategies

### BRIN Index (Block Range Index)

```sql
-- BRIN: Perfect for naturally time-ordered data
-- Very small index size, fast range scans

CREATE INDEX events_recorded_at_brin_idx
    ON data.events USING brin (recorded_at)
    WITH (pages_per_range = 128);

-- BRIN works best when data is physically ordered
-- Insert data in time order for best results

-- Check correlation (should be close to 1 or -1)
SELECT correlation
FROM pg_stats
WHERE tablename = 'events' AND attname = 'recorded_at';
```

### Composite B-tree Index

```sql
-- For queries filtering by device + time range
CREATE INDEX events_device_time_idx
    ON data.events (device_id, recorded_at DESC);

-- Covering index for common queries
CREATE INDEX events_device_time_covering_idx
    ON data.events (device_id, recorded_at DESC)
    INCLUDE (event_type, value);
```

### Partial Indexes for Recent Data

```sql
-- Index only recent data (hot data)
CREATE INDEX events_recent_idx
    ON data.events (device_id, recorded_at)
    WHERE recorded_at > now() - interval '7 days';

-- Recreate periodically to update the condition
-- This requires a function to manage the index

CREATE PROCEDURE private.refresh_recent_index()
LANGUAGE plpgsql
AS $$
BEGIN
    DROP INDEX IF EXISTS data.events_recent_idx;

    EXECUTE format(
        'CREATE INDEX events_recent_idx ON data.events (device_id, recorded_at) WHERE recorded_at > %L',
        now() - interval '7 days'
    );
END;
$$;
```

### Per-Partition Indexes

```sql
-- Indexes are automatically created on each partition
-- when you create an index on the parent table

CREATE INDEX events_type_idx ON data.events (event_type);
-- Creates: events_2024_01_event_type_idx, events_2024_02_event_type_idx, etc.

-- For special per-partition indexes
CREATE INDEX events_2024_01_special_idx
    ON data.events_2024_01 (value)
    WHERE event_type = 'critical';
```

## Query Patterns

### Time Range Query

```sql
-- Basic range query (uses partition pruning)
SELECT *
FROM data.events
WHERE recorded_at >= '2024-03-01'
  AND recorded_at < '2024-03-02'
ORDER BY recorded_at;

-- With device filter
SELECT *
FROM data.events
WHERE device_id = 'device-uuid'
  AND recorded_at >= now() - interval '24 hours'
ORDER BY recorded_at DESC
LIMIT 100;
```

### Latest Value per Device

```sql
-- Get most recent reading per device
SELECT DISTINCT ON (device_id)
    device_id,
    recorded_at,
    value
FROM data.events
WHERE recorded_at >= now() - interval '1 hour'
ORDER BY device_id, recorded_at DESC;

-- Alternative using lateral join (can be faster)
SELECT d.id AS device_id, e.recorded_at, e.value
FROM data.devices d
CROSS JOIN LATERAL (
    SELECT recorded_at, value
    FROM data.events
    WHERE device_id = d.id
    ORDER BY recorded_at DESC
    LIMIT 1
) e;
```

### Time Bucketing

```sql
-- Aggregate into time buckets
SELECT
    date_trunc('hour', recorded_at) AS bucket,
    device_id,
    avg(value) AS avg_value,
    min(value) AS min_value,
    max(value) AS max_value,
    count(*) AS count
FROM data.events
WHERE recorded_at >= now() - interval '24 hours'
GROUP BY 1, 2
ORDER BY 1 DESC, 2;

-- Custom bucket size (15 minutes)
SELECT
    date_bin('15 minutes', recorded_at, timestamptz '2024-01-01') AS bucket,
    device_id,
    avg(value) AS avg_value
FROM data.events
WHERE recorded_at >= now() - interval '24 hours'
GROUP BY 1, 2
ORDER BY 1;
```

### Gap Detection

```sql
-- Find gaps in time-series data
WITH readings AS (
    SELECT
        device_id,
        recorded_at,
        lead(recorded_at) OVER (PARTITION BY device_id ORDER BY recorded_at) AS next_at
    FROM data.events
    WHERE device_id = 'device-uuid'
      AND recorded_at >= now() - interval '24 hours'
)
SELECT
    device_id,
    recorded_at AS gap_start,
    next_at AS gap_end,
    next_at - recorded_at AS gap_duration
FROM readings
WHERE next_at - recorded_at > interval '5 minutes'
ORDER BY gap_duration DESC;
```

### Moving Averages

```sql
-- Rolling average over last N readings
SELECT
    recorded_at,
    value,
    avg(value) OVER (
        ORDER BY recorded_at
        ROWS BETWEEN 9 PRECEDING AND CURRENT ROW
    ) AS moving_avg_10,
    avg(value) OVER (
        ORDER BY recorded_at
        ROWS BETWEEN 59 PRECEDING AND CURRENT ROW
    ) AS moving_avg_60
FROM data.events
WHERE device_id = 'device-uuid'
  AND recorded_at >= now() - interval '1 hour'
ORDER BY recorded_at;

-- Time-based window (last 5 minutes)
SELECT
    recorded_at,
    value,
    avg(value) OVER (
        ORDER BY recorded_at
        RANGE BETWEEN interval '5 minutes' PRECEDING AND CURRENT ROW
    ) AS moving_avg
FROM data.events
WHERE device_id = 'device-uuid'
ORDER BY recorded_at;
```

## Downsampling & Aggregation

### Continuous Aggregation (Materialized View)

```sql
-- Create materialized view for hourly aggregates
CREATE MATERIALIZED VIEW data.mv_events_hourly AS
SELECT
    date_trunc('hour', recorded_at) AS bucket,
    device_id,
    event_type,
    count(*) AS event_count,
    avg(value) AS avg_value,
    min(value) AS min_value,
    max(value) AS max_value,
    percentile_cont(0.95) WITHIN GROUP (ORDER BY value) AS p95_value
FROM data.events
GROUP BY 1, 2, 3
WITH NO DATA;

-- Create indexes on materialized view
CREATE INDEX mv_events_hourly_bucket_idx ON data.mv_events_hourly (bucket);
CREATE INDEX mv_events_hourly_device_idx ON data.mv_events_hourly (device_id, bucket);

-- Initial population
REFRESH MATERIALIZED VIEW data.mv_events_hourly;

-- Schedule refresh
SELECT cron.schedule(
    'refresh-events-hourly',
    '5 * * * *',  -- 5 minutes after each hour
    $$REFRESH MATERIALIZED VIEW CONCURRENTLY data.mv_events_hourly$$
);
```

### Incremental Aggregation Table

```sql
-- Pre-computed aggregates table
CREATE TABLE data.events_hourly (
    bucket          timestamptz NOT NULL,
    device_id       uuid NOT NULL,
    event_type      text NOT NULL,
    event_count     integer NOT NULL DEFAULT 0,
    value_sum       double precision NOT NULL DEFAULT 0,
    value_min       double precision,
    value_max       double precision,

    PRIMARY KEY (bucket, device_id, event_type)
);

-- Upsert aggregates
CREATE PROCEDURE private.aggregate_events_hourly(in_hour timestamptz)
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO data.events_hourly (bucket, device_id, event_type, event_count, value_sum, value_min, value_max)
    SELECT
        date_trunc('hour', recorded_at) AS bucket,
        device_id,
        event_type,
        count(*),
        sum(value),
        min(value),
        max(value)
    FROM data.events
    WHERE recorded_at >= in_hour
      AND recorded_at < in_hour + interval '1 hour'
    GROUP BY 1, 2, 3
    ON CONFLICT (bucket, device_id, event_type) DO UPDATE SET
        event_count = EXCLUDED.event_count,
        value_sum = EXCLUDED.value_sum,
        value_min = LEAST(events_hourly.value_min, EXCLUDED.value_min),
        value_max = GREATEST(events_hourly.value_max, EXCLUDED.value_max);
END;
$$;

-- Schedule aggregation
SELECT cron.schedule(
    'aggregate-events-hourly',
    '0 * * * *',
    $$CALL private.aggregate_events_hourly(date_trunc('hour', now() - interval '1 hour'))$$
);
```

### Multi-Resolution Aggregates

```sql
-- Store aggregates at multiple resolutions
CREATE TABLE data.events_1min (
    bucket timestamptz, device_id uuid, event_count int, value_avg double precision,
    PRIMARY KEY (bucket, device_id)
);

CREATE TABLE data.events_5min (
    bucket timestamptz, device_id uuid, event_count int, value_avg double precision,
    PRIMARY KEY (bucket, device_id)
);

CREATE TABLE data.events_1hour (
    bucket timestamptz, device_id uuid, event_count int, value_avg double precision,
    PRIMARY KEY (bucket, device_id)
);

-- Query function that selects appropriate resolution
CREATE FUNCTION api.get_events_aggregated(
    in_device_id uuid,
    in_start timestamptz,
    in_end timestamptz
)
RETURNS TABLE (bucket timestamptz, event_count int, value_avg double precision)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    l_duration interval := in_end - in_start;
BEGIN
    IF l_duration <= interval '1 hour' THEN
        -- Use raw data for short ranges
        RETURN QUERY
        SELECT
            date_trunc('minute', recorded_at),
            count(*)::int,
            avg(value)
        FROM data.events
        WHERE device_id = in_device_id
          AND recorded_at >= in_start AND recorded_at < in_end
        GROUP BY 1;
    ELSIF l_duration <= interval '1 day' THEN
        -- Use 5-minute aggregates
        RETURN QUERY
        SELECT bucket, event_count, value_avg
        FROM data.events_5min
        WHERE device_id = in_device_id
          AND bucket >= in_start AND bucket < in_end;
    ELSE
        -- Use hourly aggregates
        RETURN QUERY
        SELECT bucket, event_count, value_avg
        FROM data.events_1hour
        WHERE device_id = in_device_id
          AND bucket >= in_start AND bucket < in_end;
    END IF;
END;
$$;
```

## Retention Management

### Drop Old Partitions

```sql
-- Drop partitions older than retention period
CREATE FUNCTION private.drop_old_partitions(
    in_parent_table text,
    in_cutoff timestamptz
)
RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE
    l_partition record;
    l_count integer := 0;
BEGIN
    FOR l_partition IN
        SELECT c.relname AS partition_name
        FROM pg_inherits i
        JOIN pg_class p ON i.inhparent = p.oid
        JOIN pg_class c ON i.inhrelid = c.oid
        WHERE p.relname = in_parent_table
    LOOP
        -- Extract date from partition name and compare
        -- Assumes naming like events_2024_01
        BEGIN
            IF to_date(
                substring(l_partition.partition_name from '\d{4}_\d{2}'),
                'YYYY_MM'
            ) < date_trunc('month', in_cutoff) THEN
                EXECUTE format('DROP TABLE data.%I', l_partition.partition_name);
                l_count := l_count + 1;
                RAISE NOTICE 'Dropped partition: %', l_partition.partition_name;
            END IF;
        EXCEPTION WHEN OTHERS THEN
            -- Skip partitions that don't match expected format
            NULL;
        END;
    END LOOP;

    RETURN l_count;
END;
$$;
```

### Archive Before Drop

```sql
-- Archive to cold storage before dropping
CREATE PROCEDURE private.archive_and_drop_partition(
    in_partition_name text,
    in_archive_path text
)
LANGUAGE plpgsql
AS $$
BEGIN
    -- Export to CSV
    EXECUTE format(
        'COPY data.%I TO %L WITH (FORMAT CSV, HEADER)',
        in_partition_name,
        in_archive_path || '/' || in_partition_name || '.csv'
    );

    -- Drop after successful export
    EXECUTE format('DROP TABLE data.%I', in_partition_name);

    RAISE NOTICE 'Archived and dropped: %', in_partition_name;
END;
$$;
```

## Performance Optimization

### Bulk Insert Optimization

```sql
-- Batch insert with COPY
COPY data.events (device_id, event_type, value, recorded_at)
FROM '/path/to/data.csv' WITH (FORMAT CSV, HEADER);

-- Or use COPY ... FROM STDIN in application
-- COPY data.events FROM STDIN WITH (FORMAT CSV);

-- For streaming inserts, use prepared statements
PREPARE insert_event AS
    INSERT INTO data.events (device_id, event_type, value, recorded_at)
    VALUES ($1, $2, $3, $4);
```

### Query Performance Tips

```sql
-- 1. Always include time range in WHERE clause
-- ❌ Bad: Full table scan
SELECT * FROM data.events WHERE device_id = 'uuid';

-- ✅ Good: Partition pruning
SELECT * FROM data.events
WHERE device_id = 'uuid'
  AND recorded_at >= now() - interval '24 hours';

-- 2. Use LIMIT for recent data queries
SELECT * FROM data.events
WHERE recorded_at >= now() - interval '1 hour'
ORDER BY recorded_at DESC
LIMIT 1000;

-- 3. Analyze tables after bulk loads
ANALYZE data.events;

-- 4. Check execution plan
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM data.events
WHERE device_id = 'uuid'
  AND recorded_at >= '2024-03-01'
  AND recorded_at < '2024-03-02';
```

### Configuration Tuning

```sql
-- postgresql.conf settings for time-series

-- Increase for write-heavy workloads
checkpoint_completion_target = 0.9
wal_buffers = 64MB

-- For large time range queries
work_mem = 256MB  -- Per operation
effective_cache_size = 12GB  -- 75% of RAM

-- For BRIN indexes
effective_io_concurrency = 200  -- For SSD
random_page_cost = 1.1  -- For SSD

-- Autovacuum tuning for append-only tables
ALTER TABLE data.events SET (
    autovacuum_vacuum_scale_factor = 0,
    autovacuum_vacuum_threshold = 10000,
    autovacuum_analyze_scale_factor = 0,
    autovacuum_analyze_threshold = 10000
);
```
