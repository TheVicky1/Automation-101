-- ============================================================================
-- SCRIPT: dev_reset.sql
-- DESCRIPTION: Development-only destructive reset script (DO NOT RUN IN PRODUCTION)
-- AUTHOR: Senior Database Architect
-- DATE: 2026-09-15
-- ============================================================================

BEGIN;

DROP FUNCTION IF EXISTS update_message_delivery_status CASCADE;
DROP FUNCTION IF EXISTS claim_scheduled_followups CASCADE;
DROP FUNCTION IF EXISTS ingest_meta_lead CASCADE;
DROP FUNCTION IF EXISTS normalize_phone_e164 CASCADE;

DROP TABLE IF EXISTS events CASCADE;
DROP TABLE IF EXISTS followups CASCADE;
DROP TABLE IF EXISTS messages CASCADE;
DROP TABLE IF EXISTS conversations CASCADE;
DROP TABLE IF EXISTS lead_submissions CASCADE;
DROP TABLE IF EXISTS leads CASCADE;

DROP TYPE IF EXISTS followup_status_enum CASCADE;
DROP TYPE IF EXISTS message_status_enum CASCADE;
DROP TYPE IF EXISTS message_direction_enum CASCADE;
DROP TYPE IF EXISTS conversation_status_enum CASCADE;
DROP TYPE IF EXISTS lead_category_enum CASCADE;
DROP TYPE IF EXISTS lead_status_enum CASCADE;

DROP FUNCTION IF EXISTS update_updated_at_column CASCADE;

COMMIT;
