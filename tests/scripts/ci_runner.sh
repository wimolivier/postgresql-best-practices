#!/bin/bash
# ============================================================================
# CI/CD TEST RUNNER
# ============================================================================
# Optimized test runner for CI/CD pipelines.
# Returns proper exit codes and minimal output.
#
# Exit codes:
#   0 - All tests passed
#   1 - One or more tests failed
#   2 - Setup/connection error
#
# Usage: ./ci_runner.sh [OPTIONS]
#
# Environment variables:
#   PGHOST, PGPORT, PGUSER, PGDATABASE, PGPASSWORD
# ============================================================================

set -e

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$(dirname "$SCRIPT_DIR")"

# Connection parameters from environment
DB_NAME="${PGDATABASE:-postgres}"
DB_HOST="${PGHOST:-localhost}"
DB_PORT="${PGPORT:-5432}"
DB_USER="${PGUSER:-postgres}"

PSQL="psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -v ON_ERROR_STOP=1"

# Logging
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" >&2
}

# ============================================================================
# PRE-FLIGHT CHECKS
# ============================================================================

log "Starting CI test run..."
log "Database: $DB_NAME @ $DB_HOST:$DB_PORT (user: $DB_USER)"

# Test connection
if ! $PSQL -c "SELECT 1" &>/dev/null; then
    error "Cannot connect to database"
    exit 2
fi

# Check PostgreSQL version
PG_VERSION=$($PSQL -t -A -c "SHOW server_version_num")
log "PostgreSQL version: $PG_VERSION"

if [ "$PG_VERSION" -lt 140000 ]; then
    error "PostgreSQL 14+ required (found: $PG_VERSION)"
    exit 2
fi

# ============================================================================
# SETUP
# ============================================================================

log "Installing test framework..."

cd "$TESTS_DIR/setup"
$PSQL -f "01_install_test_framework.sql" -q 2>/dev/null

cd "$TESTS_DIR/../scripts"
$PSQL -f "001_install_migration_system.sql" -q 2>/dev/null
$PSQL -f "002_migration_runner_helpers.sql" -q 2>/dev/null

# Clear old test results
$PSQL -c "TRUNCATE test.results" -q 2>/dev/null || true
$PSQL -c "TRUNCATE test.runs CASCADE" -q 2>/dev/null || true

# ============================================================================
# RUN TESTS
# ============================================================================

log "Running test modules..."

run_tests() {
    local dir=$1
    local name=$2

    if [ -d "$dir" ]; then
        log "  Module: $name"
        for f in "$dir"/*.sql; do
            [ -f "$f" ] && $PSQL -f "$f" -q 2>&1 | grep -E "^(not ok)" || true
        done
    fi
}

# Run all modules
run_tests "$TESTS_DIR/modules/01_migration_system" "migration_system"
run_tests "$TESTS_DIR/modules/02_schema_architecture" "schema_architecture"
run_tests "$TESTS_DIR/modules/03_plpgsql_patterns" "plpgsql_patterns"
run_tests "$TESTS_DIR/modules/04_data_types" "data_types"
run_tests "$TESTS_DIR/modules/05_anti_patterns" "anti_patterns"
run_tests "$TESTS_DIR/integration" "integration"

# ============================================================================
# RESULTS
# ============================================================================

log "Collecting results..."

# Get results
RESULTS=$($PSQL -t -A -c "
    SELECT
        count(*) FILTER (WHERE passed),
        count(*) FILTER (WHERE NOT passed),
        count(*)
    FROM test.results
")

PASSED=$(echo "$RESULTS" | cut -d'|' -f1)
FAILED=$(echo "$RESULTS" | cut -d'|' -f2)
TOTAL=$(echo "$RESULTS" | cut -d'|' -f3)

log "Results: $PASSED passed, $FAILED failed ($TOTAL total)"

# Output failed tests for CI logs
if [ "$FAILED" -gt 0 ]; then
    echo ""
    echo "FAILED TESTS:"
    echo "============="
    $PSQL -t -A -c "
        SELECT test_name || ': ' || description || ' (got: ' || COALESCE(got, 'NULL') || ', expected: ' || COALESCE(expected, 'NULL') || ')'
        FROM test.results
        WHERE NOT passed
        ORDER BY executed_at
        LIMIT 50
    "
fi

# ============================================================================
# CLEANUP
# ============================================================================

log "Cleaning up..."
cd "$TESTS_DIR/teardown"
$PSQL -f "01_cleanup.sql" -q 2>/dev/null || true

# ============================================================================
# EXIT
# ============================================================================

if [ "$FAILED" -gt 0 ]; then
    log "TEST RUN FAILED"
    exit 1
else
    log "TEST RUN PASSED"
    exit 0
fi
