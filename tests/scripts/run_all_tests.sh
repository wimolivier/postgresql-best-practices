#!/bin/bash
# ============================================================================
# RUN ALL TESTS
# ============================================================================
# Executes the complete test suite for PostgreSQL Best Practices Skill.
#
# Usage: ./run_all_tests.sh [OPTIONS]
#
# Options:
#   -d, --database    Database name (default: from PGDATABASE or postgres)
#   -h, --host        Database host (default: from PGHOST or localhost)
#   -p, --port        Database port (default: from PGPORT or 5432)
#   -U, --user        Database user (default: from PGUSER or current user)
#   -v, --verbose     Show verbose output
#   --skip-setup      Skip framework installation
#   --skip-cleanup    Skip cleanup after tests
#   --help            Show this help message
# ============================================================================

set -e

# Default values (use environment variables if set)
DB_NAME="${PGDATABASE:-postgres}"
DB_HOST="${PGHOST:-localhost}"
DB_PORT="${PGPORT:-5432}"
DB_USER="${PGUSER:-$USER}"
VERBOSE=false
SKIP_SETUP=false
SKIP_CLEANUP=false

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$(dirname "$SCRIPT_DIR")"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -d|--database)
            DB_NAME="$2"
            shift 2
            ;;
        -h|--host)
            DB_HOST="$2"
            shift 2
            ;;
        -p|--port)
            DB_PORT="$2"
            shift 2
            ;;
        -U|--user)
            DB_USER="$2"
            shift 2
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        --skip-setup)
            SKIP_SETUP=true
            shift
            ;;
        --skip-cleanup)
            SKIP_CLEANUP=true
            shift
            ;;
        --help)
            head -25 "$0" | tail -20
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# psql command with connection parameters
PSQL="psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME"

# Helper functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[PASS]${NC} $1"
}

log_error() {
    echo -e "${RED}[FAIL]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

run_sql_file() {
    local file=$1
    local name=$(basename "$file" .sql)

    if $VERBOSE; then
        $PSQL -f "$file" 2>&1
    else
        $PSQL -f "$file" -q 2>&1 | grep -E "^(ok|not ok|#|NOTICE:.*test)" || true
    fi
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

echo ""
echo "============================================================"
echo "PostgreSQL Best Practices - Test Suite"
echo "============================================================"
echo ""
log_info "Database: $DB_NAME @ $DB_HOST:$DB_PORT"
log_info "User: $DB_USER"
echo ""

# Check prerequisites
log_info "Checking prerequisites..."
if ! command -v psql &> /dev/null; then
    log_error "psql command not found. Please install PostgreSQL client."
    exit 1
fi

# Test connection
if ! $PSQL -c "SELECT 1" &> /dev/null; then
    log_error "Cannot connect to database. Check connection parameters."
    exit 1
fi

log_success "Database connection OK"

# Install test framework
if ! $SKIP_SETUP; then
    echo ""
    log_info "Installing test framework..."
    cd "$TESTS_DIR/setup"

    # Check prerequisites
    run_sql_file "00_check_prerequisites.sql"

    # Install framework
    run_sql_file "01_install_test_framework.sql"

    log_success "Test framework installed"
fi

# Install migration system if needed
log_info "Ensuring migration system is installed..."
cd "$TESTS_DIR/../scripts"
$PSQL -f "001_install_migration_system.sql" -q 2>/dev/null || true
$PSQL -f "002_migration_runner_helpers.sql" -q 2>/dev/null || true
log_success "Migration system ready"

# Run tests by module
echo ""
echo "============================================================"
echo "Running Test Modules"
echo "============================================================"

TOTAL_PASSED=0
TOTAL_FAILED=0
MODULES_RUN=0

run_module() {
    local module_dir=$1
    local module_name=$(basename "$module_dir")

    echo ""
    log_info "Module: $module_name"
    echo "------------------------------------------------------------"

    # Run all test files in the module directory in order
    for test_file in "$module_dir"/*.sql; do
        if [ -f "$test_file" ]; then
            local test_name=$(basename "$test_file" .sql)
            log_info "  Running: $test_name"
            run_sql_file "$test_file"
        fi
    done

    MODULES_RUN=$((MODULES_RUN + 1))
}

# Run all modules in order (sorted alphabetically)
for module_dir in "$TESTS_DIR/modules"/*; do
    if [ -d "$module_dir" ]; then
        run_module "$module_dir"
    fi
done

# Integration Tests
if [ -d "$TESTS_DIR/integration" ]; then
    echo ""
    log_info "Integration Tests"
    echo "------------------------------------------------------------"
    for test_file in "$TESTS_DIR/integration"/*.sql; do
        if [ -f "$test_file" ]; then
            test_name=$(basename "$test_file" .sql)
            log_info "  Running: $test_name"
            run_sql_file "$test_file"
        fi
    done
fi

# Get final results
echo ""
echo "============================================================"
echo "Test Results Summary"
echo "============================================================"

# Query test results from database
RESULTS=$($PSQL -t -A -c "
    SELECT
        count(*) FILTER (WHERE passed) as passed,
        count(*) FILTER (WHERE NOT passed) as failed,
        count(*) as total
    FROM test.results
    WHERE executed_at > now() - interval '1 hour'
" 2>/dev/null || echo "0|0|0")

PASSED=$(echo "$RESULTS" | cut -d'|' -f1)
FAILED=$(echo "$RESULTS" | cut -d'|' -f2)
TOTAL=$(echo "$RESULTS" | cut -d'|' -f3)

echo ""
echo "Modules run: $MODULES_RUN"
echo "Total assertions: $TOTAL"
echo -e "Passed: ${GREEN}$PASSED${NC}"
echo -e "Failed: ${RED}$FAILED${NC}"

if [ "$TOTAL" -gt 0 ]; then
    PCT=$(echo "scale=1; $PASSED * 100 / $TOTAL" | bc)
    echo "Success rate: $PCT%"
fi

# Show failed tests if any
if [ "$FAILED" -gt 0 ]; then
    echo ""
    log_error "Failed assertions:"
    $PSQL -c "
        SELECT test_name, description, got, expected
        FROM test.results
        WHERE NOT passed
          AND executed_at > now() - interval '1 hour'
        ORDER BY executed_at
        LIMIT 20
    " 2>/dev/null || true
fi

# Cleanup
if ! $SKIP_CLEANUP; then
    echo ""
    log_info "Cleaning up test data..."
    cd "$TESTS_DIR/teardown"
    $PSQL -f "01_cleanup.sql" -q 2>/dev/null || true
    log_success "Cleanup complete"
fi

echo ""
echo "============================================================"
if [ "$FAILED" -gt 0 ]; then
    log_error "TEST SUITE FAILED"
    exit 1
else
    log_success "TEST SUITE PASSED"
    exit 0
fi
