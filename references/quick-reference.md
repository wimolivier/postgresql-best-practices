# PostgreSQL Best Practices - Quick Reference Card

> Print this page or keep it open while coding. For details, see the full documentation.

---

## Schema Architecture

```
Application → api schema → data schema
                ↓
            private schema (triggers, helpers)
```

| Schema | Contains | Access |
|--------|----------|--------|
| `data` | Tables, indexes, constraints | None (internal) |
| `private` | Triggers, helpers, password hashing | None (internal) |
| `api` | Functions, procedures, views | Applications |
| `app_audit` | Audit log tables | Admins only |
| `app_migration` | Migration tracking | Admins only |

**Data Warehouse Schemas** (if using Medallion Architecture):
| `bronze` | Raw data landing | ETL role |
| `silver` | Cleansed data | ETL role |
| `gold` | Business-ready data | Analysts |
| `dwh_lineage` | Data lineage tracking | ETL role |

---

## Trivadis Naming Conventions

### Variables & Parameters

| Prefix | Type | Example |
|--------|------|---------|
| `l_` | Local variable | `l_count`, `l_customer_id` |
| `g_` | Session/global | `g_current_user_id` |
| `co_` | Constant | `co_max_retries` |
| `in_` | IN parameter | `in_customer_id` |
| `out_` | OUT parameter (functions only) | `out_total` |
| `io_` | INOUT parameter (procedures) | `io_id` |
| `c_` | Cursor | `c_orders` |
| `r_` | Record | `r_customer` |
| `t_` | Array | `t_ids` |
| `e_` | Exception | `e_not_found` |

> **Note**: PostgreSQL procedures only support INOUT, not OUT. Use `io_` for procedure outputs.

### Database Objects

| Object | Pattern | Example |
|--------|---------|---------|
| Table | plural, snake_case | `customers`, `order_items` |
| Column | singular, snake_case | `customer_id`, `created_at` |
| PK | `{table}_pk` | `customers_pk` |
| FK | `{table}_{ref}_fk` | `orders_customers_fk` |
| Unique constraint | `{table}_{cols}_uk` | `customers_email_uk` |
| Unique index | `{table}_{cols}_key` | `customers_email_key` |
| Index | `{table}_{cols}_idx` | `orders_customer_id_idx` |
| Check | `{table}_{col}_ck` | `orders_status_ck` |
| Function | `{action}_{entity}` | `get_customer` |
| Procedure | `{action}_{entity}` | `insert_order` |
| Trigger | `{table}_{timing}{event}_trg` | `orders_bu_trg` |

---

## Data Types - Use / Avoid

| ✅ Use | ❌ Avoid |
|--------|----------|
| `text` | `char(n)`, `varchar(n)` |
| `numeric(p,s)` | `money`, `float`, `real` |
| `timestamptz` | `timestamp` |
| `boolean` | `integer` flags |
| `uuid DEFAULT uuidv7()` | `serial`, `uuid_generate_v4()` |
| `GENERATED ALWAYS AS IDENTITY` | `serial`, `bigserial` |
| `jsonb` | `json`, EAV tables |
| `integer` / `bigint` | `smallint` (unless space-critical) |

---

## Essential Patterns

### Create Table
```sql
CREATE TABLE data.customers (
    id          uuid PRIMARY KEY DEFAULT uuidv7(),
    email       text NOT NULL,
    name        text NOT NULL,
    is_active   boolean NOT NULL DEFAULT true,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX customers_email_key ON data.customers(lower(email));
CREATE INDEX customers_is_active_idx ON data.customers(is_active) WHERE is_active;

CREATE TRIGGER customers_bu_trg
    BEFORE UPDATE ON data.customers
    FOR EACH ROW EXECUTE FUNCTION private.set_updated_at();
```

### API Function (Read)
```sql
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

### API Procedure (Write)
```sql
CREATE PROCEDURE api.insert_customer(
    in_email  text,
    in_name   text,
    INOUT io_id uuid DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, private, pg_temp
AS $$
DECLARE
    l_email text;
BEGIN
    l_email := lower(trim(in_email));
    
    INSERT INTO data.customers (email, name)
    VALUES (l_email, trim(in_name))
    RETURNING id INTO io_id;
END;
$$;
```

### Private Trigger Function
```sql
CREATE FUNCTION private.set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$;
```

### Error Handling
```sql
-- Raise custom error
RAISE EXCEPTION 'Customer not found: %', in_id
    USING ERRCODE = 'P0001';

-- Handle errors
BEGIN
    -- risky operation
EXCEPTION
    WHEN unique_violation THEN
        RAISE EXCEPTION 'Email already exists' USING ERRCODE = 'P0002';
    WHEN OTHERS THEN
        RAISE;  -- Re-raise unexpected errors
END;
```

---

## Index Quick Reference

| Query Pattern | Index Type |
|---------------|------------|
| `=`, `<`, `>`, `BETWEEN`, `ORDER BY` | B-tree (default) |
| `=` only (large table) | Hash |
| `LIKE 'prefix%'` | B-tree |
| `LIKE '%text%'` | GIN + pg_trgm |
| `@>`, `?`, `?&` (JSONB) | GIN |
| `@@` (full-text) | GIN |
| Geometry, ranges | GiST |
| Very large, ordered data | BRIN |

```sql
-- Always index foreign keys!
CREATE INDEX orders_customer_id_idx ON data.orders(customer_id);

-- Partial index for common queries
CREATE INDEX orders_pending_idx ON data.orders(created_at)
    WHERE status = 'pending';

-- Covering index (includes extra columns)
CREATE INDEX orders_status_idx ON data.orders(status)
    INCLUDE (total, created_at);
```

---

## Migrations Quick Reference

```sql
-- 1. Acquire lock
SELECT app_migration.acquire_lock();

-- 2. Run versioned migration (runs once)
CALL app_migration.run_versioned(
    in_version := '001',
    in_description := 'Create customers table',
    in_sql := $mig$ CREATE TABLE data.customers (...); $mig$,
    in_rollback_sql := 'DROP TABLE IF EXISTS data.customers;'
);

-- 3. Run repeatable migration (re-runs if changed)
CALL app_migration.run_repeatable(
    in_filename := 'R__api_functions.sql',
    in_description := 'API functions',
    in_sql := $mig$ CREATE OR REPLACE FUNCTION api.get_customer... $mig$
);

-- 4. Release lock
SELECT app_migration.release_lock();
```

---

## Grants / Permissions

```sql
-- Create role
CREATE ROLE app_service LOGIN PASSWORD 'secure';

-- Grant API access only
GRANT USAGE ON SCHEMA api TO app_service;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA api TO app_service;
GRANT EXECUTE ON ALL PROCEDURES IN SCHEMA api TO app_service;

-- Set search path
ALTER ROLE app_service SET search_path = api, pg_temp;

-- NEVER grant on data or private schemas!
```

---

## Critical Anti-Patterns

| ❌ Don't | ✅ Do |
|----------|-------|
| `RETURNS SETOF table` | `RETURNS TABLE (col1 type, ...)` |
| `SECURITY DEFINER` without `SET search_path` | Always include both |
| `SELECT *` | Explicit column list |
| `NOT IN (subquery)` | `NOT EXISTS (...)` |
| `BETWEEN` with timestamps | `>= AND <` |
| Missing FK indexes | Always index FKs |
| `timestamp` | `timestamptz` |
| `varchar(255)` | `text` |

---

## PostgreSQL 18+ Features

```sql
-- UUIDv7 (timestamp-ordered)
id uuid PRIMARY KEY DEFAULT uuidv7()

-- Extract timestamp from UUIDv7
SELECT uuid_extract_timestamp(id) FROM data.orders;

-- Virtual generated column
full_name text GENERATED ALWAYS AS (first_name || ' ' || last_name) VIRTUAL

-- OLD/NEW in RETURNING
UPDATE data.orders SET status = 'shipped'
RETURNING OLD.status AS old_status, NEW.status AS new_status;
```

---

## Common SQL Patterns

```sql
-- Upsert
INSERT INTO data.customers (email, name) VALUES ($1, $2)
ON CONFLICT (email) DO UPDATE SET name = EXCLUDED.name;

-- Batch insert
INSERT INTO data.orders (customer_id, total)
SELECT unnest($1::uuid[]), unnest($2::numeric[]);

-- Pagination
SELECT * FROM data.orders
ORDER BY created_at DESC
LIMIT 20 OFFSET 40;  -- Page 3, 20 per page

-- Conditional update
UPDATE data.customers
SET name = COALESCE(in_name, name),
    email = COALESCE(in_email, email)
WHERE id = in_id;
```

---

*For complete documentation, see SKILL.md and reference files.*
