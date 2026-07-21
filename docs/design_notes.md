# Design Notes — Implementation Requirements
## VISA Commercial Spend Analytics — PBIE + FilterSession Context Injection (Pattern 2)

**Prepared for:** Customer Implementation Team  
**Pattern:** Host-App Filter Injection + FilterSession Context Grounding  
**Tenant:** `MngEnvMCAP660444.onmicrosoft.com`  
**Last updated:** 2026-07-21  
**Redesign note:** Project scope updated 2026-07-21 from Pattern 1 (slicer-read context injection) to Pattern 2 (host-app filter injection via `setFilters()` + `Fact_FilterSession` grounding). See Section 4 for the updated context flow and Section 11 for the new data model.

---

## Purpose

This document captures the implementation requirements, constraints, and decisions that the development team needs to know before building the Pattern 2 solution. It covers identity, token management, embedding, filter-state ownership, session persistence, and agent grounding.

### Pattern 2 — Host-App Filter Injection (current design)

The host application (VISA Partner Portal) **owns the filter/prompt experience**. The report never uses native Power BI slicers for context-driven filtering. Instead:

```
VISA Partner Portal
  → custom prompt / filter UI
  → accumulated filter state
  → PBIE setFilters()            ← applies state to embedded report
  → Direct Lake semantic model
  → persisted Fact_FilterSession ← same state written to Fabric Lakehouse
  → Foundry / Fabric Data Agent  ← agent receives filter state as grounding context
```

This approach avoids Power BI native slicer interaction issues in embedded scenarios, gives the host app full control over filter state, and allows the agent to query `Fact_FilterSession` directly against the governed semantic model rather than relying on screenshot/DOM capture.

---

## 1. Identity & Service Principal

### What is required

A **native service principal** must be registered in the `MngEnvMCAP660444.onmicrosoft.com` tenant. This SP is used by the backend server to:

1. Acquire embed tokens for the PBIE iframe (Power BI REST API)
2. Query the Fabric Data Agent (Fabric REST API)
3. Optionally, acquire tokens for Azure AI Foundry (if not using Managed Identity)

### Why a native SP is required (not a guest/cross-tenant identity)

This tenant enforces an **inbound communication policy** (`RequestDeniedByInboundPolicy`) that blocks Power BI and Fabric REST API calls from cross-tenant/external identities — even with a valid access token. Guest accounts (e.g., `seankelley@microsoft.com`) cannot call these APIs from outside the tenant. The service principal must be homed in `MngEnvMCAP660444`.

### App registration steps

1. Sign in to **https://entra.microsoft.com** with an account that is a native member of `MngEnvMCAP660444.onmicrosoft.com`
2. Navigate to **App registrations → New registration**
3. Name: `pbie-context-agent-sp` (or similar)
4. Supported account types: **Accounts in this organizational directory only**
5. Add a client secret under **Certificates & secrets**
6. Grant the following **Application permissions** (not Delegated) under **API permissions**:

| API | Permission | Type |
|-----|-----------|------|
| Power BI Service | `Report.Read.All` | Application |
| Power BI Service | `Dataset.Read.All` | Application |
| Power BI Service | `Workspace.Read.All` | Application |
| Azure Fabric | `Item.Read.All` | Application |

7. Grant admin consent for all permissions (requires a tenant admin)

### Workspace role assignment

Add the service principal as a **Member** in the **VISA** Fabric workspace:

- Workspace: `VISA` (`8dd24078-9814-4e5d-a26c-3713092564bd`)
- Role: **Member** (Viewer is insufficient for embed token generation)

Steps:
1. Open the VISA workspace in Fabric portal
2. Click **Manage access**
3. Add the service principal (search by app name or client ID)
4. Set role to Member

---

## 2. Token Management

### Token types in this solution

The solution uses **three distinct token types** from three different auth flows. Understanding each is critical for a production implementation.

| Token | Purpose | Acquired By | TTL | Refresh Strategy |
|-------|---------|------------|-----|-----------------|
| **Embed Token** | Authorizes the PBIE iframe to render the report | Backend via Power BI REST API | **1 hour** | Silent re-issue before expiry |
| **Entra Access Token** | Backend calls to Power BI REST API and Fabric API | Backend via client credentials flow | 1 hour | Automatic via MSAL token cache |
| **Foundry Token** | Backend calls to Azure AI Foundry Agent | Backend via DefaultAzureCredential or client credentials | 1 hour | Automatic via MSAL token cache |

---

### 2a. Embed Token — App-Owns-Data Flow

This is the most critical token. The embed token is a short-lived credential that authorizes a specific user session to view a specific report. It is **not** a general OAuth token.

**API call to generate it:**

```
POST https://api.powerbi.com/v1.0/myorg/groups/{workspaceId}/reports/{reportId}/GenerateToken
Authorization: Bearer {entraAccessToken}
Content-Type: application/json

{
  "accessLevel": "View",
  "datasetId": "{datasetId}"
}
```

**Confirmed values for this project:**

```json
{
  "workspaceId": "8dd24078-9814-4e5d-a26c-3713092564bd",
  "reportId": "daed8d4d-2dc3-4708-ad82-5611c667498c",
  "datasetId": "5686371f-58c7-453f-89c8-26b0e2fb7f9d",
  "accessLevel": "View"
}
```

**Embed token response shape:**

```json
{
  "token": "H4sI...",
  "tokenId": "...",
  "expiration": "2026-07-21T20:00:00Z"
}
```

**Token expiry handling (required for production):**

The embed token expires in 1 hour by default. The `powerbi-client` SDK raises a `tokenExpired` event when this occurs. The host application must handle this and silently re-issue.

```javascript
embeddedReport.on('tokenExpired', async () => {
  const newToken = await fetch('/api/embed-token').then(r => r.json());
  await embeddedReport.setAccessToken(newToken.token);
});
```

> **Implementation requirement:** The `/api/embed-token` backend endpoint must be callable by the frontend at any time without user interaction. It must never prompt for MFA. This is why a **service principal with client credentials** (not delegated/user flow) is required.

---

### 2b. Entra Access Token — Client Credentials Flow

The backend acquires this token to call the Power BI REST API (for embed token generation) and the Fabric API (for Data Agent queries).

**Token acquisition (Node.js / MSAL):**

```javascript
import { ConfidentialClientApplication } from '@azure/msal-node';

const msalClient = new ConfidentialClientApplication({
  auth: {
    clientId: process.env.CLIENT_ID,
    clientSecret: process.env.CLIENT_SECRET,
    authority: `https://login.microsoftonline.com/${process.env.TENANT_ID}`
  }
});

// For Power BI REST API
const pbiToken = await msalClient.acquireTokenByClientCredential({
  scopes: ['https://analysis.windows.net/powerbi/api/.default']
});

// For Fabric REST API
const fabricToken = await msalClient.acquireTokenByClientCredential({
  scopes: ['https://api.fabric.microsoft.com/.default']
});
```

MSAL automatically caches and refreshes these tokens. Do not manually manage Entra access token expiry.

---

### 2c. Row-Level Security (RLS) Considerations

If the semantic model uses Row-Level Security, the embed token must include an **effective identity** to enforce data access:

```json
{
  "accessLevel": "View",
  "datasetId": "5686371f-58c7-453f-89c8-26b0e2fb7f9d",
  "identities": [
    {
      "username": "user@domain.com",
      "roles": ["RoleName"],
      "datasets": ["5686371f-58c7-453f-89c8-26b0e2fb7f9d"]
    }
  ]
}
```

> **Action required:** Confirm whether the `Visa Slicer Demo v2` semantic model has RLS roles defined. If yes, the effective identity must be passed per-user-session. If no, RLS can be omitted.

---

## 3. Power BI Embedded Capacity

### Confirmed capacity

The VISA workspace is on a **dedicated Fabric capacity**:

| Field | Value |
|-------|-------|
| Capacity ID | `cb113ec9-926c-4af4-99fe-0b5b55fb69b6` |
| Capacity Name | `fabcmksettlement` |
| Workspace | VISA (`8dd24078-9814-4e5d-a26c-3713092564bd`) |

Embed tokens can be generated without a per-user Power BI Pro or Premium Per User license because the workspace is backed by dedicated capacity. The **service principal** generating the embed token does not itself need a Power BI license.

> **Do not move the VISA workspace off dedicated capacity** — doing so will break embed token generation unless PPU licenses are assigned to all users.

---

## 4. Context Flow — Host-App Filter Injection (Pattern 2)

In Pattern 2, the host application owns the filter state. The `powerbi-client` SDK is used to **apply** filters to the report, not to read them back.

### 4a. Applying Filters to the Embedded Report

The host app builds a filter object from the custom UI and pushes it into the report:

```javascript
import * as pbi from 'powerbi-client';

// Build a basic filter — IBasicFilter from powerbi-models
const filter = {
  $schema: 'http://powerbi.com/product/schema#basic',
  target: { table: 'Dim_Client', column: 'ClientName' },
  operator: 'In',
  values: ['ACME Corp', 'Global Bank']
};

// Apply to report (replaces all report-level filters)
await report.setFilters([filter]);

// Or apply to a specific page
const pages = await report.getPages();
const activePage = pages.find(p => p.isActive);
await activePage.setFilters([filter]);
```

> **Why `setFilters()` instead of slicers?** Native Power BI slicers in embedded scenarios have cross-visual sync issues and are difficult to drive programmatically from the host app. `setFilters()` applies directly to the report's filter context, is reliable in embedded mode, and keeps filter state management in the host app where it belongs.

### 4b. Accumulating Filter State in the Host App

The host app maintains a `filterState` object in memory (or in React/component state). Each user interaction updates this object:

```javascript
// filterState shape — matches embedded_filter_context_schema.json
const filterState = {
  sessionId: crypto.randomUUID(),
  timestamp: new Date().toISOString(),
  userId: window.PBIE_USER_UPN,
  reportId: '<reportId>',
  page: { name: 'Demo PBIP', displayName: 'Demo PBIP' },
  filters: [
    { table: 'Dim_Client', column: 'ClientName', values: ['ACME Corp'] },
    { table: 'Dim_Date', column: 'CalendarYear', values: [2024, 2025] }
  ],
  segments: [],
  mccs: []
};
```

### 4c. Persisting Filter State to Fact_FilterSession

On each filter change (or on session end), the host app writes the filter state to `Fact_FilterSession` in the Fabric Lakehouse. This table is part of the Direct Lake semantic model and queryable by the Fabric Data Agent:

```javascript
// POST to backend — backend writes to Lakehouse via Fabric REST API
await fetch('/api/session', {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify(filterState)
});
```

### 4d. Passing Filter State to the Agent

When the user sends a chat message, the current `filterState` is serialized and injected as context in the Foundry Agent user turn:

```
[Report Context]
Page: Demo PBIP
Filters active:
  - Client: ACME Corp
  - Year: 2024, 2025

[User Question]
What is the approval rate trend for this client over the selected period?
```

The agent also has access to `Fact_FilterSession` via the semantic model, enabling it to look up historical filter sessions for the same user.

### 4e. SDK version

```json
"powerbi-client": "^2.23.1"
```

### Previously implemented (Pattern 1 — superseded)

The prior implementation in `frontend/context-capture/captureContext.js` reads slicer state via `getSlicerState()`. This file is retained in the codebase but is superseded by the Pattern 2 approach. It can be repurposed as a fallback or removed in Sprint 3.

---

## 5. Fabric Data Agent

### What it is

The Fabric Data Agent is an AI-powered query interface provisioned inside a Fabric workspace. It accepts natural language questions and returns answers by generating and executing DAX queries against a connected semantic model.

### Status

> **Not yet provisioned.** Target model is the **VISA Commercial Spend Analytics** Direct Lake semantic model (see Section 11). Must be created after the Lakehouse + semantic model are deployed.

### Target semantic model for the Data Agent

The Data Agent should be provisioned against the **VISA Commercial Spend Analytics** model (not `Visa Slicer Demo v2`). Key tables the agent should be able to query:

| Table | Purpose |
|-------|---------|
| `Fact_CommercialSpend` | 250k synthetic transaction rows — primary fact table |
| `Fact_FilterSession` | Persisted host-app filter sessions — agent uses this for user context |
| `Dim_Client` | Client/cardholder dimension |
| `Dim_Merchant` | Merchant dimension |
| `Dim_MCC` | Merchant Category Code dimension |
| `Dim_Country` | Country/region dimension |
| `Dim_Product` | Card product dimension |
| `Dim_Segment` | Business segment dimension |
| `Dim_Date` | Date dimension |
| `Dim_ApprovalStatus` | Transaction approval status dimension |

### Provisioning steps

1. Complete Section 11 (Fabric Lakehouse deployment) first
2. Open the **VISA PBIE Context Injection** workspace in Fabric portal
3. Click **New item → Data agent** (or "AI skill" depending on tenant feature flag)
4. Select data source type: **Semantic model (Power BI)**
5. Select **VISA Commercial Spend Analytics**
6. Add table/measure descriptions using the descriptions in `model_spec.json` (from starter package)
7. Publish the agent and record the **agent ID** and **endpoint URL**

### Auth for backend calls to Fabric Data Agent

```
POST https://api.fabric.microsoft.com/v1/workspaces/{workspaceId}/dataagentruns
Authorization: Bearer {fabricAccessToken}
```

The `fabricAccessToken` is the client credentials token acquired against scope `https://api.fabric.microsoft.com/.default` (see Section 2b).

### Fallback if Fabric Data Agent is not available

If the Data Agent feature is unavailable in this tenant, the fallback is **direct XMLA/DAX execution** via the Power BI REST API `executeQueries` endpoint:

```
POST https://api.powerbi.com/v1.0/myorg/groups/{workspaceId}/datasets/{datasetId}/executeQueries
```

This requires the backend to generate DAX — which is the Foundry Agent's responsibility in Sprint 4.

---

## 6. Azure AI Foundry Agent

### Status

> **Not yet provisioned.** Requires an Azure AI Foundry project in an accessible subscription.

### Recommended placement

Create the Foundry project in the same subscription as the Fabric capacity or in the MSIE Azure subscription — wherever the customer's AI Services quota is available.

### Auth for backend calls to Foundry

```javascript
import { AIProjectClient } from '@azure/ai-projects';
import { DefaultAzureCredential } from '@azure/identity';

const client = new AIProjectClient(
  process.env.FOUNDRY_PROJECT_ENDPOINT,
  new DefaultAzureCredential()
);
```

`DefaultAzureCredential` will use the service principal if `AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET`, and `AZURE_TENANT_ID` are set in the environment — same SP as the embed token flow.

The SP needs **Azure AI Developer** role on the Foundry project resource.

---

## 7. CORS and Local Dev Constraints

### Local development

The Node.js server runs on `http://localhost:3000`. The `powerbi-client` SDK embeds the iframe pointing to `app.powerbi.com`. Power BI's embedding does not require CORS headers on the host server — the iframe loads from Microsoft's CDN.

CORS **is** required on `/api/*` routes if the frontend is served from a different origin than the backend (e.g., Vite dev server on port 5173 + Express on port 3000). Configure:

```javascript
app.use(cors({
  origin: ['http://localhost:3000', 'http://localhost:5173'],
  methods: ['GET', 'POST']
}));
```

### Production hosting

In production, the server should run over **HTTPS** — Power BI embedded content requires secure context in most browser configurations. A self-signed certificate is sufficient for internal demos.

---

## 8. Known Tenant Constraints

| Constraint | Detail |
|-----------|--------|
| Cross-tenant CLI access blocked | `az login` with device code flow to `MngEnvMCAP660444` is blocked for external Microsoft identities — do not attempt programmatic token acquisition from a `@microsoft.com` account against this tenant's Fabric/PBI APIs |
| Power BI REST API restricted to tenant members | API calls must originate from a token scoped to `b7e47691-9726-4f67-a302-e567815f3522` |
| Service principal consent requires admin | The SP's API permissions require **admin consent** — a tenant administrator in `MngEnvMCAP660444` must grant consent before any embed token can be generated |
| Fabric Data Agent feature flag | The "Data agent" / "AI skill" item type may need to be enabled by the Fabric tenant admin under **Tenant settings → AI skills** |

---

## 8a. External User Auth Boundary — Pattern 1 Design Decision

The iframe is consumed by **external users** (guests) who are not native members of `MngEnvMCAP660444`. Because the tenant's inbound communication policy (`RequestDeniedByInboundPolicy`) blocks cross-tenant API calls, external user credentials **cannot** be used to call Fabric or Power BI REST APIs directly from the backend.

**This is the primary reason Pattern 1 (context injection) exists.**

### How the user data boundary is enforced without delegated credentials

| Boundary mechanism | How it works | Requires |
|-------------------|-------------|----------|
| **Effective identity in embed token** | SP generates an embed token with the user's UPN as `effectiveIdentity` — the Power BI engine enforces any RLS roles defined on the semantic model for that user | RLS roles defined on the model |
| **Context injection layer** | `captureContext.js` reads only what is currently visible in the user's filtered iframe. The Foundry Agent receives only that slice of context — it cannot query data outside the user's current view | Pattern 1 implementation (done) |

Together these two mechanisms scope the AI agent's data access to exactly what the user can see, without requiring the external user's token to reach Fabric APIs.

### Production path — enabling full delegated access for external users (Path A)

If full user-delegated Fabric access is required in production (agent queries run as the user, not the SP), the tenant admin must:

1. **Entra ID → External Identities → Cross-tenant access settings**
2. For each external tenant (e.g. `microsoft.com`): configure **Inbound** → B2B collaboration → **Allow** for the specific app registration (`pbie-context-agent-sp`)
3. This removes the `RequestDeniedByInboundPolicy` error for those external identities
4. Once enabled: add MSAL.js to the frontend, acquire Fabric-scoped tokens for the signed-in guest user, and pass them to the backend via `Authorization` header

**This is a tenant admin action. No code change unblocks it.**

### Current implementation (Path B — active)

- SP makes all Fabric/Foundry API calls
- Embed token includes `effectiveIdentity` (user's UPN) when provided → RLS enforced at report layer
- Context injection constrains agent queries to the user's visible report state
- User identity is passed as a query param to `/api/embed-token?user=<upn>` (to be replaced with a validated session token before production)

---

## 9. Confirmed Resource IDs

> These are production values confirmed via API on 2026-07-21. Treat as stable unless workspace is recreated.

```
TENANT_ID     = b7e47691-9726-4f67-a302-e567815f3522
WORKSPACE_ID  = 8dd24078-9814-4e5d-a26c-3713092564bd
REPORT_ID     = daed8d4d-2dc3-4708-ad82-5611c667498c
DATASET_ID    = 5686371f-58c7-453f-89c8-26b0e2fb7f9d
CAPACITY_ID   = cb113ec9-926c-4af4-99fe-0b5b55fb69b6
REPORT_PAGE   = Demo PBIP  (internal: 837f1f392a2c651b68e5)
EMBED_URL     = https://app.powerbi.com/reportEmbed?reportId=daed8d4d-2dc3-4708-ad82-5611c667498c&groupId=8dd24078-9814-4e5d-a26c-3713092564bd&w=2&config=eyJjbHVzdGVyVXJsIjoiaHR0cHM6Ly9XQUJJLVdFU1QtVVMzLUEtUFJJTUFSWS1yZWRpcmVjdC5hbmFseXNpcy53aW5kb3dzLm5ldCIsImVtYmVkRmVhdHVyZXMiOnsidXNhZ2VNZXRyaWNzVk5leHQiOnRydWV9fQ%3d%3d
XMLA_ENDPOINT = powerbi://api.powerbi.com/v1.0/myorg/VISA
```

---

## 11. Data Model — VISA Commercial Spend Analytics

The project uses a purpose-built synthetic dataset. It does **not** contain real VISA, PAN, PII, cardholder, merchant, or production transaction data.

### Dataset summary

| Item | Detail |
|------|--------|
| Transaction rows | 250,000 synthetic commercial spend records |
| Filter session rows | 5,000 synthetic host-app filter sessions |
| Dimension tables | 8 |
| Fact tables | 2 |
| Storage mode | Direct Lake (Fabric Lakehouse → Delta tables) |
| Starter package | `VISA commercial spend starter package.zip` (contains CSVs, DAX measures, model spec, filter contract, notebook) |

### Tables

| File | Type | Description |
|------|------|-------------|
| `Dim_Date.csv` | Dimension | Calendar date table |
| `Dim_Client.csv` | Dimension | Client / cardholder accounts |
| `Dim_Country.csv` | Dimension | Country / region |
| `Dim_Product.csv` | Dimension | Card product type |
| `Dim_Segment.csv` | Dimension | Business segment |
| `Dim_Merchant.csv` | Dimension | Merchant records |
| `Dim_MCC.csv` | Dimension | Merchant Category Codes |
| `Dim_ApprovalStatus.csv` | Dimension | Transaction approval status codes |
| `Fact_CommercialSpend.csv` | Fact | Commercial spend transactions |
| `Fact_FilterSession.csv` | Fact | Host-app filter/prompt sessions |

### Fabric deployment path

1. Upload all CSV files to the **Files** area of a Fabric Lakehouse in the `VISA PBIE Context Injection` workspace
2. Load each CSV to a Delta table with the same table name (use the included Fabric notebook or Dataflow Gen2)
3. Create a **Direct Lake** semantic model over the Delta tables
4. Apply relationships from `model_spec.json` (included in starter package)
5. Add DAX measures from `semantic_model_measures.dax` (included in starter package)
6. Provision the Fabric Data Agent against this model (see Section 5)

> Microsoft Learn reference: [Load data into a Fabric Lakehouse](https://learn.microsoft.com/en-us/fabric/data-engineering/load-data-lakehouse) · [CSV-to-Delta quickstart](https://learn.microsoft.com/en-us/fabric/data-engineering/get-started-csv-upload)

### Updating semantic/model_metadata.md

Once the model is deployed, update `semantic/model_metadata.md` and `semantic/metadata/field_map.json` with the confirmed table names and column names from this model (replacing the `Visa Slicer Demo v2` placeholders).

---

## 12. Filter Context Contract

The file `embedded_filter_context_schema.json` (included in the starter package) defines the JSON contract that flows between:

- Host application prompt/filter UI state
- `report.setFilters()` call to PBIE
- `Fact_FilterSession` write to Fabric Lakehouse
- Agent prompt builder (grounding context block)

### Schema shape

```json
{
  "sessionId": "<uuid>",
  "timestamp": "2026-07-21T18:00:00Z",
  "userId": "user@domain.com",
  "reportId": "<pbi-report-id>",
  "page": {
    "name": "Demo PBIP",
    "displayName": "Demo PBIP"
  },
  "filters": [
    {
      "table": "Dim_Client",
      "column": "ClientName",
      "operator": "In",
      "values": ["ACME Corp"]
    },
    {
      "table": "Dim_Date",
      "column": "CalendarYear",
      "operator": "In",
      "values": [2024, 2025]
    }
  ],
  "segments": [],
  "mccs": [],
  "question": "What is the approval rate for this client YTD?"
}
```

### Contract usage by component

| Component | Usage |
|-----------|-------|
| Frontend filter UI | Writes to `filterState` object in memory |
| `embed.js` | Calls `report.setFilters()` using `filters[]` array converted to `IBasicFilter` objects |
| `server/routes/session.js` (Sprint 3) | Receives full contract, writes to `Fact_FilterSession` via Fabric Lakehouse API |
| `server/routes/chat.js` | Receives `filterState` as `rawContext`, builds context block for agent turn |
| Fabric Data Agent | Queries `Fact_FilterSession` directly by `sessionId` or `userId` for historical context |

---

## 10. Implementation Checklist (Pre-Sprint 1)

### Blocked on Customer Tenant Admin

| Item | Owner | Status |
|------|-------|--------|
| Register service principal in `MngEnvMCAP660444` tenant | Customer tenant admin | Open |
| Grant admin consent for Power BI + Fabric API permissions | Customer tenant admin | Open |
| Add SP as Member to VISA workspace | Customer tenant admin | Open |
| Confirm `CLIENT_ID` and `CLIENT_SECRET` and add to `.env` | Dev team | Open |
| Confirm RLS status of `Visa Slicer Demo v2` — if RLS roles exist, capture role names for `effectiveIdentity` | Customer | Open |
| Provision Fabric Data Agent against `Visa Slicer Demo v2` | Customer/Fabric admin | Open |
| Enable "AI skills" feature in Fabric tenant admin settings | Customer tenant admin | Open |

### Blocked on Dev Team

| Item | Owner | Status |
|------|-------|--------|
| Create Azure AI Foundry project | Dev team | Open |
| Assign SP **Azure AI Developer** role on Foundry project | Dev team | Open |
| Run `node scripts/provision-foundry-agent.js` to create agent | Dev team | Open (requires Foundry project) |
| Add `FOUNDRY_AGENT_ID` to `.env` | Dev team | Open |
| Install Node.js 20+ locally | Dev team | Open |

### Production Gate — External User Auth (Path A, not required for demo)

| Item | Owner | Status |
|------|-------|--------|
| Configure Entra cross-tenant access policy to allow B2B inbound for external orgs | Customer tenant admin | Not started |
| Scope to specific app registration (`pbie-context-agent-sp`) in inbound policy | Customer tenant admin | Not started |
| Replace `?user=<upn>` query param with validated session identity | Dev team | Not started |
| Add MSAL.js to frontend for guest user sign-in | Dev team | Not started |
| Switch `fabricAgent.js` to use user-delegated token when present | Dev team | Not started |
