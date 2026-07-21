# Design Notes — Implementation Requirements
## MSIE Power BI Embedded Context-Aware AI Assistant (Pattern 1)

**Prepared for:** Customer Implementation Team  
**Pattern:** Context Injection Agent  
**Tenant:** `MngEnvMCAP660444.onmicrosoft.com`  
**Last updated:** 2026-07-21

---

## Purpose

This document captures the implementation requirements, constraints, and decisions that the development team needs to know before building the Pattern 1 solution. It is intended as a handoff document covering identity, token management, embedding, security, and hosting prerequisites.

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

## 4. Context Capture — PBIE JavaScript SDK

The host application captures report state using the `powerbi-client` JavaScript SDK. This runs entirely in the browser against the iframe.

### SDK version

```json
"powerbi-client": "^2.23.1"
```

### Context capture API calls

These are the SDK methods used in `captureContext.js`:

| Method | Returns | Notes |
|--------|---------|-------|
| `report.getPages()` | Array of page objects | `.isActive` identifies current page |
| `report.getFilters()` | Array of filter objects | Report-level filters |
| `activePage.getFilters()` | Array of filter objects | Page-level filters |
| `activePage.getVisuals()` | Array of visual objects | Used to identify slicer visuals |
| `visual.getSlicerState()` | Slicer state object | Per-slicer selected values |

### Known limitations

- `getSlicerState()` requires the visual to be of type `slicer` — non-slicer visuals cannot be queried for selection state via this API
- Report-level filters and page-level filters are separate collections and must both be retrieved
- Visual cross-filter selections (cross-highlighting) are **not** captured in the initial implementation (Sprint 5 scope)
- `getSlicerState()` may throw on visuals where no selection has been made — implement try/catch per visual

---

## 5. Fabric Data Agent

### What it is

The Fabric Data Agent is an AI-powered query interface provisioned inside a Fabric workspace. It accepts natural language questions and returns answers by generating and executing DAX queries against a connected semantic model.

### Status

> **Not yet provisioned** for the `Visa Slicer Demo v2` semantic model. Must be created before Sprint 3.

### Provisioning steps

1. Open the **VISA** workspace in Fabric portal (`app.fabric.microsoft.com`)
2. Click **New item → Data agent** (or "AI skill" depending on tenant feature flag)
3. Select data source type: **Semantic model (Power BI)**
4. Select **Visa Slicer Demo v2**
5. Add table/measure descriptions to improve query accuracy
6. Publish the agent and record the **agent ID** and **endpoint URL**

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
