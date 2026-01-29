# PostgreSQL Best Practices Skill

A Claude Code skill providing comprehensive PostgreSQL 18+ best practices for enterprise database development.

## What This Skill Provides

- **Schema Architecture**: Three-schema separation pattern (data/private/api)
- **Table API Design**: SECURITY DEFINER functions with proper search_path
- **PL/pgSQL Coding Standards**: Trivadis-style naming conventions (l_, in_, io_, co_)
- **Native Migration System**: Pure PL/pgSQL alternative to Flyway/Liquibase
- **Data Warehousing**: Medallion Architecture (Bronze/Silver/Gold)
- **And more**: Indexes, constraints, JSONB patterns, RLS, audit logging, Oracle migration

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
├── references/              # Detailed reference documentation
│   ├── quick-reference.md   # Single-page cheat sheet
│   ├── schema-architecture.md
│   ├── coding-standards-trivadis.md
│   ├── plpgsql-table-api.md
│   ├── data-types.md
│   ├── indexes-constraints.md
│   ├── migrations.md
│   ├── anti-patterns.md
│   └── ... (13 more reference files)
└── scripts/                 # Executable SQL scripts
    ├── 001_install_migration_system.sql
    ├── 002_migration_runner_helpers.sql
    └── 003_example_migrations.sql
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

## Updating

To update the skill:

```bash
cd .claude/skills/postgresql-best-practices  # or ~/.claude/skills/...
git pull
```

## License

[Add your license here]
