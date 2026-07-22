# Fabric Semantic Model Discovery

## Purpose

This document guides the process of identifying an **existing Microsoft Fabric semantic model** to power the PBIE iframe and Fabric Data Agent in this project.

---

## Confirmed Infrastructure

| Field | Value |
|-------|-------|
| Tenant | `MngEnvMCAP660444.onmicrosoft.com` |
| Tenant ID | `b7e47691-9726-4f67-a302-e567815f3522` |
| Fabric Capacity | [fabriccapwest3](https://portal.azure.com/#resource/subscriptions/0a913923-fe62-46fb-8fdd-b78fb498f7a9/resourceGroups/Fabric-West3-RG/providers/Microsoft.Fabric/capacities/fabriccapwest3) |
| Subscription | `ME-MngEnvMCAP660444-seankelley-2` (`c4a3460a-3527-460c-ab59-4a4c7a15646b`) |
| Region | West US |
| Admin Account | `seankelley@MngEnvMCAP660444.onmicrosoft.com` |

> **Discovery complete (2026-07-21).** All IDs below are confirmed via API. The sections below are preserved as reference for future model additions.

---

## Step 1 — Access the Fabric Portal

Navigate to: **https://app.fabric.microsoft.com**

You are already confirmed logged in. The capacity `fabriccapwest3` is visible at:
```
https://portal.azure.com/#resource/subscriptions/0a913923-fe62-46fb-8fdd-b78fb498f7a9/resourceGroups/Fabric-West3-RG/providers/Microsoft.Fabric/capacities/fabriccapwest3
```

Workspaces assigned to this capacity will appear in the Fabric portal sidebar.

---

## Step 2 — Identify Candidate Workspaces

### ✅ Confirmed Target Workspace

| Workspace Name | Workspace ID | Contains Reports | Contains Semantic Model | Fabric Data Agent? | Notes |
|---------------|-------------|-----------------|------------------------|-------------------|-------|
| **VISA** | `8dd24078-9814-4e5d-a26c-3713092564bd` | ✅ | ✅ | ❌ Not yet provisioned | **Primary target** |

XMLA endpoint: `powerbi://api.powerbi.com/v1.0/myorg/VISA`

---

## Step 3 — Identify Target Semantic Model

### ✅ Confirmed Target Model

| Field | Value |
|-------|-------|
| Semantic Model Name | **Visa Slicer Demo v2** |
| Semantic Model ID | `5686371f-58c7-453f-89c8-26b0e2fb7f9d` |
| Workspace ID | `8dd24078-9814-4e5d-a26c-3713092564bd` |
| Storage Mode | To be confirmed via XMLA |
| Tables / Measures | Pending — browse via DAX Studio or Tabular Editor against XMLA endpoint |
| Key Measures | Pending — populate `semantic/metadata/field_map.json` after browse |

---

## Step 4 — Extract Model Metadata

### Option A — Fabric Portal (Manual)

1. Open the workspace → click the semantic model
2. Click **Open data model** in the toolbar
3. Browse tables and measures
4. Record key business measures in [model_metadata.md](../semantic/model_metadata.md)

### Option B — Power BI REST API (Programmatic)

```bash
# Get access token
TOKEN=$(az account get-access-token --resource https://analysis.windows.net/powerbi/api --query accessToken -o tsv)

# List datasets in workspace
curl -H "Authorization: Bearer $TOKEN" \
  "https://api.powerbi.com/v1.0/myorg/groups/{workspaceId}/datasets"

# Get tables in a dataset
curl -H "Authorization: Bearer $TOKEN" \
  "https://api.powerbi.com/v1.0/myorg/groups/{workspaceId}/datasets/{datasetId}/tables"
```

### Option C — DAX Studio / Tabular Editor (Local tool)

Connect Tabular Editor to the XMLA endpoint:
```
powerbi://api.powerbi.com/v1.0/myorg/{WorkspaceName}
```
Browse the model, export table/measure metadata.

---

## Step 5 — Identify Embedded Reports

For the local PBIE server, you need a **Report ID** that is backed by the target semantic model.

### Via Portal

1. Open the workspace
2. Find a report built on the target semantic model
3. Open the report
4. The URL will contain: `...reports/{reportId}/...`
5. Record the Report ID

| Field | Value |
|-------|-------|
| Report Name | _(fill in)_ |
| Report ID | _(fill in)_ |
| Backed by Model | _(semantic model name)_ |
| Key Pages | _(fill in page names used in demo)_ |
| Demo Slicers | _(fill in slicer fields for Pattern 1 demo)_ |

---

## Step 6 — Check Fabric Data Agent Availability

### What is a Fabric Data Agent?

A Fabric Data Agent is an AI agent provisioned within Microsoft Fabric that:
- Connects to a semantic model or Lakehouse
- Accepts natural language queries
- Returns structured answers (and optionally the DAX it generated)

### Check if one exists for your model

1. Navigate to the workspace
2. Filter items by type **"AI skill"** or **"Data agent"**
3. If one exists connected to your target model, record the endpoint and agent ID

| Field | Value |
|-------|-------|
| Agent Name | _(fill in)_ |
| Agent ID | _(fill in)_ |
| Agent Endpoint | _(fill in)_ |
| Connected Model | _(semantic model name)_ |

### Create a Fabric Data Agent (if one doesn't exist)

1. In the workspace, click **New → Data agent** (or **AI skill**)
2. Select **Semantic model** as the data source
3. Choose the target semantic model
4. Configure the agent:
   - Add key measures as agent instructions
   - Add table descriptions for better query accuracy
5. Test: ask "What is the total approval rate?"
6. Publish and copy the agent endpoint URL

---

## Step 7 — Populate `.env` with Discovered Values

Once you have discovered the workspace, model, report, and agent, populate the `.env` file:

```env
WORKSPACE_ID=<workspace-id-from-step-2>
REPORT_ID=<report-id-from-step-5>
DATASET_ID=<semantic-model-id-from-step-3>
FABRIC_AGENT_ENDPOINT=<agent-endpoint-from-step-6>
FABRIC_AGENT_ID=<agent-id-from-step-6>
```

And update [model_metadata.md](../semantic/model_metadata.md) with the table and measure inventory.

---

## Current Discovery Status

> **Action Required:** Complete steps 2–6 to identify the target Fabric workspace and model.
>
> The Fabric MCP connection returned a 403 during automated discovery — Fabric REST API data plane access may need to be enabled in tenant admin settings or the service principal may need additional permissions.

### Root Cause (Confirmed)

Fabric REST API and Power BI REST API are returning **403 — Access is not permitted by policy**. This is enforced by Conditional Access policy on this tenant (`352b9d2f-d198-492f-849c-5ba900caf39d`). The restriction applies to non-compliant device or unregistered app contexts.

### Resolution Options

**Option 1 — Tenant Admin Action (preferred for automation)**
1. Go to **https://app.fabric.microsoft.com** → Admin portal
2. Navigate to **Tenant settings → Developer settings**
3. Enable **"Service principals can use Fabric APIs"**
4. Add the service principal to the allowed security group

**Option 2 — Manual portal discovery (immediate, no admin needed)**
Use Steps 2–6 above. Browse the Fabric portal directly and extract IDs from the URL bar.

**Option 3 — Interactive token via Azure CLI**
```bash
az login
az account get-access-token --resource https://analysis.windows.net/powerbi/api
```
Then use the token in the REST API calls in Step 4, Option B.

### Extracting IDs from Fabric Portal URLs

| Item Type | URL Pattern | ID to copy |
|-----------|-------------|------------|
| Workspace | `app.fabric.microsoft.com/.../groups/{id}/...` | After `/groups/` |
| Semantic Model | `.../datasets/{id}/...` | After `/datasets/` |
| Report | `.../reports/{id}/...` | After `/reports/` |
| Data Agent / AI Skill | `.../items/{id}?experience=...` | After `/items/` |
