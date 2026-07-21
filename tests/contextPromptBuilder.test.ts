/**
 * Tests — Context Prompt Builder
 *
 * Run with: npx vitest tests/contextPromptBuilder.test.ts
 * Or:       npx jest tests/contextPromptBuilder.test.ts
 *
 * Install test runner (one-time):
 *   npm install --save-dev vitest
 */

import { describe, it, expect } from 'vitest';
import {
  buildAgentGroundingPayload,
  serializeForChatApi,
} from '../src/agent/context-injection/contextPromptBuilder.js';
import {
  createFilterContext,
  type FilterContext,
} from '../src/pbie-host/filter-context/filterContextContract.js';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function makeContext(overrides: Partial<FilterContext> = {}): FilterContext {
  return {
    ...createFilterContext('analyst@visa-demo.example', 'CommercialSpendOverview', {
      Year: [2025],
      CountryName: ['United States'],
      SegmentName: ['Enterprise'],
      ApprovalStatus: ['Approved'],
    }),
    ...overrides,
  };
}

// ---------------------------------------------------------------------------
// buildAgentGroundingPayload — systemContext
// ---------------------------------------------------------------------------

describe('buildAgentGroundingPayload — systemContext', () => {
  it('includes the model name', () => {
    const { systemContext } = buildAgentGroundingPayload(makeContext(), 'Test?');
    expect(systemContext).toContain('VISA Commercial Spend Analytics');
  });

  it('instructs the agent to use the query_semantic_model tool', () => {
    const { systemContext } = buildAgentGroundingPayload(makeContext(), 'Test?');
    expect(systemContext).toContain('query_semantic_model');
  });

  it('injects the contextPrompt from the FilterContext', () => {
    const ctx = makeContext({ contextPrompt: 'Custom prompt instruction.' });
    const { systemContext } = buildAgentGroundingPayload(ctx, 'Test?');
    expect(systemContext).toContain('Custom prompt instruction.');
  });
});

// ---------------------------------------------------------------------------
// buildAgentGroundingPayload — userTurn
// ---------------------------------------------------------------------------

describe('buildAgentGroundingPayload — userTurn', () => {
  it('includes [Report Context] section header', () => {
    const { userTurn } = buildAgentGroundingPayload(makeContext(), 'What is spend?');
    expect(userTurn).toContain('[Report Context]');
  });

  it('includes [Active Filters] section header', () => {
    const { userTurn } = buildAgentGroundingPayload(makeContext(), 'What is spend?');
    expect(userTurn).toContain('[Active Filters]');
  });

  it('includes [User Question] section header', () => {
    const { userTurn } = buildAgentGroundingPayload(makeContext(), 'What is spend?');
    expect(userTurn).toContain('[User Question]');
  });

  it('renders the user question in the userTurn', () => {
    const { userTurn } = buildAgentGroundingPayload(makeContext(), 'What is total spend?');
    expect(userTurn).toContain('What is total spend?');
  });

  it('renders Year filter value', () => {
    const { userTurn } = buildAgentGroundingPayload(makeContext(), 'Q?');
    expect(userTurn).toContain('Year: 2025');
  });

  it('renders CountryName filter value', () => {
    const { userTurn } = buildAgentGroundingPayload(makeContext(), 'Q?');
    expect(userTurn).toContain('Country: United States');
  });

  it('renders ApprovalStatus filter value', () => {
    const { userTurn } = buildAgentGroundingPayload(makeContext(), 'Q?');
    expect(userTurn).toContain('Approval Status: Approved');
  });

  it('shows "no filters active" when filter object is empty', () => {
    const ctx = createFilterContext('u@e.com', 'Page');
    const { userTurn } = buildAgentGroundingPayload(ctx, 'Q?');
    expect(userTurn).toContain('no filters active');
  });

  it('includes the sessionId in the userTurn', () => {
    const ctx = makeContext();
    const { userTurn } = buildAgentGroundingPayload(ctx, 'Q?');
    expect(userTurn).toContain(ctx.sessionId);
  });

  it('includes the userId in the userTurn', () => {
    const { userTurn } = buildAgentGroundingPayload(makeContext(), 'Q?');
    expect(userTurn).toContain('analyst@visa-demo.example');
  });
});

// ---------------------------------------------------------------------------
// buildAgentGroundingPayload — rawFilterContext
// ---------------------------------------------------------------------------

describe('buildAgentGroundingPayload — rawFilterContext', () => {
  it('attaches the question to rawFilterContext', () => {
    const { rawFilterContext } = buildAgentGroundingPayload(makeContext(), 'My question?');
    expect(rawFilterContext.question).toBe('My question?');
  });

  it('does not mutate the original context', () => {
    const ctx = makeContext();
    buildAgentGroundingPayload(ctx, 'Q?');
    expect(ctx.question).toBeUndefined();
  });

  it('preserves filter values in rawFilterContext', () => {
    const ctx = makeContext();
    const { rawFilterContext } = buildAgentGroundingPayload(ctx, 'Q?');
    expect(rawFilterContext.filters.Year).toEqual([2025]);
  });
});

// ---------------------------------------------------------------------------
// serializeForChatApi
// ---------------------------------------------------------------------------

describe('serializeForChatApi', () => {
  it('returns question and rawContext keys', () => {
    const payload = buildAgentGroundingPayload(makeContext(), 'What is spend?');
    const serialized = serializeForChatApi(payload);
    expect(serialized).toHaveProperty('question');
    expect(serialized).toHaveProperty('rawContext');
  });

  it('question matches the user input', () => {
    const payload = buildAgentGroundingPayload(makeContext(), 'What is spend?');
    const { question } = serializeForChatApi(payload);
    expect(question).toBe('What is spend?');
  });

  it('rawContext is the full FilterContext', () => {
    const ctx = makeContext();
    const payload = buildAgentGroundingPayload(ctx, 'Q?');
    const { rawContext } = serializeForChatApi(payload);
    expect(rawContext.userId).toBe(ctx.userId);
    expect(rawContext.filters.Year).toEqual([2025]);
  });
});
