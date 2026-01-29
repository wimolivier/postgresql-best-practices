# Monitoring and Observability Patterns

This document covers pg_stat_statements, slow query logging, custom metrics, health checks, and alerting patterns for PostgreSQL.

## Table of Contents

1. [pg_stat_statements](#pg_stat_statements)
2. [Slow Query Logging](#slow-query-logging)
3. [Connection Monitoring](#connection-monitoring)
4. [Table and Index Statistics](#table-and-index-statistics)
5. [Lock Monitoring](#lock-monitoring)
6. [Replication Monitoring](#replication-monitoring)
7. [Custom Metrics](#custom-metrics)
8. [Health Check Endpoints](#health-check-endpoints)
9. [Alerting Patterns](#alerting-patterns)

## pg_stat_statements

### Setup

```sql
-- Enable extension (requires postgresql.conf change and restart)
-- shared_preload_libraries = 'pg_stat_statements'

CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

-- Configuration options (postgresql.conf)
-- pg_stat_statements.max = 10000
-- pg_stat_statements.track = all
-- pg_stat_statements.track_utility = on
-- pg_stat_statements.track_planning = on
```

### Query Analysis

```sql
-- Top queries by total time
SELECT 
    round(total_exec_time::numeric, 2) AS total_time_ms,
    calls,
    round(mean_exec_time::numeric, 2) AS avg_time_ms,
    round((100 * total_exec_time / sum(total_exec_time) OVER ())::numeric, 2) AS pct_total,
    rows,
    query
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 20;

-- Top queries by call count
SELECT 
    calls,
    round(total_exec_time::numeric, 2) AS total_time_ms,
    round(mean_exec_time::numeric, 2) AS avg_time_ms,
    rows,
    query
FROM pg_stat_statements
ORDER BY calls DESC
LIMIT 20;

-- Slowest queries on average
SELECT 
    round(mean_exec_time::numeric, 2) AS avg_time_ms,
    round(stddev_exec_time::numeric, 2) AS stddev_ms,
    calls,
    query
FROM pg_stat_statements
WHERE calls >= 10  -- Filter out rarely executed queries
ORDER BY mean_exec_time DESC
LIMIT 20;
```

### Query Performance View

```sql
CREATE OR REPLACE VIEW api.v_query_performance AS
SELECT 
    queryid,
    calls,
    round(total_exec_time::numeric, 2) AS total_time_ms,
    round(mean_exec_time::numeric, 2) AS avg_time_ms,
    round(min_exec_time::numeric, 2) AS min_time_ms,
    round(max_exec_time::numeric, 2) AS max_time_ms,
    round(stddev_exec_time::numeric, 2) AS stddev_ms,
    rows,
    round((100.0 * shared_blks_hit / nullif(shared_blks_hit + shared_blks_read, 0))::numeric, 2) AS cache_hit_pct,
    left(query, 200) AS query_preview
FROM pg_stat_statements
WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
ORDER BY total_exec_time DESC;

-- Reset statistics periodically
SELECT pg_stat_statements_reset();
```

### Tracking Query Changes Over Time

```sql
-- Store snapshots for trend analysis
CREATE TABLE app_audit.query_stats_snapshots (
    snapshot_id     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    snapshot_at     timestamptz NOT NULL DEFAULT now(),
    queryid         bigint NOT NULL,
    calls           bigint,
    total_time_ms   numeric,
    avg_time_ms     numeric,
    rows            bigint
);

-- Procedure to capture snapshot
CREATE OR REPLACE PROCEDURE app_audit.capture_query_stats()
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO app_audit.query_stats_snapshots 
        (snapshot_at, queryid, calls, total_time_ms, avg_time_ms, rows)
    SELECT 
        now(),
        queryid,
        calls,
        round(total_exec_time::numeric, 2),
        round(mean_exec_time::numeric, 2),
        rows
    FROM pg_stat_statements
    WHERE calls >= 100;  -- Only track frequently used queries
END;
$$;

-- Schedule with pg_cron (hourly)
SELECT cron.schedule('query-stats-snapshot', '0 * * * *', 
    'CALL app_audit.capture_query_stats()');
```

## Slow Query Logging

### PostgreSQL Configuration

```ini
# postgresql.conf

# Log queries slower than 1 second
log_min_duration_statement = 1000

# Log all statements (for debugging - use sparingly)
# log_statement = 'all'

# Log detailed execution stats
log_duration = on
log_lock_waits = on
log_temp_files = 0  # Log all temp file usage

# Log format for parsing
log_line_prefix = '%t [%p]: [%l-1] user=%u,db=%d,app=%a,client=%h '

# Log to CSV for analysis
log_destination = 'csvlog'
logging_collector = on
log_directory = 'log'
log_filename = 'postgresql-%Y-%m-%d.log'
```

### Slow Query Analysis Table

```sql
-- Table to store analyzed slow queries
CREATE TABLE app_audit.slow_queries (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    logged_at       timestamptz NOT NULL,
    duration_ms     numeric NOT NULL,
    query           text NOT NULL,
    user_name       text,
    database_name   text,
    application     text,
    client_addr     inet,
    query_hash      text GENERATED ALWAYS AS (md5(query)) STORED,
    analyzed        boolean NOT NULL DEFAULT false,
    notes           text
);

CREATE INDEX idx_slow_queries_logged ON app_audit.slow_queries(logged_at);
CREATE INDEX idx_slow_queries_duration ON app_audit.slow_queries(duration_ms DESC);
CREATE INDEX idx_slow_queries_hash ON app_audit.slow_queries(query_hash);

-- Function to import from CSV log
CREATE OR REPLACE PROCEDURE app_audit.import_slow_queries(
    in_log_file text
)
LANGUAGE plpgsql
AS $$
BEGIN
    -- Create temp table for CSV import
    CREATE TEMP TABLE temp_log (
        log_time timestamptz,
        user_name text,
        database_name text,
        process_id int,
        connection_from text,
        session_id text,
        session_line_num bigint,
        command_tag text,
        session_start_time timestamptz,
        virtual_transaction_id text,
        transaction_id bigint,
        error_severity text,
        sql_state_code text,
        message text,
        detail text,
        hint text,
        internal_query text,
        internal_query_pos int,
        context text,
        query text,
        query_pos int,
        location text,
        application_name text
    );
    
    EXECUTE format('COPY temp_log FROM %L WITH CSV', in_log_file);
    
    INSERT INTO app_audit.slow_queries (logged_at, duration_ms, query, user_name, database_name, application)
    SELECT 
        log_time,
        (regexp_match(message, 'duration: ([0-9.]+) ms'))[1]::numeric,
        query,
        user_name,
        database_name,
        application_name
    FROM temp_log
    WHERE message LIKE 'duration:%'
      AND query IS NOT NULL;
    
    DROP TABLE temp_log;
END;
$$;
```

## Connection Monitoring

### Connection Statistics View

```sql
CREATE OR REPLACE VIEW api.v_connection_stats AS
WITH connection_counts AS (
    SELECT 
        usename,
        application_name,
        client_addr,
        state,
        wait_event_type,
        COUNT(*) AS count
    FROM pg_stat_activity
    WHERE datname = current_database()
    GROUP BY usename, application_name, client_addr, state, wait_event_type
)
SELECT 
    usename,
    application_name,
    state,
    wait_event_type,
    SUM(count) AS connections,
    ROUND(100.0 * SUM(count) / (SELECT COUNT(*) FROM pg_stat_activity WHERE datname = current_database()), 2) AS pct
FROM connection_counts
GROUP BY usename, application_name, state, wait_event_type
ORDER BY connections DESC;

-- Connection pool status
CREATE OR REPLACE FUNCTION api.get_connection_pool_status()
RETURNS TABLE (
    total_connections int,
    active_connections int,
    idle_connections int,
    idle_in_transaction int,
    waiting_connections int,
    max_connections int,
    connection_utilization_pct numeric
)
LANGUAGE sql
STABLE
AS $$
    SELECT 
        (SELECT COUNT(*)::int FROM pg_stat_activity WHERE datname = current_database()),
        (SELECT COUNT(*)::int FROM pg_stat_activity WHERE datname = current_database() AND state = 'active'),
        (SELECT COUNT(*)::int FROM pg_stat_activity WHERE datname = current_database() AND state = 'idle'),
        (SELECT COUNT(*)::int FROM pg_stat_activity WHERE datname = current_database() AND state LIKE 'idle in transaction%'),
        (SELECT COUNT(*)::int FROM pg_stat_activity WHERE datname = current_database() AND wait_event_type = 'Lock'),
        current_setting('max_connections')::int,
        ROUND(100.0 * (SELECT COUNT(*) FROM pg_stat_activity) / current_setting('max_connections')::int, 2);
$$;
```

### Long-Running Query Detection

```sql
CREATE OR REPLACE FUNCTION api.get_long_running_queries(
    in_threshold interval DEFAULT interval '5 minutes'
)
RETURNS TABLE (
    pid int,
    duration interval,
    state text,
    query text,
    waiting boolean,
    username text,
    application text,
    client_addr inet
)
LANGUAGE sql
STABLE
AS $$
    SELECT 
        pid,
        now() - query_start AS duration,
        state,
        left(query, 500),
        wait_event IS NOT NULL,
        usename,
        application_name,
        client_addr
    FROM pg_stat_activity
    WHERE datname = current_database()
      AND state != 'idle'
      AND query_start < now() - in_threshold
      AND pid != pg_backend_pid()
    ORDER BY query_start;
$$;
```

## Table and Index Statistics

### Table Health View

```sql
CREATE OR REPLACE VIEW api.v_table_health AS
SELECT 
    schemaname,
    relname AS table_name,
    n_live_tup AS live_rows,
    n_dead_tup AS dead_rows,
    ROUND(100.0 * n_dead_tup / NULLIF(n_live_tup + n_dead_tup, 0), 2) AS dead_row_pct,
    last_vacuum,
    last_autovacuum,
    last_analyze,
    last_autoanalyze,
    vacuum_count,
    autovacuum_count,
    pg_size_pretty(pg_total_relation_size(schemaname || '.' || relname)) AS total_size
FROM pg_stat_user_tables
WHERE schemaname = 'data'
ORDER BY n_dead_tup DESC;

-- Index usage statistics
CREATE OR REPLACE VIEW api.v_index_usage AS
SELECT 
    schemaname,
    tablename,
    indexname,
    idx_scan AS index_scans,
    idx_tup_read AS tuples_read,
    idx_tup_fetch AS tuples_fetched,
    pg_size_pretty(pg_relation_size(indexrelid)) AS index_size,
    CASE 
        WHEN idx_scan = 0 THEN 'UNUSED'
        WHEN idx_scan < 100 THEN 'LOW USAGE'
        ELSE 'ACTIVE'
    END AS usage_status
FROM pg_stat_user_indexes
WHERE schemaname = 'data'
ORDER BY idx_scan;
```

### Bloat Detection

```sql
-- Estimate table bloat
CREATE OR REPLACE VIEW api.v_table_bloat AS
WITH constants AS (
    SELECT current_setting('block_size')::numeric AS bs
),
table_stats AS (
    SELECT 
        schemaname,
        tablename,
        reltuples::bigint AS row_count,
        relpages::bigint AS page_count,
        pg_relation_size(schemaname || '.' || tablename) AS actual_size
    FROM pg_stat_user_tables
    JOIN pg_class ON relname = tablename
    WHERE schemaname = 'data'
)
SELECT 
    schemaname,
    tablename,
    row_count,
    pg_size_pretty(actual_size) AS actual_size,
    pg_size_pretty((page_count * (SELECT bs FROM constants))::bigint) AS page_size,
    ROUND(100.0 * (actual_size - page_count * (SELECT bs FROM constants)) / NULLIF(actual_size, 0), 2) AS bloat_pct
FROM table_stats
WHERE actual_size > 1024 * 1024  -- Only tables > 1MB
ORDER BY actual_size DESC;
```

## Lock Monitoring

### Current Locks View

```sql
CREATE OR REPLACE VIEW api.v_current_locks AS
SELECT 
    l.pid,
    l.mode,
    l.granted,
    l.locktype,
    CASE l.locktype
        WHEN 'relation' THEN c.relname
        WHEN 'virtualxid' THEN l.virtualxid::text
        WHEN 'transactionid' THEN l.transactionid::text
        ELSE l.locktype
    END AS locked_object,
    a.usename,
    a.application_name,
    a.state,
    a.query_start,
    now() - a.query_start AS duration,
    left(a.query, 200) AS query
FROM pg_locks l
JOIN pg_stat_activity a ON l.pid = a.pid
LEFT JOIN pg_class c ON l.relation = c.oid
WHERE l.pid != pg_backend_pid()
ORDER BY a.query_start;

-- Lock wait chains (who's blocking whom)
CREATE OR REPLACE FUNCTION api.get_blocking_queries()
RETURNS TABLE (
    blocked_pid int,
    blocked_user text,
    blocked_query text,
    blocked_duration interval,
    blocking_pid int,
    blocking_user text,
    blocking_query text
)
LANGUAGE sql
STABLE
AS $$
    SELECT 
        blocked.pid AS blocked_pid,
        blocked.usename AS blocked_user,
        left(blocked.query, 200) AS blocked_query,
        now() - blocked.query_start AS blocked_duration,
        blocking.pid AS blocking_pid,
        blocking.usename AS blocking_user,
        left(blocking.query, 200) AS blocking_query
    FROM pg_locks blocked_locks
    JOIN pg_stat_activity blocked ON blocked_locks.pid = blocked.pid
    JOIN pg_locks blocking_locks ON (
        blocking_locks.locktype = blocked_locks.locktype AND
        blocking_locks.database IS NOT DISTINCT FROM blocked_locks.database AND
        blocking_locks.relation IS NOT DISTINCT FROM blocked_locks.relation AND
        blocking_locks.page IS NOT DISTINCT FROM blocked_locks.page AND
        blocking_locks.tuple IS NOT DISTINCT FROM blocked_locks.tuple AND
        blocking_locks.virtualxid IS NOT DISTINCT FROM blocked_locks.virtualxid AND
        blocking_locks.transactionid IS NOT DISTINCT FROM blocked_locks.transactionid AND
        blocking_locks.classid IS NOT DISTINCT FROM blocked_locks.classid AND
        blocking_locks.objid IS NOT DISTINCT FROM blocked_locks.objid AND
        blocking_locks.objsubid IS NOT DISTINCT FROM blocked_locks.objsubid AND
        blocking_locks.pid != blocked_locks.pid
    )
    JOIN pg_stat_activity blocking ON blocking_locks.pid = blocking.pid
    WHERE NOT blocked_locks.granted
      AND blocking_locks.granted;
$$;
```

## Replication Monitoring

### Replication Status

```sql
-- Check replication status (on primary)
CREATE OR REPLACE VIEW api.v_replication_status AS
SELECT 
    client_addr,
    usename,
    application_name,
    state,
    sync_state,
    sent_lsn,
    write_lsn,
    flush_lsn,
    replay_lsn,
    pg_size_pretty(pg_wal_lsn_diff(sent_lsn, replay_lsn)) AS replication_lag,
    write_lag,
    flush_lag,
    replay_lag
FROM pg_stat_replication;

-- Replication lag in seconds
CREATE OR REPLACE FUNCTION api.get_replication_lag_seconds()
RETURNS TABLE (
    replica text,
    lag_bytes bigint,
    lag_seconds numeric
)
LANGUAGE sql
STABLE
AS $$
    SELECT 
        client_addr::text || ' (' || application_name || ')',
        pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn),
        EXTRACT(EPOCH FROM replay_lag)
    FROM pg_stat_replication;
$$;
```

## Custom Metrics

### Metrics Collection Tables

```sql
CREATE TABLE app_audit.metrics (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    metric_name     text NOT NULL,
    metric_value    numeric NOT NULL,
    labels          jsonb DEFAULT '{}',
    collected_at    timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_metrics_name_time ON app_audit.metrics(metric_name, collected_at);

-- Partition by time for efficiency
-- (See partitioning section for implementation)
```

### Metrics Collection Procedure

```sql
CREATE OR REPLACE PROCEDURE app_audit.collect_metrics()
LANGUAGE plpgsql
AS $$
DECLARE
    l_metric_time timestamptz := now();
BEGIN
    -- Connection metrics
    INSERT INTO app_audit.metrics (metric_name, metric_value, labels, collected_at)
    SELECT 
        'pg_connections_total',
        COUNT(*),
        jsonb_build_object('state', state),
        l_metric_time
    FROM pg_stat_activity
    WHERE datname = current_database()
    GROUP BY state;
    
    -- Transaction metrics
    INSERT INTO app_audit.metrics (metric_name, metric_value, labels, collected_at)
    SELECT 
        'pg_stat_database_xact_commit',
        xact_commit,
        jsonb_build_object('database', datname),
        l_metric_time
    FROM pg_stat_database
    WHERE datname = current_database();
    
    INSERT INTO app_audit.metrics (metric_name, metric_value, labels, collected_at)
    SELECT 
        'pg_stat_database_xact_rollback',
        xact_rollback,
        jsonb_build_object('database', datname),
        l_metric_time
    FROM pg_stat_database
    WHERE datname = current_database();
    
    -- Cache hit ratio
    INSERT INTO app_audit.metrics (metric_name, metric_value, collected_at)
    SELECT 
        'pg_cache_hit_ratio',
        round(100.0 * sum(heap_blks_hit) / nullif(sum(heap_blks_hit) + sum(heap_blks_read), 0), 2),
        l_metric_time
    FROM pg_statio_user_tables;
    
    -- Table sizes
    INSERT INTO app_audit.metrics (metric_name, metric_value, labels, collected_at)
    SELECT 
        'pg_table_size_bytes',
        pg_total_relation_size(schemaname || '.' || tablename),
        jsonb_build_object('schema', schemaname, 'table', tablename),
        l_metric_time
    FROM pg_tables
    WHERE schemaname = 'data';
    
    -- Dead tuple ratio
    INSERT INTO app_audit.metrics (metric_name, metric_value, labels, collected_at)
    SELECT 
        'pg_dead_tuple_ratio',
        round(100.0 * n_dead_tup / nullif(n_live_tup + n_dead_tup, 0), 2),
        jsonb_build_object('table', relname),
        l_metric_time
    FROM pg_stat_user_tables
    WHERE schemaname = 'data'
      AND n_live_tup > 0;
END;
$$;

-- Schedule collection (every minute)
SELECT cron.schedule('collect-metrics', '* * * * *', 
    'CALL app_audit.collect_metrics()');
```

### Prometheus-Compatible Metrics Endpoint

```sql
-- Function that returns metrics in Prometheus format
CREATE OR REPLACE FUNCTION api.metrics_prometheus()
RETURNS text
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    l_output text := '';
    l_record RECORD;
BEGIN
    -- Database connections
    l_output := l_output || '# HELP pg_connections_total Number of database connections' || E'\n';
    l_output := l_output || '# TYPE pg_connections_total gauge' || E'\n';
    FOR l_record IN
        SELECT state, COUNT(*) AS count
        FROM pg_stat_activity
        WHERE datname = current_database()
        GROUP BY state
    LOOP
        l_output := l_output || format('pg_connections_total{state="%s"} %s', l_record.state, l_record.count) || E'\n';
    END LOOP;
    
    -- Cache hit ratio
    l_output := l_output || E'\n# HELP pg_cache_hit_ratio Cache hit ratio' || E'\n';
    l_output := l_output || '# TYPE pg_cache_hit_ratio gauge' || E'\n';
    l_output := l_output || format('pg_cache_hit_ratio %s', (
        SELECT round(100.0 * sum(heap_blks_hit) / nullif(sum(heap_blks_hit) + sum(heap_blks_read), 0), 2)
        FROM pg_statio_user_tables
    )) || E'\n';
    
    -- Transaction rate
    l_output := l_output || E'\n# HELP pg_xact_commit_total Transactions committed' || E'\n';
    l_output := l_output || '# TYPE pg_xact_commit_total counter' || E'\n';
    l_output := l_output || format('pg_xact_commit_total %s', (
        SELECT xact_commit FROM pg_stat_database WHERE datname = current_database()
    )) || E'\n';
    
    RETURN l_output;
END;
$$;
```

## Health Check Endpoints

### Comprehensive Health Check

```sql
CREATE OR REPLACE FUNCTION api.healthcheck()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    l_result jsonb;
    l_start_time timestamptz := clock_timestamp();
    l_checks jsonb := '{}';
    l_healthy boolean := true;
BEGIN
    -- Database connectivity
    l_checks := l_checks || jsonb_build_object(
        'database', jsonb_build_object(
            'status', 'ok',
            'latency_ms', round(extract(milliseconds from clock_timestamp() - l_start_time)::numeric, 2)
        )
    );
    
    -- Connection pool
    DECLARE
        l_conn_count int;
        l_max_conn int;
        l_util_pct numeric;
    BEGIN
        SELECT COUNT(*) INTO l_conn_count FROM pg_stat_activity WHERE datname = current_database();
        l_max_conn := current_setting('max_connections')::int;
        l_util_pct := round(100.0 * l_conn_count / l_max_conn, 2);
        
        l_checks := l_checks || jsonb_build_object(
            'connections', jsonb_build_object(
                'status', CASE WHEN l_util_pct < 80 THEN 'ok' WHEN l_util_pct < 95 THEN 'warning' ELSE 'critical' END,
                'current', l_conn_count,
                'max', l_max_conn,
                'utilization_pct', l_util_pct
            )
        );
        
        IF l_util_pct >= 95 THEN l_healthy := false; END IF;
    END;
    
    -- Replication lag (if replica)
    DECLARE
        l_lag_bytes bigint;
    BEGIN
        SELECT pg_wal_lsn_diff(pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn())
        INTO l_lag_bytes;
        
        IF l_lag_bytes IS NOT NULL THEN
            l_checks := l_checks || jsonb_build_object(
                'replication', jsonb_build_object(
                    'status', CASE WHEN l_lag_bytes < 1048576 THEN 'ok' WHEN l_lag_bytes < 104857600 THEN 'warning' ELSE 'critical' END,
                    'lag_bytes', l_lag_bytes,
                    'lag_mb', round(l_lag_bytes / 1048576.0, 2)
                )
            );
            
            IF l_lag_bytes >= 104857600 THEN l_healthy := false; END IF;
        END IF;
    EXCEPTION
        WHEN OTHERS THEN NULL;  -- Not a replica
    END;
    
    -- Long-running queries
    DECLARE
        l_long_queries int;
    BEGIN
        SELECT COUNT(*) INTO l_long_queries
        FROM pg_stat_activity
        WHERE state = 'active'
          AND query_start < now() - interval '5 minutes'
          AND pid != pg_backend_pid();
        
        l_checks := l_checks || jsonb_build_object(
            'long_queries', jsonb_build_object(
                'status', CASE WHEN l_long_queries = 0 THEN 'ok' WHEN l_long_queries < 5 THEN 'warning' ELSE 'critical' END,
                'count', l_long_queries
            )
        );
        
        IF l_long_queries >= 5 THEN l_healthy := false; END IF;
    END;
    
    -- Dead tuple ratio (vacuum needed?)
    DECLARE
        l_max_dead_ratio numeric;
    BEGIN
        SELECT MAX(round(100.0 * n_dead_tup / NULLIF(n_live_tup + n_dead_tup, 0), 2))
        INTO l_max_dead_ratio
        FROM pg_stat_user_tables
        WHERE schemaname = 'data' AND n_live_tup > 1000;
        
        l_checks := l_checks || jsonb_build_object(
            'vacuum', jsonb_build_object(
                'status', CASE WHEN COALESCE(l_max_dead_ratio, 0) < 10 THEN 'ok' WHEN l_max_dead_ratio < 30 THEN 'warning' ELSE 'critical' END,
                'max_dead_tuple_ratio', COALESCE(l_max_dead_ratio, 0)
            )
        );
    END;
    
    l_result := jsonb_build_object(
        'status', CASE WHEN l_healthy THEN 'healthy' ELSE 'unhealthy' END,
        'timestamp', now(),
        'response_time_ms', round(extract(milliseconds from clock_timestamp() - l_start_time)::numeric, 2),
        'checks', l_checks
    );
    
    RETURN l_result;
END;
$$;

-- Simple liveness check
CREATE OR REPLACE FUNCTION api.liveness()
RETURNS text
LANGUAGE sql
AS $$
    SELECT 'ok';
$$;

-- Readiness check (can accept traffic?)
CREATE OR REPLACE FUNCTION api.readiness()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    l_ready boolean := true;
    l_issues text[] := '{}';
BEGIN
    -- Check connection pool
    IF (SELECT COUNT(*) FROM pg_stat_activity) > current_setting('max_connections')::int * 0.95 THEN
        l_ready := false;
        l_issues := array_append(l_issues, 'Connection pool near capacity');
    END IF;
    
    -- Check for lock contention
    IF (SELECT COUNT(*) FROM pg_locks WHERE NOT granted) > 10 THEN
        l_ready := false;
        l_issues := array_append(l_issues, 'High lock contention');
    END IF;
    
    RETURN jsonb_build_object(
        'ready', l_ready,
        'issues', to_jsonb(l_issues)
    );
END;
$$;
```

## Alerting Patterns

### Alert Rules Table

```sql
CREATE TABLE app_audit.alert_rules (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name            text NOT NULL UNIQUE,
    description     text,
    query           text NOT NULL,
    threshold       numeric NOT NULL,
    comparison      text NOT NULL CHECK (comparison IN ('>', '<', '>=', '<=', '=', '!=')),
    severity        text NOT NULL CHECK (severity IN ('info', 'warning', 'critical')),
    is_enabled      boolean NOT NULL DEFAULT true,
    cooldown_minutes int NOT NULL DEFAULT 15,
    created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE app_audit.alert_history (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    rule_id         bigint REFERENCES app_audit.alert_rules(id),
    fired_at        timestamptz NOT NULL DEFAULT now(),
    current_value   numeric,
    message         text,
    acknowledged_at timestamptz,
    acknowledged_by text
);

-- Default alert rules
INSERT INTO app_audit.alert_rules (name, description, query, threshold, comparison, severity)
VALUES 
    ('high_connections', 'Connection pool utilization > 80%',
     'SELECT 100.0 * COUNT(*) / current_setting(''max_connections'')::int FROM pg_stat_activity',
     80, '>', 'warning'),
     
    ('critical_connections', 'Connection pool utilization > 95%',
     'SELECT 100.0 * COUNT(*) / current_setting(''max_connections'')::int FROM pg_stat_activity',
     95, '>', 'critical'),
     
    ('long_running_queries', 'Queries running > 5 minutes',
     'SELECT COUNT(*) FROM pg_stat_activity WHERE state = ''active'' AND query_start < now() - interval ''5 minutes''',
     0, '>', 'warning'),
     
    ('replication_lag_mb', 'Replication lag > 100MB',
     'SELECT COALESCE(MAX(pg_wal_lsn_diff(sent_lsn, replay_lsn)) / 1048576.0, 0) FROM pg_stat_replication',
     100, '>', 'critical'),
     
    ('dead_tuple_ratio', 'Tables with > 20% dead tuples',
     'SELECT COUNT(*) FROM pg_stat_user_tables WHERE n_dead_tup > n_live_tup * 0.2 AND n_live_tup > 1000',
     0, '>', 'warning');
```

### Alert Checking Procedure

```sql
CREATE OR REPLACE PROCEDURE app_audit.check_alerts()
LANGUAGE plpgsql
AS $$
DECLARE
    l_rule RECORD;
    l_value numeric;
    l_should_fire boolean;
    l_last_fired timestamptz;
BEGIN
    FOR l_rule IN 
        SELECT * FROM app_audit.alert_rules WHERE is_enabled
    LOOP
        -- Execute the check query
        EXECUTE l_rule.query INTO l_value;
        
        -- Evaluate condition
        l_should_fire := CASE l_rule.comparison
            WHEN '>' THEN l_value > l_rule.threshold
            WHEN '<' THEN l_value < l_rule.threshold
            WHEN '>=' THEN l_value >= l_rule.threshold
            WHEN '<=' THEN l_value <= l_rule.threshold
            WHEN '=' THEN l_value = l_rule.threshold
            WHEN '!=' THEN l_value != l_rule.threshold
        END;
        
        IF l_should_fire THEN
            -- Check cooldown
            SELECT MAX(fired_at) INTO l_last_fired
            FROM app_audit.alert_history
            WHERE rule_id = l_rule.id;
            
            IF l_last_fired IS NULL OR l_last_fired < now() - (l_rule.cooldown_minutes || ' minutes')::interval THEN
                -- Fire alert
                INSERT INTO app_audit.alert_history (rule_id, current_value, message)
                VALUES (
                    l_rule.id,
                    l_value,
                    format('[%s] %s: current value %s %s threshold %s',
                        l_rule.severity, l_rule.name, l_value, l_rule.comparison, l_rule.threshold)
                );
                
                -- Here you could also call a notification function
                -- PERFORM private.send_alert_notification(l_rule, l_value);
                
                RAISE NOTICE 'Alert fired: %', l_rule.name;
            END IF;
        END IF;
    END LOOP;
END;
$$;

-- Schedule alert checks (every minute)
SELECT cron.schedule('check-alerts', '* * * * *', 
    'CALL app_audit.check_alerts()');
```

### View Active Alerts

```sql
CREATE OR REPLACE VIEW api.v_active_alerts AS
SELECT 
    r.name AS alert_name,
    r.severity,
    h.fired_at,
    h.current_value,
    h.message,
    h.acknowledged_at IS NOT NULL AS is_acknowledged,
    h.acknowledged_by
FROM app_audit.alert_history h
JOIN app_audit.alert_rules r ON r.id = h.rule_id
WHERE h.fired_at > now() - interval '24 hours'
ORDER BY h.fired_at DESC;
```
