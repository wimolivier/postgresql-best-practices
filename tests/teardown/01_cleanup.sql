-- ============================================================================
-- TEST CLEANUP
-- ============================================================================
-- Removes test data and optionally test objects.
-- Run after tests to clean up the database.
-- ============================================================================

\echo ''
\echo '============================================================'
\echo 'CLEANING UP TEST DATA'
\echo '============================================================'
\echo ''

-- Clean up test migration records
DO $$
DECLARE
    l_count integer;
BEGIN
    -- Only if migration schema exists
    IF EXISTS (SELECT 1 FROM information_schema.schemata WHERE schema_name = 'app_migration') THEN
        -- Delete test migrations
        DELETE FROM app_migration.changelog
        WHERE version LIKE 'TEST_%' OR filename LIKE 'TEST_%';
        GET DIAGNOSTICS l_count = ROW_COUNT;
        RAISE NOTICE 'Deleted % test migration changelog entries', l_count;

        DELETE FROM app_migration.rollback_scripts WHERE version LIKE 'TEST_%';
        GET DIAGNOSTICS l_count = ROW_COUNT;
        RAISE NOTICE 'Deleted % test rollback scripts', l_count;

        DELETE FROM app_migration.rollback_history WHERE version LIKE 'TEST_%';
        GET DIAGNOSTICS l_count = ROW_COUNT;
        RAISE NOTICE 'Deleted % test rollback history entries', l_count;

        -- Release any held migration locks
        IF app_migration.is_locked() THEN
            PERFORM app_migration.release_lock();
            RAISE NOTICE 'Released migration lock';
        END IF;
    END IF;
END;
$$;

-- Clean up test results
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'test' AND table_name = 'results') THEN
        TRUNCATE test.results;
        RAISE NOTICE 'Truncated test.results';
    END IF;

    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'test' AND table_name = 'run_details') THEN
        TRUNCATE test.run_details CASCADE;
        RAISE NOTICE 'Truncated test.run_details';
    END IF;

    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'test' AND table_name = 'runs') THEN
        TRUNCATE test.runs CASCADE;
        RAISE NOTICE 'Truncated test.runs';
    END IF;
END;
$$;

-- Clean up test objects in data schema (if exists)
DO $$
DECLARE
    l_obj record;
    l_count integer := 0;
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.schemata WHERE schema_name = 'data') THEN
        -- Drop test tables
        FOR l_obj IN
            SELECT table_name
            FROM information_schema.tables
            WHERE table_schema = 'data'
              AND (table_name LIKE 'test_%' OR table_name LIKE 'TEST_%')
        LOOP
            EXECUTE format('DROP TABLE IF EXISTS data.%I CASCADE', l_obj.table_name);
            l_count := l_count + 1;
        END LOOP;

        IF l_count > 0 THEN
            RAISE NOTICE 'Dropped % test tables from data schema', l_count;
        END IF;
    END IF;
END;
$$;

-- Clean up test objects in api schema (if exists)
DO $$
DECLARE
    l_obj record;
    l_count integer := 0;
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.schemata WHERE schema_name = 'api') THEN
        -- Drop test functions
        FOR l_obj IN
            SELECT routine_name, routine_type
            FROM information_schema.routines
            WHERE routine_schema = 'api'
              AND (routine_name LIKE 'test_%' OR routine_name LIKE 'TEST_%')
        LOOP
            IF l_obj.routine_type = 'FUNCTION' THEN
                EXECUTE format('DROP FUNCTION IF EXISTS api.%I CASCADE', l_obj.routine_name);
            ELSE
                EXECUTE format('DROP PROCEDURE IF EXISTS api.%I CASCADE', l_obj.routine_name);
            END IF;
            l_count := l_count + 1;
        END LOOP;

        IF l_count > 0 THEN
            RAISE NOTICE 'Dropped % test routines from api schema', l_count;
        END IF;
    END IF;
END;
$$;

-- Clean up test objects in private schema (if exists)
DO $$
DECLARE
    l_obj record;
    l_count integer := 0;
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.schemata WHERE schema_name = 'private') THEN
        FOR l_obj IN
            SELECT routine_name, routine_type
            FROM information_schema.routines
            WHERE routine_schema = 'private'
              AND (routine_name LIKE 'test_%' OR routine_name LIKE 'TEST_%')
        LOOP
            IF l_obj.routine_type = 'FUNCTION' THEN
                EXECUTE format('DROP FUNCTION IF EXISTS private.%I CASCADE', l_obj.routine_name);
            ELSE
                EXECUTE format('DROP PROCEDURE IF EXISTS private.%I CASCADE', l_obj.routine_name);
            END IF;
            l_count := l_count + 1;
        END LOOP;

        IF l_count > 0 THEN
            RAISE NOTICE 'Dropped % test routines from private schema', l_count;
        END IF;
    END IF;
END;
$$;

-- Reset test context
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'test' AND table_name = 'context') THEN
        UPDATE test.context
        SET current_test = 'unknown',
            current_function = NULL,
            assertion_count = 0,
            pass_count = 0,
            fail_count = 0,
            started_at = clock_timestamp()
        WHERE id = 1;
        RAISE NOTICE 'Reset test context';
    END IF;
END;
$$;

\echo ''
\echo '============================================================'
\echo 'CLEANUP COMPLETE'
\echo '============================================================'
\echo ''
