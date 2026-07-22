# VISA Commercial Spend Analytics — Model Definition

**Model name:** VISA Commercial Spend Analytics + FilterSession Context Injection  
**Storage mode:** Direct Lake  
**Workspace:** VISA PBIE Context Injection  
**Grain:**
- `Fact_CommercialSpend` — one row per synthetic commercial-card transaction
- `Fact_FilterSession` — one row per host-app filter state transition

---

## Tables and Columns

### Dim_Date

| Column | Type | Description |
|--------|------|-------------|
| DateKey | Int64 | Surrogate key (YYYYMMDD) |
| Date | DateTime | Calendar date |
| Year | Int64 | Calendar year |
| Quarter | String | Quarter label (Q1–Q4) |
| Month | Int64 | Month number (1–12) |
| MonthName | String | Month name (January–December) |
| WeekNumber | Int64 | ISO week number |

### Dim_Client

| Column | Type | Description |
|--------|------|-------------|
| ClientKey | Int64 | Surrogate key |
| ClientCode | String | Client identifier code |
| ClientName | String | Client display name |
| ClientType | String | Client type (Corporate, SMB, etc.) |

### Dim_Country

| Column | Type | Description |
|--------|------|-------------|
| CountryKey | Int64 | Surrogate key |
| CountryCode | String | ISO 3166-1 alpha-2 code |
| CountryName | String | Full country name |
| Region | String | Geographic region |

### Dim_Product

| Column | Type | Description |
|--------|------|-------------|
| ProductKey | Int64 | Surrogate key |
| ProductCode | String | Product code |
| ProductName | String | Card product name (e.g. Visa Corporate) |
| ProductCategory | String | Category (Commercial, Consumer, etc.) |

### Dim_Segment

| Column | Type | Description |
|--------|------|-------------|
| SegmentKey | Int64 | Surrogate key |
| SegmentCode | String | Segment code |
| SegmentName | String | Segment name (Enterprise, SMB, etc.) |

### Dim_Merchant

| Column | Type | Description |
|--------|------|-------------|
| MerchantKey | Int64 | Surrogate key |
| MerchantCode | String | Merchant identifier |
| MerchantName | String | Merchant display name |

### Dim_MCC

| Column | Type | Description |
|--------|------|-------------|
| MCCKey | Int64 | Surrogate key |
| MCCCode | String | 4-digit Merchant Category Code |
| MCCDescription | String | MCC description (e.g. Software) |
| MCCCategory | String | Rolled-up category |

### Dim_ApprovalStatus

| Column | Type | Description |
|--------|------|-------------|
| ApprovalStatusKey | Int64 | Surrogate key |
| ApprovalStatus | String | Status value (Approved, Declined, Pending) |
| ApprovalStatusDescription | String | Long description |

### Fact_CommercialSpend

| Column | Type | Description |
|--------|------|-------------|
| TransactionKey | Int64 | Surrogate key |
| TransactionDateKey | Int64 | FK → Dim_Date[DateKey] |
| ClientKey | Int64 | FK → Dim_Client[ClientKey] |
| CountryKey | Int64 | FK → Dim_Country[CountryKey] |
| MerchantKey | Int64 | FK → Dim_Merchant[MerchantKey] |
| MCCKey | Int64 | FK → Dim_MCC[MCCKey] |
| ProductKey | Int64 | FK → Dim_Product[ProductKey] |
| SegmentKey | Int64 | FK → Dim_Segment[SegmentKey] |
| ApprovalStatusKey | Int64 | FK → Dim_ApprovalStatus[ApprovalStatusKey] |
| SpendAmountUSD | Decimal | Transaction spend amount in USD |
| TransactionCount | Int64 | Number of transactions in row |
| InterchangeRevenueUSD | Decimal | Interchange revenue in USD |
| FraudScore | Decimal | Fraud risk score (0–100) |

### Fact_FilterSession

| Column | Type | Description |
|--------|------|-------------|
| SessionKey | Int64 | Surrogate key |
| SessionId | String | UUID from host app (matches FilterContext.sessionId) |
| UserId | String | User UPN from host app |
| Timestamp | DateTime | Session state capture time |
| ReportPage | String | Active Power BI report page |
| FilterYear | String | Serialized Year filter values |
| FilterQuarter | String | Serialized Quarter filter values |
| FilterCountry | String | Serialized CountryName filter values |
| FilterClient | String | Serialized ClientName filter values |
| FilterSegment | String | Serialized SegmentName filter values |
| FilterProduct | String | Serialized ProductName filter values |
| FilterMCC | String | Serialized MCCDescription filter values |
| FilterMerchant | String | Serialized MerchantName filter values |
| FilterApprovalStatus | String | Serialized ApprovalStatus filter values |

---

## Relationships

| From | Cardinality | To |
|------|-------------|-----|
| Dim_Date[DateKey] | 1:* | Fact_CommercialSpend[TransactionDateKey] |
| Dim_Client[ClientKey] | 1:* | Fact_CommercialSpend[ClientKey] |
| Dim_Country[CountryKey] | 1:* | Fact_CommercialSpend[CountryKey] |
| Dim_Merchant[MerchantKey] | 1:* | Fact_CommercialSpend[MerchantKey] |
| Dim_MCC[MCCKey] | 1:* | Fact_CommercialSpend[MCCKey] |
| Dim_Product[ProductKey] | 1:* | Fact_CommercialSpend[ProductKey] |
| Dim_Segment[SegmentKey] | 1:* | Fact_CommercialSpend[SegmentKey] |
| Dim_ApprovalStatus[ApprovalStatusKey] | 1:* | Fact_CommercialSpend[ApprovalStatusKey] |

> `Fact_FilterSession` has no foreign key relationships to dimension tables — it stores serialized filter values as strings for agent grounding queries.

---

## Measures

See [measures.dax](./measures.dax) for full DAX definitions.

| Measure | Description |
|---------|-------------|
| Total Spend USD | Sum of SpendAmountUSD |
| Transaction Count | Sum of TransactionCount |
| Average Ticket USD | Total Spend / Transaction Count |
| Interchange Revenue USD | Sum of InterchangeRevenueUSD |
| Fraud Exposure Score | Average FraudScore |
| Approval Rate | Approved transactions / total transactions |
| Decline Rate | Declined transactions / total transactions |
| High Fraud Transactions | Transaction Count where FraudScore >= 70 |
| Spend YoY % | Year-over-year spend growth percentage — self-scoping via explicit Year-arithmetic filtering (see `docs/design_notes.md` Section 18), correct whether unfiltered (latest vs. prior year) or filtered/grouped by year |
