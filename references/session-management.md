# Connection and Session Management

This document covers session variables, application context, connection pooling integration, and session lifecycle management.

## Table of Contents

1. [Session Variables](#session-variables)
2. [Application Context Pattern](#application-context-pattern)
3. [Connection Pooling Integration](#connection-pooling-integration)
4. [Session Configuration](#session-configuration)
5. [Connection Lifecycle](#connection-lifecycle)
6. [Security Context](#security-context)

## Session Variables

### Setting Session Variables

```sql
-- Set variable for entire session (persists until connection closes)
SET myapp.current_user_id = 'user-uuid-here';
SET myapp.current_tenant_id = 'tenant-uuid-here';

-- Set variable for current transaction only
SET LOCAL myapp.current_user_id = 'user-uuid-here';

-- Using set_config function (more flexible)
SELECT set_config('myapp.current_user_id', 'user-uuid-here', false);  -- session
SELECT set_config('myapp.current_user_id', 'user-uuid-here', true);   -- transaction only
```

### Reading Session Variables

```sql
-- Get variable (returns NULL if not set)
SELECT current_setting('myapp.current_user_id', true);  -- true = missing_ok

-- Get variable (throws error if not set)
SELECT current_setting('myapp.current_user_id');

-- In PL/pgSQL functions
CREATE OR REPLACE FUNCTION private.get_current_user_id()
RETURNS uuid
LANGUAGE sql
STABLE
AS $$
    SELECT NULLIF(current_setting('myapp.current_user_id', true), '')::uuid;
$$;

CREATE OR REPLACE FUNCTION private.get_current_tenant_id()
RETURNS uuid
LANGUAGE sql
STABLE
AS $$
    SELECT NULLIF(current_setting('myapp.current_tenant_id', true), '')::uuid;
$$;
```

### Custom GUC Variables

```sql
-- Register custom variable namespace in postgresql.conf:
-- custom_variable_classes = 'myapp'

-- Or dynamically (requires superuser)
ALTER SYSTEM SET custom_variable_classes = 'myapp';
SELECT pg_reload_conf();

-- Now you can use typed variables
SET myapp.debug_mode = 'true';
SET myapp.log_level = 'debug';
SET myapp.max_results = '100';
```

## Application Context Pattern

### Context Setup Function

```sql
-- Comprehensive context setup
CREATE OR REPLACE FUNCTION api.set_context(
    in_user_id      uuid,
    in_tenant_id    uuid DEFAULT NULL,
    in_role         text DEFAULT 'user',
    in_session_id   text DEFAULT NULL,
    in_metadata     jsonb DEFAULT '{}'
)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    -- Core context
    PERFORM set_config('myapp.current_user_id', in_user_id::text, false);
    PERFORM set_config('myapp.current_tenant_id', COALESCE(in_tenant_id::text, ''), false);
    PERFORM set_config('myapp.current_role', in_role, false);
    PERFORM set_config('myapp.session_id', COALESCE(in_session_id, ''), false);
    
    -- Additional metadata
    PERFORM set_config('myapp.context_metadata', in_metadata::text, false);
    
    -- Set timestamp for context creation
    PERFORM set_config('myapp.context_created_at', now()::text, false);
    
    -- Set application name for pg_stat_activity
    PERFORM set_config('application_name', 
        format('myapp[user=%s,tenant=%s]', in_user_id, in_tenant_id), 
        false);
END;
$$;

-- Transaction-scoped context (for pooled connections)
CREATE OR REPLACE FUNCTION api.set_transaction_context(
    in_user_id      uuid,
    in_tenant_id    uuid DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    -- Use LOCAL for transaction scope
    PERFORM set_config('myapp.current_user_id', in_user_id::text, true);
    PERFORM set_config('myapp.current_tenant_id', COALESCE(in_tenant_id::text, ''), true);
END;
$$;
```

### Context Validation

```sql
-- Require context to be set
CREATE OR REPLACE FUNCTION private.require_context()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_user_id uuid;
BEGIN
    l_user_id := private.get_current_user_id();
    
    IF l_user_id IS NULL THEN
        RAISE EXCEPTION 'User context not set. Call api.set_context() first.'
            USING ERRCODE = 'P0050';  -- Custom error code
    END IF;
END;
$$;

-- API functions that require context
CREATE OR REPLACE FUNCTION api.get_my_profile()
RETURNS TABLE (id uuid, email text, name text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, private, pg_temp
AS $$
DECLARE
    l_user_id uuid;
BEGIN
    -- Require context
    PERFORM private.require_context();
    l_user_id := private.get_current_user_id();
    
    RETURN QUERY
    SELECT u.id, u.email, u.name
    FROM data.users u
    WHERE u.id = l_user_id;
END;
$$;
```

### Context for Auditing

```sql
-- Set audit context
CREATE OR REPLACE FUNCTION api.set_audit_context(
    in_reason   text DEFAULT NULL,
    in_ticket   text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM set_config('myapp.audit_context', 
        jsonb_build_object(
            'reason', in_reason,
            'ticket', in_ticket,
            'timestamp', now()
        )::text, 
        true);  -- Transaction-local
END;
$$;

-- Usage in audit trigger
CREATE OR REPLACE FUNCTION private.get_audit_context()
RETURNS jsonb
LANGUAGE sql
STABLE
AS $$
    SELECT NULLIF(current_setting('myapp.audit_context', true), '')::jsonb;
$$;
```

## Connection Pooling Integration

### PgBouncer Configuration

```ini
# pgbouncer.ini
[databases]
myapp = host=localhost dbname=myapp

[pgbouncer]
pool_mode = transaction      # Best for web apps with SECURITY DEFINER
max_client_conn = 1000
default_pool_size = 20
min_pool_size = 5
reserve_pool_size = 5
reserve_pool_timeout = 3

# Important for session variables
server_reset_query = DISCARD ALL
```

### Transaction-Mode Pooling Pattern

```sql
-- Application must set context at start of each transaction
-- because connections are shared

-- Example application flow:
BEGIN;
SELECT api.set_transaction_context('user-id'::uuid, 'tenant-id'::uuid);

-- Now execute queries
SELECT * FROM api.get_my_orders();
SELECT * FROM api.get_my_profile();

COMMIT;
-- Connection returns to pool, context is discarded
```

### Session-Mode Pooling Pattern

```sql
-- If using session pooling, set context once after connect
-- Connection stays dedicated to this client

SELECT api.set_context(
    in_user_id := 'user-id'::uuid,
    in_tenant_id := 'tenant-id'::uuid,
    in_session_id := 'app-session-123'
);

-- All subsequent queries use this context
SELECT * FROM api.get_my_orders();
-- ... many more queries ...

-- Context persists until disconnect
```

### Connection Validation

```sql
-- Function to validate connection is properly set up
CREATE OR REPLACE FUNCTION api.validate_connection()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    l_result jsonb;
BEGIN
    l_result := jsonb_build_object(
        'user_id', current_setting('myapp.current_user_id', true),
        'tenant_id', current_setting('myapp.current_tenant_id', true),
        'application_name', current_setting('application_name', true),
        'server_version', current_setting('server_version'),
        'timezone', current_setting('timezone'),
        'search_path', current_setting('search_path'),
        'is_superuser', current_setting('is_superuser')
    );
    
    RETURN l_result;
END;
$$;
```

## Session Configuration

### Role-Based Defaults

```sql
-- Set defaults for application role
ALTER ROLE app_service SET search_path = api, pg_temp;
ALTER ROLE app_service SET statement_timeout = '30s';
ALTER ROLE app_service SET lock_timeout = '10s';
ALTER ROLE app_service SET idle_in_transaction_session_timeout = '60s';
ALTER ROLE app_service SET timezone = 'UTC';

-- Set custom defaults
ALTER ROLE app_service SET myapp.default_page_size = '25';
```

### Dynamic Configuration

```sql
-- Set session-level configuration
SET statement_timeout = '10s';
SET work_mem = '256MB';  -- For complex queries in this session
SET enable_seqscan = off;  -- For testing indexes

-- Reset to default
RESET statement_timeout;
RESET ALL;

-- Check current settings
SHOW statement_timeout;
SHOW ALL;
```

### Application-Specific Settings

```sql
-- Create settings table for application configuration
CREATE TABLE data.app_settings (
    key         text PRIMARY KEY,
    value       text NOT NULL,
    description text,
    updated_at  timestamptz NOT NULL DEFAULT now()
);

-- Load settings into session
CREATE OR REPLACE FUNCTION api.load_app_settings()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_setting RECORD;
BEGIN
    FOR l_setting IN SELECT key, value FROM data.app_settings LOOP
        PERFORM set_config('myapp.' || l_setting.key, l_setting.value, false);
    END LOOP;
END;
$$;

-- Get setting with fallback
CREATE OR REPLACE FUNCTION private.get_app_setting(
    in_key text,
    in_default text DEFAULT NULL
)
RETURNS text
LANGUAGE sql
STABLE
AS $$
    SELECT COALESCE(
        NULLIF(current_setting('myapp.' || in_key, true), ''),
        in_default
    );
$$;
```

## Connection Lifecycle

### Connection Initialization

```sql
-- Procedure to initialize new connections
CREATE OR REPLACE FUNCTION api.init_connection()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    -- Load application settings
    PERFORM api.load_app_settings();
    
    -- Set standard configuration
    SET timezone = 'UTC';
    SET datestyle = 'ISO, MDY';
    
    -- Log connection
    INSERT INTO data.connection_log (
        connected_at,
        client_addr,
        application_name,
        backend_pid
    ) VALUES (
        now(),
        inet_client_addr(),
        current_setting('application_name', true),
        pg_backend_pid()
    );
END;
$$;
```

### Idle Connection Management

```sql
-- Find and terminate idle connections
CREATE OR REPLACE FUNCTION api.cleanup_idle_connections(
    in_idle_timeout interval DEFAULT interval '10 minutes'
)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    l_terminated integer := 0;
    l_pid integer;
BEGIN
    FOR l_pid IN
        SELECT pid
        FROM pg_stat_activity
        WHERE state = 'idle'
          AND state_change < now() - in_idle_timeout
          AND pid != pg_backend_pid()
          AND usename = 'app_service'
    LOOP
        PERFORM pg_terminate_backend(l_pid);
        l_terminated := l_terminated + 1;
    END LOOP;
    
    RETURN l_terminated;
END;
$$;
```

### Connection Statistics

```sql
-- View current connections
CREATE OR REPLACE VIEW api.v_connection_stats AS
SELECT 
    usename AS username,
    application_name,
    client_addr,
    state,
    state_change,
    now() - state_change AS idle_time,
    query,
    wait_event_type,
    wait_event
FROM pg_stat_activity
WHERE datname = current_database()
ORDER BY state_change;

-- Connection pool status
CREATE OR REPLACE FUNCTION api.get_connection_summary()
RETURNS TABLE (
    state text,
    count bigint,
    avg_idle_seconds numeric
)
LANGUAGE sql
STABLE
AS $$
    SELECT 
        state,
        COUNT(*),
        ROUND(AVG(EXTRACT(EPOCH FROM (now() - state_change)))::numeric, 2)
    FROM pg_stat_activity
    WHERE datname = current_database()
    GROUP BY state;
$$;
```

## Security Context

### Multi-Tenant Security

```sql
-- Ensure tenant isolation in all queries
CREATE OR REPLACE FUNCTION private.require_tenant_context()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_tenant_id uuid;
BEGIN
    l_tenant_id := private.get_current_tenant_id();
    
    IF l_tenant_id IS NULL THEN
        RAISE EXCEPTION 'Tenant context not set'
            USING ERRCODE = 'P0051';
    END IF;
END;
$$;

-- Verify user belongs to tenant
CREATE OR REPLACE FUNCTION private.verify_user_tenant_access()
RETURNS boolean
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    l_user_id uuid;
    l_tenant_id uuid;
    l_has_access boolean;
BEGIN
    l_user_id := private.get_current_user_id();
    l_tenant_id := private.get_current_tenant_id();
    
    SELECT EXISTS(
        SELECT 1 FROM data.user_tenants
        WHERE user_id = l_user_id
          AND tenant_id = l_tenant_id
          AND is_active = true
    ) INTO l_has_access;
    
    IF NOT l_has_access THEN
        RAISE EXCEPTION 'User does not have access to tenant'
            USING ERRCODE = 'P0052';
    END IF;
    
    RETURN true;
END;
$$;
```

### Impersonation

```sql
-- Allow admins to impersonate other users
CREATE OR REPLACE FUNCTION api.impersonate_user(
    in_target_user_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, private, pg_temp
AS $$
DECLARE
    l_current_user_id uuid;
    l_is_admin boolean;
BEGIN
    l_current_user_id := private.get_current_user_id();
    
    -- Check if current user is admin
    SELECT role = 'admin' INTO l_is_admin
    FROM data.users
    WHERE id = l_current_user_id;
    
    IF NOT l_is_admin THEN
        RAISE EXCEPTION 'Only admins can impersonate users'
            USING ERRCODE = 'P0053';
    END IF;
    
    -- Store original user for audit
    PERFORM set_config('myapp.original_user_id', l_current_user_id::text, false);
    
    -- Set impersonated user
    PERFORM set_config('myapp.current_user_id', in_target_user_id::text, false);
    PERFORM set_config('myapp.is_impersonating', 'true', false);
    
    -- Log impersonation
    INSERT INTO app_audit.impersonation_log (
        admin_user_id, target_user_id, started_at
    ) VALUES (
        l_current_user_id, in_target_user_id, now()
    );
END;
$$;

-- End impersonation
CREATE OR REPLACE FUNCTION api.end_impersonation()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_original_user_id text;
BEGIN
    l_original_user_id := current_setting('myapp.original_user_id', true);
    
    IF l_original_user_id IS NULL OR l_original_user_id = '' THEN
        RAISE EXCEPTION 'Not currently impersonating';
    END IF;
    
    -- Restore original user
    PERFORM set_config('myapp.current_user_id', l_original_user_id, false);
    PERFORM set_config('myapp.original_user_id', '', false);
    PERFORM set_config('myapp.is_impersonating', 'false', false);
END;
$$;
```

### Rate Limiting

```sql
-- Simple rate limiting using session tracking
CREATE TABLE data.rate_limits (
    user_id     uuid NOT NULL,
    action      text NOT NULL,
    window_start timestamptz NOT NULL,
    count       integer NOT NULL DEFAULT 1,
    PRIMARY KEY (user_id, action, window_start)
);

CREATE OR REPLACE FUNCTION private.check_rate_limit(
    in_action text,
    in_max_requests integer,
    in_window_seconds integer
)
RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
    l_user_id uuid;
    l_window_start timestamptz;
    l_current_count integer;
BEGIN
    l_user_id := private.get_current_user_id();
    l_window_start := date_trunc('second', now()) 
        - ((EXTRACT(EPOCH FROM now())::integer % in_window_seconds) * interval '1 second');
    
    -- Upsert rate limit counter
    INSERT INTO data.rate_limits (user_id, action, window_start, count)
    VALUES (l_user_id, in_action, l_window_start, 1)
    ON CONFLICT (user_id, action, window_start) DO UPDATE
    SET count = data.rate_limits.count + 1
    RETURNING count INTO l_current_count;
    
    -- Check limit
    IF l_current_count > in_max_requests THEN
        RAISE EXCEPTION 'Rate limit exceeded for action: %', in_action
            USING ERRCODE = 'P0054';
    END IF;
    
    RETURN true;
END;
$$;

-- Usage in API functions
CREATE OR REPLACE FUNCTION api.send_email(in_to text, in_subject text, in_body text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    -- Check rate limit: 10 emails per minute
    PERFORM private.check_rate_limit('send_email', 10, 60);
    
    -- Send email logic...
END;
$$;
```
