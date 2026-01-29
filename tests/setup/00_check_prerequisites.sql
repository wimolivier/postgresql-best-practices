-- ============================================================================
-- PREREQUISITES CHECK
-- ============================================================================
-- Verify PostgreSQL version and required extensions before running tests.
-- Run this first to ensure the environment is properly configured.
-- ============================================================================

DO $$
DECLARE
    l_version integer;
    l_version_str text;
    l_has_uuidv7 boolean;
BEGIN
    -- Get PostgreSQL version
    SELECT current_setting('server_version_num')::integer INTO l_version;
    SELECT current_setting('server_version') INTO l_version_str;

    RAISE NOTICE '';
    RAISE NOTICE '============================================================';
    RAISE NOTICE 'PREREQUISITES CHECK';
    RAISE NOTICE '============================================================';
    RAISE NOTICE '';
    RAISE NOTICE 'PostgreSQL version: %', l_version_str;

    -- Check minimum version (PostgreSQL 18+)
    IF l_version < 180000 THEN
        RAISE NOTICE '  WARNING: PostgreSQL 18+ recommended (current: %)', l_version_str;
        RAISE NOTICE '  Some tests may fail on older versions';
    ELSE
        RAISE NOTICE '  OK: PostgreSQL 18+ detected';
    END IF;

    -- Check for uuidv7 function (PG17+)
    SELECT EXISTS (
        SELECT 1 FROM pg_proc WHERE proname = 'uuidv7'
    ) INTO l_has_uuidv7;

    IF l_has_uuidv7 THEN
        RAISE NOTICE '  OK: uuidv7() function available';
    ELSE
        RAISE NOTICE '  WARNING: uuidv7() not available (PG17+ feature)';
        RAISE NOTICE '  UUID tests will use gen_random_uuid() fallback';
    END IF;

    -- Check superuser/admin privileges
    IF NOT (
        SELECT usesuper FROM pg_user WHERE usename = current_user
    ) THEN
        RAISE NOTICE '  WARNING: Current user is not superuser';
        RAISE NOTICE '  Some tests may require elevated privileges';
    ELSE
        RAISE NOTICE '  OK: Running as superuser';
    END IF;

    -- Check current database
    RAISE NOTICE '';
    RAISE NOTICE 'Connection details:';
    RAISE NOTICE '  Database: %', current_database();
    RAISE NOTICE '  User: %', current_user;
    RAISE NOTICE '  Schema search path: %', current_setting('search_path');

    -- Check for existing test schema
    IF EXISTS (SELECT 1 FROM information_schema.schemata WHERE schema_name = 'test') THEN
        RAISE NOTICE '';
        RAISE NOTICE '  NOTE: test schema already exists';
        RAISE NOTICE '  Framework installation will preserve existing data';
    END IF;

    -- Check for existing migration system
    IF EXISTS (SELECT 1 FROM information_schema.schemata WHERE schema_name = 'app_migration') THEN
        RAISE NOTICE '';
        RAISE NOTICE '  OK: app_migration schema exists';
    ELSE
        RAISE NOTICE '';
        RAISE NOTICE '  NOTE: app_migration schema not found';
        RAISE NOTICE '  Migration system tests will install it';
    END IF;

    RAISE NOTICE '';
    RAISE NOTICE '============================================================';
    RAISE NOTICE 'Prerequisites check complete';
    RAISE NOTICE '============================================================';
    RAISE NOTICE '';
END;
$$;

-- Verify key system functions exist
SELECT 'System functions check:' AS info;

SELECT
    proname AS function_name,
    CASE WHEN proname IS NOT NULL THEN 'available' ELSE 'missing' END AS status
FROM (
    VALUES ('gen_random_uuid'), ('clock_timestamp'), ('md5')
) AS required(fname)
LEFT JOIN pg_proc ON proname = fname;
