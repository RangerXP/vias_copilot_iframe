# DAX Query Pattern Library

Reference for the DAX shapes used by `server/services/fabricAgent.js` to answer
Analytics Assistant questions. Each shape is executed via the Power BI
`executeQueries` REST API against `Commercial_Spend_Analytics`
(`b7bc94fc-a087-4e71-9476-f128ba57cf3a`, workspace `349db6f1`).

`pickDax(question)` routes a natural-language question to one of these shapes
using keyword matching. Order matters — more specific patterns are checked
first. See the function in `fabricAgent.js` for the exact routing rules.

---

## Model reference (confirmed from TMDL, 2026-07-22)

**Fact table:** `fact_commercialspend` (250,000 rows)

| Measure | Display Folder | Format |
|---|---|---|
| `Total Spend USD` | Core Spend | `$#,0.00` |
| `Transaction Count` | Core Spend | `#,0` |
| `Average Ticket USD` | Core Spend | `$#,0.00` |
| `Interchange Revenue USD` | Core Spend | `$#,0.00` |
| `Fraud Exposure Score` | Risk | `0.0` |
| `High Fraud Transactions` | Risk | `#,0` |
| `Approval Rate` | Approval | `0.0%` |
| `Decline Rate` | Approval | `0.0%` |
| `Spend YoY %` | Time Intelligence | `0.0%` — year-over-year vs. same period prior year. Requires filtering by year for a meaningful result (blank at unfiltered grand-total level by design). |
| `Spend YoY % (Latest Year)` | Time Intelligence | `0.0%` — self-scoped to the most recent year in the model; used by the headline KPI cards so they always show a specific, defensible year-over-year figure. **Fixed 2026-07-22** — see `docs/design_notes.md` Section 18 (root cause: `dim_date` wasn't marked as a Date Table + KPI cards had no year filter). |

**Dimension tables** (all Direct Lake, joined 1:many from fact table):

| Table | Key Columns |
|---|---|
| `dim_date` | `Year`, `Quarter`, `MonthName`, `FiscalYear`, `FiscalQuarter`, `Date` |
| `dim_merchant` | `MerchantName`, `MerchantType`, `MCCKey`, `CountryKey` |
| `dim_country` | `CountryName`, `Region`, `CurrencyCode` |
| `dim_product` | `ProductName`, `ProductFamily` |
| `dim_mcc` | `MCCDescription`, `MCCGroup`, `MCCCode` |
| `dim_segment` | `SegmentName` |
| `dim_approvalstatus` | `ApprovalStatus`, `StatusDescription` |
| `dim_client` | `ClientName`, `Industry`, `GlobalAccountTier`, `HomeRegion` |

---

## Query shapes

### 1. Summary (default — no specific breakdown requested)
All key measures in one row-per-metric result. Used when the question doesn't
match any more specific pattern (e.g. "give me a summary", "how are we doing").

```dax
EVALUATE
UNION(
  ROW("Metric", "Total Spend USD",      "Value", FORMAT([Total Spend USD],      "$#,##0.00")),
  ROW("Metric", "Transaction Count",    "Value", FORMAT([Transaction Count],    "#,##0")),
  ROW("Metric", "Average Ticket USD",   "Value", FORMAT([Average Ticket USD],   "$#,##0.00")),
  ROW("Metric", "Approval Rate",        "Value", FORMAT([Approval Rate],        "0.0%")),
  ROW("Metric", "Interchange Revenue USD", "Value", FORMAT([Interchange Revenue USD], "$#,##0.00")),
  ROW("Metric", "Fraud Exposure Score", "Value", FORMAT([Fraud Exposure Score], "0.0"))
)
```

### 2. Trend (keywords: trend, year, yoy, over time, annual, by year)
```dax
EVALUATE
SUMMARIZECOLUMNS(
  dim_date[Year],
  "Total Spend USD",    [Total Spend USD],
  "Transaction Count",  [Transaction Count],
  "Average Ticket USD", [Average Ticket USD]
)
ORDER BY dim_date[Year] ASC
```

### 3. Segment (keywords: segment, vertical)
```dax
EVALUATE
SUMMARIZECOLUMNS(
  dim_segment[SegmentName],
  "Total Spend USD",   [Total Spend USD],
  "Transaction Count", [Transaction Count]
)
ORDER BY [Total Spend USD] DESC
```
> Fixed 2026-07-22: previously referenced `fact_commercialspend[SegmentName]`,
> which doesn't exist — `SegmentName` lives in `dim_segment`.

### 4. Merchant (keyword: merchant, excluding "merchant category")
Top 10 merchants by spend.
```dax
EVALUATE
TOPN(
  10,
  SUMMARIZECOLUMNS(
    dim_merchant[MerchantName],
    "Total Spend USD",   [Total Spend USD],
    "Transaction Count", [Transaction Count]
  ),
  [Total Spend USD], DESC
)
ORDER BY [Total Spend USD] DESC
```

### 5. Country / Region (keywords: countr* [country/countries], region)
```dax
EVALUATE
SUMMARIZECOLUMNS(
  dim_country[CountryName],
  dim_country[Region],
  "Total Spend USD",   [Total Spend USD],
  "Transaction Count", [Transaction Count]
)
ORDER BY [Total Spend USD] DESC
```

### 6. Product (keyword: product)
```dax
EVALUATE
SUMMARIZECOLUMNS(
  dim_product[ProductName],
  dim_product[ProductFamily],
  "Total Spend USD",   [Total Spend USD],
  "Transaction Count", [Transaction Count]
)
ORDER BY [Total Spend USD] DESC
```

### 7. Merchant Category / MCC (keywords: merchant category, mcc)
Top 10 categories by spend.
```dax
EVALUATE
TOPN(
  10,
  SUMMARIZECOLUMNS(
    dim_mcc[MCCDescription],
    dim_mcc[MCCGroup],
    "Total Spend USD",   [Total Spend USD],
    "Transaction Count", [Transaction Count]
  ),
  [Total Spend USD], DESC
)
ORDER BY [Total Spend USD] DESC
```

### 8. Approval / Decline (keywords: approv, declin)
```dax
EVALUATE
SUMMARIZECOLUMNS(
  dim_approvalstatus[ApprovalStatus],
  "Transaction Count", [Transaction Count],
  "Total Spend USD",   [Total Spend USD]
)
ORDER BY [Transaction Count] DESC
```

### 9. Fraud / Risk (keywords: fraud, risk score, high-risk)
Top 10 merchant category groups by fraud exposure.
```dax
EVALUATE
TOPN(
  10,
  SUMMARIZECOLUMNS(
    dim_mcc[MCCGroup],
    "Fraud Exposure Score",     [Fraud Exposure Score],
    "High Fraud Transactions",  [High Fraud Transactions],
    "Transaction Count",        [Transaction Count]
  ),
  [Fraud Exposure Score], DESC
)
ORDER BY [Fraud Exposure Score] DESC
```

### 10. Industry (keywords: industr* [industry/industries])
```dax
EVALUATE
SUMMARIZECOLUMNS(
  dim_client[Industry],
  "Total Spend USD",   [Total Spend USD],
  "Transaction Count", [Transaction Count]
)
ORDER BY [Total Spend USD] DESC
```

---

## Adding a new pattern

1. Add a new `const MY_SHAPE_DAX = ...` template in `fabricAgent.js`.
2. Add a keyword match in `pickDax()` — place more specific matches before
   general ones so they aren't shadowed.
3. Document the shape here.
4. If the tool result includes a new row shape (new column names), verify
   `synthesizeToolResult()` in `foundryAgent.js` still produces a sensible
   fallback sentence for it (used only if the agent echoes raw JSON).
5. Add the query to the `daxQuery` override tests, or ask the Foundry agent
   directly with `daxQuery` in the `query_semantic_model` tool call.
