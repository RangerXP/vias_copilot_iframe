# Semantic Model Metadata

## Status: Full stack live (Lakehouse → Semantic Model → Report → Data Agent)

---

## Confirmed Infrastructure

| Field | Value |
|-------|-------|
| Tenant | `MngEnvMCAP660444.onmicrosoft.com` |
| Tenant ID | `b7e47691-9726-4f67-a302-e567815f3522` |
| Subscription | `ME-MngEnvMCAP660444-seankelley-2` (`c4a3460a-3527-460c-ab59-4a4c7a15646b`) |
| Fabric Capacity | [fabriccapwest3](https://portal.azure.com/#resource/subscriptions/0a913923-fe62-46fb-8fdd-b78fb498f7a9/resourceGroups/Fabric-West3-RG/providers/Microsoft.Fabric/capacities/fabriccapwest3) |

## Workspaces

| Workspace Name | Workspace ID | Purpose |
|---------------|-------------|----------|
| VISA | `8dd24078-9814-4e5d-a26c-3713092564bd` | Original Visa Slicer Demo reports |
| **VISA PBIE Context Injection** | **`349db6f1-5df6-4992-ba67-ebc4449fead5`** | **Active dev workspace** |

## VISA PBIE Context Injection Workspace — Items (confirmed 2026-07-21)

| Item | Type | ID |
|------|------|----|
| `Commercial_Spend_Analytics` | Lakehouse | `1aa73044-f85f-4843-b3e5-588cab4c0499` |
| `Commercial_Spend_Analytics` | SQLEndpoint | `eced6bb3-c201-4f20-beb1-e97dd806e0c2` |
| `Commercial_Spend_Analytics` | SemanticModel | `b7bc94fc-a087-4e71-9476-f128ba57cf3a` |
| `Commercial_Spend_Analytics` | Report | `e833a03b-2cf9-42d2-a1ee-a40f847fd75d` |
| `Load_Delta_Tables` | Notebook | `1a019dbc-5136-483c-b752-f9cff8b107cf` |
| `Commercial_Spend_Agent` | DataAgent | `d2042f7c-989f-47d2-a3b4-92603f3e55ab` |

### Lakehouse file inventory (Files/ root)

| File | Size | Type |
|------|------|------|
| `Dim_Date.csv` | 49 KB | Dimension CSV |
| `Dim_Client.csv` | 31 KB | Dimension CSV |
| `Dim_Country.csv` | 0.7 KB | Dimension CSV |
| `Dim_Product.csv` | 0.3 KB | Dimension CSV |
| `Dim_Segment.csv` | 0.2 KB | Dimension CSV |
| `Dim_Merchant.csv` | 44 KB | Dimension CSV |
| `Dim_MCC.csv` | 0.5 KB | Dimension CSV |
| `Dim_ApprovalStatus.csv` | 0.2 KB | Dimension CSV |
| `Fact_CommercialSpend.csv` | 14.2 MB | Fact CSV |
| `Fact_FilterSession.csv` | 1.1 MB | Fact CSV |
| `embedded_filter_context_schema.json` | 0.7 KB | Schema contract |
| `fabric_generate_delta_tables.py` | 0.9 KB | Original load script |
| `model_spec.json` | 1.2 KB | Model spec |
| `semantic_model_measures.dax` | 0.9 KB | DAX measures |

### Delta tables (dbo schema) — confirmed 2026-07-21

All 10 tables created via `Load_Delta_Tables` notebook (20/20 Spark jobs succeeded).

| Table | Rows |
|-------|------|
| `dbo.Dim_Date` | 1,096 |
| `dbo.Dim_Country` | 30 |
| `dbo.Dim_Segment` | 10 |
| `dbo.Dim_Product` | 8 |
| `dbo.Dim_ApprovalStatus` | 4 |
| `dbo.Dim_MCC` | 15 |
| `dbo.Dim_Client` | 500 |
| `dbo.Dim_Merchant` | 1,000 |
| `dbo.Fact_CommercialSpend` | 250,000 |
| `dbo.Fact_FilterSession` | 5,000 |

### Semantic model — confirmed 2026-07-21

| Field | Value |
|-------|-------|
| Name | `Commercial_Spend_Analytics` |
| ID | `b7bc94fc-a087-4e71-9476-f128ba57cf3a` |
| Storage mode | Direct Lake |
| Source lakehouse | `Commercial_Spend_Analytics` (`1aa73044-f85f-4843-b3e5-588cab4c0499`) |
| Relationships | 8 (all active, one-direction) |
| Measures | 9 (in `fact_commercialspend`) |
| Validated total spend | $74,812,278 across 250,000 transactions |

#### Relationships

| From (Many) | To (One) |
|-------------|----------|
| `fact_commercialspend[TransactionDateKey]` | `dim_date[DateKey]` |
| `fact_commercialspend[ClientKey]` | `dim_client[ClientKey]` |
| `fact_commercialspend[CountryKey]` | `dim_country[CountryKey]` |
| `fact_commercialspend[MerchantKey]` | `dim_merchant[MerchantKey]` |
| `fact_commercialspend[MCCKey]` | `dim_mcc[MCCKey]` |
| `fact_commercialspend[ProductKey]` | `dim_product[ProductKey]` |
| `fact_commercialspend[SegmentKey]` | `dim_segment[SegmentKey]` |
| `fact_commercialspend[ApprovalStatusKey]` | `dim_approvalstatus[ApprovalStatusKey]` |

#### Measures (table: `fact_commercialspend`)

| Measure | Folder | Format |
|---------|--------|--------|
| Total Spend USD | Core Spend | `$#,0.00` |
| Transaction Count | Core Spend | `#,0` |
| Average Ticket USD | Core Spend | `$#,0.00` |
| Interchange Revenue USD | Core Spend | `$#,0.00` |
| Fraud Exposure Score | Risk | `0.0` |
| High Fraud Transactions | Risk | `#,0` |
| Approval Rate | Approval | `0.0%` |
| Decline Rate | Approval | `0.0%` |
| Spend YoY % | Time Intelligence | `0.0%` |
| Spend YoY % (Latest Year) | Time Intelligence | `0.0%` |

> ⏳ **Report not yet created.** Next: create report from this model → record Report ID.

---

## VISA Workspace — Legacy items (reference only)
| **Visa Slicer Demo v2** | `5686371f-58c7-453f-89c8-26b0e2fb7f9d` | **Primary target** |

## Reports

| Name | Report ID | Dataset ID |
|------|-----------|------------|
| Visa Slicer Demo | `366f4557-9e61-43ae-af8b-a5a5011be351` | `bcfdc1db-8c47-4033-9c5a-2c637c447891` |
| **Visa Slicer Demo v2** | `daed8d4d-2dc3-4708-ad82-5611c667498c` | `5686371f-58c7-453f-89c8-26b0e2fb7f9d` |

## Report Pages (Visa Slicer Demo v2)

| Page Internal Name | Display Name | Order |
|-------------------|-------------|-------|
| `837f1f392a2c651b68e5` | Demo PBIP | 0 |

## Embed URL (Visa Slicer Demo v2)

```
https://app.powerbi.com/reportEmbed?reportId=daed8d4d-2dc3-4708-ad82-5611c667498c&groupId=8dd24078-9814-4e5d-a26c-3713092564bd&w=2&config=eyJjbHVzdGVyVXJsIjoiaHR0cHM6Ly9XQUJJLVdFU1QtVVMzLUEtUFJJTUFSWS1yZWRpcmVjdC5hbmFseXNpcy53aW5kb3dzLm5ldCIsImVtYmVkRmVhdHVyZXMiOnsidXNhZ2VNZXRyaWNzVk5leHQiOnRydWV9fQ%3d%3d
```

## XMLA Endpoint

```
powerbi://api.powerbi.com/v1.0/myorg/VISA
```

---

## Tables

> Populate by opening the model in Fabric portal → Semantic model view, or connect via Tabular Editor to XMLA endpoint `powerbi://api.powerbi.com/v1.0/myorg/VISA`.

| Table Name | Row Count (approx) | Description | Key Columns |
|-----------|-------------------|-------------|-------------|
| _(browse model in Fabric portal)_ | | | |

---

## Key Measures

> Populate by browsing the model in Fabric portal or via DAX Studio connected to the XMLA endpoint above.

| Measure Name | Table | Description | Example Output |
|-------------|-------|-------------|----------------|
| _(browse model in Fabric portal)_ | | | |

---

## Field Name Map

> This table feeds `semantic/metadata/field_map.json` — the context service uses it to translate PBIE field names to business names before prompt injection.
> Populate after opening the report in the PBIE iframe and inspecting slicer/filter field names via `powerbi-client` API.

| PBIE Field Name (raw) | Business Name (prompt-friendly) | Table |
|----------------------|-------------------------------|-------|
| _(inspect via captureContext() in Sprint 2)_ | | |

---

## Demo Report Reference

| Field | Value |
|-------|-------|
| Report Name | Visa Slicer Demo v2 |
| Report ID | `daed8d4d-2dc3-4708-ad82-5611c667498c` |
| Demo Page Name | Demo PBIP |
| Demo Page Internal Name | `837f1f392a2c651b68e5` |
| Demo Slicer Fields | _(inspect via captureContext() in Sprint 2)_ |
| Demo Filter Fields | _(inspect via captureContext() in Sprint 2)_ |
