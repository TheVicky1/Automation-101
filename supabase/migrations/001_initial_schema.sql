-- ============================================================================
-- MIGRATION: 001_initial_schema.sql
-- DESCRIPTION: Forward-only production migration for Meta Ads WhatsApp Lead Qualification System
-- AUTHOR: System Architecture Team
-- DATE: 2026-09-15
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. CREATE ENUM TYPES (IF NOT EXISTS GUARD VIA DO BLOCK)
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
-- 2. AUTOMATIC UPDATED_AT TRIGGER FUNCTION
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- ----------------------------------------------------------------------------
-- 3. CREATE TABLE: leads
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS leads (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  phone VARCHAR(20) NOT NULL,
  whatsapp_number VARCHAR(20) NULL,
  meta_lead_id VARCHAR(255) NULL,
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

-- ----------------------------------------------------------------------------
-- 4. CREATE TABLE: conversations
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

-- ----------------------------------------------------------------------------
-- 5. CREATE TABLE: messages
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS messages (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  lead_id UUID NOT NULL REFERENCES leads(id) ON DELETE RESTRICT,
  conversation_id UUID NOT NULL REFERENCES conversations(id) ON DELETE RESTRICT,
  whatsapp_message_id VARCHAR(255) NULL,
  direction message_direction_enum NOT NULL,
  delivery_status message_status_enum NOT NULL DEFAULT 'SENT',
  message_type VARCHAR(50) NOT NULL DEFAULT 'text',
  message_body TEXT NULL,
  raw_payload JSONB NOT NULL DEFAULT '{}'::jsonb,
  occurred_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ----------------------------------------------------------------------------
-- 6. CREATE TABLE: followups
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS followups (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  lead_id UUID NOT NULL REFERENCES leads(id) ON DELETE CASCADE,
  scheduled_for TIMESTAMPTZ NOT NULL,
  status followup_status_enum NOT NULL DEFAULT 'SCHEDULED',
  template_name VARCHAR(100) NULL,
  attempt_count INT NOT NULL DEFAULT 0,
  error_log TEXT NULL,
  invalidated_reason TEXT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ----------------------------------------------------------------------------
-- 7. CREATE TABLE: events
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  lead_id UUID NOT NULL REFERENCES leads(id) ON DELETE CASCADE,
  event_type VARCHAR(100) NOT NULL,
  payload JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ----------------------------------------------------------------------------
-- 8. TRIGGERS FOR UPDATED_AT
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
-- 9. INDEXES AND CONSTRAINTS
-- ----------------------------------------------------------------------------
CREATE UNIQUE INDEX IF NOT EXISTS idx_leads_phone ON leads(phone);
CREATE UNIQUE INDEX IF NOT EXISTS idx_leads_meta_lead_id ON leads(meta_lead_id) WHERE meta_lead_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_leads_status_category ON leads(status, lead_category, human_handoff, opted_out);
CREATE INDEX IF NOT EXISTS idx_leads_requirements_gin ON leads USING GIN (requirements);

CREATE INDEX IF NOT EXISTS idx_conversations_lead_status ON conversations(lead_id, status);

CREATE UNIQUE INDEX IF NOT EXISTS idx_messages_wamid ON messages(whatsapp_message_id) WHERE whatsapp_message_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_messages_lead_conv_occurred ON messages(lead_id, conversation_id, occurred_at DESC);

CREATE INDEX IF NOT EXISTS idx_followups_polling ON followups(scheduled_for, status) WHERE status = 'SCHEDULED';

CREATE INDEX IF NOT EXISTS idx_events_lead_type ON events(lead_id, event_type, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_events_payload_gin ON events USING GIN (payload);

-- ----------------------------------------------------------------------------
-- 10. CANONICAL META LEAD INGESTION RPC FUNCTION
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
  p_meta_labels JSONB DEFAULT '[]'::jsonb
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
  v_lead_id UUID;
  v_existing_by_meta UUID;
  v_resub_count INT := 0;
  v_is_resub BOOLEAN := FALSE;
BEGIN
  -- 1. Check if meta_lead_id already exists (Duplicate Submission Event Guard)
  IF p_meta_lead_id IS NOT NULL THEN
    SELECT id INTO v_existing_by_meta FROM leads WHERE meta_lead_id = p_meta_lead_id;
    IF v_existing_by_meta IS NOT NULL THEN
      RETURN QUERY SELECT v_existing_by_meta, FALSE, 0;
      RETURN;
    END IF;
  END IF;

  -- 2. Upsert on Phone Number (Canonical Identity)
  INSERT INTO leads (
    phone, whatsapp_number, meta_lead_id, name, email,
    meta_created_at, meta_source, meta_form, meta_channel, meta_stage, meta_owner, meta_labels
  )
  VALUES (
    p_phone, p_whatsapp_number, p_meta_lead_id, p_name, p_email,
    p_meta_created_at, p_meta_source, p_meta_form, p_meta_channel, p_meta_stage, p_meta_owner, COALESCE(p_meta_labels, '[]'::jsonb)
  )
  ON CONFLICT (phone) DO UPDATE SET
    meta_lead_id = EXCLUDED.meta_lead_id,
    whatsapp_number = COALESCE(EXCLUDED.whatsapp_number, leads.whatsapp_number),
    name = COALESCE(EXCLUDED.name, leads.name),
    email = COALESCE(EXCLUDED.email, leads.email),
    meta_source = COALESCE(EXCLUDED.meta_source, leads.meta_source),
    meta_form = COALESCE(EXCLUDED.meta_form, leads.meta_form),
    resubmission_count = leads.resubmission_count + 1,
    updated_at = NOW()
  RETURNING id, (resubmission_count > 0), resubmission_count 
  INTO v_lead_id, v_is_resub, v_resub_count;

  -- 3. Log Audit Event
  IF v_is_resub THEN
    INSERT INTO events (lead_id, event_type, payload)
    VALUES (v_lead_id, 'META_FORM_RESUBMITTED', jsonb_build_object(
      'meta_lead_id', p_meta_lead_id,
      'form', p_meta_form,
      'resubmission_count', v_resub_count
    ));
  ELSE
    INSERT INTO events (lead_id, event_type, payload)
    VALUES (v_lead_id, 'LEAD_CREATED', jsonb_build_object(
      'meta_lead_id', p_meta_lead_id,
      'form', p_meta_form,
      'source', p_meta_source
    ));
  END IF;

  RETURN QUERY SELECT v_lead_id, v_is_resub, v_resub_count;
END;
$$;

-- ----------------------------------------------------------------------------
-- 11. ROW LEVEL SECURITY (RLS) POLICIES
-- ----------------------------------------------------------------------------
ALTER TABLE leads ENABLE ROW LEVEL SECURITY;
ALTER TABLE conversations ENABLE ROW LEVEL SECURITY;
ALTER TABLE messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE followups ENABLE ROW LEVEL SECURITY;
ALTER TABLE events ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE policyname = 'service_role_all_leads') THEN
    CREATE POLICY service_role_all_leads ON leads FOR ALL TO service_role USING (true) WITH CHECK (true);
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
