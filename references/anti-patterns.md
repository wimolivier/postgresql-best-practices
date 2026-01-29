# PostgreSQL Anti-Patterns

## Table of Contents
1. [Data Type Anti-Patterns](#data-type-anti-patterns)
2. [Query Anti-Patterns](#query-anti-patterns)
3. [Schema Design Anti-Patterns](#schema-design-anti-patterns)
4. [PL/pgSQL Anti-Patterns](#plpgsql-anti-patterns)
5. [Security Anti-Patterns](#security-anti-patterns)
6. [Performance Anti-Patterns](#performance-anti-patterns)

## Data Type Anti-Patterns

### ❌ Using char(n)

**Problem**: Pads with spaces, causes comparison issues, wastes storage.

```sql
-- Bad
CREATE TABLE users (
    country_code char(2)  -- Stored with potential padding issues
);

-- String comparison surprises:
SELECT 'US'::char(2) = 'US ';  -- true (trailing spaces ignored)
```

**Solution**: Use `text` with constraints.

```sql
-- Good
CREATE TABLE users (
    country_code text CHECK (length(country_code) = 2)
);
```

### ❌ Using varchar(n) by Default

**Problem**: Arbitrary length limits cause future migration pain with no performance benefit.

```sql
-- Bad: Why 255? Will you migrate when someone has longer name?
CREATE TABLE users (
    name varchar(255),
    email varchar(100)
);
```

**Solution**: Use `text` unless you have a genuine business constraint.

```sql
-- Good
CREATE TABLE users (
    name text NOT NULL,
    email text NOT NULL CHECK (length(email) <= 254)  -- RFC 5321 limit
);
```

### ❌ Using money Type

**Problem**: Locale-dependent formatting, rounding issues, limited precision.

```sql
-- Bad
CREATE TABLE products (
    price money  -- Locale-dependent, unexpected behavior
);
```

**Solution**: Use `numeric(precision, scale)`.

```sql
-- Good
CREATE TABLE products (
    price numeric(15, 2) NOT NULL CHECK (price >= 0)
);
```

### ❌ Using serial/bigserial

**Problem**: Legacy syntax, permission complications, sequence ownership issues.

```sql
-- Bad
CREATE TABLE orders (
    id serial PRIMARY KEY  -- Creates separate sequence with ownership issues
);
```

**Solution**: Use identity columns or `uuidv7()`.

```sql
-- Good: Identity column
CREATE TABLE orders (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY
);

-- Good: UUIDv7 (PostgreSQL 18+)
CREATE TABLE orders (
    id uuid PRIMARY KEY DEFAULT uuidv7()
);
```

### ❌ Using timestamp (without time zone)

**Problem**: Loses timezone context, causes bugs when servers move or have different timezones.

```sql
-- Bad
CREATE TABLE events (
    event_time timestamp  -- What timezone? Nobody knows!
);
```

**Solution**: Always use `timestamptz`.

```sql
-- Good
CREATE TABLE events (
    event_time timestamptz NOT NULL  -- Stored as UTC, converted on display
);
```

### ❌ Using timetz

**Problem**: Time with timezone but no date is rarely meaningful (DST issues).

```sql
-- Bad: When does the meeting start?
CREATE TABLE schedules (
    meeting_time timetz  -- 10:00 EST... but which day? DST?
);
```

**Solution**: Store as `timestamptz` or time without timezone.

```sql
-- Good: Store full timestamp
CREATE TABLE schedules (
    meeting_start timestamptz NOT NULL
);
```

## Query Anti-Patterns

### ❌ Using NOT IN with Subqueries

**Problem**: NULL handling is counterintuitive, performance is O(N²).

```sql
-- Bad: Returns no rows if any subquery result is NULL!
SELECT * FROM orders 
WHERE customer_id NOT IN (SELECT id FROM inactive_customers);
```

**Solution**: Use `NOT EXISTS`.

```sql
-- Good: Correct NULL handling, better performance
SELECT * FROM orders o
WHERE NOT EXISTS (
    SELECT 1 FROM inactive_customers ic WHERE ic.id = o.customer_id
);
```

### ❌ Using BETWEEN with Timestamps

**Problem**: BETWEEN is inclusive on both ends, causing midnight boundary issues.

```sql
-- Bad: Includes 2024-03-01 00:00:00 from next month!
SELECT * FROM orders 
WHERE created_at BETWEEN '2024-02-01' AND '2024-03-01';
```

**Solution**: Use `>= AND <` (half-open interval).

```sql
-- Good: Half-open interval, no boundary issues
SELECT * FROM orders 
WHERE created_at >= '2024-02-01' 
  AND created_at < '2024-03-01';
```

### ❌ Using SELECT *

**Problem**: Returns unnecessary columns, breaks when schema changes, prevents covering indexes.

```sql
-- Bad
SELECT * FROM orders WHERE customer_id = 'uuid';
```

**Solution**: Explicitly list columns.

```sql
-- Good
SELECT id, status, total, created_at 
FROM orders 
WHERE customer_id = 'uuid';
```

### ❌ Implicit Type Conversions in WHERE

**Problem**: Prevents index usage when types don't match.

```sql
-- Bad: Index on user_id won't be used
SELECT * FROM orders WHERE user_id = 12345;  -- user_id is uuid/text
```

**Solution**: Match types explicitly.

```sql
-- Good
SELECT * FROM orders WHERE user_id = '550e8400-e29b-41d4-a716-446655440000';
```

### ❌ OFFSET for Pagination

**Problem**: Performance degrades with high offset values.

```sql
-- Bad: Scans and discards 10000 rows
SELECT * FROM orders ORDER BY created_at DESC LIMIT 10 OFFSET 10000;
```

**Solution**: Use keyset/cursor pagination.

```sql
-- Good: Keyset pagination (constant performance)
SELECT * FROM orders 
WHERE created_at < '2024-02-15 10:30:00'  -- Last seen timestamp
ORDER BY created_at DESC 
LIMIT 10;
```

## Schema Design Anti-Patterns

### ❌ Using Rules Instead of Triggers

**Problem**: Rules are complex, have surprising behavior, and are deprecated for most use cases.

```sql
-- Bad: Rule-based audit (don't do this)
CREATE RULE log_insert AS ON INSERT TO orders
DO ALSO INSERT INTO audit_log VALUES (NEW.*);
```

**Solution**: Use triggers.

```sql
-- Good: Trigger-based audit
CREATE FUNCTION audit_log_trigger() RETURNS trigger AS $$
BEGIN
    INSERT INTO audit_log (table_name, operation, data)
    VALUES (TG_TABLE_NAME, TG_OP, to_jsonb(NEW));
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER orders_audit_trg
    AFTER INSERT ON orders
    FOR EACH ROW EXECUTE FUNCTION audit_log_trigger();
```

### ❌ Using Table Inheritance for Data

**Problem**: No proper constraint enforcement, confusing query behavior.

```sql
-- Bad: Old-style inheritance (not partitioning)
CREATE TABLE orders_archive () INHERITS (orders);
```

**Solution**: Use declarative partitioning (PG10+).

```sql
-- Good: Native partitioning
CREATE TABLE orders (
    id uuid NOT NULL,
    created_at timestamptz NOT NULL
) PARTITION BY RANGE (created_at);

CREATE TABLE orders_2024_q1 PARTITION OF orders
    FOR VALUES FROM ('2024-01-01') TO ('2024-04-01');
```

### ❌ Using Public Schema

**Problem**: Default grants, naming conflicts, unclear ownership.

```sql
-- Bad: Everything in public
CREATE TABLE public.users (...);
```

**Solution**: Use named schemas, remove public.

```sql
-- Good: Organized schemas
CREATE SCHEMA app;
REVOKE ALL ON SCHEMA public FROM PUBLIC;
CREATE TABLE data.users (...);
```

### ❌ Using EAV (Entity-Attribute-Value) Pattern

**Problem**: No type safety, poor performance, complex queries.

```sql
-- Bad: EAV anti-pattern
CREATE TABLE entity_attributes (
    entity_id uuid,
    attribute_name text,
    attribute_value text  -- Everything is text!
);
```

**Solution**: Use proper columns or JSONB for truly dynamic attributes.

```sql
-- Good: Proper columns for known attributes
CREATE TABLE products (
    id uuid PRIMARY KEY,
    name text NOT NULL,
    price numeric(15,2) NOT NULL,
    attributes jsonb  -- Only for truly dynamic data
);
```

### ❌ Storing Comma-Separated Values

**Problem**: Can't index, can't enforce referential integrity, parsing nightmare.

```sql
-- Bad: CSV in column
CREATE TABLE posts (
    id uuid PRIMARY KEY,
    tag_ids text  -- '1,2,5,12'
);
```

**Solution**: Use arrays or junction tables.

```sql
-- Good: Array
CREATE TABLE posts (
    id uuid PRIMARY KEY,
    tags text[] NOT NULL DEFAULT '{}'
);
CREATE INDEX posts_tags_idx ON posts USING gin(tags);

-- Good: Junction table (with referential integrity)
CREATE TABLE post_tags (
    post_id uuid REFERENCES posts(id),
    tag_id uuid REFERENCES tags(id),
    PRIMARY KEY (post_id, tag_id)
);
```

## PL/pgSQL Anti-Patterns

### ❌ Not Using Parameterized Queries

**Problem**: SQL injection, plan cache misses.

```sql
-- Bad: String concatenation
CREATE FUNCTION bad_search(search_term text) RETURNS SETOF users AS $$
BEGIN
    RETURN QUERY EXECUTE 'SELECT * FROM users WHERE name = ''' || search_term || '''';
END;
$$ LANGUAGE plpgsql;
```

**Solution**: Use parameters in EXECUTE.

```sql
-- Good: Parameterized
CREATE FUNCTION safe_search(in_search_term text) RETURNS SETOF users AS $$
BEGIN
    RETURN QUERY EXECUTE 'SELECT * FROM users WHERE name = $1'
    USING in_search_term;
END;
$$ LANGUAGE plpgsql;
```

### ❌ Row-by-Row Processing

**Problem**: Slow, ignores PostgreSQL's set-based strengths.

```sql
-- Bad: Processing one row at a time
CREATE FUNCTION update_all_prices() RETURNS void AS $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN SELECT id, price FROM products LOOP
        UPDATE products SET price = r.price * 1.1 WHERE id = r.id;
    END LOOP;
END;
$$ LANGUAGE plpgsql;
```

**Solution**: Use set-based operations.

```sql
-- Good: Single statement
UPDATE products SET price = price * 1.1;
```

### ❌ Missing Volatility Declarations

**Problem**: Incorrect optimization, unexpected behavior in parallel queries.

```sql
-- Bad: Missing volatility (defaults to VOLATILE)
CREATE FUNCTION calculate_tax(amount numeric) RETURNS numeric AS $$
BEGIN
    RETURN amount * 0.08;
END;
$$ LANGUAGE plpgsql;
```

**Solution**: Always declare volatility.

```sql
-- Good: Explicit volatility
CREATE FUNCTION calculate_tax(in_amount numeric) 
RETURNS numeric
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
    SELECT in_amount * 0.08;
$$;
```

### ❌ Parameter Name Conflicts

**Problem**: Ambiguous column vs parameter references.

```sql
-- Bad: Parameter name matches column
CREATE FUNCTION get_user(id uuid) RETURNS users AS $$
BEGIN
    RETURN QUERY SELECT * FROM users WHERE id = id;  -- Always true!
END;
$$ LANGUAGE plpgsql;
```

**Solution**: Prefix parameters with `in_`.

```sql
-- Good: No ambiguity
CREATE FUNCTION get_user(in_id uuid) RETURNS users AS $$
BEGIN
    RETURN QUERY SELECT * FROM users WHERE id = in_id;
END;
$$ LANGUAGE plpgsql;
```

## Security Anti-Patterns

### ❌ Using trust Authentication Over Network

**Problem**: Anyone can connect as any user without password.

**Solution**: Use scram-sha-256 authentication.

```
# Good pg_hba.conf:
host all all 0.0.0.0/0 scram-sha-256
```

### ❌ Storing Passwords in Plain Text

**Problem**: Password exposure if database compromised.

**Solution**: Use pgcrypto and store hashes.

```sql
-- Good: Store password hash
CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE users (
    id uuid PRIMARY KEY,
    email text NOT NULL,
    password_hash text NOT NULL
);

-- Hash on insert
INSERT INTO users (id, email, password_hash)
VALUES (uuidv7(), 'user@example.com', crypt('password', gen_salt('bf')));
```

### ❌ SECURITY DEFINER Without search_path

**Problem**: Search path manipulation can execute malicious code.

```sql
-- Bad: Vulnerable to search_path attack
CREATE FUNCTION admin_action() RETURNS void 
SECURITY DEFINER AS $$
BEGIN
    DELETE FROM logs;  -- Which schema's logs table?
END;
$$ LANGUAGE plpgsql;
```

**Solution**: Set search_path explicitly.

```sql
-- Good: Fixed search_path
CREATE FUNCTION admin_action() RETURNS void 
SECURITY DEFINER
SET search_path = app, pg_temp
AS $$
BEGIN
    DELETE FROM data.logs;
END;
$$ LANGUAGE plpgsql;
```

## Performance Anti-Patterns

### ❌ SELECT FOR UPDATE Without NOWAIT/SKIP LOCKED

**Problem**: Blocking indefinitely on locked rows, causing timeouts and deadlocks.

```sql
-- Bad: Blocks forever if row is locked
SELECT * FROM data.orders WHERE id = $1 FOR UPDATE;
```

**Solution**: Use `NOWAIT` to fail fast or `SKIP LOCKED` for queue patterns.

```sql
-- Good: Fail immediately if locked
SELECT * FROM data.orders WHERE id = $1 FOR UPDATE NOWAIT;
-- Raises: ERROR: could not obtain lock on row

-- Good: Skip locked rows (for job queues)
SELECT * FROM data.orders
WHERE status = 'pending'
ORDER BY created_at
LIMIT 1
FOR UPDATE SKIP LOCKED;

-- Good: With timeout
SET lock_timeout = '5s';
SELECT * FROM data.orders WHERE id = $1 FOR UPDATE;
```

### ❌ Missing Indexes on Foreign Keys

**Problem**: Slow CASCADE operations, slow JOINs.

```sql
-- Bad: FK without index
CREATE TABLE order_items (
    id uuid PRIMARY KEY,
    order_id uuid REFERENCES orders(id) ON DELETE CASCADE
    -- Missing index on order_id!
);
```

**Solution**: Always index foreign keys.

```sql
-- Good: FK with index
CREATE TABLE order_items (
    id uuid PRIMARY KEY,
    order_id uuid NOT NULL REFERENCES orders(id) ON DELETE CASCADE
);
CREATE INDEX order_items_order_id_idx ON order_items(order_id);
```

### ❌ Over-Indexing

**Problem**: Each index slows writes and consumes storage.

**Solution**: Index based on actual queries, monitor usage.

```sql
-- Monitor and remove unused indexes:
SELECT indexrelname, idx_scan 
FROM pg_stat_user_indexes 
WHERE idx_scan = 0 AND schemaname = 'app';
```

### ❌ COUNT(*) for Existence Check

**Problem**: Counts all rows when you only need to know if any exist.

```sql
-- Bad: Counts everything
IF (SELECT COUNT(*) FROM orders WHERE customer_id = in_customer_id) > 0 THEN
```

**Solution**: Use EXISTS.

```sql
-- Good: Stops at first match
IF EXISTS (SELECT 1 FROM orders WHERE customer_id = in_customer_id) THEN
```

### ❌ Selecting Without LIMIT

**Problem**: Unexpectedly large result sets crash applications.

```sql
-- Bad: No limit
SELECT * FROM events WHERE created_at > '2024-01-01';
```

**Solution**: Always limit results in application queries.

```sql
-- Good: Explicit limit
SELECT * FROM events 
WHERE created_at > '2024-01-01'
ORDER BY created_at DESC
LIMIT 1000;
```
