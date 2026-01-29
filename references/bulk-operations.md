# Bulk Operations Patterns

This document covers efficient patterns for batch inserts, updates, deletes, and other high-volume data operations in PostgreSQL.

## Table of Contents

1. [COPY for Bulk Loading](#copy-for-bulk-loading)
2. [Batch INSERT Patterns](#batch-insert-patterns)
3. [UPSERT Patterns](#upsert-patterns)
4. [Batch UPDATE Patterns](#batch-update-patterns)
5. [Batch DELETE Patterns](#batch-delete-patterns)
6. [Processing Large Result Sets](#processing-large-result-sets)
7. [Temporary Tables for Staging](#temporary-tables-for-staging)
8. [Transaction Management](#transaction-management)

## COPY for Bulk Loading

### Basic COPY

```sql
-- Import from CSV file (fastest method)
COPY data.customers (email, name, is_active)
FROM '/path/to/customers.csv'
WITH (FORMAT csv, HEADER true);

-- Export to CSV
COPY (SELECT id, email, name FROM data.customers WHERE is_active)
TO '/path/to/export.csv'
WITH (FORMAT csv, HEADER true);

-- Import from STDIN (for application use)
COPY data.customers (email, name) FROM STDIN WITH (FORMAT csv);
john@example.com,John Doe
jane@example.com,Jane Smith
\.
```

### COPY with Preprocessing

```sql
-- Use temporary table for preprocessing
CREATE TEMP TABLE staging_customers (
    email text,
    name text,
    phone text
);

-- Load raw data
COPY staging_customers FROM '/path/to/raw_data.csv' WITH (FORMAT csv, HEADER true);

-- Process and insert
INSERT INTO data.customers (email, name, phone)
SELECT 
    lower(trim(email)),
    trim(name),
    regexp_replace(phone, '[^0-9]', '', 'g')
FROM staging_customers
WHERE email ~ '^[^@]+@[^@]+\.[^@]+$';  -- Basic email validation

DROP TABLE staging_customers;
```

### COPY in API Functions

```sql
-- Procedure to import data from application
CREATE OR REPLACE PROCEDURE api.bulk_import_customers(
    in_csv_data text  -- CSV content as text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, private, pg_temp
AS $$
DECLARE
    l_imported integer;
BEGIN
    -- Create temp table
    CREATE TEMP TABLE temp_import (
        email text,
        name text
    ) ON COMMIT DROP;
    
    -- Parse CSV data (simple implementation)
    INSERT INTO temp_import (email, name)
    SELECT 
        split_part(line, ',', 1),
        split_part(line, ',', 2)
    FROM unnest(string_to_array(in_csv_data, E'\n')) AS line
    WHERE line != '' AND line NOT LIKE 'email%';  -- Skip header
    
    -- Insert with deduplication
    INSERT INTO data.customers (email, name)
    SELECT DISTINCT lower(trim(email)), trim(name)
    FROM temp_import t
    WHERE NOT EXISTS (
        SELECT 1 FROM data.customers c 
        WHERE c.email = lower(trim(t.email))
    );
    
    GET DIAGNOSTICS l_imported = ROW_COUNT;
    RAISE NOTICE 'Imported % customers', l_imported;
END;
$$;
```

## Batch INSERT Patterns

### Multi-Row INSERT

```sql
-- Multiple rows in single statement (up to ~1000 rows per statement)
INSERT INTO data.order_items (order_id, product_id, quantity, unit_price)
VALUES 
    ('order-1', 'product-a', 2, 10.00),
    ('order-1', 'product-b', 1, 25.00),
    ('order-1', 'product-c', 3, 15.00);

-- Returns all inserted IDs
INSERT INTO data.customers (email, name)
VALUES 
    ('a@test.com', 'Alice'),
    ('b@test.com', 'Bob'),
    ('c@test.com', 'Charlie')
RETURNING id, email;
```

### INSERT with Array Parameters

```sql
-- API procedure accepting arrays
CREATE OR REPLACE PROCEDURE api.bulk_insert_order_items(
    in_order_id     uuid,
    in_product_ids  uuid[],
    in_quantities   integer[],
    in_prices       numeric[]
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, private, pg_temp
AS $$
DECLARE
    l_inserted integer;
BEGIN
    -- Validate arrays have same length
    IF array_length(in_product_ids, 1) != array_length(in_quantities, 1)
       OR array_length(in_product_ids, 1) != array_length(in_prices, 1) THEN
        RAISE EXCEPTION 'Array lengths must match';
    END IF;
    
    INSERT INTO data.order_items (order_id, product_id, quantity, unit_price)
    SELECT 
        in_order_id,
        unnest(in_product_ids),
        unnest(in_quantities),
        unnest(in_prices);
    
    GET DIAGNOSTICS l_inserted = ROW_COUNT;
    RAISE NOTICE 'Inserted % order items', l_inserted;
END;
$$;

-- Usage
CALL api.bulk_insert_order_items(
    'order-uuid',
    ARRAY['prod-1', 'prod-2', 'prod-3']::uuid[],
    ARRAY[2, 1, 3],
    ARRAY[10.00, 25.00, 15.00]
);
```

### INSERT from JSONB Array

```sql
-- API procedure accepting JSONB array
CREATE OR REPLACE PROCEDURE api.bulk_insert_from_json(
    in_items jsonb  -- [{"email": "a@test.com", "name": "Alice"}, ...]
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, private, pg_temp
AS $$
DECLARE
    l_inserted integer;
BEGIN
    INSERT INTO data.customers (email, name)
    SELECT 
        item->>'email',
        item->>'name'
    FROM jsonb_array_elements(in_items) AS item
    WHERE NOT EXISTS (
        SELECT 1 FROM data.customers c 
        WHERE c.email = item->>'email'
    );
    
    GET DIAGNOSTICS l_inserted = ROW_COUNT;
    RAISE NOTICE 'Inserted % records', l_inserted;
END;
$$;

-- Usage
CALL api.bulk_insert_from_json('[
    {"email": "a@test.com", "name": "Alice"},
    {"email": "b@test.com", "name": "Bob"}
]'::jsonb);
```

### INSERT with SELECT

```sql
-- Copy data between tables
INSERT INTO data.order_archive (id, customer_id, total, status, created_at)
SELECT id, customer_id, total, status, created_at
FROM data.orders
WHERE status = 'completed'
  AND created_at < now() - interval '1 year';

-- Insert with transformation
INSERT INTO data.monthly_summary (month, total_orders, total_revenue)
SELECT 
    date_trunc('month', created_at)::date,
    COUNT(*),
    SUM(total)
FROM data.orders
WHERE created_at >= '2024-01-01'
GROUP BY date_trunc('month', created_at);
```

## UPSERT Patterns

### Basic ON CONFLICT

```sql
-- Update on duplicate key
INSERT INTO data.customers (email, name)
VALUES ('john@example.com', 'John Doe')
ON CONFLICT (email) DO UPDATE SET
    name = EXCLUDED.name,
    updated_at = now();

-- Insert or ignore
INSERT INTO data.tags (name)
VALUES ('sale'), ('new'), ('featured')
ON CONFLICT (name) DO NOTHING;
```

### Conditional UPDATE

```sql
-- Only update if data actually changed
INSERT INTO data.products (sku, name, price)
VALUES ('SKU-001', 'Widget', 29.99)
ON CONFLICT (sku) DO UPDATE SET
    name = EXCLUDED.name,
    price = EXCLUDED.price,
    updated_at = now()
WHERE 
    data.products.name IS DISTINCT FROM EXCLUDED.name
    OR data.products.price IS DISTINCT FROM EXCLUDED.price;
```

### Bulk UPSERT

```sql
-- Upsert with arrays
CREATE OR REPLACE PROCEDURE api.bulk_upsert_products(
    in_skus     text[],
    in_names    text[],
    in_prices   numeric[]
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, private, pg_temp
AS $$
DECLARE
    l_upserted integer;
BEGIN
    INSERT INTO data.products (sku, name, price)
    SELECT unnest(in_skus), unnest(in_names), unnest(in_prices)
    ON CONFLICT (sku) DO UPDATE SET
        name = EXCLUDED.name,
        price = EXCLUDED.price,
        updated_at = now()
    WHERE data.products.name IS DISTINCT FROM EXCLUDED.name
       OR data.products.price IS DISTINCT FROM EXCLUDED.price;
    
    GET DIAGNOSTICS l_upserted = ROW_COUNT;
    RAISE NOTICE 'Upserted % products', l_upserted;
END;
$$;
```

### Upsert with RETURNING

```sql
-- Get info about what was inserted vs updated
WITH upsert AS (
    INSERT INTO data.customers (email, name)
    VALUES ('john@example.com', 'John Doe')
    ON CONFLICT (email) DO UPDATE SET
        name = EXCLUDED.name,
        updated_at = now()
    RETURNING id, email, (xmax = 0) AS inserted
)
SELECT 
    id, 
    email,
    CASE WHEN inserted THEN 'created' ELSE 'updated' END AS action
FROM upsert;
```

## Batch UPDATE Patterns

### UPDATE with JOIN

```sql
-- Update from another table
UPDATE data.products p
SET price = np.new_price,
    updated_at = now()
FROM data.new_prices np
WHERE p.sku = np.sku
  AND p.price IS DISTINCT FROM np.new_price;

-- Update with aggregated data
UPDATE data.customers c
SET total_orders = sub.order_count,
    total_spent = sub.total_amount
FROM (
    SELECT 
        customer_id,
        COUNT(*) AS order_count,
        SUM(total) AS total_amount
    FROM data.orders
    WHERE status = 'completed'
    GROUP BY customer_id
) sub
WHERE c.id = sub.customer_id;
```

### UPDATE with Arrays

```sql
-- Batch update using arrays
CREATE OR REPLACE PROCEDURE api.bulk_update_status(
    in_ids      uuid[],
    in_status   text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, private, pg_temp
AS $$
DECLARE
    l_updated integer;
BEGIN
    UPDATE data.orders
    SET status = in_status,
        updated_at = now()
    WHERE id = ANY(in_ids);
    
    GET DIAGNOSTICS l_updated = ROW_COUNT;
    RAISE NOTICE 'Updated % orders', l_updated;
END;
$$;

-- Update with different values per row
CREATE OR REPLACE PROCEDURE api.bulk_update_prices(
    in_product_ids  uuid[],
    in_prices       numeric[]
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, private, pg_temp
AS $$
BEGIN
    UPDATE data.products p
    SET price = updates.new_price,
        updated_at = now()
    FROM (
        SELECT 
            unnest(in_product_ids) AS id,
            unnest(in_prices) AS new_price
    ) updates
    WHERE p.id = updates.id
      AND p.price IS DISTINCT FROM updates.new_price;
END;
$$;
```

### UPDATE with LIMIT (Chunked)

```sql
-- Update in batches to avoid long locks
CREATE OR REPLACE PROCEDURE api.migrate_data_chunked(
    in_batch_size integer DEFAULT 1000
)
LANGUAGE plpgsql
AS $$
DECLARE
    l_updated integer;
    l_total integer := 0;
BEGIN
    LOOP
        WITH batch AS (
            SELECT id
            FROM data.legacy_table
            WHERE migrated = false
            LIMIT in_batch_size
            FOR UPDATE SKIP LOCKED
        )
        UPDATE data.legacy_table t
        SET migrated = true,
            new_column = compute_new_value(t.old_column)
        FROM batch
        WHERE t.id = batch.id;
        
        GET DIAGNOSTICS l_updated = ROW_COUNT;
        l_total := l_total + l_updated;
        
        EXIT WHEN l_updated = 0;
        
        COMMIT;  -- Release locks between batches
        RAISE NOTICE 'Processed % records (total: %)', l_updated, l_total;
    END LOOP;
    
    RAISE NOTICE 'Migration complete. Total: % records', l_total;
END;
$$;
```

## Batch DELETE Patterns

### DELETE with LIMIT

```sql
-- Delete in batches
CREATE OR REPLACE PROCEDURE api.purge_old_logs(
    in_older_than interval DEFAULT interval '90 days',
    in_batch_size integer DEFAULT 10000
)
LANGUAGE plpgsql
AS $$
DECLARE
    l_deleted integer;
    l_total integer := 0;
    l_cutoff timestamptz;
BEGIN
    l_cutoff := now() - in_older_than;
    
    LOOP
        DELETE FROM data.logs
        WHERE id IN (
            SELECT id FROM data.logs
            WHERE created_at < l_cutoff
            LIMIT in_batch_size
        );
        
        GET DIAGNOSTICS l_deleted = ROW_COUNT;
        l_total := l_total + l_deleted;
        
        EXIT WHEN l_deleted = 0;
        
        COMMIT;
        RAISE NOTICE 'Deleted % records (total: %)', l_deleted, l_total;
        
        -- Optional: Add delay to reduce system load
        PERFORM pg_sleep(0.1);
    END LOOP;
    
    RAISE NOTICE 'Purge complete. Total deleted: %', l_total;
END;
$$;
```

### DELETE with Archive

```sql
-- Move to archive before deleting
CREATE OR REPLACE PROCEDURE api.archive_and_delete_orders(
    in_older_than interval DEFAULT interval '1 year'
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, private, pg_temp
AS $$
DECLARE
    l_archived integer;
BEGIN
    -- Archive
    INSERT INTO data.orders_archive
    SELECT * FROM data.orders
    WHERE created_at < now() - in_older_than
      AND status IN ('completed', 'cancelled');
    
    GET DIAGNOSTICS l_archived = ROW_COUNT;
    
    -- Delete archived records
    DELETE FROM data.orders
    WHERE created_at < now() - in_older_than
      AND status IN ('completed', 'cancelled');
    
    RAISE NOTICE 'Archived and deleted % orders', l_archived;
END;
$$;
```

### TRUNCATE (Fastest Delete All)

```sql
-- Much faster than DELETE for removing all rows
TRUNCATE data.temp_import;

-- Truncate with restart identity
TRUNCATE data.logs RESTART IDENTITY;

-- Truncate cascade (also truncates dependent tables)
TRUNCATE data.customers CASCADE;

-- Note: TRUNCATE requires table lock, cannot be rolled back in some cases
```

## Processing Large Result Sets

### Server-Side Cursor

```sql
-- Declare cursor for large result set
CREATE OR REPLACE PROCEDURE api.process_large_dataset()
LANGUAGE plpgsql
AS $$
DECLARE
    c_orders CURSOR FOR 
        SELECT id, customer_id, total 
        FROM data.orders 
        WHERE status = 'pending';
    l_batch_size integer := 100;
    l_records RECORD[];
    l_count integer := 0;
BEGIN
    FOR l_record IN c_orders LOOP
        -- Process each record
        PERFORM private.process_order(l_record.id);
        l_count := l_count + 1;
        
        -- Periodic commit
        IF l_count % l_batch_size = 0 THEN
            COMMIT;
            RAISE NOTICE 'Processed % records', l_count;
        END IF;
    END LOOP;
    
    RAISE NOTICE 'Total processed: %', l_count;
END;
$$;
```

### FETCH with LIMIT

```sql
-- Paginated processing
CREATE OR REPLACE PROCEDURE api.process_in_pages(
    in_page_size integer DEFAULT 1000
)
LANGUAGE plpgsql
AS $$
DECLARE
    l_last_id uuid := '00000000-0000-0000-0000-000000000000';
    l_count integer;
BEGIN
    LOOP
        -- Process one page
        WITH page AS (
            SELECT id, customer_id, total
            FROM data.orders
            WHERE id > l_last_id
            ORDER BY id
            LIMIT in_page_size
        )
        UPDATE data.orders o
        SET processed = true
        FROM page p
        WHERE o.id = p.id
        RETURNING o.id INTO l_last_id;
        
        GET DIAGNOSTICS l_count = ROW_COUNT;
        
        EXIT WHEN l_count = 0;
        
        COMMIT;
        RAISE NOTICE 'Processed page, last_id: %', l_last_id;
    END LOOP;
END;
$$;
```

## Temporary Tables for Staging

### Staging Pattern

```sql
CREATE OR REPLACE PROCEDURE api.import_with_validation(
    in_data jsonb
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, private, pg_temp
AS $$
DECLARE
    l_valid integer;
    l_invalid integer;
BEGIN
    -- Create staging table
    CREATE TEMP TABLE staging (
        email text,
        name text,
        is_valid boolean DEFAULT true,
        error_message text
    ) ON COMMIT DROP;
    
    -- Load data
    INSERT INTO staging (email, name)
    SELECT 
        item->>'email',
        item->>'name'
    FROM jsonb_array_elements(in_data) AS item;
    
    -- Validate: email format
    UPDATE staging
    SET is_valid = false,
        error_message = 'Invalid email format'
    WHERE email !~ '^[^@]+@[^@]+\.[^@]+$';
    
    -- Validate: duplicate emails
    UPDATE staging s
    SET is_valid = false,
        error_message = 'Duplicate email'
    WHERE EXISTS (
        SELECT 1 FROM data.customers c WHERE c.email = s.email
    );
    
    -- Count results
    SELECT COUNT(*) FILTER (WHERE is_valid) INTO l_valid FROM staging;
    SELECT COUNT(*) FILTER (WHERE NOT is_valid) INTO l_invalid FROM staging;
    
    -- Insert valid records
    INSERT INTO data.customers (email, name)
    SELECT email, name FROM staging WHERE is_valid;
    
    -- Log invalid records
    INSERT INTO data.import_errors (email, name, error_message, imported_at)
    SELECT email, name, error_message, now()
    FROM staging WHERE NOT is_valid;
    
    RAISE NOTICE 'Imported: %, Rejected: %', l_valid, l_invalid;
END;
$$;
```

### Unlogged Tables for Speed

```sql
-- Unlogged tables are faster but not crash-safe
CREATE UNLOGGED TABLE data.temp_calculations (
    id          uuid PRIMARY KEY,
    result      numeric,
    processed   boolean DEFAULT false
);

-- Use for intermediate results that can be regenerated
-- Don't use for permanent data!
```

## Transaction Management

### Autonomous Operations (Logging)

```sql
-- PostgreSQL doesn't have autonomous transactions
-- Use dblink for separate transaction or log to external system

-- Alternative: Use SAVEPOINT for partial rollback
CREATE OR REPLACE PROCEDURE api.process_with_logging()
LANGUAGE plpgsql
AS $$
DECLARE
    l_record RECORD;
BEGIN
    FOR l_record IN SELECT * FROM data.pending_items LOOP
        SAVEPOINT item_savepoint;
        
        BEGIN
            -- Process item
            PERFORM private.process_item(l_record.id);
        EXCEPTION
            WHEN OTHERS THEN
                -- Rollback just this item
                ROLLBACK TO SAVEPOINT item_savepoint;
                
                -- Log error (still in same transaction)
                INSERT INTO data.processing_errors (item_id, error)
                VALUES (l_record.id, SQLERRM);
        END;
        
        RELEASE SAVEPOINT item_savepoint;
    END LOOP;
END;
$$;
```

### Batch Commits

```sql
-- Commit periodically during long operations
CREATE OR REPLACE PROCEDURE api.long_running_process()
LANGUAGE plpgsql
AS $$
DECLARE
    l_count integer := 0;
    co_batch_size CONSTANT integer := 1000;
BEGIN
    FOR l_record IN SELECT * FROM data.items_to_process LOOP
        -- Do work
        UPDATE data.items_to_process 
        SET processed = true 
        WHERE id = l_record.id;
        
        l_count := l_count + 1;
        
        -- Commit every batch
        IF l_count % co_batch_size = 0 THEN
            COMMIT;
        END IF;
    END LOOP;
END;
$$;
```

### Advisory Locks for Coordination

```sql
-- Ensure only one instance runs
CREATE OR REPLACE PROCEDURE api.exclusive_batch_job()
LANGUAGE plpgsql
AS $$
DECLARE
    co_lock_id CONSTANT bigint := 12345;
    l_acquired boolean;
BEGIN
    -- Try to acquire lock
    SELECT pg_try_advisory_lock(co_lock_id) INTO l_acquired;
    
    IF NOT l_acquired THEN
        RAISE NOTICE 'Another instance is running, exiting';
        RETURN;
    END IF;
    
    -- Do batch work
    BEGIN
        -- ... your batch logic here ...
        RAISE NOTICE 'Batch job completed';
    EXCEPTION
        WHEN OTHERS THEN
            -- Always release lock
            PERFORM pg_advisory_unlock(co_lock_id);
            RAISE;
    END;
    
    -- Release lock
    PERFORM pg_advisory_unlock(co_lock_id);
END;
$$;
```
