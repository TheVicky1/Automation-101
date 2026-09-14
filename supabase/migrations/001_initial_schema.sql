-- ============================================================================
-- MIGRATION: 001_initial_schema.sql
-- DESCRIPTION: Forward-only production migration for Meta Ads WhatsApp Lead Qualification System
-- AUTHOR: Senior Database Architect
-- DATE: 2026-09-15
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. CREATE ENUM TYPES (FORWARD-COMPATIBLE DO BLOCKS)
-- ----------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'lead_status_enum') THEN
    CREATE TYPE lead_status_enum AS ENUM ('NEW', 'VALIDATED', 'CONTACTED', 'CONVERSATION_ACTIVE', 'QUALIFYING', 'CLOSED');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'lead_category_enum') THEN
    CREATE TYPE lead_category_enum AS ENUM ('NEW', 'HOT', 'WARM', 'COLD', 'INVALID');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'conversation_status_enum') THEN
    CREATE TYPE conversation_status_enum AS ENUM ('ACTIVE', 'PAUSED', 'HANDED_OFF', 'CLOSED');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'message_direction_enum') THEN
    CREATE TYPE message_direction_enum AS ENUM ('INBOUND', 'OUTBOUND');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'message_status_enum') THEN
    CREATE TYPE message_status_enum AS ENUM ('PENDING', 'SENT', 'DELIVERED', 'READ', 'FAILED');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'followup_status_enum') THEN
    CREATE TYPE followup_status_enum AS ENUM ('SCHEDULED', 'PROCESSING', 'SENT', 'CANCELLED', 'COMPLETED', 'FAILED');
  END IF;
END $$;

-- ----------------------------------------------------------------------------
-- 2. HELPER FUNCTIONS
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION normalize_phone_e164(p_phone TEXT, p_default_cc TEXT DEFAULT '91')
RETURNS TEXT AS $$
DECLARE
  v_cleaned TEXT;
  v_digits_only TEXT;
BEGIN
  IF p_phone IS NULL OR TRIM(p_phone) = '' THEN
    RETURN NULL;
  END IF;
  
  v_cleaned := TRIM(p_phone);
  
  -- Handle double zero prefix '00'
  IF v_cleaned LIKE '00%' THEN
    v_cleaned := '+' || substring(v_cleaned from 3);
  END IF;
  
  -- Remove non-digits except leading +
  v_cleaned := regexp_replace(v_cleaned, '[^\d+]', '', 'g');
  
  -- Explicit international E.164 string (+ prefix)
  IF v_cleaned LIKE '+%' THEN
    v_digits_only := substring(v_cleaned from 2);
    IF length(v_digits_only) < 7 OR length(v_digits_only) > 15 THEN
      RETURN NULL;
    END IF;
    RETURN '+' || v_digits_only;
  END IF;
  
  -- Local digit string:
  v_digits_only := v_cleaned;
  
  -- Handle leading 0 for 11-digit numbers (e.g. 09876543210 -> 9876543210)
  IF v_digits_only LIKE '0%' AND length(v_digits_only) = 11 THEN
    v_digits_only := substring(v_digits_only from 2);
  END IF;
  
  -- If 10 digits (local Indian number), prepend default country code
  IF length(v_digits_only) = 10 THEN
    v_digits_only := p_default_cc || v_digits_only;
  END IF;
  
  -- E.164 length check (7..15 digits)
  IF length(v_digits_only) < 7 OR length(v_digits_only) > 15 THEN
    RETURN NULL;
  END IF;
  
  RETURN '+' || v_digits_only;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- ----------------------------------------------------------------------------
-- 3. CREATE TABLE: leads
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS leads (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  phone VARCHAR(20) NOT NULL,
  whatsapp_number VARCHAR(20) NULL,
  meta_lead_id VARCHAR(255) NULL,
  first_meta_lead_id VARCHAR(255) NULL,
  latest_meta_lead_id VARCHAR(255) NULL,
  name VARCHAR(255) NULL,
  email VARCHAR(255) NULL,
  
  meta_created_at TIMESTAMPTZ NULL,
  meta_source VARCHAR(100) NULL,
  meta_form VARCHAR(255) NULL,
  meta_channel VARCHAR(100) NULL,
  meta_stage VARCHAR(100) NULL,
  meta_owner VARCHAR(100) NULL,
  meta_labels JSONB NOT NULL DEFAULT '[]'::jsonb,
  resubmission_count INT NOT NULL DEFAULT 0,
  
  status lead_status_enum NOT NULL DEFAULT 'NEW',
  lead_category lead_category_enum NOT NULL DEFAULT 'NEW',
  lead_score INT NOT NULL DEFAULT 0 CHECK (lead_score >= 0 AND lead_score <= 100),
  intent VARCHAR(100) NULL,
  requirements JSONB NOT NULL DEFAULT '{}'::jsonb,
  ai_summary TEXT NULL,
  
  human_handoff BOOLEAN NOT NULL DEFAULT FALSE,
  ai_active BOOLEAN NOT NULL DEFAULT TRUE,
  opted_out BOOLEAN NOT NULL DEFAULT FALSE,
  
  last_inbound_at TIMESTAMPTZ NULL,
  last_outbound_at TIMESTAMPTZ NULL,
  last_contact_at TIMESTAMPTZ NULL,
  next_followup_at TIMESTAMPTZ NULL,
  
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Forward-migration column additions for existing installations
ALTER TABLE leads ADD COLUMN IF NOT EXISTS first_meta_lead_id VARCHAR(255) NULL;
ALTER TABLE leads ADD COLUMN IF NOT EXISTS latest_meta_lead_id VARCHAR(255) NULL;
ALTER TABLE leads ADD COLUMN IF NOT EXISTS resubmission_count INT NOT NULL DEFAULT 0;
ALTER TABLE leads ADD COLUMN IF NOT EXISTS last_inbound_at TIMESTAMPTZ NULL;
ALTER TABLE leads ADD COLUMN IF NOT EXISTS last_outbound_at TIMESTAMPTZ NULL;

-- ----------------------------------------------------------------------------
-- 4. CREATE TABLE: lead_submissions (Historical Meta Submissions)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS lead_submissions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  lead_id UUID NOT NULL REFERENCES leads(id) ON DELETE CASCADE,
  meta_lead_id VARCHAR(255) NULL,
  meta_form VARCHAR(255) NULL,
  meta_source VARCHAR(100) NULL,
  meta_created_at TIMESTAMPTZ NULL,
  raw_payload JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ----------------------------------------------------------------------------
-- 5. CREATE TABLE: conversations
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS conversations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  lead_id UUID NOT NULL REFERENCES leads(id) ON DELETE RESTRICT,
  status conversation_status_enum NOT NULL DEFAULT 'ACTIVE',
  started_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_activity_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Add composite unique constraint for existing installations
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'uq_conversations_id_lead'
  ) THEN
    ALTER TABLE conversations ADD CONSTRAINT uq_conversations_id_lead UNIQUE (id, lead_id);
  END IF;
END $$;

-- ----------------------------------------------------------------------------
-- 6. CREATE TABLE: messages (With Composite FK guaranteeing conversation lead alignment)
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS messages (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  lead_id UUID NOT NULL REFERENCES leads(id) ON DELETE RESTRICT,
  conversation_id UUID NOT NULL,
  whatsapp_message_id VARCHAR(255) NULL,
  direction message_direction_enum NOT NULL,
  delivery_status message_status_enum NOT NULL DEFAULT 'SENT',
  message_type VARCHAR(50) NOT NULL DEFAULT 'text',
  message_body TEXT NULL,
  raw_payload JSONB NOT NULL DEFAULT '{}'::jsonb,
  occurred_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'fk_messages_conversation_lead'
  ) THEN
    ALTER TABLE messages ADD CONSTRAINT fk_messages_conversation_lead 
      FOREIGN KEY (conversation_id, lead_id) REFERENCES conversations(id, lead_id) ON DELETE RESTRICT;
  END IF;
END $$;

-- ----------------------------------------------------------------------------
-- 7. CREATE TABLE: followups
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS followups (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  lead_id UUID NOT NULL REFERENCES leads(id) ON DELETE CASCADE,
  scheduled_for TIMESTAMPTZ NOT NULL,
  status followup_status_enum NOT NULL DEFAULT 'SCHEDULED',
  template_name VARCHAR(100) NULL,
  attempt_count INT NOT NULL DEFAULT 0,
  claimed_at TIMESTAMPTZ NULL,
  claimed_by VARCHAR(100) NULL,
  error_log TEXT NULL,
  invalidated_reason TEXT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ----------------------------------------------------------------------------
-- 8. CREATE TABLE: events
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  lead_id UUID NOT NULL REFERENCES leads(id) ON DELETE CASCADE,
  event_type VARCHAR(100) NOT NULL,
  payload JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ----------------------------------------------------------------------------
-- 9. TRIGGERS FOR UPDATED_AT
-- ----------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'set_leads_updated_at') THEN
    CREATE TRIGGER set_leads_updated_at BEFORE UPDATE ON leads FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'set_conversations_updated_at') THEN
    CREATE TRIGGER set_conversations_updated_at BEFORE UPDATE ON conversations FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'set_followups_updated_at') THEN
    CREATE TRIGGER set_followups_updated_at BEFORE UPDATE ON followups FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
  END IF;
END $$;

-- ----------------------------------------------------------------------------
-- 10. INDEXES AND CONSTRAINTS
-- ----------------------------------------------------------------------------
CREATE UNIQUE INDEX IF NOT EXISTS idx_leads_phone ON leads(phone);
CREATE UNIQUE INDEX IF NOT EXISTS idx_leads_meta_lead_id ON leads(meta_lead_id) WHERE meta_lead_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS idx_submissions_meta_lead_id ON lead_submissions(meta_lead_id) WHERE meta_lead_id IS NOT NULL;

-- Enforce single active conversation per lead
CREATE UNIQUE INDEX IF NOT EXISTS idx_conversations_single_active ON conversations(lead_id) WHERE status = 'ACTIVE';

CREATE INDEX IF NOT EXISTS idx_leads_status_category ON leads(status, lead_category, human_handoff, opted_out);
CREATE INDEX IF NOT EXISTS idx_leads_requirements_gin ON leads USING GIN (requirements);

CREATE UNIQUE INDEX IF NOT EXISTS idx_messages_wamid ON messages(whatsapp_message_id) WHERE whatsapp_message_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_messages_lead_conv_occurred ON messages(lead_id, conversation_id, occurred_at DESC);

-- Worker claiming polling index
CREATE INDEX IF NOT EXISTS idx_followups_claiming ON followups(status, scheduled_for, claimed_at);

CREATE INDEX IF NOT EXISTS idx_events_lead_type ON events(lead_id, event_type, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_events_payload_gin ON events USING GIN (payload);

-- ----------------------------------------------------------------------------
-- 11. CANONICAL META LEAD INGESTION RPC FUNCTION
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ingest_meta_lead(
  p_phone VARCHAR(20),
  p_name VARCHAR(255) DEFAULT NULL,
  p_email VARCHAR(255) DEFAULT NULL,
  p_whatsapp_number VARCHAR(20) DEFAULT NULL,
  p_meta_lead_id VARCHAR(255) DEFAULT NULL,
  p_meta_created_at TIMESTAMPTZ DEFAULT NULL,
  p_meta_source VARCHAR(100) DEFAULT NULL,
  p_meta_form VARCHAR(255) DEFAULT NULL,
  p_meta_channel VARCHAR(100) DEFAULT NULL,
  p_meta_stage VARCHAR(100) DEFAULT NULL,
  p_meta_owner VARCHAR(100) DEFAULT NULL,
  p_meta_labels JSONB DEFAULT '[]'::jsonb,
  p_raw_payload JSONB DEFAULT '{}'::jsonb
)
RETURNS TABLE (
  out_lead_id UUID,
  out_is_resubmission BOOLEAN,
  out_resubmission_count INT
) 
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_norm_phone VARCHAR(20);
  v_norm_wa VARCHAR(20);
  v_lead_id UUID;
  v_existing_lead_by_meta UUID;
  v_resub_count INT := 0;
  v_is_resub BOOLEAN := FALSE;
  v_clean_meta_id VARCHAR(255);
BEGIN
  -- 1. Normalize Phone Numbers
  v_norm_phone := normalize_phone_e164(p_phone);
  v_norm_wa := normalize_phone_e164(p_whatsapp_number);

  IF v_norm_phone IS NULL THEN
    RAISE EXCEPTION 'Invalid phone number provided for lead ingestion: %', p_phone;
  END IF;

  v_clean_meta_id := NULLIF(TRIM(p_meta_lead_id), '');

  -- 2. Check if exact meta_lead_id already exists in submissions (Retry / Duplicate Webhook Guard)
  IF v_clean_meta_id IS NOT NULL THEN
    SELECT lead_id INTO v_existing_lead_by_meta 
    FROM lead_submissions 
    WHERE meta_lead_id = v_clean_meta_id 
    LIMIT 1;

    IF v_existing_lead_by_meta IS NOT NULL THEN
      SELECT resubmission_count INTO v_resub_count FROM leads WHERE id = v_existing_lead_by_meta;
      RETURN QUERY SELECT v_existing_lead_by_meta, FALSE, COALESCE(v_resub_count, 0);
      RETURN;
    END IF;
  END IF;

  -- 3. Atomic UPSERT on Canonical Phone
  INSERT INTO leads (
    phone, whatsapp_number, meta_lead_id, first_meta_lead_id, latest_meta_lead_id,
    name, email, meta_created_at, meta_source, meta_form, meta_channel, meta_stage, meta_owner, meta_labels
  )
  VALUES (
    v_norm_phone, v_norm_wa, v_clean_meta_id, v_clean_meta_id, v_clean_meta_id,
    p_name, p_email, p_meta_created_at, p_meta_source, p_meta_form, p_meta_channel, p_meta_stage, p_meta_owner, COALESCE(p_meta_labels, '[]'::jsonb)
  )
  ON CONFLICT (phone) DO UPDATE SET
    meta_lead_id = COALESCE(EXCLUDED.meta_lead_id, leads.meta_lead_id),
    latest_meta_lead_id = COALESCE(EXCLUDED.latest_meta_lead_id, leads.latest_meta_lead_id),
    whatsapp_number = COALESCE(EXCLUDED.whatsapp_number, leads.whatsapp_number),
    name = COALESCE(EXCLUDED.name, leads.name),
    email = COALESCE(EXCLUDED.email, leads.email),
    meta_source = COALESCE(EXCLUDED.meta_source, leads.meta_source),
    meta_form = COALESCE(EXCLUDED.meta_form, leads.meta_form),
    resubmission_count = CASE 
      WHEN EXCLUDED.meta_lead_id IS DISTINCT FROM leads.latest_meta_lead_id THEN leads.resubmission_count + 1
      ELSE leads.resubmission_count
    END,
    updated_at = NOW()
  RETURNING id, (resubmission_count > 0), resubmission_count 
  INTO v_lead_id, v_is_resub, v_resub_count;

  -- 4. Record Submission History (Ignore duplicate meta_lead_id if racing)
  IF v_clean_meta_id IS NOT NULL THEN
    INSERT INTO lead_submissions (lead_id, meta_lead_id, meta_form, meta_source, meta_created_at, raw_payload)
    VALUES (v_lead_id, v_clean_meta_id, p_meta_form, p_meta_source, p_meta_created_at, COALESCE(p_raw_payload, '{}'::jsonb))
    ON CONFLICT (meta_lead_id) WHERE meta_lead_id IS NOT NULL DO NOTHING;
  ELSE
    INSERT INTO lead_submissions (lead_id, meta_lead_id, meta_form, meta_source, meta_created_at, raw_payload)
    VALUES (v_lead_id, NULL, p_meta_form, p_meta_source, p_meta_created_at, COALESCE(p_raw_payload, '{}'::jsonb));
  END IF;

  -- 5. Audit Logging
  IF v_is_resub THEN
    INSERT INTO events (lead_id, event_type, payload)
    VALUES (v_lead_id, 'META_FORM_RESUBMITTED', jsonb_build_object(
      'meta_lead_id', v_clean_meta_id,
      'form', p_meta_form,
      'resubmission_count', v_resub_count
    ));
  ELSE
    INSERT INTO events (lead_id, event_type, payload)
    VALUES (v_lead_id, 'LEAD_CREATED', jsonb_build_object(
      'meta_lead_id', v_clean_meta_id,
      'form', p_meta_form,
      'source', p_meta_source
    ));
  END IF;

  RETURN QUERY SELECT v_lead_id, v_is_resub, v_resub_count;
END;
$$;

-- ----------------------------------------------------------------------------
-- 12. FOLLOW-UP WORKER CLAIMING RPC FUNCTION
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION claim_scheduled_followups(
  p_worker_id VARCHAR(100),
  p_limit INT DEFAULT 10,
  p_timeout_minutes INT DEFAULT 5,
  p_max_attempts INT DEFAULT 5
)
RETURNS TABLE (
  out_followup_id UUID,
  out_lead_id UUID,
  out_scheduled_for TIMESTAMPTZ,
  out_template_name VARCHAR(100)
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- 1. Invalidate tasks for leads that received inbound activity after task creation
  UPDATE followups f
  SET status = 'CANCELLED',
      invalidated_reason = 'INBOUND_MESSAGE_RECEIVED',
      updated_at = NOW()
  FROM leads l
  WHERE f.lead_id = l.id
    AND f.status IN ('SCHEDULED', 'PROCESSING')
    AND l.last_inbound_at IS NOT NULL
    AND l.last_inbound_at > f.created_at;

  -- 2. Mark failed tasks exceeding max attempts
  UPDATE followups
  SET status = 'FAILED',
      error_log = 'Max execution attempts exceeded',
      updated_at = NOW()
  WHERE status = 'PROCESSING'
    AND attempt_count >= p_max_attempts
    AND claimed_at < NOW() - (p_timeout_minutes || ' minutes')::INTERVAL;

  -- 3. Reset stale processing tasks below max attempts
  UPDATE followups
  SET status = 'SCHEDULED', claimed_at = NULL, claimed_by = NULL
  WHERE status = 'PROCESSING'
    AND attempt_count < p_max_attempts
    AND claimed_at < NOW() - (p_timeout_minutes || ' minutes')::INTERVAL;

  -- 4. Atomically Claim Ready Tasks
  RETURN QUERY
  WITH ready_tasks AS (
    SELECT f.id
    FROM followups f
    JOIN leads l ON l.id = f.lead_id
    WHERE f.status = 'SCHEDULED'
      AND f.scheduled_for <= NOW()
      AND l.opted_out = FALSE
      AND l.human_handoff = FALSE
      AND l.ai_active = TRUE
      AND l.status <> 'CLOSED'
      AND (l.last_inbound_at IS NULL OR l.last_inbound_at < f.created_at)
    ORDER BY f.scheduled_for ASC
    FOR UPDATE OF f SKIP LOCKED
    LIMIT p_limit
  )
  UPDATE followups f
  SET status = 'PROCESSING',
      claimed_at = NOW(),
      claimed_by = p_worker_id,
      attempt_count = f.attempt_count + 1,
      updated_at = NOW()
  FROM ready_tasks rt
  WHERE f.id = rt.id
  RETURNING f.id, f.lead_id, f.scheduled_for, f.template_name;
END;
$$;

-- ----------------------------------------------------------------------------
-- 13. MESSAGE DELIVERY STATUS TRANSITION RPC FUNCTION
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION update_message_delivery_status(
  p_whatsapp_message_id VARCHAR(255),
  p_new_status message_status_enum
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_current_status message_status_enum;
BEGIN
  IF p_whatsapp_message_id IS NULL OR TRIM(p_whatsapp_message_id) = '' THEN
    RETURN FALSE;
  END IF;

  SELECT delivery_status INTO v_current_status
  FROM messages WHERE whatsapp_message_id = p_whatsapp_message_id FOR UPDATE;

  IF v_current_status IS NULL THEN
    RETURN FALSE;
  END IF;

  -- State Machine Transition Guard: Block backward regressions
  IF (v_current_status = 'READ' AND p_new_status IN ('PENDING', 'SENT', 'DELIVERED')) OR
     (v_current_status = 'DELIVERED' AND p_new_status IN ('PENDING', 'SENT')) OR
     (v_current_status = 'SENT' AND p_new_status = 'PENDING') OR
     (v_current_status = 'FAILED' AND p_new_status IN ('PENDING', 'SENT', 'DELIVERED')) THEN
    RETURN FALSE;
  END IF;

  UPDATE messages
  SET delivery_status = p_new_status
  WHERE whatsapp_message_id = p_whatsapp_message_id;

  RETURN TRUE;
END;
$$;

-- ----------------------------------------------------------------------------
-- 14. SECURITY & EXPLICIT ROLE PRIVILEGES
-- ----------------------------------------------------------------------------
-- Lock down RPC functions from public execution
REVOKE EXECUTE ON FUNCTION normalize_phone_e164(TEXT, TEXT) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION ingest_meta_lead(VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, TIMESTAMPTZ, VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, JSONB, JSONB) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION claim_scheduled_followups(VARCHAR, INT, INT, INT) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION update_message_delivery_status(VARCHAR, message_status_enum) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION normalize_phone_e164(TEXT, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION ingest_meta_lead(VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, TIMESTAMPTZ, VARCHAR, VARCHAR, VARCHAR, VARCHAR, VARCHAR, JSONB, JSONB) TO service_role;
GRANT EXECUTE ON FUNCTION claim_scheduled_followups(VARCHAR, INT, INT, INT) TO service_role;
GRANT EXECUTE ON FUNCTION update_message_delivery_status(VARCHAR, message_status_enum) TO service_role;

-- Revoke direct table access from public/anon/authenticated
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM PUBLIC, anon, authenticated;
GRANT ALL ON ALL TABLES IN SCHEMA public TO service_role;

-- Enable Row Level Security (RLS) as defense-in-depth
ALTER TABLE leads ENABLE ROW LEVEL SECURITY;
ALTER TABLE lead_submissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE conversations ENABLE ROW LEVEL SECURITY;
ALTER TABLE messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE followups ENABLE ROW LEVEL SECURITY;
ALTER TABLE events ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE policyname = 'service_role_all_leads') THEN
    CREATE POLICY service_role_all_leads ON leads FOR ALL TO service_role USING (true) WITH CHECK (true);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE policyname = 'service_role_all_lead_submissions') THEN
    CREATE POLICY service_role_all_lead_submissions ON lead_submissions FOR ALL TO service_role USING (true) WITH CHECK (true);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE policyname = 'service_role_all_conversations') THEN
    CREATE POLICY service_role_all_conversations ON conversations FOR ALL TO service_role USING (true) WITH CHECK (true);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE policyname = 'service_role_all_messages') THEN
    CREATE POLICY service_role_all_messages ON messages FOR ALL TO service_role USING (true) WITH CHECK (true);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE policyname = 'service_role_all_followups') THEN
    CREATE POLICY service_role_all_followups ON followups FOR ALL TO service_role USING (true) WITH CHECK (true);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE policyname = 'service_role_all_events') THEN
    CREATE POLICY service_role_all_events ON events FOR ALL TO service_role USING (true) WITH CHECK (true);
  END IF;
END $$;

COMMIT;
