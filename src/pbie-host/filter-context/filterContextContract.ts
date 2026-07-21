/**
 * VISA Commercial Spend Analytics — Filter Context Contract
 *
 * This TypeScript contract defines the shape of the filter state object
 * that flows between all four layers of the Pattern 2 architecture:
 *   1. Host application prompt / filter UI  (accumulated in memory)
 *   2. Power BI Embedded report.setFilters() (applied to the iframe)
 *   3. Fact_FilterSession row written to Fabric Lakehouse (persisted)
 *   4. Foundry / Fabric Data Agent user turn (agent grounding context)
 *
 * Source schema: embedded_filter_context_schema.json
 */

// ---------------------------------------------------------------------------
// Filter dimension values
// ---------------------------------------------------------------------------

/** All filter-able dimensions in the VISA Commercial Spend semantic model. */
export interface FilterContextFilters {
  Year?: number[];
  Quarter?: string[];            // "Q1" | "Q2" | "Q3" | "Q4"
  CountryName?: string[];
  ClientName?: string[];
  SegmentName?: string[];
  ProductName?: string[];
  MCCDescription?: string[];
  MerchantName?: string[];
  ApprovalStatus?: string[];     // "Approved" | "Declined" | "Pending"
}

// ---------------------------------------------------------------------------
// Root context object
// ---------------------------------------------------------------------------

/** Full filter context payload shared across all layers. */
export interface FilterContext {
  /** Unique session identifier — written to Fact_FilterSession.SessionId. */
  sessionId: string;
  /** User UPN from host application auth context. */
  userId: string;
  /** ISO 8601 timestamp of the filter state snapshot. */
  timestamp: string;
  /** Power BI report ID (from embed token response). */
  reportId?: string;
  /** Active Power BI report page name. */
  reportPage: string;
  /** Active filter selections. Omitted keys = no filter applied for that dimension. */
  filters: FilterContextFilters;
  /** Current user question, populated when sending to the agent. */
  question?: string;
  /**
   * Authoritative context instruction injected into the agent user turn.
   * Instructs the agent to scope answers to the active filter state.
   */
  contextPrompt: string;
}

// ---------------------------------------------------------------------------
// Serialization helper for Fact_FilterSession write
// ---------------------------------------------------------------------------

/** Flat row shape for writing to Fact_FilterSession in the Lakehouse. */
export interface FilterSessionRow {
  SessionId: string;
  UserId: string;
  Timestamp: string;
  ReportPage: string;
  FilterYear: string;
  FilterQuarter: string;
  FilterCountry: string;
  FilterClient: string;
  FilterSegment: string;
  FilterProduct: string;
  FilterMCC: string;
  FilterMerchant: string;
  FilterApprovalStatus: string;
}

/** Serialize a FilterContext to a flat Fact_FilterSession row. */
export function toFilterSessionRow(ctx: FilterContext): FilterSessionRow {
  const f = ctx.filters;
  return {
    SessionId: ctx.sessionId,
    UserId: ctx.userId,
    Timestamp: ctx.timestamp,
    ReportPage: ctx.reportPage,
    FilterYear: (f.Year ?? []).join(','),
    FilterQuarter: (f.Quarter ?? []).join(','),
    FilterCountry: (f.CountryName ?? []).join(','),
    FilterClient: (f.ClientName ?? []).join(','),
    FilterSegment: (f.SegmentName ?? []).join(','),
    FilterProduct: (f.ProductName ?? []).join(','),
    FilterMCC: (f.MCCDescription ?? []).join(','),
    FilterMerchant: (f.MerchantName ?? []).join(','),
    FilterApprovalStatus: (f.ApprovalStatus ?? []).join(','),
  };
}

// ---------------------------------------------------------------------------
// Factory
// ---------------------------------------------------------------------------

const DEFAULT_CONTEXT_PROMPT =
  'Use this filter context as authoritative report state. ' +
  'Answer only for selected years, countries, segments, products, MCCs, ' +
  'and approval status unless the user explicitly asks to compare outside ' +
  'the current context.';

/** Create a new FilterContext with defaults applied. */
export function createFilterContext(
  userId: string,
  reportPage: string,
  filters: FilterContextFilters = {},
  reportId?: string,
): FilterContext {
  return {
    sessionId: `SSN-${Date.now()}`,
    userId,
    timestamp: new Date().toISOString(),
    reportId,
    reportPage,
    filters,
    contextPrompt: DEFAULT_CONTEXT_PROMPT,
  };
}

/** Return a copy of the context with updated filter values. */
export function updateFilters(
  ctx: FilterContext,
  patch: Partial<FilterContextFilters>,
): FilterContext {
  return {
    ...ctx,
    timestamp: new Date().toISOString(),
    filters: { ...ctx.filters, ...patch },
  };
}

/** Return true if any filter dimension has at least one value selected. */
export function hasActiveFilters(ctx: FilterContext): boolean {
  return Object.values(ctx.filters).some((v) => Array.isArray(v) && v.length > 0);
}
