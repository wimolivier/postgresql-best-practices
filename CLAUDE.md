# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Purpose

This is a **Claude Code Skill** for PostgreSQL 18+ enterprise database development best practices.

**Structure:**
- `SKILL.md` - Main skill file (frontmatter + core patterns)
- `references/` - Detailed reference documentation (34 files)
- `scripts/` - Executable SQL migration scripts
- `tests/` - Comprehensive PL/pgSQL test suite (11 modules)
- `README.md` - Installation instructions

**Installation:** Users copy this entire directory to `.claude/skills/postgresql-best-practices/` (project) or `~/.claude/skills/postgresql-best-practices/` (personal).

**Skill behavior:** Configured with `user-invocable: false` so it doesn't appear in `/` menu but Claude auto-loads it when users work on PostgreSQL tasks.

## Core Architecture Pattern

The documentation advocates a three-schema separation pattern:

```
Application → api schema → data schema
                ↓
            private schema (triggers, helpers)
```

| Schema | Contains | Access |
|--------|----------|--------|
| `data` | Tables, indexes | None (internal) |
| `private` | Triggers, helpers | None (internal) |
| `api` | Functions, procedures | Applications |

All `api` functions must use `SECURITY DEFINER` with `SET search_path = data, private, pg_temp`.

## Trivadis Naming Conventions

Variable prefixes used in all PL/pgSQL code:

| Prefix | Type |
|--------|------|
| `l_` | Local variable |
| `g_` | Session/global |
| `co_` | Constant |
| `in_` | IN parameter |
| `io_` | INOUT parameter (procedures) |
| `c_` | Cursor |
| `r_` | Record |
| `t_` | Array |

Note: PostgreSQL procedures only support INOUT parameters, not OUT.

## Key Patterns

**Table creation:**
```sql
CREATE TABLE data.{table} (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    ...
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);
```

**API function (reads):**
```sql
CREATE FUNCTION api.{action}_{entity}(in_param type)
RETURNS TABLE (...) LANGUAGE sql STABLE
SECURITY DEFINER SET search_path = data, private, pg_temp
```

**API procedure (writes):**
```sql
CREATE PROCEDURE api.{action}_{entity}(in_param type, INOUT io_id uuid DEFAULT NULL)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = data, private, pg_temp
```

## Data Type Preferences

| Use | Avoid |
|-----|-------|
| `text` | `char(n)`, `varchar(n)` |
| `timestamptz` | `timestamp` |
| `numeric(p,s)` | `money`, `float` |
| `uuidv7()` | `serial`, `uuid_generate_v4()` |
| `GENERATED ALWAYS AS IDENTITY` | `serial`, `bigserial` |

## Migration System

The `scripts/` directory contains a native PL/pgSQL migration system:
- `001_install_migration_system.sql` - Install the system
- `002_migration_runner_helpers.sql` - Helper functions
- `003_example_migrations.sql` - Example patterns
- `999_uninstall_migration_system.sql` - Clean removal

Usage pattern:
```sql
SELECT app_migration.acquire_lock();
CALL app_migration.run_versioned(in_version := '001', in_description := '...', in_sql := $mig$ ... $mig$);
SELECT app_migration.release_lock();
```

## Reference Documentation

Key files in `references/`:
- `quick-reference.md` - Single-page cheat sheet
- `schema-architecture.md` - Schema separation pattern
- `coding-standards-trivadis.md` - PL/pgSQL coding standards
- `plpgsql-table-api.md` - Table API functions/procedures
- `anti-patterns.md` - Common mistakes to avoid
- `data-warehousing-medallion.md` - Medallion Architecture (Bronze/Silver/Gold)

## Test Suite

The `tests/` directory contains a comprehensive PL/pgSQL test suite:

```bash
# Run all tests
./tests/scripts/run_all_tests.sh

# Run specific module
./tests/scripts/run_module.sh 01_migration_system

# CI mode
./tests/scripts/ci_runner.sh
```

Test modules cover: migrations, schema architecture, PL/pgSQL patterns, data types, anti-patterns, RLS, audit logging, medallion architecture, indexing, bulk operations, and transactions.

## Critical Anti-Patterns

1. Direct table access from applications
2. `RETURNS SETOF table` (exposes all columns)
3. Missing `SET search_path` with `SECURITY DEFINER`
4. `timestamp` without timezone
5. `NOT IN` with subqueries (use `NOT EXISTS`)
6. `BETWEEN` with timestamps (use `>= AND <`)
7. Missing indexes on foreign keys
