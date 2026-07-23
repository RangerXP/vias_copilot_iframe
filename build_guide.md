# Pattern 1 – Context Injection Agent
## Power BI Embedded Context-Aware AI Assistant

### Objective

Build an AI assistant that can answer questions about the specific report state currently displayed within a Power BI Embedded (App-Owns-Data) solution.

The assistant does not interact directly with the report iframe. Instead, the hosting application captures the active report context and injects that context into the chat backend's query to the Fabric Data Agent, which queries the same semantic model powering the embedded analytics experience.

The resulting architecture provides a Copilot-like user experience while remaining compatible with Power BI Embedded architectures where native Copilot capabilities are unavailable.

---

## Business Goal

Enable users of the PBIE portal to ask questions such as:

- Why did approval rates decrease?
- Show me the highest risk merchant in this view.
- Explain this chart.

without manually re-entering the filters currently applied within the report.

The AI assistant should behave as if it understands the report state currently visible to the user.

---

## Architecture Overview

```text
User
 │
 ▼
PBIE Portal
 │
 ├─ Embedded Report
 │
 ├─ AI Chat Panel
 │
 └─ Context Service
         │
         ▼
Fabric Data Agent (chat backend query layer)
         │
         ▼
Power BI Semantic Model
```

The Portal is the source of truth for report state.

The Semantic Model is the source of truth for business answers.

The chat backend's query layer is responsible for reasoning.

---

## Repository Structure

```text
pbie-context-agent/

├── frontend/
│   ├── embedded-report/
│   ├── chat-panel/
│   └── context-capture/
│
├── backend/
│   ├── api/
│   ├── context-service/
│   └── fabric-agent/
│
├── semantic/
│   ├── dax/
│   └── metadata/
│
├── docs/
│   ├── architecture.md
│   └── build_guide.md
│
└── infra/
    ├── bicep/
    └── terraform/
```

---

## Phase 1 Deliverable

### Report Context Capture

Capture:

- Current report
- Current page
- Active slicers
- Report filters
- Page filters
- Visual selections

Initial goal:

```json
{
  "reportId": "merchant_summary",
  "page": "customer_risk",
  "filters": [
    {
      "field": "Region",
      "value": "North America"
    }
  ],
  "slicers": [
    {
      "field": "Merchant",
      "value": "Costco"
    }
  ]
}
```

No AI yet.

Validate:

> Can we accurately reproduce current report state?

---

## Phase 2 Deliverable

### Context Service

Create a service responsible for translating PBIE state into a normalized object.

PBIE objects are not ideal for LLM consumption.

Translate:

```json
{
  "field": "MerchantName",
  "value": "Costco"
}
```

into:

```json
{
  "businessContext": {
    "Merchant": "Costco"
  }
}
```

Output should be business-friendly.

---

## Phase 3 Deliverable

### Chat Backend Integration

Build a chat route that accepts:

```json
{
  "question": "Why are declines increasing?",
  "context": {
    "Merchant": "Costco",
    "Region": "North America",
    "DateRange": "Last 90 Days"
  }
}
```

Query template:

```text
The user is viewing:

Merchant = Costco
Region = North America
Date Range = Last 90 Days

Answer the question in the context of the currently displayed analytics.

Question:
Why are declines increasing?
```

At this phase we are validating:

- Query grounding
- Context injection
- User experience

No advanced DAX generation required.

---

## Phase 4 Deliverable

### Semantic Model Query Layer

Replace simple query-layer reasoning with semantic-model-backed answers.

Workflow:

```text
Question
+
Context
        │
        ▼
Chat Backend
        │
        ▼
Generate Query
        │
        ▼
Semantic Model
        │
        ▼
Result
        │
        ▼
Natural Language Response
```

This becomes the production architecture.

---

## Key Components

### 1. Context Capture Layer

Responsible for capturing embedded Power BI state from the host application.

Candidate interaction points:

```typescript
getFilters()
getPages()
getVisuals()
getSlicerState()
```

Produces current report state.

---

### 2. Context Service

Converts PBIE terminology into business terminology.

Example:

```text
merchant_id
```

becomes:

```text
Merchant
```

This improves AI answer quality by ensuring the chat backend's query to the Fabric Data Agent receives business-readable context rather than raw report metadata alone.

---

### 3. Chat Backend Query Layer

Responsibilities:

- Context injection
- Query construction
- DAX query shape mapping

Not responsible for:

- Report state management
- Semantic model access control
- PBIE interaction

---

### 4. Semantic Model

Single source of truth.

The agent should never compute business answers independently.

All metric calculations should originate from:

- Measures
- KPIs
- Relationships
- Business logic

contained in the Power BI semantic model.

---

## Success Criteria

The system should correctly answer:

- What am I looking at?
- Summarize this page.
- Why is this metric trending down?
- Which merchant contributes most to this result?

while maintaining alignment with the current PBIE report state.

---

## Recommended POC Build Order

### Sprint 1: Context Capture to JSON Output

Prove the portal can capture an accurate representation of the current embedded report state.

### Sprint 2: Context Service to Business Context Object

Normalize raw PBIE state into business-friendly metadata that can be consumed by the agent.

### Sprint 3: Chat Backend to Context-Aware Responses

Send user questions plus report state into the chat backend's query layer and validate that responses are grounded in the current report context.

### Sprint 4: Semantic Model Query Tool to Production Answering

Introduce semantic-model-backed query execution so answers are grounded in governed measures and model logic.

### Sprint 5: Conversation Memory and Multi-Page Context

Add session awareness, page transitions, prior questions, and multi-page report context.

---

## North Star

Phase 2 architecture evolves into:

```text
PBIE
+
Context Service
+
Chat Backend Query Layer
+
Semantic Model
+
Knowledge Sources
+
RAG
```

At that point the assistant effectively becomes:

> Copilot for Embedded Analytics

without requiring native Copilot support inside the Power BI Embedded experience.

---

## Development Framing for PG Review

Pattern 1 should be positioned as a compatibility architecture for App-Owns-Data embedded analytics scenarios where native Copilot in Power BI is not available inside the PBIE iframe.

The framework does not attempt to modify or extend the embedded report runtime. Instead, it uses the hosting application as the orchestration boundary. The host application captures report state, normalizes it, and sends it to the chat backend, which queries the same governed semantic model used by the embedded report via the Fabric Data Agent.

This keeps PBIE responsible for visualization, the semantic model responsible for business logic, and the chat backend responsible for conversational reasoning.
