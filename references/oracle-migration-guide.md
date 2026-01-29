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
