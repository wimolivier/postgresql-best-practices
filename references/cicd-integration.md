# CI/CD Integration for PostgreSQL

This document provides templates and patterns for integrating PostgreSQL database changes into CI/CD pipelines.

## Table of Contents

1. [GitHub Actions](#github-actions)
2. [GitLab CI](#gitlab-ci)
3. [Docker Setup](#docker-setup)
4. [Database Testing Pipeline](#database-testing-pipeline)
5. [Migration Validation](#migration-validation)
6. [Schema Comparison](#schema-comparison)
7. [Deployment Strategies](#deployment-strategies)

## GitHub Actions

### Basic Migration Workflow

```yaml
# .github/workflows/database.yml
name: Database CI

on:
  push:
    branches: [main, develop]
    paths:
      - 'db/**'
  pull_request:
    branches: [main]
    paths:
      - 'db/**'

env:
  POSTGRES_USER: test
  POSTGRES_PASSWORD: test
  POSTGRES_DB: test_db

jobs:
  test-migrations:
    runs-on: ubuntu-latest
    
    services:
      postgres:
        image: postgres:18
        env:
          POSTGRES_USER: ${{ env.POSTGRES_USER }}
          POSTGRES_PASSWORD: ${{ env.POSTGRES_PASSWORD }}
          POSTGRES_DB: ${{ env.POSTGRES_DB }}
        ports:
          - 5432:5432
        options: >-
          --health-cmd pg_isready
          --health-interval 10s
          --health-timeout 5s
          --health-retries 5

    steps:
      - uses: actions/checkout@v4
      
      - name: Install PostgreSQL client
        run: |
          sudo apt-get update
          sudo apt-get install -y postgresql-client
          
      - name: Wait for PostgreSQL
        run: |
          until pg_isready -h localhost -p 5432 -U $POSTGRES_USER; do
            echo "Waiting for postgres..."
            sleep 2
          done
          
      - name: Run migrations
        env:
          PGHOST: localhost
          PGUSER: ${{ env.POSTGRES_USER }}
          PGPASSWORD: ${{ env.POSTGRES_PASSWORD }}
          PGDATABASE: ${{ env.POSTGRES_DB }}
        run: |
          # Install migration system
          psql -f db/scripts/001_install_migration_system.sql
          psql -f db/scripts/002_migration_runner_helpers.sql
          
          # Run all migrations
          for f in db/migrations/V*.sql; do
            echo "Running: $f"
            psql -f "$f"
          done
          
          # Run repeatable migrations
          for f in db/migrations/R__*.sql; do
            echo "Running: $f"
            psql -f "$f"
          done
          
      - name: Run tests
        env:
          PGHOST: localhost
          PGUSER: ${{ env.POSTGRES_USER }}
          PGPASSWORD: ${{ env.POSTGRES_PASSWORD }}
          PGDATABASE: ${{ env.POSTGRES_DB }}
        run: |
          psql -f db/tests/install_tests.sql
          psql -c "SELECT * FROM test.run_all_tests();" | tee test_results.txt
          
      - name: Check test results
        run: |
          if grep -q "FAIL\|ERROR" test_results.txt; then
            echo "::error::Database tests failed"
            exit 1
          fi
          echo "All tests passed!"
          
      - name: Upload test results
        uses: actions/upload-artifact@v3
        if: always()
        with:
          name: test-results
          path: test_results.txt
```

### Migration Validation Workflow

```yaml
# .github/workflows/validate-migrations.yml
name: Validate Migrations

on:
  pull_request:
    paths:
      - 'db/migrations/**'

jobs:
  validate:
    runs-on: ubuntu-latest
    
    services:
      postgres:
        image: postgres:18
        env:
          POSTGRES_USER: test
          POSTGRES_PASSWORD: test
          POSTGRES_DB: test_db
        ports:
          - 5432:5432
        options: --health-cmd pg_isready --health-interval 10s --health-timeout 5s --health-retries 5

    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0  # Need full history for diff
          
      - name: Get changed migrations
        id: changed
        run: |
          CHANGED=$(git diff --name-only origin/${{ github.base_ref }}...HEAD -- 'db/migrations/*.sql')
          echo "files=$CHANGED" >> $GITHUB_OUTPUT
          echo "Changed files: $CHANGED"
          
      - name: Validate migration naming
        run: |
          for f in ${{ steps.changed.outputs.files }}; do
            filename=$(basename "$f")
            # Check versioned migrations
            if [[ $filename == V* ]]; then
              if ! [[ $filename =~ ^V[0-9]{3}__[a-z_]+\.sql$ ]]; then
                echo "::error::Invalid migration name: $filename"
                echo "Expected format: V001__description_here.sql"
                exit 1
              fi
            fi
            # Check repeatable migrations  
            if [[ $filename == R__* ]]; then
              if ! [[ $filename =~ ^R__[a-z_]+\.sql$ ]]; then
                echo "::error::Invalid repeatable migration name: $filename"
                echo "Expected format: R__description.sql"
                exit 1
              fi
            fi
          done
          echo "Migration naming validation passed"
          
      - name: Check for destructive operations
        run: |
          WARNINGS=""
          for f in ${{ steps.changed.outputs.files }}; do
            if grep -qiE "DROP\s+TABLE|TRUNCATE|DELETE\s+FROM.*WHERE\s+1\s*=\s*1" "$f"; then
              WARNINGS="$WARNINGS\n⚠️ $f contains potentially destructive operations"
            fi
          done
          if [ -n "$WARNINGS" ]; then
            echo -e "::warning::$WARNINGS"
          fi
          
      - name: Syntax check
        env:
          PGHOST: localhost
          PGUSER: test
          PGPASSWORD: test
          PGDATABASE: test_db
        run: |
          for f in ${{ steps.changed.outputs.files }}; do
            echo "Checking syntax: $f"
            # Use EXPLAIN to check syntax without executing
            psql -c "BEGIN; \i $f ROLLBACK;" 2>&1 || {
              echo "::error::Syntax error in $f"
              exit 1
            }
          done
```

### Deployment Workflow

```yaml
# .github/workflows/deploy.yml
name: Deploy Database

on:
  push:
    branches: [main]
    paths:
      - 'db/**'

jobs:
  deploy-staging:
    runs-on: ubuntu-latest
    environment: staging
    
    steps:
      - uses: actions/checkout@v4
      
      - name: Deploy to staging
        env:
          PGHOST: ${{ secrets.STAGING_DB_HOST }}
          PGUSER: ${{ secrets.STAGING_DB_USER }}
          PGPASSWORD: ${{ secrets.STAGING_DB_PASSWORD }}
          PGDATABASE: ${{ secrets.STAGING_DB_NAME }}
        run: |
          ./scripts/deploy-migrations.sh
          
      - name: Run smoke tests
        env:
          PGHOST: ${{ secrets.STAGING_DB_HOST }}
          PGUSER: ${{ secrets.STAGING_DB_USER }}
          PGPASSWORD: ${{ secrets.STAGING_DB_PASSWORD }}
          PGDATABASE: ${{ secrets.STAGING_DB_NAME }}
        run: |
          psql -c "SELECT api.healthcheck();"

  deploy-production:
    needs: deploy-staging
    runs-on: ubuntu-latest
    environment: production
    
    steps:
      - uses: actions/checkout@v4
      
      - name: Create backup
        env:
          PGHOST: ${{ secrets.PROD_DB_HOST }}
          PGUSER: ${{ secrets.PROD_DB_USER }}
          PGPASSWORD: ${{ secrets.PROD_DB_PASSWORD }}
          PGDATABASE: ${{ secrets.PROD_DB_NAME }}
        run: |
          pg_dump -Fc > backup_$(date +%Y%m%d_%H%M%S).dump
          # Upload to S3 or other backup storage
          
      - name: Deploy to production
        env:
          PGHOST: ${{ secrets.PROD_DB_HOST }}
          PGUSER: ${{ secrets.PROD_DB_USER }}
          PGPASSWORD: ${{ secrets.PROD_DB_PASSWORD }}
          PGDATABASE: ${{ secrets.PROD_DB_NAME }}
        run: |
          ./scripts/deploy-migrations.sh
```

## GitLab CI

```yaml
# .gitlab-ci.yml
stages:
  - test
  - validate
  - deploy

variables:
  POSTGRES_USER: test
  POSTGRES_PASSWORD: test
  POSTGRES_DB: test_db

.db-test-template:
  image: postgres:18
  services:
    - postgres:18
  variables:
    PGHOST: postgres
    PGUSER: $POSTGRES_USER
    PGPASSWORD: $POSTGRES_PASSWORD
    PGDATABASE: $POSTGRES_DB
  before_script:
    - apt-get update && apt-get install -y postgresql-client
    - until pg_isready -h $PGHOST; do sleep 1; done

test-migrations:
  extends: .db-test-template
  stage: test
  script:
    - psql -f db/scripts/001_install_migration_system.sql
    - psql -f db/scripts/002_migration_runner_helpers.sql
    - for f in db/migrations/V*.sql; do psql -f "$f"; done
    - psql -f db/tests/install_tests.sql
    - psql -c "SELECT * FROM test.run_all_tests();" | tee test_results.txt
    - "! grep -q 'FAIL\\|ERROR' test_results.txt"
  artifacts:
    paths:
      - test_results.txt
    when: always
  only:
    changes:
      - db/**/*

validate-schema:
  extends: .db-test-template
  stage: validate
  script:
    - ./scripts/validate-schema.sh
  only:
    refs:
      - merge_requests
    changes:
      - db/**/*

deploy-staging:
  stage: deploy
  environment:
    name: staging
  script:
    - ./scripts/deploy-migrations.sh
  only:
    - main
  when: manual

deploy-production:
  stage: deploy
  environment:
    name: production
  script:
    - ./scripts/deploy-migrations.sh
  only:
    - main
  when: manual
  needs:
    - deploy-staging
```

## Docker Setup

### Dockerfile for Testing

```dockerfile
# Dockerfile.db-test
FROM postgres:18

# Install pgTAP for testing
RUN apt-get update && apt-get install -y \
    postgresql-18-pgtap \
    make \
    && rm -rf /var/lib/apt/lists/*

# Copy initialization scripts
COPY db/scripts/*.sql /docker-entrypoint-initdb.d/00-scripts/
COPY db/migrations/V*.sql /docker-entrypoint-initdb.d/01-versioned/
COPY db/migrations/R__*.sql /docker-entrypoint-initdb.d/02-repeatable/
COPY db/tests/*.sql /docker-entrypoint-initdb.d/03-tests/

# Copy test runner
COPY scripts/run-db-tests.sh /docker-entrypoint-initdb.d/99-run-tests.sh
RUN chmod +x /docker-entrypoint-initdb.d/99-run-tests.sh
```

### Docker Compose for Development

```yaml
# docker-compose.yml
version: '3.8'

services:
  db:
    image: postgres:18
    environment:
      POSTGRES_USER: dev
      POSTGRES_PASSWORD: dev
      POSTGRES_DB: myapp_dev
    ports:
      - "5432:5432"
    volumes:
      - postgres_data:/var/lib/postgresql/data
      - ./db/scripts:/docker-entrypoint-initdb.d/scripts:ro
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U dev -d myapp_dev"]
      interval: 5s
      timeout: 5s
      retries: 5

  db-test:
    build:
      context: .
      dockerfile: Dockerfile.db-test
    environment:
      POSTGRES_USER: test
      POSTGRES_PASSWORD: test
      POSTGRES_DB: myapp_test
    ports:
      - "5433:5432"

  migrate:
    image: postgres:18
    depends_on:
      db:
        condition: service_healthy
    environment:
      PGHOST: db
      PGUSER: dev
      PGPASSWORD: dev
      PGDATABASE: myapp_dev
    volumes:
      - ./db:/db:ro
      - ./scripts:/scripts:ro
    command: ["/scripts/run-migrations.sh"]

volumes:
  postgres_data:
```

### Test Docker Compose

```yaml
# docker-compose.test.yml
version: '3.8'

services:
  db:
    image: postgres:18
    environment:
      POSTGRES_USER: test
      POSTGRES_PASSWORD: test
      POSTGRES_DB: test_db
    tmpfs:
      - /var/lib/postgresql/data  # Use tmpfs for speed
    healthcheck:
      test: ["CMD-SHELL", "pg_isready"]
      interval: 2s
      timeout: 2s
      retries: 10

  test-runner:
    image: postgres:18
    depends_on:
      db:
        condition: service_healthy
    environment:
      PGHOST: db
      PGUSER: test
      PGPASSWORD: test
      PGDATABASE: test_db
    volumes:
      - ./db:/db:ro
      - ./scripts:/scripts:ro
    command: ["/scripts/run-all-tests.sh"]
```

## Database Testing Pipeline

### Test Runner Script

```bash
#!/bin/bash
# scripts/run-all-tests.sh

set -e

echo "=== Installing migration system ==="
psql -f /db/scripts/001_install_migration_system.sql
psql -f /db/scripts/002_migration_runner_helpers.sql

echo "=== Running versioned migrations ==="
for f in /db/migrations/V*.sql; do
    if [ -f "$f" ]; then
        echo "Running: $f"
        psql -f "$f"
    fi
done

echo "=== Running repeatable migrations ==="
for f in /db/migrations/R__*.sql; do
    if [ -f "$f" ]; then
        echo "Running: $f"
        psql -f "$f"
    fi
done

echo "=== Installing tests ==="
psql -f /db/tests/install_tests.sql

echo "=== Running tests ==="
RESULTS=$(psql -t -c "SELECT * FROM test.run_all_tests();")
echo "$RESULTS"

# Check for failures
if echo "$RESULTS" | grep -qE "FAIL|ERROR"; then
    echo "=== TESTS FAILED ==="
    exit 1
fi

echo "=== ALL TESTS PASSED ==="
exit 0
```

### Migration Deployment Script

```bash
#!/bin/bash
# scripts/deploy-migrations.sh

set -e

# Configuration
LOCK_TIMEOUT=${LOCK_TIMEOUT:-30}
STATEMENT_TIMEOUT=${STATEMENT_TIMEOUT:-300}

echo "=== Starting migration deployment ==="
echo "Database: $PGDATABASE @ $PGHOST"

# Set timeouts
export PGOPTIONS="-c lock_timeout=${LOCK_TIMEOUT}s -c statement_timeout=${STATEMENT_TIMEOUT}s"

# Check migration system exists
if ! psql -c "SELECT 1 FROM app_migration.changelog LIMIT 1" 2>/dev/null; then
    echo "Installing migration system..."
    psql -f db/scripts/001_install_migration_system.sql
    psql -f db/scripts/002_migration_runner_helpers.sql
fi

# Acquire migration lock
echo "Acquiring migration lock..."
psql -c "SELECT app_migration.acquire_lock();"

# Track if we need to release lock
LOCK_ACQUIRED=true
cleanup() {
    if [ "$LOCK_ACQUIRED" = true ]; then
        echo "Releasing migration lock..."
        psql -c "SELECT app_migration.release_lock();" || true
    fi
}
trap cleanup EXIT

# Get last applied version
LAST_VERSION=$(psql -t -c "
    SELECT COALESCE(MAX(version), '000') 
    FROM app_migration.changelog 
    WHERE type = 'versioned' AND success = true;
" | tr -d ' ')

echo "Last applied version: $LAST_VERSION"

# Find and apply new migrations
for f in db/migrations/V*.sql; do
    if [ -f "$f" ]; then
        VERSION=$(basename "$f" | sed 's/V\([0-9]*\)__.*/\1/')
        if [ "$VERSION" -gt "$LAST_VERSION" ]; then
            echo "Applying: $f"
            psql -f "$f"
        else
            echo "Skipping (already applied): $f"
        fi
    fi
done

# Apply repeatable migrations
echo "Checking repeatable migrations..."
for f in db/migrations/R__*.sql; do
    if [ -f "$f" ]; then
        FILENAME=$(basename "$f")
        CHECKSUM=$(md5sum "$f" | cut -d' ' -f1)
        
        LAST_CHECKSUM=$(psql -t -c "
            SELECT checksum FROM app_migration.changelog 
            WHERE filename = '$FILENAME' AND success = true
            ORDER BY executed_at DESC LIMIT 1;
        " | tr -d ' ')
        
        if [ "$CHECKSUM" != "$LAST_CHECKSUM" ]; then
            echo "Applying (changed): $f"
            psql -f "$f"
        else
            echo "Skipping (unchanged): $f"
        fi
    fi
done

# Release lock
echo "Releasing migration lock..."
psql -c "SELECT app_migration.release_lock();"
LOCK_ACQUIRED=false

echo "=== Migration deployment complete ==="
```

## Migration Validation

### Pre-deployment Validation Script

```bash
#!/bin/bash
# scripts/validate-migrations.sh

set -e

ERRORS=0

echo "=== Validating migrations ==="

# Check naming convention
echo "Checking naming conventions..."
for f in db/migrations/*.sql; do
    filename=$(basename "$f")
    
    # Versioned migrations
    if [[ $filename == V* ]]; then
        if ! [[ $filename =~ ^V[0-9]{3}__[a-z][a-z0-9_]*\.sql$ ]]; then
            echo "ERROR: Invalid versioned migration name: $filename"
            echo "  Expected: V001__description_here.sql"
            ((ERRORS++))
        fi
    fi
    
    # Repeatable migrations
    if [[ $filename == R__* ]]; then
        if ! [[ $filename =~ ^R__[a-z][a-z0-9_]*\.sql$ ]]; then
            echo "ERROR: Invalid repeatable migration name: $filename"
            echo "  Expected: R__description.sql"
            ((ERRORS++))
        fi
    fi
done

# Check for sequential versioning
echo "Checking version sequence..."
PREV_VERSION=0
for f in db/migrations/V*.sql; do
    if [ -f "$f" ]; then
        VERSION=$(basename "$f" | sed 's/V0*\([0-9]*\)__.*/\1/')
        EXPECTED=$((PREV_VERSION + 1))
        
        if [ "$VERSION" != "$EXPECTED" ]; then
            echo "WARNING: Non-sequential version: $f (expected V$(printf '%03d' $EXPECTED))"
        fi
        PREV_VERSION=$VERSION
    fi
done

# Check for dangerous operations
echo "Checking for dangerous operations..."
for f in db/migrations/V*.sql; do
    if [ -f "$f" ]; then
        # Check for DROP TABLE without IF EXISTS
        if grep -qiE "DROP\s+TABLE\s+(?!IF\s+EXISTS)" "$f"; then
            echo "WARNING: $f contains DROP TABLE without IF EXISTS"
        fi
        
        # Check for unqualified DELETE
        if grep -qiE "DELETE\s+FROM\s+\w+\s*;" "$f"; then
            echo "WARNING: $f contains DELETE without WHERE clause"
        fi
        
        # Check for TRUNCATE
        if grep -qi "TRUNCATE" "$f"; then
            echo "WARNING: $f contains TRUNCATE"
        fi
    fi
done

# Syntax check against test database
echo "Checking SQL syntax..."
for f in db/migrations/*.sql; do
    if [ -f "$f" ]; then
        # Try to parse the SQL
        if ! psql -c "\\set ON_ERROR_STOP on" -c "BEGIN;" -f "$f" -c "ROLLBACK;" 2>/dev/null; then
            echo "ERROR: Syntax error in $f"
            ((ERRORS++))
        fi
    fi
done

if [ $ERRORS -gt 0 ]; then
    echo "=== VALIDATION FAILED: $ERRORS errors ==="
    exit 1
fi

echo "=== VALIDATION PASSED ==="
exit 0
```

## Schema Comparison

### Schema Diff Script

```bash
#!/bin/bash
# scripts/schema-diff.sh
# Compare schema between two databases

SOURCE_DB=${1:-"source_db"}
TARGET_DB=${2:-"target_db"}

echo "Comparing $SOURCE_DB -> $TARGET_DB"

# Dump schemas
pg_dump -s -d "$SOURCE_DB" > /tmp/source_schema.sql
pg_dump -s -d "$TARGET_DB" > /tmp/target_schema.sql

# Compare
diff -u /tmp/source_schema.sql /tmp/target_schema.sql > /tmp/schema_diff.txt || true

if [ -s /tmp/schema_diff.txt ]; then
    echo "Schema differences found:"
    cat /tmp/schema_diff.txt
    exit 1
else
    echo "Schemas are identical"
    exit 0
fi
```

### Schema Snapshot Function

```sql
-- Create schema snapshot for comparison
CREATE OR REPLACE FUNCTION api.get_schema_snapshot()
RETURNS jsonb
LANGUAGE sql
STABLE
AS $$
    SELECT jsonb_build_object(
        'tables', (
            SELECT jsonb_agg(jsonb_build_object(
                'schema', table_schema,
                'name', table_name,
                'columns', (
                    SELECT jsonb_agg(jsonb_build_object(
                        'name', column_name,
                        'type', data_type,
                        'nullable', is_nullable
                    ) ORDER BY ordinal_position)
                    FROM information_schema.columns c
                    WHERE c.table_schema = t.table_schema 
                      AND c.table_name = t.table_name
                )
            ))
            FROM information_schema.tables t
            WHERE table_schema IN ('data', 'api', 'private')
              AND table_type = 'BASE TABLE'
        ),
        'functions', (
            SELECT jsonb_agg(jsonb_build_object(
                'schema', n.nspname,
                'name', p.proname,
                'args', pg_get_function_arguments(p.oid)
            ))
            FROM pg_proc p
            JOIN pg_namespace n ON p.pronamespace = n.oid
            WHERE n.nspname IN ('api', 'private')
        ),
        'snapshot_at', now()
    );
$$;
```

## Deployment Strategies

### Blue-Green Schema Deployment

```sql
-- Use schema versioning for blue-green deployments

-- Current production uses 'api_v1' schema
-- Deploy new version to 'api_v2' schema

-- 1. Create new schema
CREATE SCHEMA api_v2;

-- 2. Deploy new functions to api_v2
CREATE FUNCTION api_v2.get_customer(...) ...;

-- 3. Test api_v2 thoroughly

-- 4. Switch traffic (update search_path)
ALTER ROLE app_service SET search_path = api_v2, pg_temp;

-- 5. After verification, drop old schema
DROP SCHEMA api_v1 CASCADE;
ALTER SCHEMA api_v2 RENAME TO api;
```

### Canary Deployment

```sql
-- Route percentage of traffic to new version
CREATE OR REPLACE FUNCTION api.get_customer(in_id uuid)
RETURNS TABLE (...)
LANGUAGE plpgsql
AS $$
BEGIN
    -- 10% canary
    IF random() < 0.10 THEN
        RETURN QUERY SELECT * FROM api_v2.get_customer_impl(in_id);
    ELSE
        RETURN QUERY SELECT * FROM api_v1.get_customer_impl(in_id);
    END IF;
END;
$$;
```

### Rollback Procedure

```bash
#!/bin/bash
# scripts/rollback-migration.sh

VERSION=$1

if [ -z "$VERSION" ]; then
    echo "Usage: $0 <version>"
    exit 1
fi

echo "Rolling back to version $VERSION..."

# Get rollback SQL
ROLLBACK_SQL=$(psql -t -c "
    SELECT rollback_sql 
    FROM app_migration.rollback_scripts 
    WHERE version = '$VERSION';
")

if [ -z "$ROLLBACK_SQL" ]; then
    echo "ERROR: No rollback script found for version $VERSION"
    exit 1
fi

# Confirm
read -p "Are you sure you want to rollback? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    echo "Rollback cancelled"
    exit 0
fi

# Execute rollback
echo "Executing rollback..."
psql -c "CALL app_migration.rollback('$VERSION');"

echo "Rollback complete"
```
