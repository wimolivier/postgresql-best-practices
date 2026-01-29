# PostgreSQL Best Practices - Test Suite

Comprehensive test suite for validating the PostgreSQL Best Practices Claude Skill.

## Prerequisites

- **PostgreSQL 18+** (recommended) or PostgreSQL 14+ (minimum)
- `psql` command-line client
- Database with admin/superuser privileges
- Bash shell (for running scripts)

## Quick Start

```bash
# 1. Navigate to tests directory
cd tests

# 2. Set connection (optional - uses defaults if not set)
export PGHOST=localhost
export PGPORT=5432
export PGUSER=postgres
export PGDATABASE=testdb

# 3. Run all tests
./scripts/run_all_tests.sh
```

## Directory Structure

```
tests/
├── README.md                           # This file
├── setup/
│   ├── 00_check_prerequisites.sql      # Verify PG version and extensions
│   └── 01_install_test_framework.sql   # Install test schema and functions
├── teardown/
│   └── 01_cleanup.sql                  # Clean up test data
├── framework/
│   ├── assertions.sql                  # Core assertion functions
│   ├── test_runner.sql                 # Test discovery and execution
│   └── test_helpers.sql                # Utilities and data factories
├── modules/
│   ├── 01_migration_system/            # Migration system tests (~40 tests)
│   ├── 02_schema_architecture/         # Schema pattern tests (~10 tests)
│   ├── 03_plpgsql_patterns/            # PL/pgSQL convention tests (~15 tests)
│   ├── 04_data_types/                  # Data type tests (~12 tests)
│   └── 05_anti_patterns/               # Anti-pattern detection (~8 tests)
├── integration/
│   ├── 010_full_workflow_test.sql      # End-to-end workflow
│   └── 020_concurrent_access_test.sql  # Locking behavior
├── scripts/
│   ├── run_all_tests.sh                # Run complete suite
│   ├── run_module.sh                   # Run specific module
│   └── ci_runner.sh                    # CI/CD optimized runner
└── config/
    └── test_config.env                 # Environment configuration
```

## Running Tests

### Run All Tests

```bash
./scripts/run_all_tests.sh
```

Options:
- `-d, --database <name>`: Database name
- `-h, --host <host>`: Database host
- `-p, --port <port>`: Database port
- `-U, --user <user>`: Database user
- `-v, --verbose`: Show detailed output
- `--skip-setup`: Skip framework installation
- `--skip-cleanup`: Keep test data after run

### Run Specific Module

```bash
./scripts/run_module.sh 01_migration_system
./scripts/run_module.sh 02_schema_architecture
./scripts/run_module.sh integration
```

### Run in CI/CD

```bash
./scripts/ci_runner.sh
```

Exit codes:
- `0`: All tests passed
- `1`: One or more tests failed
- `2`: Setup/connection error

### Run Individual Test File

```bash
psql -d testdb -f modules/01_migration_system/020_locking_test.sql
```

## Test Framework API

### Assertions

| Function | Description |
|----------|-------------|
| `test.ok(condition, description)` | Pass if condition is true |
| `test.is(got, expected, description)` | Pass if values match |
| `test.isnt(got, unexpected, description)` | Pass if values differ |
| `test.is_null(value, description)` | Pass if value is NULL |
| `test.is_not_null(value, description)` | Pass if value is not NULL |
| `test.throws_ok(sql, errcode, description)` | Pass if SQL throws expected error |
| `test.throws_like(sql, pattern, description)` | Pass if error matches pattern |
| `test.lives_ok(sql, description)` | Pass if SQL executes without error |
| `test.has_schema(name, description)` | Pass if schema exists |
| `test.has_table(schema, table, description)` | Pass if table exists |
| `test.has_function(schema, func, description)` | Pass if function exists |
| `test.has_procedure(schema, proc, description)` | Pass if procedure exists |
| `test.has_column(schema, table, col, description)` | Pass if column exists |
| `test.has_index(schema, table, idx, description)` | Pass if index exists |
| `test.row_count_is(query, count, description)` | Pass if query returns expected count |
| `test.is_empty(query, description)` | Pass if query returns no rows |
| `test.matches(value, pattern, description)` | Pass if value matches regex |

### Test Execution

| Function | Description |
|----------|-------------|
| `test.set_context(name)` | Set current test name |
| `test.run_test(func_name)` | Run a single test function |
| `test.run_all(schema, pattern)` | Run all tests matching pattern |
| `test.run_module(module_name)` | Run tests for a module |
| `test.print_summary()` | Print formatted results |

### Helpers

| Function | Description |
|----------|-------------|
| `test.unique_id()` | Generate unique test identifier |
| `test.test_email(suffix)` | Generate test email address |
| `test.begin_test(name)` | Create savepoint for isolation |
| `test.rollback_test(name)` | Rollback to savepoint |
| `test.exec_count(sql)` | Execute and return row count |
| `test.measure_time(sql)` | Measure execution time (ms) |
| `test.is_secure_function(schema, func)` | Check SECURITY DEFINER + search_path |

## Writing New Tests

### Test Function Convention

```sql
CREATE OR REPLACE FUNCTION test.test_<module>_<number>_<description>()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM test.set_context('test_<module>_<number>_<description>');

    -- Your assertions here
    PERFORM test.ok(true, 'description');
END;
$$;
```

### Example Test

```sql
CREATE OR REPLACE FUNCTION test.test_example_010_basic()
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    l_result integer;
BEGIN
    PERFORM test.set_context('test_example_010_basic');

    -- Test basic assertion
    l_result := 1 + 1;
    PERFORM test.is(l_result, 2, '1 + 1 should equal 2');

    -- Test SQL execution
    PERFORM test.lives_ok('SELECT 1', 'SELECT should succeed');

    -- Test error handling
    PERFORM test.throws_ok(
        'SELECT 1/0',
        '22012',  -- division_by_zero
        'Division by zero should throw'
    );
END;
$$;
```

### Test Naming Convention

- `test_<module>_<NNN>_<description>`
- Module prefixes match directory numbers (e.g., `migration_01`, `schema_02`)
- Numbers should be sequential within each test file (010, 011, 020, etc.)

## Test Modules

### 01_migration_system (~40 tests)

Tests for the native PL/pgSQL migration system:
- Installation and schema structure
- Lock acquire/release/timeout
- Versioned migration execution
- Repeatable migration change detection
- Checksum calculation and validation
- Rollback functionality
- Batch execution
- Status and info queries

### 02_schema_architecture (~10 tests)

Tests for three-schema separation pattern:
- data/private/api schema existence
- SECURITY DEFINER with SET search_path
- Role-based access control

### 03_plpgsql_patterns (~15 tests)

Tests for PL/pgSQL conventions:
- Trivadis naming conventions (l_, in_, io_, co_, r_, c_, t_)
- Table API pattern (functions for reads, procedures for writes)
- Trigger patterns (updated_at, audit logging)
- Error handling with SQLSTATE codes

### 04_data_types (~12 tests)

Tests for data type recommendations:
- UUIDv7 generation and properties
- timestamptz vs timestamp handling
- numeric precision for financial data
- JSONB storage, querying, and indexing

### 05_anti_patterns (~8 tests)

Tests demonstrating correct patterns vs anti-patterns:
- NOT EXISTS vs NOT IN with NULLs
- >= AND < vs BETWEEN for date ranges
- Missing FK index detection
- SECURITY DEFINER without search_path

## Troubleshooting

### Connection Issues

```bash
# Test connection
psql -h localhost -p 5432 -U postgres -d testdb -c "SELECT 1"

# Check PostgreSQL version
psql -c "SELECT version()"
```

### Permission Issues

The test framework requires privileges to:
- Create schemas (test, data, private, api)
- Create functions and procedures
- Create and drop tables
- Execute advisory locks

### Cleanup Stuck Locks

```sql
-- Release any held migration locks
SELECT app_migration.release_lock();

-- Check lock status
SELECT * FROM app_migration.get_lock_holder();
```

### Reset Test Framework

```sql
-- Clear all test results
CALL test.clear_results();

-- Reinstall framework
\i setup/01_install_test_framework.sql
```

## Output Format

Tests output TAP (Test Anything Protocol) format:

```
ok 1 - schema exists
ok 2 - table created
not ok 3 - expected 5 rows, got 3
#   got: 3
#   expected: 5
```

## License

Part of the PostgreSQL Best Practices Claude Skill repository.
