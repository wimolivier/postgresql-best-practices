-- ============================================================================
-- POSTGRESQL MIGRATION SYSTEM - UNINSTALL SCRIPT
-- ============================================================================
-- WARNING: This script removes the entire migration system and all history!
-- Only use this if you want to completely remove the migration system.
-- ============================================================================

-- Safety check - require explicit confirmation
DO $$
BEGIN
    -- Comment out the following line to allow uninstall
    RAISE EXCEPTION 'Safety check: Edit this script and comment out this line to confirm uninstall';
END;
$$;

BEGIN;

-- Drop all objects in the migration schema
DROP SCHEMA IF EXISTS app_migration CASCADE;

COMMIT;

DO $$
BEGIN
    RAISE NOTICE '';
    RAISE NOTICE '============================================================';
    RAISE NOTICE 'Migration system uninstalled.';
    RAISE NOTICE 'All migration history has been deleted.';
    RAISE NOTICE '============================================================';
END;
$$;
