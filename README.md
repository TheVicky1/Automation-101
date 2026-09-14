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
  WHATSAPP CONVERSATION (Customer Context)
             ↓
  OPENAI EXTRACTION (Structured Business Intelligence)
             ↓
  DETERMINISTIC BUSINESS RULES (Qualification & Actioning)
             ↓
  SUPABASE PERSISTENCE + CLIENT CRM SYNC (Hot / Warm / Cold / Handoff)
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
                       │ (Validate/Normalize/Dedupe)
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
│ (Notify Sales)  │        │ (Scheduled Task) │       │ (Flag Opt-Out)  │
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
| **System Memory** | Supabase (PostgreSQL) | **Authoritative System Source of Truth** for state, profiles, messages, & audit history. | All application decisions rely on Supabase state. |
| **Channel** | WhatsApp Business Cloud API | Two-way lead communication, message delivery, webhooks. | Governed by Meta 24-hr windows & approved templates. |
| **Intelligence** | OpenAI API (Structured JSON) | Intent extraction, conversational response, qualification scoring, entity recognition. | Must **never** execute direct system actions. All output is validated. |
| **Client UI** | Google Sheets (CRM Sheet) | Clean, client-facing operational view with score, status, & summaries. | Read-only synchronized view from Supabase. **Not** authoritative. |

> [!IMPORTANT]
> **What This System Is NOT**: This is a production **automation system**, not a multi-tenant SaaS application. Do **NOT** add user auth, login portals, billing, or complex frontend frameworks.

---

## 💎 Core Data Principles

### 1. Evolving Lead State Model
Initial Meta Ads data is minimal. The system progressively builds a complete lead profile through WhatsApp dialogue:

$$\text{Meta Raw Data} + \text{WhatsApp Dialogue} + \text{AI Entity Extraction} + \text{Qualification Rules} = \text{Canonical Lead Profile}$$

* **Initial State (Meta)**: `Name: Rahul`, `Phone: +919876543210`, `Email: null`
* **Turn 1 (WhatsApp)**: Customer requests "3BHK in Bangalore" $\rightarrow$ `Requirement: 3BHK`, `Location: Bangalore`
* **Turn 2 (WhatsApp)**: Customer states "Budget around 80 Lakhs" $\rightarrow$ `Budget: ₹80L`, `Category: WARM`, `Score: 68`
* **Turn 3 (WhatsApp)**: Customer asks "Can someone call me tomorrow?" $\rightarrow$ `Intent: HIGH`, `Category: HOT`, `Human Handoff: TRUE`, `AI Active: FALSE`

### 2. Phone Number Canonicalization
* Phone numbers **must strictly be treated as strings**, never numeric values.
* Handles spreadsheet exponential formatting (e.g., `9.72E+11` $\rightarrow$ `+919720000000`).
* Mandatory normalization to **E.164 format** (e.g., `+919876543210`) *prior* to deduplication.
* Cleans leading zeros, spaces, hyphens, and country code variations.

### 3. Missing Data Resilience
* Incoming Meta fields may be incomplete (`Email`, `WhatsApp number`, `Secondary phone`, `Labels`, or `Owner` may be `NULL`).
* The system must execute intake workflows gracefully without throwing uncaught exceptions when optional fields are missing.

---

## 🗄️ Database Architecture (Supabase / PostgreSQL)

The database schema is normalized into five core domain tables:

```
                  ┌──────────────┐
                  │    leads     │ ◄──────────────────┐
                  └──────┬───────┘                    │
                         │ 1                          │ 1
                         │                            │
            ┌────────────┼────────────┐               │
          N │          N │          N │               │ N
    ┌───────┴──────┐ ┌───┴──────┐ ┌───┴──────┐ ┌──────┴───────┐
    │conversations │ │ messages │ │followups │ │   events     │
    └──────────────┘ └──────────┘ └──────────┘ └──────────────┘
```

### Table Specifications

#### 1. `leads` (Lead Identity & Evolving State)
* `id` (UUID, Primary Key)
* `phone` (VARCHAR, Unique, E.164 format)
* `whatsapp_number` (VARCHAR)
* `name` (VARCHAR)
* `email` (VARCHAR, Nullable)
* `meta_created_at` (TIMESTAMPTZ)
* `meta_source`, `meta_form`, `meta_channel`, `meta_stage`, `meta_owner`, `meta_labels` (JSONB / TEXT)
* `lead_category` (ENUM: `'NEW'`, `'HOT'`, `'WARM'`, `'COLD'`, `'INVALID'`)
* `lead_score` (INT, 0-100)
* `intent` (VARCHAR)
* `requirements` (JSONB - e.g., `{ "property_type": "3BHK", "budget": "80L", "location": "Bangalore" }`)
* `ai_summary` (TEXT)
* `human_handoff` (BOOLEAN, Default: `FALSE`)
* `ai_active` (BOOLEAN, Default: `TRUE`)
* `opted_out` (BOOLEAN, Default: `FALSE`)
* `last_contact_at` (TIMESTAMPTZ)
* `next_followup_at` (TIMESTAMPTZ, Nullable)
* `created_at`, `updated_at` (TIMESTAMPTZ)

#### 2. `conversations` (Session Tracking)
* `id` (UUID, Primary Key)
* `lead_id` (UUID, Foreign Key $\rightarrow$ `leads.id`)
* `status` (ENUM: `'ACTIVE'`, `'PAUSED'`, `'HANDED_OFF'`, `'CLOSED'`)
* `started_at` (TIMESTAMPTZ)
* `last_activity_at` (TIMESTAMPTZ)

#### 3. `messages` (Granular Message Log & Idempotency)
* `id` (UUID, Primary Key)
* `lead_id` (UUID, Foreign Key $\rightarrow$ `leads.id`)
* `conversation_id` (UUID, Foreign Key $\rightarrow$ `conversations.id`)
* `whatsapp_message_id` (VARCHAR, Unique - For Idempotency Check)
* `direction` (ENUM: `'INBOUND'`, `'OUTBOUND'`)
* `message_body` (TEXT)
* `raw_payload` (JSONB)
* `sent_at` (TIMESTAMPTZ)

#### 4. `followups` (Scheduled Tasks State Machine)
* `id` (UUID, Primary Key)
* `lead_id` (UUID, Foreign Key $\rightarrow$ `leads.id`)
* `scheduled_for` (TIMESTAMPTZ)
* `status` (ENUM: `'SCHEDULED'`, `'SENT'`, `'CANCELLED'`, `'COMPLETED'`, `'FAILED'`)
* `attempt_count` (INT, Default: `0`)
* `created_at`, `updated_at` (TIMESTAMPTZ)

#### 5. `events` (Audit & System Observability Trail)
* `id` (UUID, Primary Key)
* `lead_id` (UUID, Foreign Key $\rightarrow$ `leads.id`)
* `event_type` (VARCHAR - e.g., `'LEAD_CREATED'`, `'MESSAGE_RECEIVED'`, `'AI_PROCESSED'`, `'CLASSIFIED_HOT'`, `'FOLLOWUP_CANCELLED'`, `'HUMAN_HANDOFF'`, `'OPT_OUT'`)
* `payload` (JSONB)
* `created_at` (TIMESTAMPTZ)

---

## 🔄 Complete Lead Lifecycle

```
 [ NEW ] ──► [ VALIDATED ] ──► [ CONTACT_ELIGIBLE ] ──► [ CONTACTED ]
                                                              │
                                                              v
 [ OPTED_OUT ] ◄─────────────────────────────────── [ CONVERSATION_ACTIVE ]
       ▲                                                      │
       │                                                      v
 [ CLOSED ] ◄───────── [ HOT / WARM / COLD ] ◄───────── [ QUALIFYING ]
                             │
                             v
                    [ HUMAN_HANDOFF ]
```

---

## ⚙️ Modular n8n Workflow Architecture

The system is decomposed into 12 distinct, bounded sub-workflows to prevent single-point-of-failure monolithic complexity:

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│ MODULAR n8n WORKFLOW PIPELINE                                                   │
├─────────────────────────────────────────────────────────────────────────────────┤
│ WF-01: Lead Intake & Structural Validation                                      │
│ WF-02: Phone Normalization & Deduplication Check                                │
│ WF-03: WhatsApp Initial Template Dispatch & Eligibility Verify                   │
│ WF-04: Inbound Webhook Handling & Idempotency Filter (`wamid` check)             │
│ WF-05: Conversation Context Hydration & OpenAI Prompt Construction              │
│ WF-06: OpenAI Execution & Structured Output Schema Enforcement                  │
│ WF-07: Deterministic Business Guardrails & Qualification Logic                  │
│ WF-08: WhatsApp Outbound Dispatch & Conversation State Sync                     │
│ WF-09: Hot Lead Escalation & Sales Notification Dispatch                        │
│ WF-10: Scheduled Follow-Up Engine & Stale Follow-Up Interruption Filter         │
│ WF-11: Opt-Out Engine & Communication Suppression Enforcement                   │
│ WF-12: Client CRM Google Sheet Sync                                            │
└─────────────────────────────────────────────────────────────────────────────────┘
```

---

## 🛡️ AI vs. Deterministic Business Guardrails

> [!CAUTION]
> **Critical Architectural Rule**: The LLM interprets language; deterministic code executes decisions. Never grant the AI autonomous control over infrastructure actions or system flags.

```
                  ┌─────────────────────────────────────────┐
                  │            INBOUND MESSAGE              │
                  └────────────────────┬────────────────────┘
                                       │
                                       v
                  ┌─────────────────────────────────────────┐
                  │            OPENAI INFERENCE             │
                  │  • Extracts Intent & Requirements       │
                  │  • Proposes Reply & Lead Score         │
                  └────────────────────┬────────────────────┘
                                       │ Raw JSON Output
                                       v
                  ┌─────────────────────────────────────────┐
                  │    DETERMINISTIC RULES ENGINE (n8n)     │
                  ├─────────────────────────────────────────┤
                  │ 1. Validate JSON against Schema         │
                  │ 2. IF opted_out == TRUE ──► STOP        │
                  │ 3. IF human_handoff == TRUE ──► PAUSE   │
                  │ 4. IF score >= 80 ──► Set HOT & Handoff │
                  │ 5. IF wamid exists ──► Ignore Duplicate │
                  │ 6. IF pending follow-up ──► CANCEL      │
                  └────────────────────┬────────────────────┘
                                       │ Validated Execution
                                       v
                  ┌─────────────────────────────────────────┐
                  │      DATABASE UPDATE & OUTREACH         │
                  └─────────────────────────────────────────┘
```

| Decision / Feature | OpenAI Responsibility | Deterministic Rules Responsibility |
| :--- | :--- | :--- |
| **User Intent & Sentiment** | Interprets customer message context & implicit needs. | Maps raw intent string to allowed canonical categories. |
| **Entity Extraction** | Extracts budget, location, requirement fields. | Validates data types, ranges, & sanitizes inputs before DB write. |
| **Lead Category / Score** | Calculates suggested score (0–100) & category. | Enforces hard bounds; overrides score if explicit escalation rules trigger. |
| **Opt-Out Handling** | Detects refusal phrases ("Stop texting me"). | **Hard-stops** all outbound engines immediately; updates `opted_out = TRUE`. |
| **Human Escalation** | Suggests `requires_human: true`. | Disables `ai_active`, sets `human_handoff = TRUE`, triggers Sales alert. |
| **Follow-up Management** | Identifies follow-up need. | **Cancels** pending follow-ups instantly if new customer message arrives. |

---

## ⚡ Edge Cases & Production Reliability Guards

### 1. Idempotency Guarantee
* Every WhatsApp inbound webhook contains a unique `wamid`.
* n8n performs an atomic deduplication check against the `messages` table before invoking OpenAI.
* Prevents duplicate AI invocations and double outbound messages during Meta webhook retries.

### 2. Follow-Up Interruption Logic
* When a customer sends a message, n8n executes an immediate SQL update:
  ```sql
  UPDATE followups
  SET status = 'CANCELLED', updated_at = NOW()
  WHERE lead_id = $1 AND status = 'SCHEDULED';
  ```
* Prevents sending outdated follow-ups (e.g., sending "Are you still interested?" after the user has already replied asking for pricing).

### 3. Strict Schema Validation for OpenAI Output
Expected JSON payload enforced via JSON Schema validation node in n8n:
```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "type": "object",
  "properties": {
    "reply": { "type": "string" },
    "intent": { "type": "string" },
    "lead_score": { "type": "integer", "minimum": 0, "maximum": 100 },
    "lead_category": { "type": "string", "enum": ["HOT", "WARM", "COLD"] },
    "confidence": { "type": "number", "minimum": 0.0, "maximum": 1.0 },
    "summary": { "type": "string" },
    "requirements": {
      "type": "object",
      "properties": {
        "property_type": { "type": ["string", "null"] },
        "budget": { "type": ["string", "null"] },
        "location": { "type": ["string", "null"] }
      }
    },
    "requires_human": { "type": "boolean" },
    "follow_up_required": { "type": "boolean" }
  },
  "required": ["reply", "lead_score", "lead_category", "requires_human"]
}
```

---

## 📈 System Scale & Performance Target

* **Target Monthly Leads**: $300 \text{ to } 1,000+$ new leads/month.
* **Estimated Message Volume**: $3,000 \text{ to } 10,000+$ messages/month.
* **Database Optimization**: Indexed on `leads(phone)`, `leads(lead_category)`, `messages(whatsapp_message_id)`, and `followups(scheduled_for, status)`.

---

## 📋 Pre-Flight Client Verification & Business Audits

Before activating the production pipeline, the following 10 items must be explicitly audited and verified:

- [ ] **1. Phone vs. WhatsApp Number Audit**: Determine if raw `Phone` column equals `WhatsApp number` in client Meta forms.
- [ ] **2. WhatsApp Consent & Opt-In Policy**: Verify explicit opt-in text on Meta Lead forms.
- [ ] **3. Meta Business Account & WhatsApp Cloud API Setup**: Verify WABA registration and phone number quality rating.
- [ ] **4. Approved Message Templates**: Ensure initial outreach HSM templates are pre-approved by Meta.
- [ ] **5. 24-Hour Messaging Window Compliance**: Verify fallback logic for out-of-session messaging.
- [ ] **6. Supabase Environment Variables**: Confirm database connection strings, Service Role Keys, and RLS policies.
- [ ] **7. n8n Webhook Verification Secrets**: Verify Meta webhook verification tokens and payload signing.
- [ ] **8. OpenAI API Rate Limits & Fallbacks**: Configure model timeouts, retry logic, and fallback responses.
- [ ] **9. Sales Escalation Channel**: Confirm notification target for HOT leads (Slack / WhatsApp / Email / CRM).
- [ ] **10. Client CRM Sheet Mapping**: Validate column header alignment between Supabase sync workflow and the Client Google Sheet.

---

## 📄 License

This project is proprietary and confidential. Internal client use only.
