import { DefaultAzureCredential } from '@azure/identity';

// ── DAX query library ────────────────────────────────────────────────────────
// Each shape maps to a common analytics question pattern. pickDax() routes the
// user's question to the closest-matching shape. See semantic/dax/query_patterns.md
// for the full reference and semantic/metadata/field_map.json for column labels.

// Default: all key measures — used when no specific breakdown is requested.
const SUMMARY_DAX = `
EVALUATE
UNION(
  ROW("Metric", "Total Spend USD",      "Value", FORMAT([Total Spend USD],      "$#,##0.00")),
  ROW("Metric", "Transaction Count",    "Value", FORMAT([Transaction Count],    "#,##0")),
  ROW("Metric", "Average Ticket USD",   "Value", FORMAT([Average Ticket USD],   "$#,##0.00")),
  ROW("Metric", "Approval Rate",        "Value", FORMAT([Approval Rate],        "0.0%")),
  ROW("Metric", "Interchange Revenue USD", "Value", FORMAT([Interchange Revenue USD], "$#,##0.00")),
  ROW("Metric", "Fraud Exposure Score", "Value", FORMAT([Fraud Exposure Score], "0.0"))
)
`.trim();

// Year-over-year breakdown used when the question references trends or YoY.
const TREND_DAX = `
EVALUATE
SUMMARIZECOLUMNS(
  dim_date[Year],
  "Total Spend USD",    [Total Spend USD],
  "Transaction Count",  [Transaction Count],
  "Average Ticket USD", [Average Ticket USD]
)
ORDER BY dim_date[Year] ASC
`.trim();

// Spend by client segment (dim_segment, joined via fact_commercialspend[SegmentKey]).
const SEGMENT_DAX = `
EVALUATE
SUMMARIZECOLUMNS(
  dim_segment[SegmentName],
  "Total Spend USD",   [Total Spend USD],
  "Transaction Count", [Transaction Count]
)
ORDER BY [Total Spend USD] DESC
`.trim();

// Top merchants by spend.
const MERCHANT_DAX = `
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
`.trim();

// Spend by country / region.
const COUNTRY_DAX = `
EVALUATE
SUMMARIZECOLUMNS(
  dim_country[CountryName],
  dim_country[Region],
  "Total Spend USD",   [Total Spend USD],
  "Transaction Count", [Transaction Count]
)
ORDER BY [Total Spend USD] DESC
`.trim();

// Spend by product / product family.
const PRODUCT_DAX = `
EVALUATE
SUMMARIZECOLUMNS(
  dim_product[ProductName],
  dim_product[ProductFamily],
  "Total Spend USD",   [Total Spend USD],
  "Transaction Count", [Transaction Count]
)
ORDER BY [Total Spend USD] DESC
`.trim();

// Spend by merchant category (MCC).
const MCC_DAX = `
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
`.trim();

// Approval / decline breakdown by status.
const APPROVAL_DAX = `
EVALUATE
SUMMARIZECOLUMNS(
  dim_approvalstatus[ApprovalStatus],
  "Transaction Count", [Transaction Count],
  "Total Spend USD",   [Total Spend USD]
)
ORDER BY [Transaction Count] DESC
`.trim();

// Risk / fraud breakdown by merchant category group (highest fraud exposure first).
const FRAUD_DAX = `
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
`.trim();

// Spend by client industry.
const INDUSTRY_DAX = `
EVALUATE
SUMMARIZECOLUMNS(
  dim_client[Industry],
  "Total Spend USD",   [Total Spend USD],
  "Transaction Count", [Transaction Count]
)
ORDER BY [Total Spend USD] DESC
`.trim();

let msalClient = null;
let _credential = null;

function getCredential() {
  if (!_credential) _credential = new DefaultAzureCredential();
  return _credential;
}

async function getPowerBIToken() {
  const tokenResponse = await getCredential().getToken(
    'https://analysis.windows.net/powerbi/api/.default'
  );
  if (!tokenResponse?.token) throw new Error('Failed to acquire Power BI access token');
  return tokenResponse.token;
}

/**
 * Route a natural-language question to the closest-matching DAX shape.
 * Order matters — more specific patterns are checked before general ones.
 */
function pickDax(question) {
  const q = (question ?? '').toLowerCase();
  if (/fraud|risk score|high.risk/.test(q)) return FRAUD_DAX;
  if (/approv|declin/.test(q)) return APPROVAL_DAX;
  if (/merchant categor|\bmcc\b/.test(q)) return MCC_DAX;
  if (/merchant/.test(q)) return MERCHANT_DAX;
  if (/countr|region/.test(q)) return COUNTRY_DAX;
  if (/product/.test(q)) return PRODUCT_DAX;
  if (/industr/.test(q)) return INDUSTRY_DAX;
  if (/segment|vertical/.test(q)) return SEGMENT_DAX;
  if (/trend|year|yoy|over.time|annual|by year/.test(q)) return TREND_DAX;
  return SUMMARY_DAX;
}

/**
 * Convert Power BI executeQueries rows into a clean key→value object.
 * Column names arrive as `[TableName][ColumnName]` or `[ColumnName]` — strip brackets.
 */
/**
 * Power BI returns column names like `[Metric]`, `[Total Spend USD]`, or `dim_date[Year]`.
 * Extract the last bracketed segment so we get clean names like `Metric`, `Total Spend USD`, `Year`.
 */
function cleanCol(k) {
  const m = k.match(/\[([^\]]+)\]$/);
  return m ? m[1] : k;
}

function normalizeRows(rows) {
  return (rows ?? []).map(row =>
    Object.fromEntries(
      Object.entries(row).map(([k, v]) => [cleanCol(k), v ?? null])
    )
  );
}

/**
 * Execute a DAX query against the Fabric semantic model via the Power BI REST API.
 * Uses the service principal (CLIENT_ID/CLIENT_SECRET) which has Admin access to the workspace.
 *
 * @param {{ question: string, context?: object, daxQuery?: string }} params
 * @returns {Promise<string>} query results as formatted text for the Foundry agent to interpret
 */
export async function queryFabricAgent({ question, context, daxQuery }) {
  const accessToken = await getPowerBIToken();
  const groupId   = process.env.WORKSPACE_ID;
  const datasetId = process.env.DATASET_ID;
  const query = daxQuery ?? pickDax(question);

  const contextNote = context
    ? Object.entries(context).map(([k, v]) => `${k}=${v}`).join(', ')
    : null;

  const url = `https://api.powerbi.com/v1.0/myorg/groups/${groupId}/datasets/${datasetId}/executeQueries`;

  const response = await fetch(url, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${accessToken}`,
      'Content-Type': 'application/json'
    },
    body: JSON.stringify({
      queries: [{ query }],
      serializerSettings: { includeNulls: true }
    })
  });

  if (!response.ok) {
    const detail = await response.text();
    throw new Error(`Power BI executeQueries failed (${response.status}): ${detail}`);
  }

  const data = await response.json();
  const rows = data.results?.[0]?.tables?.[0]?.rows ?? [];
  if (!rows.length) return JSON.stringify({ error: 'No data returned from semantic model.', question });
  return JSON.stringify({
    source: 'Power BI semantic model',
    question,
    filters: contextNote || null,
    rows: normalizeRows(rows)
  });
}
