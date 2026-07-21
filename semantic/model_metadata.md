# Semantic Model Metadata

## Status: Pending Discovery

> Complete [fabric_model_discovery.md](../docs/fabric_model_discovery.md) Steps 2–4 to populate this file.

---

## Confirmed Infrastructure

| Field | Value |
|-------|-------|
| Tenant | `MngEnvMCAP660444.onmicrosoft.com` |
| Tenant ID | `b7e47691-9726-4f67-a302-e567815f3522` |
| Subscription | `ME-MngEnvMCAP660444-seankelley-2` (`c4a3460a-3527-460c-ab59-4a4c7a15646b`) |
| Fabric Capacity ID | `cb113ec9-926c-4af4-99fe-0b5b55fb69b6` |

## Target Workspace

| Field | Value |
|-------|-------|
| Workspace Name | `VISA` |
| Workspace ID | `8dd24078-9814-4e5d-a26c-3713092564bd` |
| On Dedicated Capacity | Yes |

## Semantic Models

| Name | ID | Use |
|------|----|-----|
| Visa Slicer Demo | `bcfdc1db-8c47-4033-9c5a-2c637c447891` | v1 (baseline) |
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
