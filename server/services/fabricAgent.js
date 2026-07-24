import { DefaultAzureCredential } from '@azure/identity';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { resolveRoles, resolveEntitlement, ENTITLEMENT_ROLE_NAME } from './rlsTestUsers.js';

const execFileAsync = promisify(execFile);
const __dirname = path.dirname(fileURLToPath(import.meta.url));
const XMLA_SCRIPT_PATH = path.join(__dirname, '..', '..', 'scripts', 'query_xmla.ps1');

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

// ── Page business-value grounding ───────────────────────────────────────────
// Maps each report page (server/services/contextService.js normalizeContext's `page`
// value, i.e. the PBIR page displayName) to the business outcome it was designed to
// serve (per docs/demo_script.md Scene 2 and the report's actual visual layout —
// Commercial_Spend_Analytics.Report/definition/pages/*/page.json) and the DAX shapes
// (see DAX_SHAPES below) needed to cover every visual on that page. Used to ground
// exploratory questions ("what am I looking at?") in the model's real design intent,
// not just the single measure a keyword match would pick.
const PAGE_META = {
  'Overview': {
    purpose: 'the portfolio-wide snapshot of commercial card spend, transaction volume, approval health, and interchange revenue — the entry point into the Commercial Spend Analytics model.',
    shapes: ['summary', 'trend', 'segment', 'merchant', 'mcc']
  },
  'Risk & Approval': {
    purpose: 'transaction approval and decline patterns, and fraud exposure across merchants and merchant categories in the Commercial Spend Analytics model.',
    shapes: ['fraud', 'approval']
  },
  'Executive Summary': {
    purpose: 'a leadership-level rollup of the program\u2019s headline KPIs \u2014 total spend, approval rate, year-over-year growth, interchange revenue, and fraud exposure \u2014 alongside where that spend concentrates by client segment, client, and product.',
    shapes: ['summary', 'segment']
  },
  'Supplier Analysis': {
    purpose: 'where commercial spend concentrates across merchants and merchant categories, used to identify top suppliers and negotiating-leverage opportunities.',
    shapes: ['summary', 'merchant', 'mcc']
  },
  'Spend Trends': {
    purpose: 'how spend, transaction volume, and average ticket size are trending year over year, to spot growth, seasonality, and momentum shifts in the program.',
    shapes: ['trend']
  },
  'Savings Opportunities': {
    purpose: 'interchange revenue alongside approval and decline performance, used to surface where declines or inefficiencies are costing the program money and where there\u2019s room to improve.',
    shapes: ['summary', 'approval']
  },
  'Filter Context Analysis': {
    purpose: 'telemetry captured from how users filter and navigate the report itself (Fact_FilterSession) \u2014 this page demonstrates the context-injection mechanism that grounds this assistant, rather than commercial spend business data.',
    shapes: ['summary']
  }
};

// Registry of every DAX shape above, keyed for PAGE_META.shapes lookups.
const DAX_SHAPES = {
  summary:  { label: 'Key metrics',              dax: SUMMARY_DAX },
  trend:    { label: 'Year-over-year trend',     dax: TREND_DAX },
  segment:  { label: 'Spend by segment',         dax: SEGMENT_DAX },
  merchant: { label: 'Top merchants by spend',   dax: MERCHANT_DAX },
  country:  { label: 'Spend by country',         dax: COUNTRY_DAX },
  product:  { label: 'Spend by product',         dax: PRODUCT_DAX },
  mcc:      { label: 'Spend by merchant category', dax: MCC_DAX },
  approval: { label: 'Approval vs. decline',     dax: APPROVAL_DAX },
  fraud:    { label: 'Fraud exposure by category', dax: FRAUD_DAX },
  industry: { label: 'Spend by industry',        dax: INDUSTRY_DAX }
};

/**
 * True for open-ended/exploratory questions ("what am I looking at?") that should get
 * the full, business-grounded, exhaustive-per-page answer (PAGE_META) instead of a
 * single keyword-matched DAX shape (pickDax below).
 */
function isExploratoryQuestion(question) {
  const q = (question ?? '').toLowerCase();
  return /what (am i|do you|can you) (see|looking at|showing|seeing)|what('?s| is) (this|on this|here|going on)|tell me about (this|the) page|explain (this|the) page|summar(y|ize)( this| the)? page|overview of (this|the) page|what should i know|walk me through|give me a (summary|recap|rundown)/.test(q);
}

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

// ── Fabric Data Agent (conversational, native LLM-backed) ──────────────────
// Wires the chat backend to the actual Commercial_Spend_Agent Fabric Data Agent item
// (Commercial_Spend_Agent.DataAgent) instead of the fixed DAX_SHAPES/pickDax() path.
// This is a native Fabric capability (Microsoft-managed model backing the Data
// Agent's own NL->query translation) — NOT a Foundry/Copilot Studio orchestration
// layer. Gated by USE_DATA_AGENT so the proven deterministic path remains the
// default/fallback if this isn't configured or a call fails.
//
// Protocol: the Fabric Data Agent's published endpoint speaks the OpenAI Assistants
// API shape (create assistant -> create thread -> post message -> create run -> poll
// -> read messages), per Microsoft's documented "use the Fabric data agent
// programmatically" flow. FABRIC_AGENT_ENDPOINT must be the *published* base URL
// (Fabric portal -> Commercial_Spend_Agent -> Publish -> Settings) — this is not
// discoverable via the Fabric REST API (Get/Publish DataAgent responses do not
// include it), so it must be captured manually once and stored in .env.
const FABRIC_AGENT_API_VERSION = '2024-05-01-preview';
const FABRIC_AGENT_POLL_INTERVAL_MS = 1500;
const FABRIC_AGENT_TIMEOUT_MS = 45000;
const FABRIC_AGENT_TERMINAL_STATES = new Set(['completed', 'failed', 'cancelled', 'expired', 'requires_action']);

// conversationId -> { assistantId, threadId } — reused across turns so the Data Agent
// retains real multi-turn memory within a chat session, instead of starting a fresh
// thread per question (server/routes/chat.js already mints/echoes conversationId).
const dataAgentThreads = new Map();

async function getFabricToken() {
  const tokenResponse = await getCredential().getToken('https://api.fabric.microsoft.com/.default');
  if (!tokenResponse?.token) throw new Error('Failed to acquire Fabric access token');
  return tokenResponse.token;
}

async function callDataAgent(basePath, pathSuffix, method, token, body) {
  const url = `${basePath}${pathSuffix}${pathSuffix.includes('?') ? '&' : '?'}api-version=${FABRIC_AGENT_API_VERSION}`;
  const res = await fetch(url, {
    method,
    headers: {
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/json'
    },
    body: body !== undefined ? JSON.stringify(body) : undefined
  });
  if (!res.ok) {
    const detail = await res.text().catch(() => '');
    throw new Error(`Fabric Data Agent ${method} ${pathSuffix} failed (${res.status}): ${detail}`);
  }
  return res.status === 204 ? null : res.json();
}

async function getOrCreateDataAgentThread(basePath, token, conversationId) {
  const cached = conversationId && dataAgentThreads.get(conversationId);
  if (cached) return cached;

  const assistant = await callDataAgent(basePath, '/assistants', 'POST', token, { model: 'not used' });
  const thread = await callDataAgent(basePath, '/threads', 'POST', token, {});
  const entry = { assistantId: assistant.id, threadId: thread.id };
  if (conversationId) dataAgentThreads.set(conversationId, entry);
  return entry;
}

/**
 * Query the live Commercial_Spend_Agent Fabric Data Agent (native LLM-backed NL->DAX)
 * instead of the fixed DAX_SHAPES/pickDax() path. Reuses one assistant+thread per
 * conversationId so follow-up questions retain conversational memory.
 *
 * @param {{ question: string, context?: object, conversationId?: string }} params
 * @returns {Promise<string>} HTML-safe answer paragraph
 */
async function queryDataAgentConversation({ question, context, conversationId }) {
  const basePath = process.env.FABRIC_AGENT_ENDPOINT;
  if (!basePath) throw new Error('FABRIC_AGENT_ENDPOINT not set in .env (required when USE_DATA_AGENT=true)');

  const contextNote = describeContext(context);
  const enrichedQuestion = contextNote
    ? `${question}\n\n[Current report context: ${contextNote}]`
    : question;

  const token = await getFabricToken();
  const { assistantId, threadId } = await getOrCreateDataAgentThread(basePath, token, conversationId);

  await callDataAgent(basePath, `/threads/${threadId}/messages`, 'POST', token, {
    role: 'user',
    content: enrichedQuestion
  });

  let run = await callDataAgent(basePath, `/threads/${threadId}/runs`, 'POST', token, {
    assistant_id: assistantId
  });

  const start = Date.now();
  while (!FABRIC_AGENT_TERMINAL_STATES.has(run.status)) {
    if (Date.now() - start > FABRIC_AGENT_TIMEOUT_MS) {
      throw new Error(`Fabric Data Agent run timed out after ${FABRIC_AGENT_TIMEOUT_MS}ms (last status=${run.status})`);
    }
    await new Promise(resolve => setTimeout(resolve, FABRIC_AGENT_POLL_INTERVAL_MS));
    run = await callDataAgent(basePath, `/threads/${threadId}/runs/${run.id}`, 'GET', token);
  }

  if (run.status !== 'completed') {
    throw new Error(`Fabric Data Agent run finished with status: ${run.status}`);
  }

  const messages = await callDataAgent(basePath, `/threads/${threadId}/messages?order=asc`, 'GET', token);
  const assistantMessages = (messages?.data ?? []).filter(m => m.role === 'assistant');
  const last = assistantMessages[assistantMessages.length - 1];
  const text = last?.content?.[0]?.text?.value ?? "I couldn't get an answer from the Data Agent.";

  return `<p>${escapeHtml(text).replace(/\n/g, '<br>')}</p>`;
}

/**
 * Execute a DAX query against the semantic model via the XMLA endpoint, shelling out to
 * scripts/query_xmla.ps1 (Invoke-ASCmd / SqlServer PowerShell module).
 *
 * Design decision + rationale: docs/design_notes.md Section 15c/15f. This replaces
 * executeQueries as the primary query mechanism once XMLA_ENABLED/USE_XMLA is turned on,
 * to avoid the same executeQueries+SPN RLS limitation VISA hit in production.
 *
 * Auth: uses the SP's own ClientId/ClientSecret/TenantId directly (the documented
 * `User ID=app:<ClientId>@<TenantId>` MSOLAP connection-string pattern) — confirmed
 * working 2026-07-22 against the live model, unlike passing a pre-acquired bearer
 * token as Password (which failed with "Authentication failed for all authenticators").
 * This is a different tenant permission gate than the one that blocks SP
 * client-credentials for executeQueries, so it's viable here.
 *
 * RLS enforcement (docs/design_notes.md Section 16): since effectiveUserName here is a
 * synthetic test UPN (not a real Entra ID account), we cannot use XMLA's EffectiveUserName
 * property. Default mechanism is entitlement-based dynamic RLS via CUSTOMDATA(): we resolve
 * the user's entitlement value via rlsTestUsers.resolveEntitlement() and activate it through
 * the connection string's `Roles=Role_Entitlement` + `CustomData=<value>` properties — a
 * single dynamic TMDL role (dim_client[HomeRegion] = CUSTOMDATA()) evaluates it, replacing
 * the need for one static role per value. Pass rlsMode: 'static' to fall back to the
 * legacy per-value Roles= mapping (rlsTestUsers.resolveRoles()) for comparison purposes
 * (see scripts/compare_rls_mechanisms.ps1).
 *
 * @param {{ query: string, effectiveUserName?: string, rlsMode?: 'entitlement'|'static' }} params
 * @returns {Promise<Array<object>>} normalized rows (already clean column names)
 */
async function runXmlaQuery({ query, effectiveUserName, rlsMode = 'entitlement' }) {
  const xmlaEndpoint = process.env.XMLA_ENDPOINT;
  const datasetName = process.env.DATASET_NAME || 'Commercial_Spend_Analytics';
  const clientId = process.env.CLIENT_ID;
  const clientSecret = process.env.CLIENT_SECRET;
  const tenantId = process.env.TENANT_ID;

  if (!xmlaEndpoint) throw new Error('XMLA_ENDPOINT not set in .env (required when USE_XMLA=true)');
  if (!clientId || !clientSecret || !tenantId) {
    throw new Error('CLIENT_ID/CLIENT_SECRET/TENANT_ID must be set in .env (required when USE_XMLA=true)');
  }

  let roles = [];
  let customData;
  if (rlsMode === 'static') {
    roles = resolveRoles(effectiveUserName);
  } else {
    const entitlement = resolveEntitlement(effectiveUserName);
    if (entitlement) {
      roles = [ENTITLEMENT_ROLE_NAME];
      customData = entitlement;
    }
  }

  const args = [
    '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
    '-File', XMLA_SCRIPT_PATH,
    '-XmlaEndpoint', xmlaEndpoint,
    '-Database', datasetName,
    '-Query', query,
    '-ClientId', clientId,
    '-ClientSecret', clientSecret,
    '-TenantId', tenantId
  ];
  if (roles.length) {
    args.push('-Roles', roles.join(','));
  }
  if (customData) {
    args.push('-CustomData', customData);
  }

  let stdout;
  try {
    ({ stdout } = await execFileAsync('pwsh', args, { maxBuffer: 10 * 1024 * 1024 }));
  } catch (err) {
    throw new Error(`XMLA query failed: ${err.stderr || err.message}`);
  }

  const trimmed = stdout.trim();
  if (!trimmed) return [];
  const parsed = JSON.parse(trimmed);
  return Array.isArray(parsed) ? parsed : [parsed];
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
 * Turn normalized query rows into a natural-language answer for the chat UI.
 *
 * NOTE: this replaces the synthesis the (now-removed) Azure AI Foundry agent used to
 * do — previously `queryFabricAgent()`'s raw JSON was handed to an LLM as tool output
 * and the LLM wrote the natural-language reply. Now that there's no LLM in the loop
 * (see "Foundry Agent removal" in docs/design_notes.md), this deterministic formatter
 * is the only thing standing between the raw DAX result and the user-facing answer —
 * don't go back to returning JSON.stringify(...) directly here.
 */
/**
 * Render a normalized business context (server/services/contextService.js#normalizeContext
 * shape: { page, filters: {}, slicers: {}, selections: {} }) as a short inline phrase for
 * the "(filtered by ...)" suffix. Must NOT template-string the nested objects directly —
 * that produces "[object Object]" since filters/slicers/selections are objects, not scalars.
 * Omits any of the three groups entirely when empty, instead of printing an empty object.
 */
function describeContext(context) {
  if (!context) return null;
  const parts = [];
  if (context.page) parts.push(`page=${context.page}`);
  for (const group of [context.filters, context.slicers, context.selections]) {
    for (const [k, v] of Object.entries(group || {})) {
      parts.push(`${k}=${Array.isArray(v) ? v.join('/') : v}`);
    }
  }
  return parts.length ? parts.join(', ') : null;
}

function formatAnswer({ question, rows, contextNote }) {
  if (!rows || !rows.length) {
    return `<p>I couldn't find any data for "${escapeHtml(question)}".</p>`;
  }

  const filterSuffix = contextNote ? ` <span class="chat-filter-note">(filtered by ${escapeHtml(contextNote)})</span>` : '';
  const keys = Object.keys(rows[0]);

  // Summary shape: rows of {Metric, Value} pairs — render as a two-column table.
  if (keys.length === 2 && keys.includes('Metric') && keys.includes('Value')) {
    const table = renderHtmlTable(rows, 'Metric', ['Value']);
    return `<p><strong>Here's what I found</strong>${filterSuffix}:</p>${table}`;
  }

  // Breakdown shape: first column is the category label, remaining columns are measures.
  const [labelKey, ...valueKeys] = keys;
  const table = renderHtmlTable(rows, labelKey, valueKeys);
  const bars = renderHtmlBars(rows, labelKey, valueKeys[0]);
  return `<p><strong>Breakdown by ${escapeHtml(labelKey)}</strong>${filterSuffix}:</p>${table}${bars}`;
}

/**
 * Escape a value for safe insertion into the HTML answer string. Applied to every
 * interpolated value — including data-derived labels/measures — as defense in depth,
 * and is essential for `question`, which is raw, untrusted user input reflected back
 * in the "couldn't find any data" message (server/routes/chat.js passes it through
 * unmodified). The frontend renders this HTML via innerHTML (frontend/chat.js), so
 * anything not escaped here would be a stored/reflected XSS risk.
 */
function escapeHtml(value) {
  return String(value ?? '').replace(/[&<>"']/g, (c) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
  }[c]));
}

/**
 * Format a single measure's cell value for display. DAX shapes other than SUMMARY_DAX
 * return raw numbers (not pre-formatted with FORMAT()), so a "Total Spend USD" column
 * would otherwise render as an unrounded float like "30231171.03000009" with no $ sign.
 * Values that are already formatted strings (SUMMARY_DAX uses FORMAT(), e.g. "$74,812,278.37"
 * or "94.0%") are passed through untouched.
 */
function formatMeasureValue(colName, rawValue) {
  if (typeof rawValue === 'string' && /[$%]/.test(rawValue)) return rawValue;
  const num = Number(rawValue);
  if (!Number.isFinite(num)) return String(rawValue ?? '');
  if (/USD$/.test(colName)) {
    return `$${num.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
  }
  if (/Score$/.test(colName)) return num.toFixed(1);
  return Math.round(num).toLocaleString('en-US');
}

/**
 * Render rows as a real HTML table (frontend/chat.js renders the answer via innerHTML,
 * frontend/styles.css supplies .chat-table styling) — replaces the earlier plain-text/
 * ASCII table, which only lined up as a monospace-font approximation.
 */
function renderHtmlTable(rows, labelKey, valueKeys) {
  const headerCells = [labelKey, ...valueKeys]
    .map(h => `<th>${escapeHtml(h)}</th>`).join('');
  const bodyRows = rows.map(r => {
    const labelCell = `<td>${escapeHtml(r[labelKey])}</td>`;
    const valueCells = valueKeys
      .map(k => `<td class="chat-num">${escapeHtml(formatMeasureValue(k, r[k]))}</td>`)
      .join('');
    return `<tr>${labelCell}${valueCells}</tr>`;
  }).join('');
  return `<table class="chat-table"><thead><tr>${headerCells}</tr></thead><tbody>${bodyRows}</tbody></table>`;
}

/**
 * Render a small rich bar chart (div-based, styled via .chat-bars/.chat-bar-* in
 * frontend/styles.css) for a breakdown's primary numeric column, so the assistant's
 * response includes a real visual, not just a list of numbers. Returns '' when the
 * values aren't numeric or there's nothing to compare.
 */
function renderHtmlBars(rows, labelKey, valueKey, maxRows = 6) {
  if (!valueKey) return '';
  const entries = rows.slice(0, maxRows).map(r => ({
    label: r[labelKey],
    value: Number(String(r[valueKey] ?? '').replace(/[^0-9.\-]/g, ''))
  })).filter(e => Number.isFinite(e.value));
  if (entries.length < 2) return '';

  const max = Math.max(...entries.map(e => Math.abs(e.value)));
  if (!max) return '';

  const bars = entries.map(e => {
    const pct = Math.max(4, Math.round((Math.abs(e.value) / max) * 100));
    return `<div class="chat-bar-row"><span class="chat-bar-label">${escapeHtml(e.label)}</span>` +
      `<span class="chat-bar-track"><span class="chat-bar-fill" style="width:${pct}%"></span></span></div>`;
  }).join('');
  return `<div class="chat-bars">${bars}</div>`;
}

/**
 * Render the "exhaustive" answer for an exploratory question (isExploratoryQuestion) on
 * a known report page: a business-purpose framing sentence (PAGE_META, grounded in
 * docs/demo_script.md's design intent for each page) followed by every DAX shape that
 * page's visuals cover, instead of just the single shape a keyword match would pick.
 */
function formatExhaustiveAnswer({ page, pageMeta, sections, contextNote }) {
  const filterSuffix = contextNote ? ` <span class="chat-filter-note">(${escapeHtml(contextNote)})</span>` : '';
  const intro = `<p>You're viewing the <strong>${escapeHtml(page)}</strong> page${filterSuffix}. This page focuses on ${escapeHtml(pageMeta.purpose)}</p>`;

  const blocks = sections.map(({ label, rows }) => {
    if (!rows.length) return `<h4>${escapeHtml(label)}</h4><p>No data for the current filter context.</p>`;

    const keys = Object.keys(rows[0]);
    if (keys.length === 2 && keys.includes('Metric') && keys.includes('Value')) {
      return `<h4>${escapeHtml(label)}</h4>${renderHtmlTable(rows, 'Metric', ['Value'])}`;
    }

    const [labelKey, ...valueKeys] = keys;
    const limitedRows = rows.slice(0, 6);
    const table = renderHtmlTable(limitedRows, labelKey, valueKeys);
    const bars = renderHtmlBars(rows, labelKey, valueKeys[0]);
    return `<h4>${escapeHtml(label)}</h4>${table}${bars}`;
  });

  return `${intro}${blocks.join('')}`;
}

/**
 * Execute one DAX query against the Fabric semantic model, via XMLA or the Power BI
 * executeQueries REST API depending on USE_XMLA (docs/design_notes.md Section 15c).
 * Always returns clean-column-name rows — REST rows go through normalizeRows(),
 * XMLA rows already come back clean from scripts/query_xmla.ps1's own schema mapping.
 *
 * @param {string} query
 * @param {{ effectiveUserName?: string, rlsMode?: 'entitlement'|'static' }} params
 * @returns {Promise<Array<object>>}
 */
async function executeDax(query, { effectiveUserName, rlsMode } = {}) {
  if (process.env.USE_XMLA === 'true') {
    return runXmlaQuery({ query, effectiveUserName, rlsMode });
  }

  const accessToken = await getPowerBIToken();
  const groupId   = process.env.WORKSPACE_ID;
  const datasetId = process.env.DATASET_ID;

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
  return normalizeRows(rows);
}

/**
 * Execute a DAX query against the Fabric semantic model and return a natural-language
 * answer for the chat UI.
 *
 * If USE_DATA_AGENT=true, questions are routed to the live Commercial_Spend_Agent
 * Fabric Data Agent (native LLM-backed NL->DAX, see queryDataAgentConversation above)
 * first; any failure (not configured, not published, timeout, etc.) falls back to the
 * deterministic DAX_SHAPES/pickDax() path below so the chat never hard-fails.
 *
 * For exploratory questions on a known report page (isExploratoryQuestion + PAGE_META),
 * the fallback path runs every DAX shape that page's visuals cover (in parallel) and
 * returns a single business-grounded answer covering all of them, instead of one
 * keyword-matched shape.
 *
 * @param {{ question: string, context?: object, daxQuery?: string, effectiveUserName?: string, rlsMode?: 'entitlement'|'static', conversationId?: string }} params
 * @returns {Promise<string>} query results as formatted, natural-language text
 */
export async function queryFabricAgent({ question, context, daxQuery, effectiveUserName, rlsMode, conversationId }) {
  if (!daxQuery && process.env.USE_DATA_AGENT === 'true') {
    try {
      return await queryDataAgentConversation({ question, context, conversationId });
    } catch (err) {
      console.error('[fabricAgent] Data Agent query failed, falling back to direct DAX:', err.message);
    }
  }

  const contextNote = describeContext(context);
  const pageMeta = context?.page ? PAGE_META[context.page] : null;

  if (!daxQuery && pageMeta && isExploratoryQuestion(question)) {
    const sections = await Promise.all(
      pageMeta.shapes.map(async (shapeKey) => {
        const shape = DAX_SHAPES[shapeKey];
        const rows = await executeDax(shape.dax, { effectiveUserName, rlsMode });
        return { label: shape.label, rows };
      })
    );
    return formatExhaustiveAnswer({ page: context.page, pageMeta, sections, contextNote });
  }

  const query = daxQuery ?? pickDax(question);
  const rows = await executeDax(query, { effectiveUserName, rlsMode });
  return formatAnswer({ question, rows, contextNote });
}
