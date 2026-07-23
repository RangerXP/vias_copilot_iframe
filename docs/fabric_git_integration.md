# Fabric Git Integration — Deployment Guide

**Project:** VISA Commercial Spend Analytics + FilterSession Context Injection  
**Workspace:** VISA PBIE Context Injection  
**Last updated:** 2026-07-21

---

## Overview

This guide covers deploying the Fabric Lakehouse, Direct Lake semantic model, and Power BI report via Fabric Git Integration from the GitHub repo.

Fabric Git Integration syncs Fabric items (notebooks, semantic models, reports in PBIP format) from the `fabric-workspace/` folder of the repo into the connected Fabric workspace. The Node.js host application code (`server/`, `frontend/`, `src/`) is managed separately via standard `git push`.

---

## Prerequisites

| Requirement | Status |
|-------------|--------|
| GitHub repo connected to VISA PBIE Context Injection workspace | ✅ Connected (2026-07-21) |
| Fabric capacity assigned to workspace (`fabriccapwest3`) | ✅ Confirmed |
| `Commercial_Spend_Analytics` Lakehouse created | ✅ Created (`1aa73044-f85f-4843-b3e5-588cab4c0499`) |
| All 10 CSV files uploaded to Lakehouse Files/ root | ✅ Confirmed (2026-07-21) |
| Delta tables loaded (notebook run) | ⏳ Next step |
| Direct Lake semantic model created | ⏳ Pending |
| Service principal registered in `MngEnvMCAP660444` | Pending — see `docs/design_notes.md` Section 1 |

---

## Step 1 — CSV Files Already Uploaded ✅

All 10 CSV files are confirmed uploaded to the root of **Files/** in the `Commercial_Spend_Analytics` Lakehouse (verified 2026-07-21):

| File | Size |
|------|------|
| `Dim_Date.csv` | 49 KB |
| `Dim_Client.csv` | 31 KB |
| `Dim_Country.csv` | 0.7 KB |
| `Dim_Product.csv` | 0.3 KB |
| `Dim_Segment.csv` | 0.2 KB |
| `Dim_Merchant.csv` | 44 KB |
| `Dim_MCC.csv` | 0.5 KB |
| `Dim_ApprovalStatus.csv` | 0.2 KB |
| `Fact_CommercialSpend.csv` | 14.2 MB |
| `Fact_FilterSession.csv` | 1.1 MB |

> Files are in `Files/` root — **no subfolder**. The notebook reads from `Files/<TableName>.csv` directly.

---

## Step 2 — Run the Delta Table Loader Notebook

1. In the **VISA PBIE Context Injection** workspace, click **New item → Notebook**
2. Attach the notebook to the **`Commercial_Spend_Analytics`** Lakehouse
3. Paste the contents of `src/fabric/notebooks/load_delta_tables.py` into the first cell
4. Click **Run all**
5. Verify the output shows all 10 tables with row counts in the `dbo` schema:
   - `dbo.Fact_CommercialSpend`: ~250,000 rows
   - `dbo.Fact_FilterSession`: ~5,000 rows

> **Schema note:** This is a schema-enabled Lakehouse. Tables are created under the `dbo` schema (`dbo.Dim_Date`, `dbo.Fact_CommercialSpend`, etc.).

---

## Step 3 — Create the Direct Lake Semantic Model

1. In the `Commercial_Spend_Analytics` Lakehouse, click **New semantic model** (top toolbar)
2. Name it: `VISA Commercial Spend Analytics + FilterSession Context Injection`
3. Select schema **dbo** and all 10 tables
4. Click **Confirm**

### Add relationships

Apply each relationship from `src/semantic-model/model_spec.json` using the model editor:

| From (many side) | To (one side) |
|-----------------|---------------|
| `Fact_CommercialSpend[TransactionDateKey]` | `Dim_Date[DateKey]` |
| `Fact_CommercialSpend[ClientKey]` | `Dim_Client[ClientKey]` |
| `Fact_CommercialSpend[CountryKey]` | `Dim_Country[CountryKey]` |
| `Fact_CommercialSpend[MerchantKey]` | `Dim_Merchant[MerchantKey]` |
| `Fact_CommercialSpend[MCCKey]` | `Dim_MCC[MCCKey]` |
| `Fact_CommercialSpend[ProductKey]` | `Dim_Product[ProductKey]` |
| `Fact_CommercialSpend[SegmentKey]` | `Dim_Segment[SegmentKey]` |
| `Fact_CommercialSpend[ApprovalStatusKey]` | `Dim_ApprovalStatus[ApprovalStatusKey]` |

### Add DAX measures

Open the model in the web editor or connect via XMLA endpoint and add the measures from `src/semantic-model/measures.dax`:

- Total Spend USD
- Transaction Count
- Average Ticket USD
- Interchange Revenue USD
- Fraud Exposure Score
- Approval Rate
- Decline Rate
- High Fraud Transactions
- Spend YoY %

---

## Step 4 — Create the Power BI Report

1. From the semantic model, click **Create report**
2. Build the report against the Direct Lake model
3. Save as **VISA Commercial Spend Overview** in the workspace
4. Note the **Report ID** and **Dataset ID** from the URL and update `.env`:
   ```
   REPORT_ID=<new-report-id>
   DATASET_ID=<semantic-model-id>
   ```

---

## Step 5 — Provision the Fabric Data Agent

1. In the workspace, click **New item → Data agent**
2. Connect to the **VISA Commercial Spend Analytics** semantic model
3. Add table descriptions (refer to `src/semantic-model/model_definition.md`)
4. Enable `Fact_FilterSession` so the agent can query historical filter sessions by user
5. Publish and record:
   ```
   FABRIC_AGENT_ENDPOINT=https://api.fabric.microsoft.com/v1/workspaces/<id>/dataagentruns
   FABRIC_AGENT_ID=<agent-id>
   ```

---

## Step 6 — Wire the Fabric Git Integration (source control)

The workspace is connected to the **`branch`** branch of `https://github.com/RangerXP/visa_copilot_iframe` (not `main` — `main` is a stale early snapshot; `branch` is the actively synced, canonical working branch and should be used for all pushes and PRs against this project). This corrects an earlier version of this doc that referenced `main`.

To sync Fabric items back to the repo:

1. In the workspace header, click **Source control** (git icon)
2. Any modified Fabric items (notebook, semantic model, report) will appear as pending changes
3. Add a commit message and click **Commit** — this writes PBIP-format item definitions to the `fabric-workspace/` folder in the repo

To pull changes from the repo into the workspace:

1. In Source control, click **Update all** (or per-item update)
2. Fabric applies the item definitions from the repo to the workspace

---

## Step 7 — Run the TypeScript tests

Install the test runner (one-time):

```bash
npm install --save-dev vitest
```

Run all tests:

```bash
npx vitest run
```

Expected: all tests in `tests/filterContext.test.ts` and `tests/contextPromptBuilder.test.ts` pass.

---

## Environment variables summary

After completing all steps, your `.env` should have these values populated:

```
TENANT_ID=b7e47691-9726-4f67-a302-e567815f3522
WORKSPACE_ID=<visa-pbie-context-injection-workspace-id>
REPORT_ID=<new-report-id>
DATASET_ID=<semantic-model-id>
CAPACITY_NAME=fabriccapwest3   # see docs/design_notes.md Section 3 for portal link
CLIENT_ID=<service-principal-client-id>
CLIENT_SECRET=<service-principal-secret>
FABRIC_AGENT_ENDPOINT=https://api.fabric.microsoft.com/v1/workspaces/<workspace-id>/dataagentruns
FABRIC_AGENT_ID=<fabric-agent-id>
```
