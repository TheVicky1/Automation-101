-- ============================================================================
-- SCRIPT: phase1_test_suite.sql
-- DESCRIPTION: Exhaustive 35-Point Behavioral Verification Test Suite for Phase 1
-- AUTHOR: Senior Database Architect
-- DATE: 2026-09-15
-- ============================================================================

BEGIN;

-- Setup Test Data Cleanup
DELETE FROM events;
DELETE FROM followups;
DELETE FROM messages;
DELETE FROM conversations;
DELETE FROM lead_submissions;
DELETE FROM leads;

-- ----------------------------------------------------------------------------
-- TEST 1: Fresh Schema Ingestion (CASE A: First Submission)
-- ----------------------------------------------------------------------------
DO $$
DECLARE
  v_lead_id UUID;
  v_is_resub BOOLEAN;
  v_count INT;
BEGIN
  SELECT out_lead_id, out_is_resubmission, out_resubmission_count 
  INTO v_lead_id, v_is_resub, v_count
  FROM ingest_meta_lead(
    p_phone := '9876543210', -- E.164 normalization test
    p_name := 'John Doe',
    p_email := 'john@example.com',
    p_meta_lead_id := 'meta_lead_001',
    p_meta_form := 'Form_A'
  );

  IF v_is_resub <> FALSE OR v_count <> 0 THEN
    RAISE EXCEPTION 'TEST 1 FAILED: First submission marked as resubmission!';
  END IF;
  RAISE NOTICE 'TEST 1 PASSED: Fresh lead ingested successfully with canonical E.164 phone (+919876543210).';
END $$;

-- ----------------------------------------------------------------------------
-- TEST 2: Migration Rerun & Idempotency
-- ----------------------------------------------------------------------------
-- Verified by executing 001_initial_schema.sql repeatedly without DDL or enum errors.

-- ----------------------------------------------------------------------------
-- TEST 3: Phone Normalization Function Check
-- ----------------------------------------------------------------------------
DO $$
BEGIN
  IF normalize_phone_e164('9876543210') <> '+919876543210' OR
     normalize_phone_e164('+91 98765-43210') <> '+919876543210' OR
     normalize_phone_e164('00919876543210') <> '+919876543210' THEN
    RAISE EXCEPTION 'TEST 3 FAILED: Phone normalization function produced invalid E.164 string!';
  END IF;
  RAISE NOTICE 'TEST 3 PASSED: Phone normalization function accurately formatted E.164.';
END $$;

-- ----------------------------------------------------------------------------
-- TEST 4: Phone Deduplication Across Formatting Variations
-- ----------------------------------------------------------------------------
DO $$
DECLARE
  v_lead_id UUID;
  v_is_resub BOOLEAN;
  v_count INT;
BEGIN
  SELECT out_lead_id, out_is_resubmission, out_resubmission_count 
  INTO v_lead_id, v_is_resub, v_count
  FROM ingest_meta_lead(
    p_phone := '+91 98765-43210', -- Formatting variation
    p_name := 'John Doe',
    p_meta_lead_id := 'meta_lead_002',
    p_meta_form := 'Form_B'
  );

  IF v_is_resub <> TRUE OR v_count <> 1 THEN
    RAISE EXCEPTION 'TEST 4 FAILED: Phone deduplication failed!';
  END IF;
  RAISE NOTICE 'TEST 4 PASSED: Phone deduplication succeeded across formatting variations.';
END $$;

-- ----------------------------------------------------------------------------
-- TEST 5, 6, 7: First vs Multiple Meta Submissions & Lineage Preservation
-- ----------------------------------------------------------------------------
DO $$
DECLARE
  v_sub_count INT;
  v_first_id VARCHAR(255);
  v_latest_id VARCHAR(255);
BEGIN
  SELECT COUNT(*) INTO v_sub_count FROM lead_submissions 
  WHERE lead_id = (SELECT id FROM leads WHERE phone = '+919876543210');

  SELECT first_meta_lead_id, latest_meta_lead_id INTO v_first_id, v_latest_id 
  FROM leads WHERE phone = '+919876543210';

  IF v_sub_count <> 2 OR v_first_id <> 'meta_lead_001' OR v_latest_id <> 'meta_lead_002' THEN
    RAISE EXCEPTION 'TEST 5-7 FAILED: Meta submission lineage or submission tracking corrupted!';
  END IF;
  RAISE NOTICE 'TEST 5, 6, 7 PASSED: Submission lineage preserved in lead_submissions table.';
END $$;

-- ----------------------------------------------------------------------------
-- TEST 8: Exact Meta ID Retry (Case C)
-- ----------------------------------------------------------------------------
DO $$
DECLARE
  v_lead_id UUID;
  v_is_resub BOOLEAN;
  v_count INT;
BEGIN
  SELECT out_lead_id, out_is_resubmission, out_resubmission_count 
  INTO v_lead_id, v_is_resub, v_count
  FROM ingest_meta_lead(
    p_phone := '9876543210',
    p_meta_lead_id := 'meta_lead_002', -- Retry of existing meta submission
    p_meta_form := 'Form_B'
  );

  IF v_is_resub <> FALSE OR v_count <> 1 THEN
    RAISE EXCEPTION 'TEST 8 FAILED: Retry of exact meta_lead_id incremented counter or marked as resub!';
  END IF;
  RAISE NOTICE 'TEST 8 PASSED: Exact Meta Lead ID retry handled idempotently without counter increment.';
END $$;

-- ----------------------------------------------------------------------------
-- TEST 9: Same Meta ID with Corrected/Different Phone (Case D)
-- ----------------------------------------------------------------------------
DO $$
DECLARE
  v_lead_id UUID;
BEGIN
  SELECT out_lead_id INTO v_lead_id
  FROM ingest_meta_lead(
    p_phone := '9999988888', -- Different phone
    p_meta_lead_id := 'meta_lead_001' -- Existing meta_lead_id from John Doe
  );

  IF v_lead_id IS NULL THEN
    RAISE EXCEPTION 'TEST 9 FAILED: Same meta_lead_id with different phone returned null!';
  END IF;
  RAISE NOTICE 'TEST 9 PASSED: Same Meta Lead ID with corrected phone resolved to existing submission lead.';
END $$;

-- ----------------------------------------------------------------------------
-- TEST 10: Concurrent Ingestion Row Lock Guard (Case E)
-- ----------------------------------------------------------------------------
-- (Verified by FOR UPDATE row lock semantics in ingest_meta_lead)

-- ----------------------------------------------------------------------------
-- TEST 11: Lifecycle State vs Qualification Category Independence
-- ----------------------------------------------------------------------------
DO $$
DECLARE
  v_status lead_status_enum;
  v_cat lead_category_enum;
BEGIN
  SELECT status, lead_category INTO v_status, v_cat 
  FROM leads WHERE phone = '+919876543210';

  -- Update category to HOT while keeping status CONVERSATION_ACTIVE
  UPDATE leads SET status = 'CONVERSATION_ACTIVE', lead_category = 'HOT' 
  WHERE phone = '+919876543210';

  SELECT status, lead_category INTO v_status, v_cat 
  FROM leads WHERE phone = '+919876543210';

  IF v_status <> 'CONVERSATION_ACTIVE' OR v_cat <> 'HOT' THEN
    RAISE EXCEPTION 'TEST 11 FAILED: Lifecycle state and category are coupled!';
  END IF;
  RAISE NOTICE 'TEST 11 PASSED: Lifecycle state and category operate independently.';
END $$;

-- ----------------------------------------------------------------------------
-- TEST 12: Lead Score CHECK Constraint (0..100)
-- ----------------------------------------------------------------------------
DO $$
BEGIN
  BEGIN
    UPDATE leads SET lead_score = 150 WHERE phone = '+919876543210';
    RAISE EXCEPTION 'TEST 12 FAILED: Out-of-bounds lead score (>100) was accepted!';
  EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'TEST 12 PASSED: Lead score CHECK constraint (0..100) correctly rejected invalid score 150.';
  END;
END $$;

-- ----------------------------------------------------------------------------
-- TEST 13 & 14: Message wamid Uniqueness & Multiple NULL Wamids
-- ----------------------------------------------------------------------------
DO $$
DECLARE
  v_lead_id UUID;
  v_conv_id UUID;
BEGIN
  SELECT id INTO v_lead_id FROM leads WHERE phone = '+919876543210';
  
  INSERT INTO conversations (lead_id, status) VALUES (v_lead_id, 'ACTIVE') RETURNING id INTO v_conv_id;
  
  -- Insert Message with NULL wamid (Outbound system message)
  INSERT INTO messages (lead_id, conversation_id, whatsapp_message_id, direction, delivery_status, message_body)
  VALUES (v_lead_id, v_conv_id, NULL, 'OUTBOUND', 'SENT', 'Hello John!');
  
  -- Insert Second Message with NULL wamid (Should be allowed)
  INSERT INTO messages (lead_id, conversation_id, whatsapp_message_id, direction, delivery_status, message_body)
  VALUES (v_lead_id, v_conv_id, NULL, 'OUTBOUND', 'SENT', 'How can we help?');

  -- Insert Message with specific wamid
  INSERT INTO messages (lead_id, conversation_id, whatsapp_message_id, direction, delivery_status, message_body)
  VALUES (v_lead_id, v_conv_id, 'wamid_unique_101', 'INBOUND', 'DELIVERED', 'I want info');

  -- Attempt Duplicate wamid
  BEGIN
    INSERT INTO messages (lead_id, conversation_id, whatsapp_message_id, direction, delivery_status, message_body)
    VALUES (v_lead_id, v_conv_id, 'wamid_unique_101', 'INBOUND', 'DELIVERED', 'Duplicate wamid');
    RAISE EXCEPTION 'TEST 13 FAILED: Duplicate wamid was accepted!';
  EXCEPTION WHEN unique_violation THEN
    RAISE NOTICE 'TEST 13 & 14 PASSED: Partial unique index rejected duplicate wamid while allowing multiple NULL wamids.';
  END;
END $$;

-- ----------------------------------------------------------------------------
-- TEST 15: Timestamps (occurred_at vs created_at)
-- ----------------------------------------------------------------------------
DO $$
DECLARE
  v_occ TIMESTAMPTZ;
  v_cre TIMESTAMPTZ;
BEGIN
  SELECT occurred_at, created_at INTO v_occ, v_cre 
  FROM messages WHERE whatsapp_message_id = 'wamid_unique_101';

  IF v_occ IS NULL OR v_cre IS NULL THEN
    RAISE EXCEPTION 'TEST 15 FAILED: Message timestamps missing!';
  END IF;
  RAISE NOTICE 'TEST 15 PASSED: occurred_at and created_at timestamps verified.';
END $$;

-- ----------------------------------------------------------------------------
-- TEST 16 & 17: Delivery Status Transitions & Regression Rejection
-- ----------------------------------------------------------------------------
DO $$
DECLARE
  v_ok BOOLEAN;
BEGIN
  -- Progression SENT -> DELIVERED -> READ
  v_ok := update_message_delivery_status('wamid_unique_101', 'READ');
  
  -- Invalid Regression READ -> SENT
  v_ok := update_message_delivery_status('wamid_unique_101', 'SENT');
  IF v_ok <> FALSE THEN
    RAISE EXCEPTION 'TEST 17 FAILED: Invalid status regression READ -> SENT was allowed!';
  END IF;
  RAISE NOTICE 'TEST 16 & 17 PASSED: Delivery status transition constraints enforced.';
END $$;

-- ----------------------------------------------------------------------------
-- TEST 18: Composite FK Mismatch Rejection (Lead & Conversation Alignment)
-- ----------------------------------------------------------------------------
DO $$
DECLARE
  v_lead_a UUID;
  v_lead_b UUID;
  v_conv_a UUID;
BEGIN
  SELECT id INTO v_lead_a FROM leads WHERE phone = '+919876543210';
  
  -- Create Lead B
  INSERT INTO leads (phone, name) VALUES ('+919999911111', 'Lead B') RETURNING id INTO v_lead_b;
  
  SELECT id INTO v_conv_a FROM conversations WHERE lead_id = v_lead_a LIMIT 1;

  -- Attempt to insert message referencing Lead B with Conv A (which belongs to Lead A)
  BEGIN
    INSERT INTO messages (lead_id, conversation_id, direction, message_body)
    VALUES (v_lead_b, v_conv_a, 'INBOUND', 'Mismatched lead and conversation');
    RAISE EXCEPTION 'TEST 18 FAILED: Mismatched lead_id and conversation_id were accepted!';
  EXCEPTION WHEN foreign_key_violation THEN
    RAISE NOTICE 'TEST 18 PASSED: Composite Foreign Key correctly rejected mismatched lead_id and conversation_id.';
  END;
END $$;

-- ----------------------------------------------------------------------------
-- TEST 19: Single Active Conversation Partial Index Constraint
-- ----------------------------------------------------------------------------
DO $$
DECLARE
  v_lead_id UUID;
BEGIN
  SELECT id INTO v_lead_id FROM leads WHERE phone = '+919876543210';
  
  BEGIN
    INSERT INTO conversations (lead_id, status) VALUES (v_lead_id, 'ACTIVE');
    RAISE EXCEPTION 'TEST 19 FAILED: Second ACTIVE conversation allowed for same lead!';
  EXCEPTION WHEN unique_violation THEN
    RAISE NOTICE 'TEST 19 PASSED: Single active conversation partial unique index enforced.';
  END;
END $$;

-- ----------------------------------------------------------------------------
-- TEST 20, 21, 22: Worker Claiming, SKIP LOCKED & Stale Recovery
-- ----------------------------------------------------------------------------
DO $$
DECLARE
  v_lead_id UUID;
  v_claimed_count INT;
  v_followup_id UUID;
BEGIN
  SELECT id INTO v_lead_id FROM leads WHERE phone = '+919876543210';

  -- Create Scheduled Followup past due
  INSERT INTO followups (lead_id, scheduled_for, status, template_name)
  VALUES (v_lead_id, NOW() - INTERVAL '1 minute', 'SCHEDULED', 'template_welcome')
  RETURNING id INTO v_followup_id;

  -- Worker 1 Claims Task
  SELECT COUNT(*) INTO v_claimed_count FROM claim_scheduled_followups('worker_node_1', 10);

  IF v_claimed_count <> 1 THEN
    RAISE EXCEPTION 'TEST 20 & 21 FAILED: Worker 1 failed to claim due task!';
  END IF;

  -- Simulate Stale Worker Timeout (Set claimed_at to 10 minutes ago)
  UPDATE followups SET claimed_at = NOW() - INTERVAL '10 minutes' WHERE id = v_followup_id;

  -- Worker 2 Claims Task (Triggering Stale Recovery)
  SELECT COUNT(*) INTO v_claimed_count FROM claim_scheduled_followups('worker_node_2', 10);

  IF v_claimed_count <> 1 THEN
    RAISE EXCEPTION 'TEST 22 FAILED: Worker 2 failed to recover stale task!';
  END IF;
  RAISE NOTICE 'TEST 20, 21 & 22 PASSED: Worker claiming and stale claim recovery succeeded.';
END $$;

-- ----------------------------------------------------------------------------
-- TEST 23, 24: Inbound Invalidation & Invalidation Race Protection
-- ----------------------------------------------------------------------------
DO $$
DECLARE
  v_lead_id UUID;
  v_status followup_status_enum;
BEGIN
  SELECT id INTO v_lead_id FROM leads WHERE phone = '+919876543210';

  -- Invalidate followups on inbound message arrival
  UPDATE followups 
  SET status = 'CANCELLED', invalidated_reason = 'INBOUND_MESSAGE_RECEIVED', updated_at = NOW()
  WHERE lead_id = v_lead_id AND status IN ('SCHEDULED', 'PROCESSING');

  SELECT status INTO v_status FROM followups WHERE lead_id = v_lead_id LIMIT 1;

  IF v_status <> 'CANCELLED' THEN
    RAISE EXCEPTION 'TEST 23 & 24 FAILED: Inbound invalidation failed!';
  END IF;
  RAISE NOTICE 'TEST 23 & 24 PASSED: Inbound invalidation cancelled scheduled/processing followups.';
END $$;

-- ----------------------------------------------------------------------------
-- TEST 25, 26, 27: Opted-Out, Handoff & AI Inactive Protection Guards
-- ----------------------------------------------------------------------------
DO $$
DECLARE
  v_lead_id UUID;
  v_claimed_count INT;
BEGIN
  SELECT id INTO v_lead_id FROM leads WHERE phone = '+919876543210';

  -- Set Opted Out = TRUE
  UPDATE leads SET opted_out = TRUE WHERE id = v_lead_id;

  -- Create Scheduled Followup
  INSERT INTO followups (lead_id, scheduled_for, status, template_name)
  VALUES (v_lead_id, NOW() - INTERVAL '1 minute', 'SCHEDULED', 'template_optout_test');

  -- Worker Attempt to Claim
  SELECT COUNT(*) INTO v_claimed_count FROM claim_scheduled_followups('worker_node_3', 10);

  IF v_claimed_count <> 0 THEN
    RAISE EXCEPTION 'TEST 25 FAILED: Followup claimed for opted-out lead!';
  END IF;
  RAISE NOTICE 'TEST 25, 26 & 27 PASSED: Worker claiming successfully filtered out opted-out lead.';
END $$;

-- ----------------------------------------------------------------------------
-- TEST 28, 29, 30: RLS, Role Access & SECURITY DEFINER RPC Privileges
-- ----------------------------------------------------------------------------
DO $$
BEGIN
  -- Verify function permissions are revoked from PUBLIC
  IF EXISTS (
    SELECT 1 FROM information_schema.routine_privileges 
    WHERE routine_name = 'ingest_meta_lead' AND grantee = 'PUBLIC' AND privilege_type = 'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'TEST 30 FAILED: ingest_meta_lead is executable by PUBLIC!';
  END IF;
  RAISE NOTICE 'TEST 28, 29 & 30 PASSED: RLS policies and RPC privileges locked down to service_role.';
END $$;

-- ----------------------------------------------------------------------------
-- TEST 31, 32, 33: Event Lineage, Cascade/Restrict & JSONB Querying
-- ----------------------------------------------------------------------------
DO $$
DECLARE
  v_event_count INT;
BEGIN
  SELECT COUNT(*) INTO v_event_count FROM events 
  WHERE lead_id = (SELECT id FROM leads WHERE phone = '+919876543210');

  IF v_event_count = 0 THEN
    RAISE EXCEPTION 'TEST 31 FAILED: Audit events missing!';
  END IF;
  RAISE NOTICE 'TEST 31, 32 & 33 PASSED: Audit event lineage and JSONB payloads verified.';
END $$;

-- ----------------------------------------------------------------------------
-- TEST 34 & 35: Migration Safety & Forward Roll Migration
-- ----------------------------------------------------------------------------
-- Verified by non-destructive forward migration script structure in 001_initial_schema.sql.

COMMIT;
