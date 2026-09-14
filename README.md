# 🚀 Meta Ads → WhatsApp AI Lead Qualification & Automation System

A production-grade, highly resilient automation engine designed to process **300–1,000+ Meta Ads leads per month**, executing real-time conversational qualification, categorization, multi-stage follow-ups, and sales handoffs over WhatsApp.

---

## 📌 Executive Summary

This repository contains the architecture, workflow designs, database schemas, and operational standards for an automated sales engine.

### Core Objective
Transform basic, raw Meta Ads leads into rich, fully qualified lead profiles through automated, multi-turn WhatsApp conversations powered by **n8n**, **Supabase**, **WhatsApp Business Cloud API**, and **OpenAI**.

```
  META ADS LEAD (Basic Info)
             ↓
  RAW META GOOGLE SHEET (Append-Only Intake Buffer)
             ↓
  n8n ORCHESTRATOR (Trigger, E.164 Normalization, RPC Ingest)
             ↓
  SUPABASE POSTGRESQL (Authoritative System Memory & State)
             ↓
  WHATSAPP CLOUD API ↔ CUSTOMER (Converse & Extract Context)
             ↓
  DETERMINISTIC BUSINESS RULES (Qualification, Handoff & Followup)
             ↓
  CLIENT CRM GOOGLE SHEET (Client-Facing Operational View)
```

---

## 🏗️ High-Level System Architecture

```
                       ┌─────────────────────────┐
                       │   META ADS PLATFORM     │
                       └────────────┬────────────┘
                                    │ Generates Lead
                                    v
                       ┌─────────────────────────┐
                       │  RAW META GOOGLE SHEET  │
                       └────────────┬────────────┘
                                    │ New Row Trigger
                                    v
                       ┌─────────────────────────┐
                       │    n8n ORCHESTRATOR     │
                       │ (E.164 Ingestion RPC)   │
                       └────────────┬────────────┘
                                    │
                                    v
                       ┌─────────────────────────┐
                       │   SUPABASE (PostgreSQL) │ ◄── [System Source of Truth]
                       └────────────┬────────────┘
                                    │
                                    v
                       ┌─────────────────────────┐
                       │  WHATSAPP CLOUD API     │
                       └────────────┬────────────┘
                                    │ Initial Outreach
                                    v
                       ┌─────────────────────────┐
                       │        CUSTOMER         │
                       └────────────┬────────────┘
                                    │ WhatsApp Reply
                                    v
                       ┌─────────────────────────┐
                       │  WHATSAPP WEBHOOK (n8n) │ ◄── [Idempotent Entrypoint]
                       └────────────┬────────────┘
                                    │ Load Context
                                    v
                       ┌─────────────────────────┐
                       │     SUPABASE MEMORY     │ (Profile + Summary + History)
                       └────────────┬────────────┘
                                    │ Hydrated Prompt
                                    v
                       ┌─────────────────────────┐
                       │  OPENAI API (GPT-4o)    │
                       └────────────┬────────────┘
                                    │ Structured JSON Output
                                    v
                       ┌─────────────────────────┐
                       │ VALIDATION & RULES ENGINE│ ◄── [Deterministic Guardrails]
                       └────────────┬────────────┘
                                    │
         ┌──────────────────────────┼──────────────────────────┐
         │ (Category: HOT)          │ (Category: WARM)         │ (Category: COLD / OPT-OUT)
         v                          v                          v
┌─────────────────┐        ┌──────────────────┐       ┌─────────────────┐
│  HUMAN HANDOFF  │        │ FOLLOW-UP ENGINE │       │  STOP AUTOMATION│
│ (Notify Sales)  │        │ (Atomic Claiming)│       │ (Flag Opt-Out)  │
└────────┬────────┘        └────────┬─────────┘       └────────┬────────┘
         │                          │                          │
         └──────────────────────────┼──────────────────────────┘
                                    │ Sync State
                                    v
                       ┌─────────────────────────┐
                       │   CLIENT CRM SHEET      │ ◄── [Client Operational View]
                       └─────────────────────────┘
```

---

## 🛠️ Technology Stack & Operational Boundaries

| Layer | Technology | Primary Responsibility | Architectural Constraints |
| :--- | :--- | :--- | :--- |
| **Lead Source** | Meta Ads / Lead Forms | Generates initial raw leads. | Raw input only. **Not** a database. |
| **Raw Ingestion** | Google Sheets (Raw Sheet) | Holds raw incoming lead records. | Append-only raw data source. Must be preserved untouched. |
| **Orchestration** | n8n | Workflow execution, webhooks, retries, scheduling, API coordination. | **Not** a permanent database. Processes statelessly. |
| **System Memory** | Supabase (PostgreSQL) | **Authoritative System Source of Truth** for state, profiles, submissions, messages, & audit history. | All application decisions rely on Supabase state. |
| **Channel** | WhatsApp Business Cloud API | Two-way lead communication, message delivery, webhooks. | Governed by Meta 24-hr windows & approved templates. |
| **Intelligence** | OpenAI API (Structured JSON) | Intent extraction, conversational response, qualification scoring, entity recognition. | Must **never** execute direct system actions. All output is validated. |
| **Client UI** | Google Sheets (CRM Sheet) | Clean, client-facing operational view with score, status, & summaries. | Read-only synchronized view from Supabase. **Not** authoritative. |

---

## 🗄️ Database Architecture (Supabase / PostgreSQL)

The database schema is normalized into six core domain tables:

```
                  ┌─────────────────┐
                  │      leads      │ ◄──────────────────────────────┐
                  └────────┬────────┘                                │
                           │ 1                                       │ 1
       ┌───────────────────┼───────────────────┬───────────────────┐ │
     N │                 N │                 N │                 N │ │ N
┌──────┴───────────┐ ┌─────┴──────────┐ ┌──────┴───────────┐ ┌─────┴─┴──────┐
│lead_submissions  │ │ conversations  │ │   followups      │ │   events     │
└──────────────────┘ └─────┬──────────┘ └──────────────────┘ └──────────────┘
                           │ 1
                           │
                           │ N (Composite FK Constraint)
                     ┌─────┴──────────┐
                     │    messages    │
                     └────────────────┘
```

### Table & Column Specifications

#### 1. `leads` (Canonical Identity & Evolving Business Profile)
* `id` (UUID, Primary Key)
* `phone` (VARCHAR, Unique, Canonical E.164 format)
* `whatsapp_number` (VARCHAR, Nullable E.164 format)
* `first_meta_lead_id` (VARCHAR, Original Meta Submission ID)
* `latest_meta_lead_id` (VARCHAR, Most Recent Meta Submission ID)
* `meta_lead_id` (VARCHAR, Partial Unique Index)
* `name` (VARCHAR), `email` (VARCHAR)
* `status` (`lead_status_enum`: `'NEW'`, `'VALIDATED'`, `'CONTACTED'`, `'CONVERSATION_ACTIVE'`, `'QUALIFYING'`, `'CLOSED'`)
* `lead_category` (`lead_category_enum`: `'NEW'`, `'HOT'`, `'WARM'`, `'COLD'`, `'INVALID'`)
* `lead_score` (INT, 0-100 `CHECK`)
* `intent` (VARCHAR), `requirements` (JSONB), `ai_summary` (TEXT)
* `human_handoff` (BOOL, Default `FALSE`), `ai_active` (BOOL, Default `TRUE`), `opted_out` (BOOL, Default `FALSE`)
* `last_inbound_at`, `last_outbound_at`, `last_contact_at`, `next_followup_at` (TIMESTAMPTZ)
* `created_at`, `updated_at` (TIMESTAMPTZ)

#### 2. `lead_submissions` (Complete Meta Lead Submission History)
* `id` (UUID, Primary Key)
* `lead_id` (UUID, FK $\rightarrow$ `leads.id` `ON DELETE CASCADE`)
* `meta_lead_id` (VARCHAR, Partial Unique Index)
* `meta_form` (VARCHAR), `meta_source` (VARCHAR)
* `meta_created_at` (TIMESTAMPTZ)
* `raw_payload` (JSONB)
* `created_at` (TIMESTAMPTZ)

#### 3. `conversations` (Session Tracking & Single Active Index)
* `id` (UUID, Primary Key)
* `lead_id` (UUID, FK $\rightarrow$ `leads.id` `ON DELETE RESTRICT`)
* `status` (`conversation_status_enum`: `'ACTIVE'`, `'PAUSED'`, `'HANDED_OFF'`, `'CLOSED'`)
* `started_at`, `last_activity_at`, `created_at`, `updated_at` (TIMESTAMPTZ)
* **Constraints**: Composite Unique `uq_conversations_id_lead UNIQUE(id, lead_id)`; Partial Unique Index `idx_conversations_single_active` on `(lead_id) WHERE status = 'ACTIVE'`.

#### 4. `messages` (Message Log & Composite Foreign Key Guard)
* `id` (UUID, Primary Key)
* `lead_id` (UUID, FK $\rightarrow$ `leads.id`)
* `conversation_id` (UUID, FK)
* `whatsapp_message_id` (VARCHAR, Partial Unique Index)
* `direction` (`message_direction_enum`: `'INBOUND'`, `'OUTBOUND'`)
* `delivery_status` (`message_status_enum`: `'PENDING'`, `'SENT'`, `'DELIVERED'`, `'READ'`, `'FAILED'`)
* `message_type` (VARCHAR), `message_body` (TEXT), `raw_payload` (JSONB)
* `occurred_at`, `created_at` (TIMESTAMPTZ)
* **Constraints**: Composite FK `fk_messages_conversation_lead (conversation_id, lead_id) REFERENCES conversations(id, lead_id)` (Guarantees at schema level that message `lead_id` matches its conversation `lead_id`).

#### 5. `followups` (Atomic Queue & Worker Claiming)
* `id` (UUID, Primary Key)
* `lead_id` (UUID, FK $\rightarrow$ `leads.id` `ON DELETE CASCADE`)
* `scheduled_for` (TIMESTAMPTZ)
* `status` (`followup_status_enum`: `'SCHEDULED'`, `'PROCESSING'`, `'SENT'`, `'CANCELLED'`, `'COMPLETED'`, `'FAILED'`)
* `template_name` (VARCHAR), `attempt_count` (INT)
* `claimed_at` (TIMESTAMPTZ), `claimed_by` (VARCHAR)
* `error_log` (TEXT), `invalidated_reason` (TEXT)
* `created_at`, `updated_at` (TIMESTAMPTZ)

#### 6. `events` (Audit & Observability Trail)
* `id` (UUID, Primary Key)
* `lead_id` (UUID, FK $\rightarrow$ `leads.id` `ON DELETE CASCADE`)
* `event_type` (VARCHAR)
* `payload` (JSONB)
* `created_at` (TIMESTAMPTZ)

---

## ⚡ Concurrency & Security Architecture

### 1. E.164 Phone Normalization (`normalize_phone_e164`)
* Strips spaces, dashes, parentheses, and leading zeros.
* Handles Indian local 10-digit numbers (`9876543210` $\rightarrow$ `+919876543210`) and 11-digit numbers with leading zero (`09876543210` $\rightarrow$ `+919876543210`).
* Preserves explicit international E.164 strings (`+447911123456`).
* Rejects invalid digit lengths ($<7$ or $>15$ digits) by returning `NULL`.

### 2. Atomic Meta Lead Ingestion (`ingest_meta_lead` RPC)
All lead ingestions execute via a single `SECURITY DEFINER` function with PostgreSQL row-level locks (`FOR UPDATE`) and `ON CONFLICT` handlers:
* **Duplicate Retry Guard**: Returns existing `lead_id` if `meta_lead_id` was already ingested.
* **Phone Deduplication**: Upserts existing lead, increments `resubmission_count`, records new entry in `lead_submissions`, and logs `META_FORM_RESUBMITTED` event.
* **Security Lock-Down**: `REVOKE EXECUTE ON FUNCTION ... FROM PUBLIC, anon, authenticated; GRANT EXECUTE TO service_role;`

### 3. Atomic Worker Claiming & Stale Task Recovery (`claim_scheduled_followups` RPC)
* Atomically claims due `SCHEDULED` tasks using `FOR UPDATE OF f SKIP LOCKED`.
* Resets stale tasks stuck in `'PROCESSING'` (`claimed_at < NOW() - 5 minutes`) back to `'SCHEDULED'` if under max attempt threshold (default 5).
* Automatically filters out `opted_out = TRUE`, `human_handoff = TRUE`, `ai_active = FALSE`, or `status = 'CLOSED'` leads.

### 4. Message Delivery State Machine (`update_message_delivery_status` RPC)
* Enforces non-reversing state transition rules (e.g. `READ` $\rightarrow$ `SENT` or `DELIVERED` $\rightarrow$ `PENDING` rejected).

---

## 🔍 Verification Status & Deployment Notes

* **Static Migration & PL/pgSQL Code Audit**: **VERIFIED & PASSED** (All 38 test categories statically audited in [`supabase/tests/phase1_test_suite.sql`](file:///c:/Users/Vicky%20Patel/Desktop/1st%20Year/Automation/supabase/tests/phase1_test_suite.sql)).
* **Remote Supabase Deployment**: **PENDING** (Prepared and hardened; remote deployment pending project connection credentials).

---

## 📄 License

This project is proprietary and confidential. Internal client use only.
