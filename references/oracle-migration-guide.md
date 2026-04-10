# Oracle to PostgreSQL Migration Guide

A reference guide for developers familiar with Oracle PL/SQL transitioning to PostgreSQL PL/pgSQL. This covers syntax differences, equivalent patterns, and common gotchas.

## Table of Contents

1. [Data Type Mapping](#data-type-mapping)
2. [SQL Syntax Differences](#sql-syntax-differences)
3. [PL/SQL to PL/pgSQL](#plsql-to-plpgsql)
4. [Packages to Schemas](#packages-to-schemas)
5. [Sequences and Identity](#sequences-and-identity)
6. [Date and Time Handling](#date-and-time-handling)
7. [String Functions](#string-functions)
8. [NULL Handling](#null-handling)
9. [Transactions and Locking](#transactions-and-locking)
10. [Error Handling](#error-handling)
11. [Common Gotchas](#common-gotchas)

## Data Type Mapping

| Oracle | PostgreSQL | Notes |
|--------|------------|-------|
| `VARCHAR2(n)` | `text` or `varchar(n)` | Prefer `text` - no performance penalty |
| `NVARCHAR2(n)` | `text` | PostgreSQL is UTF-8 native |
| `CHAR(n)` | `char(n)` or `text` | Avoid `char` - use `text` |
| `NUMBER` | `numeric` | Arbitrary precision |
| `NUMBER(p)` | `numeric(p)` or `bigint` | Use `bigint` for integers |
| `NUMBER(p,s)` | `numeric(p,s)` | Exact match |
| `INTEGER` | `integer` | Same |
| `FLOAT` | `double precision` | IEEE 754 |
| `BINARY_FLOAT` | `real` | 32-bit float |
| `BINARY_DOUBLE` | `double precision` | 64-bit float |
| `DATE` | `timestamp` | Oracle DATE includes time! |
| `TIMESTAMP` | `timestamp` | Same |
| `TIMESTAMP WITH TIME ZONE` | `timestamptz` | Same |
| `INTERVAL YEAR TO MONTH` | `interval` | PostgreSQL interval is more flexible |
| `INTERVAL DAY TO SECOND` | `interval` | Same |
| `CLOB` | `text` | PostgreSQL text is unlimited |
| `BLOB` | `bytea` | Binary data |
| `RAW(n)` | `bytea` | Binary data |
| `LONG` | `text` | Deprecated in Oracle anyway |
| `LONG RAW` | `bytea` | Deprecated |
| `BOOLEAN` | `boolean` | Oracle doesn't have native boolean! |
| `ROWID` | `ctid` | Different semantics - avoid |
| `XMLType` | `xml` | Native XML support |
| `JSON` | `jsonb` | Use `jsonb` for efficiency |
| `SYS_REFCURSOR` | `refcursor` | Similar concept |

### Important Notes

```sql
-- Oracle DATE includes time (common mistake!)
-- Oracle:
SELECT SYSDATE FROM dual;  -- Returns date AND time

-- PostgreSQL:
SELECT now();              -- timestamp with time zone
SELECT CURRENT_DATE;       -- date only
SELECT CURRENT_TIMESTAMP;  -- timestamp with time zone
```

## SQL Syntax Differences

### SELECT Differences

```sql
-- Oracle: DUAL table for expressions
SELECT 1 + 1 FROM dual;

-- PostgreSQL: No FROM needed
SELECT 1 + 1;

-- Oracle: ROWNUM for limiting
SELECT * FROM customers WHERE ROWNUM <= 10;

-- PostgreSQL: LIMIT/OFFSET
SELECT * FROM customers LIMIT 10;
SELECT * FROM customers LIMIT 10 OFFSET 20;

-- Oracle: Hierarchical queries with CONNECT BY
SELECT * FROM employees
START WITH manager_id IS NULL
CONNECT BY PRIOR employee_id = manager_id;

-- PostgreSQL: Recursive CTE
WITH RECURSIVE emp_tree AS (
    SELECT employee_id, name, manager_id, 1 AS level
    FROM employees
    WHERE manager_id IS NULL
    
    UNION ALL
    
    SELECT e.employee_id, e.name, e.manager_id, et.level + 1
    FROM employees e
    JOIN emp_tree et ON e.manager_id = et.employee_id
)
SELECT * FROM emp_tree;
```

### Outer Joins

```sql
-- Oracle: Old-style (+) syntax (avoid)
SELECT * FROM orders o, customers c
WHERE o.customer_id = c.id(+);

-- PostgreSQL: ANSI join (use this in Oracle too!)
SELECT * FROM orders o
LEFT JOIN customers c ON c.id = o.customer_id;
```

### Merge Statement

```sql
-- Oracle: MERGE
MERGE INTO products p
USING new_products np ON (p.sku = np.sku)
WHEN MATCHED THEN UPDATE SET p.price = np.price
WHEN NOT MATCHED THEN INSERT (sku, price) VALUES (np.sku, np.price);

-- PostgreSQL: INSERT ON CONFLICT
INSERT INTO products (sku, price)
SELECT sku, price FROM new_products
ON CONFLICT (sku) DO UPDATE SET price = EXCLUDED.price;
```

### Sequences

```sql
-- Oracle
CREATE SEQUENCE order_seq START WITH 1 INCREMENT BY 1;
SELECT order_seq.NEXTVAL FROM dual;
SELECT order_seq.CURRVAL FROM dual;

-- PostgreSQL
CREATE SEQUENCE order_seq START WITH 1 INCREMENT BY 1;
SELECT nextval('order_seq');
SELECT currval('order_seq');

-- PostgreSQL: Better - use IDENTITY
CREATE TABLE orders (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY
);
```

## PL/SQL to PL/pgSQL

### Basic Syntax

```sql
-- Oracle PL/SQL
CREATE OR REPLACE PROCEDURE update_salary(
    p_employee_id IN NUMBER,
    p_new_salary IN NUMBER
) AS
    v_old_salary NUMBER;
BEGIN
    SELECT salary INTO v_old_salary
    FROM employees
    WHERE employee_id = p_employee_id;
    
    UPDATE employees
    SET salary = p_new_salary
    WHERE employee_id = p_employee_id;
    
    DBMS_OUTPUT.PUT_LINE('Updated from ' || v_old_salary || ' to ' || p_new_salary);
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR(-20001, 'Employee not found');
END;
/

-- PostgreSQL PL/pgSQL
CREATE OR REPLACE PROCEDURE api.update_salary(
    in_employee_id bigint,
    in_new_salary numeric
)
LANGUAGE plpgsql
AS $$
DECLARE
    l_old_salary numeric;
BEGIN
    SELECT salary INTO l_old_salary
    FROM data.employees
    WHERE employee_id = in_employee_id;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Employee not found: %', in_employee_id
            USING ERRCODE = 'P0001';
    END IF;
    
    UPDATE data.employees
    SET salary = in_new_salary
    WHERE employee_id = in_employee_id;
    
    RAISE NOTICE 'Updated from % to %', l_old_salary, in_new_salary;
END;
$$;
```

### Key Differences

| Oracle PL/SQL | PostgreSQL PL/pgSQL |
|---------------|---------------------|
| `CREATE OR REPLACE PROCEDURE name AS` | `CREATE OR REPLACE PROCEDURE name() LANGUAGE plpgsql AS $$` |
| `p_param IN NUMBER` | `in_param numeric` (no IN keyword needed) |
| `p_param OUT NUMBER` | Use `INOUT` or return value |
| `p_param IN OUT NUMBER` | `INOUT io_param numeric` |
| `v_variable NUMBER;` | `l_variable numeric;` (in DECLARE) |
| `v_variable := value;` | `l_variable := value;` |
| `DBMS_OUTPUT.PUT_LINE()` | `RAISE NOTICE '%', message;` |
| `RAISE_APPLICATION_ERROR()` | `RAISE EXCEPTION '' USING ERRCODE = '';` |
| `NO_DATA_FOUND` exception | Check `FOUND` variable or `NOT FOUND` |
| `SQL%ROWCOUNT` | `GET DIAGNOSTICS var = ROW_COUNT;` |
| `/` to execute | `;` to execute |

### Functions

```sql
-- Oracle
CREATE OR REPLACE FUNCTION get_customer_name(p_id IN NUMBER)
RETURN VARCHAR2 AS
    v_name VARCHAR2(100);
BEGIN
    SELECT name INTO v_name FROM customers WHERE id = p_id;
    RETURN v_name;
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        RETURN NULL;
END;
/

-- PostgreSQL
CREATE OR REPLACE FUNCTION api.get_customer_name(in_id bigint)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = data, private, pg_temp
AS $$
DECLARE
    l_name text;
BEGIN
    SELECT name INTO l_name 
    FROM data.customers 
    WHERE id = in_id;
    
    RETURN l_name;  -- Returns NULL if not found
END;
$$;
```

### Cursors

```sql
-- Oracle
DECLARE
    CURSOR c_orders IS
        SELECT order_id, total FROM orders WHERE status = 'PENDING';
    v_order c_orders%ROWTYPE;
BEGIN
    OPEN c_orders;
    LOOP
        FETCH c_orders INTO v_order;
        EXIT WHEN c_orders%NOTFOUND;
        -- Process v_order
    END LOOP;
    CLOSE c_orders;
END;

-- PostgreSQL (using FOR loop - preferred)
DO $$
DECLARE
    r_order RECORD;
BEGIN
    FOR r_order IN 
        SELECT order_id, total FROM orders WHERE status = 'pending'
    LOOP
        -- Process r_order
        RAISE NOTICE 'Order: %, Total: %', r_order.order_id, r_order.total;
    END LOOP;
END;
$$;

-- PostgreSQL (explicit cursor if needed)
DO $$
DECLARE
    c_orders CURSOR FOR
        SELECT order_id, total FROM orders WHERE status = 'pending';
    r_order RECORD;
BEGIN
    OPEN c_orders;
    LOOP
        FETCH c_orders INTO r_order;
        EXIT WHEN NOT FOUND;
        -- Process r_order
    END LOOP;
    CLOSE c_orders;
END;
$$;
```

### Bulk Operations

```sql
-- Oracle: BULK COLLECT and FORALL
DECLARE
    TYPE t_ids IS TABLE OF NUMBER;
    TYPE t_names IS TABLE OF VARCHAR2(100);
    v_ids t_ids;
    v_names t_names;
BEGIN
    SELECT id, name BULK COLLECT INTO v_ids, v_names
    FROM customers WHERE status = 'ACTIVE';
    
    FORALL i IN v_ids.FIRST..v_ids.LAST
        UPDATE orders SET customer_name = v_names(i)
        WHERE customer_id = v_ids(i);
END;

-- PostgreSQL: Use set-based operations (no FORALL needed)
UPDATE orders o
SET customer_name = c.name
FROM customers c
WHERE c.id = o.customer_id
  AND c.status = 'active';

-- PostgreSQL: If you need arrays
DO $$
DECLARE
    t_ids uuid[];
BEGIN
    SELECT array_agg(id) INTO t_ids
    FROM customers WHERE status = 'active';
    
    UPDATE orders SET processed = true
    WHERE customer_id = ANY(t_ids);
END;
$$;
```

## Packages to Schemas

Oracle packages provide namespacing, public/private separation, and state. PostgreSQL schemas provide similar namespacing.

```sql
-- Oracle Package Specification
CREATE OR REPLACE PACKAGE customers_pkg AS
    -- Public procedures/functions
    FUNCTION get_customer(p_id NUMBER) RETURN customers%ROWTYPE;
    PROCEDURE insert_customer(p_email VARCHAR2, p_name VARCHAR2);
    PROCEDURE update_status(p_id NUMBER, p_status VARCHAR2);
    
    -- Package variable (session state)
    g_default_status VARCHAR2(20) := 'ACTIVE';
END customers_pkg;
/

-- Oracle Package Body
CREATE OR REPLACE PACKAGE BODY customers_pkg AS
    -- Private function
    FUNCTION validate_email(p_email VARCHAR2) RETURN BOOLEAN IS
    BEGIN
        RETURN REGEXP_LIKE(p_email, '^[^@]+@[^@]+\.[^@]+$');
    END;
    
    -- Public implementations
    FUNCTION get_customer(p_id NUMBER) RETURN customers%ROWTYPE IS
        v_customer customers%ROWTYPE;
    BEGIN
        SELECT * INTO v_customer FROM customers WHERE id = p_id;
        RETURN v_customer;
    END;
    
    -- ... other implementations
END customers_pkg;
/
```

```sql
-- PostgreSQL: Use schemas for namespacing

-- Public functions in api schema
CREATE OR REPLACE FUNCTION api.get_customer(in_id uuid)
RETURNS TABLE (id uuid, email text, name text, status text)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data, private, pg_temp
AS $$
    SELECT id, email, name, status
    FROM data.customers
    WHERE id = in_id;
$$;

CREATE OR REPLACE PROCEDURE api.insert_customer(
    in_email text,
    in_name text,
    INOUT io_id uuid DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, private, pg_temp
AS $$
BEGIN
    IF NOT private.validate_email(in_email) THEN
        RAISE EXCEPTION 'Invalid email format';
    END IF;
    
    INSERT INTO data.customers (email, name, status)
    VALUES (lower(in_email), in_name, private.get_default_status())
    RETURNING id INTO io_id;
END;
$$;

-- Private functions in private schema
CREATE OR REPLACE FUNCTION private.validate_email(in_email text)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT in_email ~ '^[^@]+@[^@]+\.[^@]+$';
$$;

-- Package variables become session variables or config functions
CREATE OR REPLACE FUNCTION private.get_default_status()
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT 'active'::text;
$$;
```

### Package Variable Alternatives

```sql
-- Oracle package variable
-- customers_pkg.g_current_user_id

-- PostgreSQL: Session variable
SET myapp.current_user_id = 'user-uuid';
SELECT current_setting('myapp.current_user_id');

-- PostgreSQL: Function wrapper
CREATE OR REPLACE FUNCTION private.get_current_user_id()
RETURNS uuid
LANGUAGE sql
STABLE
AS $$
    SELECT NULLIF(current_setting('myapp.current_user_id', true), '')::uuid;
$$;
```

### Oracle-Package Style: Sub-Schemas + File-per-Module

For teams porting Oracle PL/SQL codebases, the single flat `api` schema loses the *package* mental model — the collapsible, namespaced unit that holds every routine for one domain. The pattern below restores it by giving each Oracle-package equivalent its own sub-schema (`api_customers`, `api_orders`, …) and its own source file. Combined, they deliver the closest thing PostgreSQL has to Oracle packages: per-domain folders in your IDE, per-package grants, and one file per "package body."

#### When to Use This Pattern

This is the recommended layout for **Oracle-migration projects**. The package mental model is so deeply ingrained in PL/SQL teams that the familiarity benefit can justify sub-schemas earlier than the canonical 50+ tables / 200+ functions threshold documented in [coding-standards-trivadis.md → Option 2](coding-standards-trivadis.md#option-2-sub-schema-pattern-for-large-applications). That said:

- **Smaller projects** (under ~20 tables) without an Oracle background should still start with the canonical single `api` schema described in [schema-architecture.md](schema-architecture.md). Sub-schemas add real overhead in grants, search_path, and migration runners.
- **Larger projects** with clean domain boundaries — and especially anything porting from Oracle — benefit from sub-schemas regardless of exact table count. The bigger the codebase, the more the IDE-tree grouping pays off.

#### Package Map

A 12-table online-store example, mapped to 10 packages. Tightly-coupled child tables fold into their parent's package — same way Oracle would bundle `orders` and `order_items` operations in one `orders_pkg`.

| Package schema | Tables it owns | Notes |
|---|---|---|
| `api_customers` | `data.customers` | |
| `api_addresses` | `data.addresses` | |
| `api_categories` | `data.categories` | |
| `api_products` | `data.products` | |
| `api_inventory` | `data.inventory` | |
| `api_carts` | `data.carts`, `data.cart_items` | child folds in |
| `api_orders` | `data.orders`, `data.order_items` | child folds in |
| `api_payments` | `data.payments` | |
| `api_shipments` | `data.shipments` | |
| `api_reviews` | `data.reviews` | |

10 packages cover 12 tables. Note that **tables stay in `data`** — only the routines get sub-schema-ized. Do not create `data_orders` or `data_products`; that fragments foreign keys and complicates joins.

#### Schema Creation

```sql
-- Core storage and internals
CREATE SCHEMA data;
CREATE SCHEMA private;

-- One "package" per API domain
CREATE SCHEMA api_customers;
CREATE SCHEMA api_addresses;
CREATE SCHEMA api_categories;
CREATE SCHEMA api_products;
CREATE SCHEMA api_inventory;
CREATE SCHEMA api_carts;
CREATE SCHEMA api_orders;
CREATE SCHEMA api_payments;
CREATE SCHEMA api_shipments;
CREATE SCHEMA api_reviews;

-- Lock down the default namespace
REVOKE ALL ON SCHEMA public FROM PUBLIC;
```

Schema names use the **plural** convention to mirror table naming (`data.orders` → `api_orders`), consistent with [coding-standards-trivadis.md](coding-standards-trivadis.md#database-object-naming).

#### Directory Layout (File-per-Module)

```
sql/
├── 000_schemas.sql              -- CREATE SCHEMA statements above
│
├── data/                        -- Tables, indexes, constraints
│   ├── 010_customers.sql
│   ├── 011_addresses.sql
│   ├── 012_categories.sql
│   ├── 013_products.sql
│   ├── 014_inventory.sql
│   ├── 015_carts.sql            -- carts + cart_items together
│   ├── 016_orders.sql           -- orders + order_items together
│   ├── 017_payments.sql
│   ├── 018_shipments.sql
│   └── 019_reviews.sql
│
├── private/                     -- Helpers + trigger functions
│   ├── 100_set_updated_at.sql
│   ├── 101_log_audit.sql
│   └── 110_triggers.sql
│
├── api/                         -- One file per package (Oracle "package body")
│   ├── 200_customers.sql        -- api_customers.*
│   ├── 201_addresses.sql        -- api_addresses.*
│   ├── 202_categories.sql       -- api_categories.*
│   ├── 203_products.sql         -- api_products.*
│   ├── 204_inventory.sql        -- api_inventory.*
│   ├── 205_carts.sql            -- api_carts.*
│   ├── 206_orders.sql           -- api_orders.*
│   ├── 207_payments.sql         -- api_payments.*
│   ├── 208_shipments.sql        -- api_shipments.*
│   └── 209_reviews.sql          -- api_reviews.*
│
└── grants/
    └── 900_grants.sql           -- GRANT USAGE / EXECUTE per package
```

**Numeric prefixes** give deterministic load order in any `psql -f` loop or migration runner, and IDEs render them in sequence. The `200_*` band reserves room for 99 packages before colliding with the next band.

#### Package Routine Inventory

Each package contains the same kinds of routines you'd find in an Oracle package body. Names get shorter because the package context lives in the schema name.

##### `api_customers` (file: `sql/api/200_customers.sql`)

- `api_customers.get_by_id(in_id uuid)`
- `api_customers.get_by_email(in_email text)`
- `api_customers.select_verified()`
- `api_customers.insert(in_email, in_full_name, INOUT io_id)`
- `api_customers.update(in_id, in_full_name)`
- `api_customers.delete(in_id)`

##### `api_addresses` (file: `201_addresses.sql`)

- `api_addresses.get_by_id(in_id)`
- `api_addresses.select_by_customer(in_customer_id)`
- `api_addresses.insert(...)`
- `api_addresses.update(...)`
- `api_addresses.delete(in_id)`

##### `api_categories` (file: `202_categories.sql`)

- `api_categories.get_by_id(in_id)`
- `api_categories.select_all()`
- `api_categories.select_by_parent(in_parent_id)`
- `api_categories.insert(...)`
- `api_categories.update(...)`
- `api_categories.delete(in_id)`

##### `api_products` (file: `203_products.sql`)

- `api_products.get_by_id(in_id)`
- `api_products.get_by_sku(in_sku)`
- `api_products.select_by_category(in_category_id)`
- `api_products.select_by_category_and_active(in_category_id, in_is_active)`
- `api_products.calculate_rating(in_id)`
- `api_products.insert(...)`
- `api_products.update(...)`
- `api_products.upsert(...)`
- `api_products.delete(in_id)`

##### `api_inventory` (file: `204_inventory.sql`)

- `api_inventory.get_by_product(in_product_id)`
- `api_inventory.select_by_warehouse(in_warehouse_id)`
- `api_inventory.calculate_available_stock(in_product_id)`
- `api_inventory.update_quantity(in_id, in_qty)`

##### `api_carts` (file: `205_carts.sql`) — covers carts + cart_items

- `api_carts.get_by_id(in_id)`
- `api_carts.get_by_customer(in_customer_id)`
- `api_carts.insert(in_customer_id, INOUT io_id)`
- `api_carts.delete(in_id)`
- `api_carts.item_select_by_cart(in_cart_id)`
- `api_carts.item_insert(...)`
- `api_carts.item_upsert(...)`
- `api_carts.item_update_quantity(in_id, in_qty)`
- `api_carts.item_delete(in_id)`

##### `api_orders` (file: `206_orders.sql`) — covers orders + order_items

- `api_orders.get_by_id(in_id)`
- `api_orders.select_by_customer(in_customer_id)`
- `api_orders.select_by_status_and_date(in_status, in_from, in_to)`
- `api_orders.calculate_total(in_id)`
- `api_orders.insert(in_customer_id, INOUT io_id)`
- `api_orders.update_status(in_id, in_new_status)`
- `api_orders.delete(in_id)`
- `api_orders.item_select_by_order(in_order_id)`
- `api_orders.item_insert(...)`
- `api_orders.item_delete(in_id)`

##### `api_payments` (file: `207_payments.sql`)

- `api_payments.get_by_id(in_id)`
- `api_payments.select_by_order(in_order_id)`
- `api_payments.validate(in_id)`
- `api_payments.insert(...)`
- `api_payments.update_status(in_id, in_new_status)`

##### `api_shipments` (file: `208_shipments.sql`)

- `api_shipments.get_by_id(in_id)`
- `api_shipments.select_by_order(in_order_id)`
- `api_shipments.insert(...)`
- `api_shipments.update_status(in_id, in_new_status)`

##### `api_reviews` (file: `209_reviews.sql`)

- `api_reviews.get_by_id(in_id)`
- `api_reviews.select_by_product(in_product_id)`
- `api_reviews.select_by_customer(in_customer_id)`
- `api_reviews.insert(...)`
- `api_reviews.update(...)`
- `api_reviews.delete(in_id)`

#### Sample Package File: `sql/api/206_orders.sql`

The full "package body" for `api_orders`. Everything for orders + order_items lives in one file:

```sql
-- =============================================================================
-- api_orders package
-- Owns: data.orders, data.order_items
-- Depends on: data (read/write), private (helpers, triggers)
-- =============================================================================

-- ─── READS ───────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION api_orders.get_by_id(in_order_id uuid)
RETURNS TABLE (id uuid, customer_id uuid, status text, total_amount numeric, placed_at timestamptz)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data, private, pg_temp
AS $$
    SELECT id, customer_id, status, total_amount, placed_at
      FROM data.orders
     WHERE id = in_order_id;
$$;

CREATE OR REPLACE FUNCTION api_orders.select_by_customer(
    in_customer_id uuid,
    in_limit       integer DEFAULT 100,
    in_offset      integer DEFAULT 0
)
RETURNS TABLE (id uuid, status text, total_amount numeric, placed_at timestamptz)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data, private, pg_temp
AS $$
    SELECT id, status, total_amount, placed_at
      FROM data.orders
     WHERE customer_id = in_customer_id
     ORDER BY created_at DESC
     LIMIT in_limit OFFSET in_offset;
$$;

CREATE OR REPLACE FUNCTION api_orders.select_by_status_and_date(
    in_status     text,
    in_start_date timestamptz,
    in_end_date   timestamptz
)
RETURNS TABLE (id uuid, customer_id uuid, total_amount numeric, placed_at timestamptz)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data, private, pg_temp
AS $$
    SELECT id, customer_id, total_amount, placed_at
      FROM data.orders
     WHERE status = in_status
       AND placed_at >= in_start_date
       AND placed_at <  in_end_date
     ORDER BY placed_at DESC;
$$;

CREATE OR REPLACE FUNCTION api_orders.calculate_total(in_order_id uuid)
RETURNS numeric
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data, private, pg_temp
AS $$
    SELECT COALESCE(SUM(quantity * unit_price), 0)
      FROM data.order_items
     WHERE order_id = in_order_id;
$$;

-- ─── WRITES ──────────────────────────────────────────────────────────────────

CREATE OR REPLACE PROCEDURE api_orders.insert(
    in_customer_id uuid,
    INOUT io_id    uuid DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, private, pg_temp
AS $$
BEGIN
    INSERT INTO data.orders (customer_id)
    VALUES (in_customer_id)
    RETURNING id INTO io_id;
END;
$$;

CREATE OR REPLACE PROCEDURE api_orders.update_status(
    in_order_id   uuid,
    in_new_status text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, private, pg_temp
AS $$
BEGIN
    UPDATE data.orders
       SET status     = in_new_status,
           updated_at = now()
     WHERE id = in_order_id;
END;
$$;

CREATE OR REPLACE PROCEDURE api_orders.delete(in_order_id uuid)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, private, pg_temp
AS $$
BEGIN
    DELETE FROM data.orders WHERE id = in_order_id;
END;
$$;

-- ─── CHILD: order_items (lives in the same package) ─────────────────────────

CREATE OR REPLACE FUNCTION api_orders.item_select_by_order(in_order_id uuid)
RETURNS TABLE (id uuid, product_id uuid, quantity integer, unit_price numeric)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = data, private, pg_temp
AS $$
    SELECT id, product_id, quantity, unit_price
      FROM data.order_items
     WHERE order_id = in_order_id;
$$;

CREATE OR REPLACE PROCEDURE api_orders.item_insert(
    in_order_id   uuid,
    in_product_id uuid,
    in_quantity   integer,
    in_unit_price numeric,
    INOUT io_id   uuid DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, private, pg_temp
AS $$
BEGIN
    INSERT INTO data.order_items (order_id, product_id, quantity, unit_price)
    VALUES (in_order_id, in_product_id, in_quantity, in_unit_price)
    RETURNING id INTO io_id;
END;
$$;

CREATE OR REPLACE PROCEDURE api_orders.item_delete(in_id uuid)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, private, pg_temp
AS $$
BEGIN
    DELETE FROM data.order_items WHERE id = in_id;
END;
$$;

-- ─── PACKAGE METADATA ────────────────────────────────────────────────────────

COMMENT ON SCHEMA api_orders IS
    'Orders package — orders and order_items. Owns data.orders, data.order_items.';
```

Every routine uses `SECURITY DEFINER SET search_path = data, private, pg_temp` and parameters are prefixed `in_` / `io_` per Trivadis convention. This file *is* the package body — readable top to bottom, no jumping between files.

#### Per-Package Grants

The biggest operational win of sub-schemas: **least-privilege grants happen at schema granularity**, not function-by-function.

```sql
-- sql/grants/900_grants.sql

-- App role gets every package
GRANT USAGE ON SCHEMA api_customers,  api_addresses,  api_categories,
                       api_products,   api_inventory,  api_carts,
                       api_orders,     api_payments,   api_shipments,
                       api_reviews
    TO app_role;

GRANT EXECUTE ON ALL FUNCTIONS  IN SCHEMA api_customers TO app_role;
GRANT EXECUTE ON ALL PROCEDURES IN SCHEMA api_customers TO app_role;
-- ... repeat per package, or wrap in a DO block

-- Fine-grained: shipping microservice gets only what it needs
GRANT USAGE   ON SCHEMA             api_shipments, api_orders TO shipping_svc;
GRANT EXECUTE ON ALL FUNCTIONS  IN SCHEMA api_shipments       TO shipping_svc;
GRANT EXECUTE ON ALL PROCEDURES IN SCHEMA api_shipments       TO shipping_svc;
GRANT EXECUTE ON FUNCTION api_orders.get_by_id(uuid)          TO shipping_svc;
```

No function-by-function whitelisting. New routines added to a package are automatically covered (combined with `ALTER DEFAULT PRIVILEGES`).

#### Optional: search_path for Callers

If you want callers to use short-form references like `SELECT orders.get_by_id(...)` rather than fully-qualified names, set the search_path on the role:

```sql
ALTER ROLE app_role SET search_path = api_customers, api_addresses, api_categories,
                                       api_products, api_inventory, api_carts,
                                       api_orders, api_payments, api_shipments,
                                       api_reviews, pg_catalog;
```

In practice, fully-qualified `api_orders.get_by_id(...)` is more self-documenting at the call site and avoids silent shadowing if two packages happen to expose a routine with the same name. Configuring search_path is mostly useful for ad-hoc `psql` sessions.

#### IDE Tree — The Payoff

In DataGrip / DBeaver / pgAdmin, the database browser renders each package as a collapsible folder of 5–10 routines:

```
postgres
├── data                        ← tables only
│   ├── customers
│   ├── addresses
│   ├── orders
│   ├── order_items
│   └── ...
├── private                     ← helpers, triggers
│
├── api_carts                   ← collapse/expand like an Oracle package
│   ├── Functions
│   │   ├── get_by_customer
│   │   ├── get_by_id
│   │   └── item_select_by_cart
│   └── Procedures
│       ├── delete
│       ├── insert
│       ├── item_delete
│       ├── item_insert
│       ├── item_update_quantity
│       └── item_upsert
│
├── api_orders                  ← each package is a tidy, small folder
│   ├── Functions
│   │   ├── calculate_total
│   │   ├── get_by_id
│   │   ├── item_select_by_order
│   │   ├── select_by_customer
│   │   └── select_by_status_and_date
│   └── Procedures
│       ├── delete
│       ├── insert
│       ├── item_delete
│       ├── item_insert
│       └── update_status
│
├── api_products
│   └── ...
└── ...
```

Compared to a flat 60+ routine `api` schema, navigation becomes **pick package → pick routine** instead of search/filter. That is the Oracle package mental model, restored.

#### psql Introspection

```
\dn api_*                       -- list all packages
\df api_orders.*                -- list all routines in a package
\df+ api_orders.get_by_id       -- full signature + COMMENT
```

This is the equivalent of Oracle's `DESC customers_pkg` — fast, terminal-native package introspection.

#### Design Rules That Keep Boundaries Clean

These five rules keep package boundaries from eroding over time:

1. **Packages do not call each other's `api_*` functions directly.** If `api_orders` needs product data, it reads `data.products` directly. Cross-package API-to-API calls create hidden coupling and blur permission boundaries.
2. **Shared helpers live in `private`**, not in an `api_common` package. If multiple packages need the same logic, factor it into a `private` function and call it from each.
3. **One file = one package = one `api_*` schema.** Never split a package across multiple files; never mix two packages in one file. The 1:1:1 mapping is the whole point.
4. **Child tables stay in their parent's package** unless they become independently useful. `order_items` belongs in `api_orders`. Promote a child to its own package only when external systems need direct access to it.
5. **Tables stay in `data`** — only routines get sub-schema-ized. Do not create `data_orders` or `data_products`; that fragments foreign keys and complicates joins.

#### Cross-References

- [`coding-standards-trivadis.md` → Option 2: Sub-Schema Pattern](coding-standards-trivadis.md#option-2-sub-schema-pattern-for-large-applications) — brief overview and the canonical 50+ table / 200+ function warning.
- [`schema-architecture.md`](schema-architecture.md) — the canonical single `api` schema pattern, recommended as the default for non-Oracle teams and smaller projects.
- [`schema-naming.md` → Function & Procedure Naming](schema-naming.md#function--procedure-naming) — the `{action}_{entity}` and `in_`/`io_` parameter conventions used throughout the routines above.

## Sequences and Identity

```sql
-- Oracle: Create sequence
CREATE SEQUENCE emp_seq START WITH 1 INCREMENT BY 1;

-- Oracle: Use in INSERT
INSERT INTO employees (id, name) VALUES (emp_seq.NEXTVAL, 'John');

-- Oracle: Create table with sequence
CREATE TABLE employees (
    id NUMBER DEFAULT emp_seq.NEXTVAL PRIMARY KEY,
    name VARCHAR2(100)
);

-- PostgreSQL: IDENTITY columns (preferred)
CREATE TABLE data.employees (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name text NOT NULL
);

-- PostgreSQL: Override identity for data migration
INSERT INTO data.employees (id, name) 
OVERRIDING SYSTEM VALUE
VALUES (100, 'Migrated Employee');

-- PostgreSQL: Sequence if needed
CREATE SEQUENCE data.emp_seq;
SELECT nextval('data.emp_seq');

-- PostgreSQL: UUID (often better than sequences)
CREATE TABLE data.employees (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    name text NOT NULL
);
```

## Date and Time Handling

```sql
-- Oracle
SELECT SYSDATE FROM dual;                    -- Current date+time
SELECT SYSTIMESTAMP FROM dual;               -- With timezone
SELECT TRUNC(SYSDATE) FROM dual;             -- Date only
SELECT ADD_MONTHS(SYSDATE, 3) FROM dual;     -- Add months
SELECT MONTHS_BETWEEN(date1, date2) FROM dual; -- Difference
SELECT TO_CHAR(SYSDATE, 'YYYY-MM-DD') FROM dual;
SELECT TO_DATE('2024-01-15', 'YYYY-MM-DD') FROM dual;

-- PostgreSQL
SELECT now();                                 -- Current timestamp
SELECT CURRENT_TIMESTAMP;                     -- Same
SELECT CURRENT_DATE;                          -- Date only
SELECT now() + interval '3 months';           -- Add months
SELECT age(date1, date2);                     -- Difference as interval
SELECT to_char(now(), 'YYYY-MM-DD');
SELECT '2024-01-15'::date;                    -- Or to_date()
SELECT date_trunc('day', now());              -- Truncate to day

-- Common conversions
-- Oracle TRUNC(date) -> PostgreSQL date_trunc('day', timestamp)
-- Oracle ADD_MONTHS(date, n) -> PostgreSQL date + interval 'n months'
-- Oracle LAST_DAY(date) -> PostgreSQL (date_trunc('month', date) + interval '1 month - 1 day')::date
```

## String Functions

| Oracle | PostgreSQL | Notes |
|--------|------------|-------|
| `\|\|` (concat) | `\|\|` | Same |
| `CONCAT(a, b)` | `concat(a, b)` | Same |
| `LENGTH(str)` | `length(str)` | Same |
| `SUBSTR(str, start, len)` | `substring(str from start for len)` or `substr()` | `substr()` works same |
| `INSTR(str, substr)` | `position(substr in str)` or `strpos()` | |
| `UPPER(str)` | `upper(str)` | Same |
| `LOWER(str)` | `lower(str)` | Same |
| `TRIM(str)` | `trim(str)` | Same |
| `LTRIM(str)` | `ltrim(str)` | Same |
| `RTRIM(str)` | `rtrim(str)` | Same |
| `LPAD(str, len, pad)` | `lpad(str, len, pad)` | Same |
| `RPAD(str, len, pad)` | `rpad(str, len, pad)` | Same |
| `REPLACE(str, from, to)` | `replace(str, from, to)` | Same |
| `REGEXP_LIKE(str, pattern)` | `str ~ pattern` | Different syntax |
| `REGEXP_REPLACE(str, pattern, repl)` | `regexp_replace(str, pattern, repl)` | Similar |
| `REGEXP_SUBSTR(str, pattern)` | `substring(str from pattern)` | Different |
| `NVL(val, default)` | `COALESCE(val, default)` | COALESCE is standard SQL |
| `NVL2(val, if_not_null, if_null)` | `CASE WHEN val IS NOT NULL THEN ... ELSE ... END` | No direct equivalent |
| `DECODE(val, match1, result1, ...)` | `CASE val WHEN match1 THEN result1 ... END` | Use CASE |

## NULL Handling

```sql
-- Oracle NVL -> PostgreSQL COALESCE
-- Oracle
SELECT NVL(commission, 0) FROM employees;

-- PostgreSQL
SELECT COALESCE(commission, 0) FROM employees;

-- Oracle NVL2 -> PostgreSQL CASE
-- Oracle
SELECT NVL2(commission, 'Has Commission', 'No Commission') FROM employees;

-- PostgreSQL
SELECT CASE WHEN commission IS NOT NULL 
            THEN 'Has Commission' 
            ELSE 'No Commission' 
       END FROM employees;

-- Oracle DECODE -> PostgreSQL CASE
-- Oracle
SELECT DECODE(status, 'A', 'Active', 'I', 'Inactive', 'Unknown') FROM customers;

-- PostgreSQL
SELECT CASE status 
         WHEN 'A' THEN 'Active'
         WHEN 'I' THEN 'Inactive'
         ELSE 'Unknown'
       END FROM customers;

-- Empty string vs NULL
-- Oracle: empty string equals NULL (usually)
-- PostgreSQL: empty string is NOT NULL
SELECT '' IS NULL;  -- Oracle: TRUE, PostgreSQL: FALSE
```

## Transactions and Locking

```sql
-- Oracle: Implicit transaction start
UPDATE customers SET status = 'INACTIVE' WHERE id = 1;
COMMIT;

-- PostgreSQL: Same (autocommit off by default in psql)
UPDATE customers SET status = 'inactive' WHERE id = 1;
COMMIT;

-- Savepoints (both same)
SAVEPOINT my_savepoint;
-- do something
ROLLBACK TO SAVEPOINT my_savepoint;

-- Oracle: SELECT FOR UPDATE WAIT
SELECT * FROM orders WHERE id = 1 FOR UPDATE WAIT 5;

-- PostgreSQL: No WAIT, use lock_timeout
SET lock_timeout = '5s';
SELECT * FROM orders WHERE id = 1 FOR UPDATE;

-- PostgreSQL: SKIP LOCKED (very useful!)
SELECT * FROM orders WHERE status = 'pending'
FOR UPDATE SKIP LOCKED
LIMIT 10;

-- Oracle: Autonomous transactions
-- PostgreSQL: Use dblink or separate connection
```

## Error Handling

```sql
-- Oracle
BEGIN
    -- do something
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        -- handle
    WHEN DUP_VAL_ON_INDEX THEN
        -- handle
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('Error: ' || SQLERRM);
        RAISE;
END;

-- PostgreSQL
BEGIN
    -- do something
EXCEPTION
    WHEN no_data_found THEN
        -- handle (rarely needed - use IF NOT FOUND)
    WHEN unique_violation THEN
        -- handle
    WHEN OTHERS THEN
        RAISE NOTICE 'Error: %', SQLERRM;
        RAISE;  -- Re-raise
END;
```

| Oracle Exception | PostgreSQL Exception |
|------------------|---------------------|
| `NO_DATA_FOUND` | `no_data_found` (but use `FOUND` variable instead) |
| `TOO_MANY_ROWS` | `too_many_rows` |
| `DUP_VAL_ON_INDEX` | `unique_violation` |
| `VALUE_ERROR` | `data_exception` |
| `ZERO_DIVIDE` | `division_by_zero` |
| `INVALID_NUMBER` | `invalid_text_representation` |
| Custom `-20001` | Custom `ERRCODE` like `'P0001'` |

```sql
-- Oracle: RAISE_APPLICATION_ERROR
RAISE_APPLICATION_ERROR(-20001, 'Custom error message');

-- PostgreSQL: RAISE EXCEPTION with ERRCODE
RAISE EXCEPTION 'Custom error message'
    USING ERRCODE = 'P0001',
          HINT = 'Check your input',
          DETAIL = 'Additional details here';
```

## Common Gotchas

### 1. Oracle DATE vs PostgreSQL timestamp

```sql
-- Oracle DATE includes time!
-- If you're comparing dates, this matters

-- Oracle: This might miss rows from the same day
SELECT * FROM orders WHERE order_date = DATE '2024-01-15';

-- PostgreSQL: Be explicit
SELECT * FROM orders 
WHERE order_date >= '2024-01-15'::date 
  AND order_date < '2024-01-16'::date;

-- Or use date_trunc
SELECT * FROM orders 
WHERE date_trunc('day', order_date) = '2024-01-15';
```

### 2. Case Sensitivity

```sql
-- Oracle: Identifiers uppercase by default
SELECT * FROM CUSTOMERS;  -- Works
SELECT * FROM customers;  -- Works (same as CUSTOMERS)
SELECT * FROM "Customers"; -- Only works if created with quotes

-- PostgreSQL: Identifiers lowercase by default
SELECT * FROM CUSTOMERS;  -- Becomes: customers
SELECT * FROM customers;  -- Same
SELECT * FROM "Customers"; -- Different! Case-sensitive
```

### 3. Boolean Type

```sql
-- Oracle has no native BOOLEAN in SQL (only PL/SQL)
-- Often uses NUMBER(1) or CHAR(1)
SELECT * FROM users WHERE is_active = 1;
SELECT * FROM users WHERE is_active = 'Y';

-- PostgreSQL has native boolean
SELECT * FROM users WHERE is_active = true;
SELECT * FROM users WHERE is_active;  -- Shorthand
SELECT * FROM users WHERE NOT is_active;
```

### 4. Empty String vs NULL

```sql
-- Oracle: '' is often treated as NULL
SELECT * FROM customers WHERE name = '';  -- Might return nothing
SELECT * FROM customers WHERE name IS NULL;  -- Might find ''

-- PostgreSQL: '' is NOT NULL
SELECT '' IS NULL;  -- FALSE
SELECT * FROM customers WHERE name = '';  -- Finds empty strings only
SELECT * FROM customers WHERE name IS NULL;  -- Finds NULLs only
```

### 5. ROWNUM vs LIMIT

```sql
-- Oracle ROWNUM is tricky!
-- This doesn't work as expected:
SELECT * FROM orders ORDER BY total DESC WHERE ROWNUM <= 10;
-- ROWNUM is assigned before ORDER BY!

-- Correct Oracle:
SELECT * FROM (
    SELECT * FROM orders ORDER BY total DESC
) WHERE ROWNUM <= 10;

-- PostgreSQL is straightforward:
SELECT * FROM orders ORDER BY total DESC LIMIT 10;
```

### 6. Automatic Type Coercion

```sql
-- Oracle is more lenient with types
SELECT * FROM orders WHERE id = '123';  -- Might work if id is NUMBER

-- PostgreSQL is stricter
SELECT * FROM orders WHERE id = '123';  -- Error if id is integer
SELECT * FROM orders WHERE id = 123;    -- Correct
SELECT * FROM orders WHERE id = '123'::integer;  -- Explicit cast
```
