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
| Fabric capacity assigned to workspace (`fabcmksettlement`) | ✅ Confirmed |
| Service principal registered in `MngEnvMCAP660444` | Pending — see `docs/design_notes.md` Section 1 |
| CSV files from starter package available locally | Required for Step 2 |

---

## Step 1 — Upload CSV Files to Fabric Lakehouse

1. Open the **VISA PBIE Context Injection** workspace in [Fabric portal](https://app.fabric.microsoft.com)
2. Create a new **Lakehouse** named `visa_commercial_spend`
3. In the Lakehouse explorer, navigate to **Files** → click **Upload** → **Upload folder**
4. Create a folder named `visa_commercial_spend_context_injection`
5. Upload all 10 CSV files into that folder:

   ```
   Dim_Date.csv
   Dim_Client.csv
   Dim_Country.csv
   Dim_Product.csv
   Dim_Segment.csv
   Dim_Merchant.csv
   Dim_MCC.csv
   Dim_ApprovalStatus.csv
   Fact_CommercialSpend.csv
   Fact_FilterSession.csv
   ```

---

## Step 2 — Run the Delta Table Loader Notebook

1. In the workspace, click **New item → Notebook**
2. Attach the notebook to the `visa_commercial_spend` Lakehouse
3. Paste the contents of `src/fabric/notebooks/load_delta_tables.py` into the first cell
4. Click **Run all**
5. Verify the output shows all 10 tables with row counts:
   - `Fact_CommercialSpend`: ~250,000 rows
   - `Fact_FilterSession`: ~5,000 rows

---

## Step 3 — Create the Direct Lake Semantic Model

1. In the Lakehouse, click **New semantic model** (top toolbar)
2. Name it: `VISA Commercial Spend Analytics + FilterSession Context Injection`
3. Select all 10 tables
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

The workspace is already connected to the `main` branch of `https://github.com/RangerXP/vias_copilot_iframe`.

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
CAPACITY_ID=cb113ec9-926c-4af4-99fe-0b5b55fb69b6
CLIENT_ID=<service-principal-client-id>
CLIENT_SECRET=<service-principal-secret>
FABRIC_AGENT_ENDPOINT=https://api.fabric.microsoft.com/v1/workspaces/<workspace-id>/dataagentruns
FABRIC_AGENT_ID=<fabric-agent-id>
FOUNDRY_PROJECT_ENDPOINT=<foundry-project-endpoint>
FOUNDRY_AGENT_ID=<foundry-agent-id>
```
