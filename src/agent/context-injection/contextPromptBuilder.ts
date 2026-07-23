/**
 * VISA Commercial Spend Analytics — Context Prompt Builder
 *
 * Converts the current FilterContext state into a structured grounding payload
 * for the Fabric Data Agent.
 *
 * The grounding payload contains:
 *   - systemContext: injected as a pre-turn instruction
 *   - userTurn: the structured user message with [Report Context] + [User Question]
 *   - rawFilterContext: the full FilterContext for audit / Fact_FilterSession write
 */

import type { FilterContext, FilterContextFilters } from '../pbie-host/filter-context/filterContextContract.js';

// ---------------------------------------------------------------------------
// Output types
// ---------------------------------------------------------------------------

export interface AgentGroundingPayload {
  /** System-level instruction for the agent. */
  systemContext: string;
  /**
   * Structured user turn: [Report Context] block + [User Question].
   * This is the string sent as the user message in the chat backend's query.
   */
  userTurn: string;
  /** Full filter context — attach to POST /api/chat as rawContext. */
  rawFilterContext: FilterContext;
}

/** Shape expected by POST /api/chat on the backend. */
export interface ChatApiPayload {
  question: string;
  rawContext: FilterContext;
}

// ---------------------------------------------------------------------------
// Internal: render the active filter state as a readable block
// ---------------------------------------------------------------------------

function renderFilterBlock(filters: FilterContextFilters): string {
  const lines: string[] = [];

  if (filters.Year?.length)           lines.push(`  Year: ${filters.Year.join(', ')}`);
  if (filters.Quarter?.length)        lines.push(`  Quarter: ${filters.Quarter.join(', ')}`);
  if (filters.CountryName?.length)    lines.push(`  Country: ${filters.CountryName.join(', ')}`);
  if (filters.ClientName?.length)     lines.push(`  Client: ${filters.ClientName.join(', ')}`);
  if (filters.SegmentName?.length)    lines.push(`  Segment: ${filters.SegmentName.join(', ')}`);
  if (filters.ProductName?.length)    lines.push(`  Product: ${filters.ProductName.join(', ')}`);
  if (filters.MCCDescription?.length) lines.push(`  MCC: ${filters.MCCDescription.join(', ')}`);
  if (filters.MerchantName?.length)   lines.push(`  Merchant: ${filters.MerchantName.join(', ')}`);
  if (filters.ApprovalStatus?.length) lines.push(`  Approval Status: ${filters.ApprovalStatus.join(', ')}`);

  return lines.length > 0
    ? lines.join('\n')
    : '  (no filters active — answers reflect full model scope)';
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

const SYSTEM_CONTEXT_TEMPLATE =
  'You are an AI assistant for VISA Commercial Spend Analytics. ' +
  'Answer questions about commercial card transaction data using the ' +
  '"VISA Commercial Spend Analytics + FilterSession Context Injection" semantic model. ' +
  'Always use the query_semantic_model tool to retrieve data — never answer from ' +
  'memory or training data. {contextPrompt}';

/**
 * Build the complete agent grounding payload from the current filter context
 * and the user's question.
 *
 * @param context  Current FilterContext (from host app state)
 * @param question User question string from the chat input
 */
export function buildAgentGroundingPayload(
  context: FilterContext,
  question: string,
): AgentGroundingPayload {
  const filterBlock = renderFilterBlock(context.filters);

  const systemContext = SYSTEM_CONTEXT_TEMPLATE.replace(
    '{contextPrompt}',
    context.contextPrompt,
  );

  const userTurn = [
    '[Report Context]',
    `Session ID: ${context.sessionId}`,
    `User: ${context.userId}`,
    `Report Page: ${context.reportPage}`,
    `Timestamp: ${context.timestamp}`,
    '',
    '[Active Filters]',
    filterBlock,
    '',
    '[User Question]',
    question,
  ].join('\n');

  const rawFilterContext: FilterContext = { ...context, question };

  return { systemContext, userTurn, rawFilterContext };
}

/**
 * Serialize a grounding payload to the shape expected by POST /api/chat.
 */
export function serializeForChatApi(payload: AgentGroundingPayload): ChatApiPayload {
  return {
    question: payload.rawFilterContext.question ?? '',
    rawContext: payload.rawFilterContext,
  };
}
