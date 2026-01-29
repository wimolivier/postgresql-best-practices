#!/bin/bash
# ============================================================================
# RUN SPECIFIC MODULE
# ============================================================================
# Runs tests for a specific module only.
#
# Usage: ./run_module.sh <module_name> [OPTIONS]
#
# Modules:
#   01_migration_system
#   02_schema_architecture
#   03_plpgsql_patterns
#   04_data_types
#   05_anti_patterns
#   integration
#
# Options:
#   -d, --database    Database name
#   -v, --verbose     Show verbose output
#   --help            Show this help message
# ============================================================================

set -e

# Check for module argument
if [ -z "$1" ] || [ "$1" = "--help" ]; then
    head -20 "$0" | tail -18
    exit 0
fi

MODULE_NAME=$1
shift

# Default values
DB_NAME="${PGDATABASE:-postgres}"
DB_HOST="${PGHOST:-localhost}"
DB_PORT="${PGPORT:-5432}"
DB_USER="${PGUSER:-$USER}"
VERBOSE=false

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$(dirname "$SCRIPT_DIR")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -d|--database)
            DB_NAME="$2"
            shift 2
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        *)
            shift
            ;;
    esac
done

# psql command
PSQL="psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME"

# Determine module directory
if [ "$MODULE_NAME" = "integration" ]; then
    MODULE_DIR="$TESTS_DIR/integration"
else
    MODULE_DIR="$TESTS_DIR/modules/$MODULE_NAME"
fi

if [ ! -d "$MODULE_DIR" ]; then
    echo -e "${RED}[ERROR]${NC} Module not found: $MODULE_NAME"
    echo ""
    echo "Available modules:"
    ls -1 "$TESTS_DIR/modules" 2>/dev/null || true
    echo "integration"
    exit 1
fi

echo ""
echo "============================================================"
echo "Running Module: $MODULE_NAME"
echo "============================================================"
echo ""

# Ensure test framework is installed
$PSQL -c "SELECT 1 FROM test.results LIMIT 0" &>/dev/null || {
    echo -e "${BLUE}[INFO]${NC} Installing test framework..."
    cd "$TESTS_DIR/setup"
    $PSQL -f "01_install_test_framework.sql" -q
}

# Ensure migration system is installed
$PSQL -c "SELECT 1 FROM app_migration.changelog LIMIT 0" &>/dev/null || {
    echo -e "${BLUE}[INFO]${NC} Installing migration system..."
    cd "$TESTS_DIR/../scripts"
    $PSQL -f "001_install_migration_system.sql" -q
    $PSQL -f "002_migration_runner_helpers.sql" -q
}

# Clear previous results for this run
$PSQL -c "DELETE FROM test.results WHERE executed_at < now() - interval '1 minute'" -q 2>/dev/null || true

# Run test files
for test_file in "$MODULE_DIR"/*.sql; do
    if [ -f "$test_file" ]; then
        test_name=$(basename "$test_file" .sql)
        echo -e "${BLUE}[INFO]${NC} Running: $test_name"

        if $VERBOSE; then
            $PSQL -f "$test_file" 2>&1
        else
            $PSQL -f "$test_file" -q 2>&1 | grep -E "^(ok|not ok|#)" || true
        fi

        echo ""
    fi
done

# Show results
echo "============================================================"
echo "Results"
echo "============================================================"

RESULTS=$($PSQL -t -A -c "
    SELECT
        count(*) FILTER (WHERE passed) as passed,
        count(*) FILTER (WHERE NOT passed) as failed,
        count(*) as total
    FROM test.results
    WHERE executed_at > now() - interval '5 minutes'
" 2>/dev/null || echo "0|0|0")

PASSED=$(echo "$RESULTS" | cut -d'|' -f1)
FAILED=$(echo "$RESULTS" | cut -d'|' -f2)
TOTAL=$(echo "$RESULTS" | cut -d'|' -f3)

echo ""
echo "Total: $TOTAL"
echo -e "Passed: ${GREEN}$PASSED${NC}"
echo -e "Failed: ${RED}$FAILED${NC}"

if [ "$FAILED" -gt 0 ]; then
    echo ""
    echo -e "${RED}Failed assertions:${NC}"
    $PSQL -c "
        SELECT test_name, description, got, expected
        FROM test.results
        WHERE NOT passed
          AND executed_at > now() - interval '5 minutes'
        ORDER BY executed_at
    " 2>/dev/null || true
    exit 1
fi

exit 0
