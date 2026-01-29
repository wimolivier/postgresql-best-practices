# PostgreSQL Best Practices Skill

A Claude Code skill providing comprehensive PostgreSQL 18+ best practices for enterprise database development.

## What This Skill Provides

- **Schema Architecture**: Three-schema separation pattern (data/private/api)
- **Table API Design**: SECURITY DEFINER functions with proper search_path
- **PL/pgSQL Coding Standards**: Trivadis-style naming conventions (l_, in_, io_, co_)
- **Native Migration System**: Pure PL/pgSQL alternative to Flyway/Liquibase
- **Data Warehousing**: Medallion Architecture (Bronze/Silver/Gold)
- **Testing Framework**: Pure PL/pgSQL test suite with assertions and CI integration
- **And more**: Indexes, partitioning, JSONB patterns, RLS, audit logging, vector search, PostGIS, Oracle migration

## Installation

### Project-Level (Recommended)

Install for a specific project:

```bash
# From your project root
mkdir -p .claude/skills
git clone https://github.com/YOUR_USERNAME/postgresql-best-practices.git .claude/skills/postgresql-best-practices
```

### Personal (All Projects)

Install for all your projects:

```bash
mkdir -p ~/.claude/skills
git clone https://github.com/YOUR_USERNAME/postgresql-best-practices.git ~/.claude/skills/postgresql-best-practices
```

### Manual Installation

1. Download or clone this repository
2. Copy the entire directory to one of:
   - `.claude/skills/postgresql-best-practices/` (project-level)
   - `~/.claude/skills/postgresql-best-practices/` (personal)

## How It Works

Once installed, Claude Code automatically loads this skill when you:

- Create PostgreSQL schemas, tables, functions, procedures, or triggers
- Ask about PostgreSQL data types (uuid, text, timestamptz, jsonb, numeric)
- Write PL/pgSQL code needing naming conventions
- Implement Table API patterns
- Set up database migrations
- Need index optimization or constraint design
- Work with PostgreSQL 18+ features (uuidv7, virtual columns)
- Build data warehouses with Medallion Architecture
- Review database code for best practices
- Migrate from Oracle PL/SQL

This skill is configured with `user-invocable: false`, meaning it won't appear in the `/` command menu but Claude will automatically reference it when relevant.

## Contents

```
postgresql-best-practices/
├── SKILL.md                 # Main skill file (auto-loaded by Claude)
├── references/              # Detailed reference documentation (34 files)
│   ├── quick-reference.md   # Single-page cheat sheet
│   ├── schema-architecture.md
│   ├── coding-standards-trivadis.md
│   ├── plpgsql-table-api.md
│   ├── data-types.md
│   ├── indexes-constraints.md
│   ├── migrations.md
│   ├── anti-patterns.md
│   ├── jsonb-patterns.md
│   ├── row-level-security.md
│   ├── audit-logging.md
│   ├── data-warehousing-medallion.md
│   ├── oracle-migration-guide.md
│   ├── performance-tuning.md
│   ├── partitioning.md
│   ├── replication-ha.md
│   ├── vector-search.md
│   ├── full-text-search.md
│   ├── postgis-patterns.md
│   ├── time-series.md
│   ├── window-functions.md
│   ├── queue-patterns.md
│   ├── event-sourcing.md
│   ├── bulk-operations.md
│   ├── transaction-patterns.md
│   ├── testing-patterns.md
│   ├── cicd-integration.md
│   ├── monitoring-observability.md
│   ├── backup-recovery.md
│   ├── encryption.md
│   ├── session-management.md
│   ├── analytical-queries.md
│   ├── schema-naming.md
│   └── checklists-troubleshooting.md
├── scripts/                 # Executable SQL scripts
│   ├── 001_install_migration_system.sql
│   ├── 002_migration_runner_helpers.sql
│   ├── 003_example_migrations.sql
│   └── 999_uninstall_migration_system.sql
└── tests/                   # Comprehensive test suite
    ├── framework/           # Test runner and assertions
    ├── modules/             # Unit tests by topic (11 modules)
    ├── integration/         # End-to-end workflow tests
    └── scripts/             # CI runner and test execution scripts
```

## Core Patterns

### Schema Separation

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

### Naming Conventions

| Prefix | Type |
|--------|------|
| `l_` | Local variable |
| `in_` | IN parameter |
| `io_` | INOUT parameter |
| `co_` | Constant |

### API Function Pattern

```sql
CREATE FUNCTION api.get_customer(in_id uuid)
RETURNS TABLE (id uuid, email text, name text)
LANGUAGE sql STABLE
SECURITY DEFINER
SET search_path = data, private, pg_temp
AS $$
    SELECT id, email, name FROM data.customers WHERE id = in_id;
$$;
```

## Running Tests

The test suite validates all documented patterns against a real PostgreSQL database.

```bash
# Run all tests
./tests/scripts/run_all_tests.sh

# Run a specific module
./tests/scripts/run_module.sh 01_migration_system

# Run in CI mode (exits with error code on failure)
./tests/scripts/ci_runner.sh
```

**Prerequisites**: PostgreSQL 16+ with superuser access. Configure connection in `tests/config/test_config.env`.

## Updating

To update the skill:

```bash
cd .claude/skills/postgresql-best-practices  # or ~/.claude/skills/...
git pull
```

## License

[Add your license here]
