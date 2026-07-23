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
                        │  /api/chat (Node.js Express route)            │
                        │                                               │
                        │  Injects context block into query prompt      │
                        │  Calls Fabric Data Agent directly              │
                        └──────────────────────┬────────────────────────┘
                                               │ Query call
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
| `/api/chat` | Injects context block into the query prompt and calls the Fabric Data Agent directly |
| Context Service | Translates PBIE field names to business names via `field_map.json` |

### AI Layer

| Component | Responsibility |
|-----------|--------------|
| Fabric Data Agent | Natural language + DAX query execution against Fabric semantic model, called directly from `/api/chat` |

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
6. `/api/chat` builds a query prompt with the injected context block + user question
7. Backend calls the Fabric Data Agent directly: query_semantic_model("decline trend for Costco last 90 days", context)
8. Fabric Data Agent:
   → translates to DAX → executes → returns results
9. Backend synthesizes the results into a natural language response
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
| CORS | Disabled / localhost only | Configured for portal domain |
| Auth | Dev credentials in `.env` | Managed Identity |

---

## Security Considerations

- Embed tokens are short-lived (1 hour); `tokenExpired` event handled in `embed.js` — refresh preserves `effectiveIdentity`
- Service principal credentials stored in `.env` only — never committed to git (`.gitignore` enforced)
- Fabric Data Agent access scoped to semantic model read-only
- Context object sanitized before query prompt injection (no raw user input passed unvalidated)
- The chat backend does not have write access to any data source

---

## Auth Boundary — External User Access

Iframe consumers are **external (B2B guest) users**. Two paths are defined:

### Path B — Active (current implementation)

The service principal makes all API calls. User data boundary is enforced at two levels:

1. **`effectiveIdentity` in embed token** — SP generates an embed token with the user's UPN, causing the Power BI engine to enforce any RLS roles on the semantic model for that user
2. **Context injection** — `captureContext.js` reads only what is visible in the user's filtered iframe view; the chat backend's query to the Fabric Data Agent is scoped to that context

No user token ever reaches the backend for Fabric API calls.

### Path A — Production gate (not yet active)

Requires customer tenant admin to configure Entra cross-tenant access policy (inbound B2B for the external org). Once enabled, MSAL.js can acquire guest user tokens scoped to `https://api.fabric.microsoft.com/.default` and pass them to the backend, replacing SP credentials for Fabric Data Agent calls.

### Fabric Tenant Policy Status (audited 2026-07-21)

| Setting | Status |
|---------|--------|
| `Embedding` — Embed content in apps | ✅ Enabled |
| `ServicePrincipalAccessPermissionAPIs` — SP can call Fabric public APIs | ✅ Enabled |
| `AllowGuestUserToAccessSharedContent` — Guest users can access Microsoft Fabric | ✅ Enabled |
| `ElevatedGuestsTenant` — Guest users can browse and access Fabric content | ✅ **Enabled 2026-07-21** |
| Entra cross-tenant B2B inbound default policy | ✅ Open (allows all) |
