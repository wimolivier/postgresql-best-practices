# Checklists & Troubleshooting

Quick reference checklists for common tasks and solutions to common problems.

> **Related**: See [quick-reference.md](quick-reference.md) for patterns and [anti-patterns.md](anti-patterns.md) for what to avoid.

---

## Checklist: New Project Setup

- [ ] Create schemas: `data`, `private`, `api`, `app_audit`
- [ ] Revoke public schema access: `REVOKE ALL ON SCHEMA public FROM PUBLIC`
- [ ] Install migration system (run `scripts/001_install_migration_system.sql`)
- [ ] Create application roles with appropriate permissions
- [ ] Set up `private.set_updated_at()` trigger function

## Checklist: New Table

- [ ] Create table in `data` schema
- [ ] Use `uuidv7()` or `GENERATED ALWAYS AS IDENTITY` for primary key
- [ ] Add `created_at timestamptz NOT NULL DEFAULT now()`
- [ ] Add `updated_at timestamptz NOT NULL DEFAULT now()`
- [ ] Apply `private.set_updated_at()` trigger
- [ ] Create indexes for foreign keys
- [ ] Create indexes for common query patterns
- [ ] Create API functions in `api` schema

## Checklist: API Function

- [ ] Place in `api` schema
- [ ] Add `SECURITY DEFINER`
- [ ] Add `SET search_path = data, private, pg_temp`
- [ ] Use explicit `RETURNS TABLE (...)` (never `RETURNS SETOF table`)
- [ ] Prefix parameters with `in_`, outputs with `io_`
- [ ] Add appropriate volatility (`STABLE` for reads, default for writes)
- [ ] Add comments

## Checklist: Security Review

- [ ] No direct grants on `data` or `private` schemas
- [ ] All `api` functions use `SECURITY DEFINER` with `SET search_path`
- [ ] Sensitive columns (passwords, tokens) never returned by API functions
- [ ] Application role has only `EXECUTE` on `api` schema

---

## Troubleshooting

### "Permission denied for table..."

**Cause**: Application trying to access `data` schema directly.

**Fix**: Access data through `api` functions only. Check that:
1. Function uses `SECURITY DEFINER`
2. Function has `SET search_path = data, private, pg_temp`
3. Application role has `EXECUTE` permission on the function

### "Migration lock not available"

**Cause**: Another migration is running or crashed without releasing lock.

**Fix**:
```sql
-- Check who holds the lock
SELECT * FROM app_migration.get_lock_holder();

-- If the session is gone, the lock will auto-release
-- If stuck, check for orphaned advisory locks:
SELECT * FROM pg_locks WHERE locktype = 'advisory';
```

### "Checksum mismatch for version..."

**Cause**: A versioned migration was modified after execution.

**Fix**: Versioned migrations should never be modified. Either:
1. Create a new migration to make changes
2. If in development, clear and re-run: `CALL app_migration.clear_failed();`

### Function returns wrong columns

**Cause**: Using `RETURNS SETOF table` exposes all columns.

**Fix**: Use explicit `RETURNS TABLE (col1 type, col2 type, ...)` to control output.

### Slow queries

**Check**:
1. Is there an index on the WHERE clause columns?
2. Is the query using the index? (`EXPLAIN ANALYZE`)
3. For foreign keys, is there an index on the FK column?

See [performance-tuning.md](performance-tuning.md) for detailed optimization strategies.

### SECURITY DEFINER function not working

**Cause**: Missing `SET search_path` allows search path manipulation attacks.

**Fix**: Always pair `SECURITY DEFINER` with `SET search_path`:
```sql
CREATE FUNCTION api.my_function(...)
RETURNS ...
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = data, private, pg_temp  -- Required!
AS $$
...
$$;
```

### Trigger not firing

**Cause**: Trigger may be disabled or on wrong timing.

**Check**:
```sql
-- List triggers on table
SELECT tgname, tgenabled, tgtype 
FROM pg_trigger 
WHERE tgrelid = 'data.my_table'::regclass;

-- Enable if disabled
ALTER TABLE data.my_table ENABLE TRIGGER my_trigger;
```

### UUID vs IDENTITY confusion

**Use UUIDv7 when**:
- Distributed systems (no coordination needed)
- URLs/external references (no sequence guessing)
- Time-ordered sorting needed

**Use IDENTITY when**:
- Internal IDs only
- Need compact storage (8 bytes vs 16)
- Sequential inserts matter for performance
