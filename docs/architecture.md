# Architecture — MSIE PBIE Context-Aware AI Assistant

## System Overview

This document describes the full architecture for Pattern 1 — Context Injection Agent, incorporating a **Microsoft Fabric Data Agent** as the semantic model access layer for the Power BI Embedded experience.

---

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────┐
│  Browser (localhost:3000 during dev / MSIE portal in prod)          │
│                                                                     │
│  ┌─────────────────────────┐    ┌─────────────────────────────┐    │
│  │   PBIE iframe           │    │   AI Chat Panel             │    │
│  │                         │    │                             │    │
│  │  [Embedded Report]      │    │  [Chat Input]               │    │
│  │   page / filters /      │────▶  [Context Capture]          │    │
│  │   slicers / selections  │    │  [Response Display]         │    │
│  └─────────────────────────┘    └──────────┬──────────────────┘    │
└─────────────────────────────────────────────┼───────────────────────┘
                                              │ HTTP POST
                                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│  Node.js Backend (Express)                                          │
│                                                                     │
│  ┌──────────────────┐   ┌──────────────────┐   ┌───────────────┐   │
│  │  /api/embed-token │   │  /api/context    │   │  /api/chat    │   │
│  │  (PBIE token gen) │   │  (context store) │   │  (agent proxy)│   │
│  └──────────────────┘   └──────────────────┘   └───────┬───────┘   │
│                                                         │           │
│  ┌──────────────────────────────────────────────────────▼────────┐  │
│  │  Context Service                                               │  │
│  │  PBIE field names → Business field names (field_map.json)     │  │
│  └──────────────────────────────────────────────────────┬────────┘  │
└─────────────────────────────────────────────────────────┼───────────┘
                                                          │
                        ┌─────────────────────────────────▼────────────┐
                        │  Azure AI Foundry Agent                       │
                        │                                               │
                        │  System prompt: inject context block          │
                        │  Tool: query_semantic_model()                 │
                        │  Memory: conversation history                 │
                        └──────────────────────┬────────────────────────┘
                                               │ Tool call
                                               ▼
                        ┌──────────────────────────────────────────────┐
                        │  Fabric Data Agent                           │
                        │                                              │
                        │  Natural language → DAX translation          │
                        │  Executes queries against semantic model     │
                        │  Returns structured results                  │
                        └──────────────────────┬───────────────────────┘
                                               │
                                               ▼
                        ┌──────────────────────────────────────────────┐
                        │  Microsoft Fabric Semantic Model             │
                        │                                              │
                        │  Tables / Measures / KPIs / Relationships    │
                        │  Single source of truth for business answers │
                        └──────────────────────────────────────────────┘
                                               ▲
                        ┌──────────────────────┘
                        │  Also connects directly for iframe embed:
                        │  Power BI REST API → embed token
                        │  powerbi-client SDK → renders iframe
                        └──────────────────────────────────────────────
```

---

## Component Responsibilities

### Browser Layer

| Component | Responsibility |
|-----------|--------------|
| PBIE iframe | Renders the embedded report; managed entirely by `powerbi-client` SDK |
| Context Capture | Reads filter state, slicers, active page, visual selections from iframe |
| AI Chat Panel | Accepts user questions; displays agent responses; triggers context capture on send |

### Backend Layer

| Component | Responsibility |
|-----------|--------------|
| `/api/embed-token` | Generates App-Owns-Data embed token using service principal |
| `/api/context` | Receives and normalizes context from frontend |
| `/api/chat` | Proxies request to Foundry Agent with context block injected |
| Context Service | Translates PBIE field names to business names via `field_map.json` |

### AI Layer

| Component | Responsibility |
|-----------|--------------|
| Azure AI Foundry Agent | Conversation memory, prompt orchestration, tool calling |
| Fabric Data Agent | Natural language + DAX query execution against Fabric semantic model |

### Data Layer

| Component | Responsibility |
|-----------|--------------|
| Fabric Semantic Model | Tables, measures, KPIs — single source of truth |
| Power BI REST API | Embed token generation for iframe rendering |

---

## Data Flow — User Question with Active Filters

```
1. User sets slicer: Merchant = Costco
2. User types: "Why are declines increasing?"
3. Frontend captureContext() called:
   → { page: "risk_summary", slicers: [{ Merchant: "Costco" }], filters: [...] }
4. POST /api/chat:
   → { question: "Why are declines increasing?", rawContext: { ... } }
5. Context Service normalizes:
   → { Merchant: "Costco", Region: "North America", DateRange: "Last 90 Days" }
6. Foundry Agent receives:
   → system prompt with injected context block + user question
7. Foundry Agent calls tool: query_semantic_model("decline trend for Costco last 90 days", context)
8. Fabric Data Agent:
   → translates to DAX → executes → returns results
9. Foundry Agent composes natural language response
10. Response rendered in chat panel
```

---

## Fabric Integration Detail

### Why Fabric Data Agent (not direct XMLA)?

| Approach | Pros | Cons |
|----------|------|------|
| Fabric Data Agent | Natural language query, no DAX authoring, governed | Requires provisioning, GA status |
| XMLA endpoint direct | Full DAX control, well-documented | Requires DAX generation in agent |
| REST API + DAX | Maximum control | Complex auth, DAX authoring required |

**Recommendation:** Fabric Data Agent for Sprint 3–4. Fall back to XMLA if agent not available for target model.

### Fabric Data Agent Auth Flow

```
Backend service principal
       │
       ▼ Entra ID token (scope: fabric.agent.execute)
       │
       ▼
Fabric Data Agent endpoint
       │  (agent ID from model discovery)
       ▼
Semantic Model query execution
```

---

## Local Dev vs Production Comparison

| Concern | Local Dev | Production |
|---------|-----------|-----------|
| Server | `localhost:3000` (Node/Express) | Azure App Service or Container Apps |
| Embed token | Generated from dev service principal | Generated from prod service principal |
| Fabric model | Same Fabric workspace | Same Fabric workspace |
| Foundry Agent | Dev Foundry project | Prod Foundry project |
| CORS | Disabled / localhost only | Configured for portal domain |
| Auth | Dev credentials in `.env` | Managed Identity |

---

## Security Considerations

- Embed tokens are short-lived (1 hour); implement token refresh on expiry
- Service principal credentials stored in `.env` only — never committed to git
- Fabric Data Agent access scoped to semantic model read-only
- Context object sanitized before prompt injection (no raw user input in system prompt)
- Foundry Agent does not have write access to any data source
