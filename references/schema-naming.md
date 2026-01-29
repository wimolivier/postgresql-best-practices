# Schema Design & Naming Conventions

## Table of Contents
1. [Schema Organization](#schema-organization)
2. [Naming Rules](#naming-rules)
3. [Table Naming](#table-naming)
4. [Column Naming](#column-naming)
5. [Index Naming](#index-naming)
6. [Constraint Naming](#constraint-naming)
7. [Function & Procedure Naming](#function--procedure-naming)
8. [Trigger Naming](#trigger-naming)

## Schema Organization

### Use Named Schemas

Create a single database with multiple named schemas. Remove the public schema.

```sql
-- Create application schemas
CREATE SCHEMA app;           -- Main application objects
CREATE SCHEMA app_audit;     -- Audit logging
CREATE SCHEMA app_migration; -- Migration system
CREATE SCHEMA app_api;       -- External API functions

-- Revoke public access
REVOKE ALL ON SCHEMA public FROM PUBLIC;

-- Grant schema access to roles
GRANT USAGE ON SCHEMA app TO app_role;
GRANT USAGE ON SCHEMA app_api TO api_role;
```

### Schema Benefits
- Namespace isolation prevents naming conflicts
- Simplified permission management at schema level
- Logical grouping of related objects
- Multi-tenant support via schema-per-tenant

## Naming Rules

### Universal Rules

1. **Lowercase only**: Never use uppercase. PostgreSQL folds unquoted identifiers to lowercase; mixed case requires double-quoting everywhere and causes tool incompatibility.

2. **Snake_case**: Use underscores to separate words: `order_items`, not `orderItems` or `OrderItems`.

3. **No reserved words**: Avoid SQL reserved words as identifiers.

4. **No prefixes**: Don't use `tbl_`, `sp_`, `fn_` prefixes. Don't prefix with `pg_` (reserved).

5. **Maximum 63 characters**: PostgreSQL truncates longer names.

6. **Descriptive names**: Prefer clarity over brevity. `customer_shipping_address` over `cust_ship_addr`.

### Prohibited Characters
- Spaces
- Special characters except underscore
- Leading numbers

## Table Naming

### Rules
- Use **plural nouns**: `orders`, `customers`, `order_items`
- Use **snake_case**: `order_line_items`
- No prefixes: `orders`, not `tbl_orders`

### Special Table Prefixes
| Prefix | Use |
|--------|-----|
| `v_` | Views |
| `mv_` | Materialized views |
| `tmp_` | Temporary tables |

### Join Table Naming
For many-to-many relationships, combine both table names alphabetically:
```sql
-- users <-> roles many-to-many
CREATE TABLE data.roles_users (
    role_id uuid REFERENCES data.roles(id),
    user_id uuid REFERENCES data.users(id),
    PRIMARY KEY (role_id, user_id)
);
```

## Column Naming

### Primary Keys
```sql
-- Option 1: Simple 'id' (preferred for most cases)
id uuid PRIMARY KEY DEFAULT uuidv7()

-- Option 2: Table-prefixed (for clarity in complex joins)
order_id uuid PRIMARY KEY DEFAULT uuidv7()
```

### Foreign Keys
Name as `{referenced_table_singular}_id`:
```sql
customer_id uuid REFERENCES data.customers(id)
parent_order_id uuid REFERENCES data.orders(id)  -- self-reference
```

### Timestamp Columns
```sql
created_at  timestamptz NOT NULL DEFAULT now()
updated_at  timestamptz NOT NULL DEFAULT now()
deleted_at  timestamptz  -- for soft deletes
```

### Boolean Columns
Use `is_` or `has_` prefix:
```sql
is_active       boolean NOT NULL DEFAULT true
is_verified     boolean NOT NULL DEFAULT false
has_subscription boolean NOT NULL DEFAULT false
```

### Status/State Columns
```sql
status      text NOT NULL DEFAULT 'pending'
order_state text NOT NULL DEFAULT 'draft'
```

### Numeric Columns
Use descriptive suffixes:
```sql
quantity        integer
total_amount    numeric(15,2)
discount_rate   numeric(5,4)
retry_count     integer DEFAULT 0
```

## Index Naming

### Standard Indexes
Pattern: `{table}_{column(s)}_idx` (Trivadis v4.4)
```sql
CREATE INDEX orders_customer_id_idx ON data.orders(customer_id);
CREATE INDEX orders_status_created_idx ON data.orders(status, created_at DESC);
```

### Unique Indexes
Pattern: `{table}_{column(s)}_key`
```sql
CREATE UNIQUE INDEX users_email_key ON data.users(lower(email));
```

### Partial Indexes
Include condition hint:
```sql
CREATE INDEX orders_pending_idx ON data.orders(created_at)
    WHERE status = 'pending';
```

### Expression Indexes
```sql
CREATE INDEX users_email_lower_idx ON data.users(lower(email));
```

## Constraint Naming

> **Note**: PostgreSQL auto-generates constraint names with suffixes like `_pkey`, `_fkey`, `_key`, `_check`. The patterns below use shorter Trivadis-style suffixes for explicit naming. Both approaches are acceptable; explicit naming provides clearer error messages.

### Primary Keys
Pattern: `{table}_pk`
```sql
ALTER TABLE data.orders ADD CONSTRAINT orders_pk PRIMARY KEY (id);
```

### Foreign Keys
Pattern: `{table}_{reftable}_fk`
```sql
ALTER TABLE data.orders
    ADD CONSTRAINT orders_customers_fk
    FOREIGN KEY (customer_id) REFERENCES data.customers(id);
```

### Unique Constraints
Pattern: `{table}_{column(s)}_uk`
```sql
ALTER TABLE data.users
    ADD CONSTRAINT users_email_uk UNIQUE (email);
```

### Check Constraints
Pattern: `{table}_{column}_ck`
```sql
ALTER TABLE data.orders
    ADD CONSTRAINT orders_status_ck
    CHECK (status IN ('draft', 'pending', 'confirmed', 'shipped', 'delivered', 'cancelled'));

ALTER TABLE data.orders
    ADD CONSTRAINT orders_total_ck
    CHECK (total >= 0);
```

### Exclusion Constraints
Pattern: `{table}_{description}_excl`
```sql
ALTER TABLE data.reservations 
    ADD CONSTRAINT reservations_no_overlap_excl 
    EXCLUDE USING gist (room_id WITH =, during WITH &&);
```

## Function & Procedure Naming

### Action Prefixes
| Prefix | Returns | Use |
|--------|---------|-----|
| `select_` | SETOF/TABLE | Query operations |
| `get_` | Single value/row | Fetch one item |
| `insert_` | void/id | Create new record |
| `update_` | void/count | Modify existing |
| `delete_` | void/count | Remove record |
| `upsert_` | void/id | Insert or update |
| `validate_` | boolean | Check validity |
| `calculate_` | value | Compute result |

### Naming Pattern
`{action}_{entity}[_by{filter}][_with{modifier}]`

```sql
-- Query functions
select_orders()
select_orders_by_customer(in_customer_id)
select_orders_by_status_and_date(in_status, in_start_date, in_end_date)
get_order_by_id(in_order_id)
get_customer_balance(in_customer_id)

-- Mutation procedures
insert_order(in_customer_id, in_items)
update_order_status(in_order_id, in_new_status)
delete_order(in_order_id)
upsert_customer(in_email, in_name)
```

### Parameter Naming
Prefix all parameters with `in_` to avoid conflicts with column names:
```sql
CREATE FUNCTION api.select_orders_by_customer(
    in_customer_id uuid,
    in_limit integer DEFAULT 100,
    in_offset integer DEFAULT 0
)
```

## Trigger Naming

### Pattern
`{table}_{timing}{event(s)}_trg`

Where:
- Timing: `b` (before), `a` (after), `i` (instead of)
- Events: `i` (insert), `u` (update), `d` (delete), `t` (truncate)

### Examples
```sql
-- Before insert/update trigger (trigger function in private schema)
CREATE TRIGGER orders_biu_trg
    BEFORE INSERT OR UPDATE ON data.orders
    FOR EACH ROW EXECUTE FUNCTION private.set_updated_at();

-- After insert trigger (audit function in private schema)
CREATE TRIGGER orders_ai_trg
    AFTER INSERT ON data.orders
    FOR EACH ROW EXECUTE FUNCTION private.log_audit();

-- After delete trigger
CREATE TRIGGER orders_ad_trg
    AFTER DELETE ON data.orders
    FOR EACH ROW EXECUTE FUNCTION private.log_audit();
```

### Trigger Function Naming
Pattern: `{action}` or `{table}_{action}` - placed in `private` schema
```sql
CREATE FUNCTION private.set_updated_at() RETURNS trigger ...
CREATE FUNCTION private.log_audit() RETURNS trigger ...
```
