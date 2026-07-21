/**
 * Tests — Filter Context Contract + setFilters() Helper
 *
 * Run with: npx vitest tests/filterContext.test.ts
 * Or:       npx jest tests/filterContext.test.ts
 *
 * Install test runner (one-time):
 *   npm install --save-dev vitest
 */

import { describe, it, expect } from 'vitest';
import {
  createFilterContext,
  updateFilters,
  hasActiveFilters,
  toFilterSessionRow,
  type FilterContextFilters,
} from '../src/pbie-host/filter-context/filterContextContract.js';
import {
  buildPbiFilters,
} from '../src/pbie-host/filter-context/setFiltersHelper.js';

// ---------------------------------------------------------------------------
// createFilterContext
// ---------------------------------------------------------------------------

describe('createFilterContext', () => {
  it('generates a sessionId with SSN- prefix', () => {
    const ctx = createFilterContext('user@example.com', 'CommercialSpendOverview');
    expect(ctx.sessionId).toMatch(/^SSN-\d+$/);
  });

  it('sets userId and reportPage from arguments', () => {
    const ctx = createFilterContext('user@example.com', 'CommercialSpendOverview');
    expect(ctx.userId).toBe('user@example.com');
    expect(ctx.reportPage).toBe('CommercialSpendOverview');
  });

  it('sets an ISO timestamp', () => {
    const ctx = createFilterContext('user@example.com', 'CommercialSpendOverview');
    expect(() => new Date(ctx.timestamp)).not.toThrow();
    expect(ctx.timestamp).toMatch(/^\d{4}-\d{2}-\d{2}T/);
  });

  it('defaults to empty filters', () => {
    const ctx = createFilterContext('user@example.com', 'Page');
    expect(ctx.filters).toEqual({});
  });

  it('accepts initial filters', () => {
    const ctx = createFilterContext('user@example.com', 'Page', { Year: [2025] });
    expect(ctx.filters.Year).toEqual([2025]);
  });
});

// ---------------------------------------------------------------------------
// updateFilters
// ---------------------------------------------------------------------------

describe('updateFilters', () => {
  it('merges new filter values into existing context', () => {
    const ctx = createFilterContext('u@e.com', 'Page', { Year: [2024] });
    const updated = updateFilters(ctx, { CountryName: ['United States'] });
    expect(updated.filters.Year).toEqual([2024]);
    expect(updated.filters.CountryName).toEqual(['United States']);
  });

  it('overwrites an existing filter key', () => {
    const ctx = createFilterContext('u@e.com', 'Page', { Year: [2024] });
    const updated = updateFilters(ctx, { Year: [2025, 2026] });
    expect(updated.filters.Year).toEqual([2025, 2026]);
  });

  it('does not mutate the original context', () => {
    const ctx = createFilterContext('u@e.com', 'Page', { Year: [2024] });
    updateFilters(ctx, { Year: [2025] });
    expect(ctx.filters.Year).toEqual([2024]);
  });
});

// ---------------------------------------------------------------------------
// hasActiveFilters
// ---------------------------------------------------------------------------

describe('hasActiveFilters', () => {
  it('returns false when no filters are set', () => {
    const ctx = createFilterContext('u@e.com', 'Page');
    expect(hasActiveFilters(ctx)).toBe(false);
  });

  it('returns true when at least one filter has values', () => {
    const ctx = createFilterContext('u@e.com', 'Page', { Year: [2025] });
    expect(hasActiveFilters(ctx)).toBe(true);
  });

  it('returns false when all filter arrays are empty', () => {
    const ctx = createFilterContext('u@e.com', 'Page', { Year: [], CountryName: [] });
    expect(hasActiveFilters(ctx)).toBe(false);
  });
});

// ---------------------------------------------------------------------------
// toFilterSessionRow
// ---------------------------------------------------------------------------

describe('toFilterSessionRow', () => {
  it('serializes filter values as comma-separated strings', () => {
    const ctx = createFilterContext('u@e.com', 'Page', {
      Year: [2024, 2025],
      CountryName: ['United States', 'Canada'],
    });
    const row = toFilterSessionRow(ctx);
    expect(row.FilterYear).toBe('2024,2025');
    expect(row.FilterCountry).toBe('United States,Canada');
  });

  it('serializes empty filters as empty strings', () => {
    const ctx = createFilterContext('u@e.com', 'Page');
    const row = toFilterSessionRow(ctx);
    expect(row.FilterYear).toBe('');
    expect(row.FilterMCC).toBe('');
  });

  it('copies sessionId and userId to the row', () => {
    const ctx = createFilterContext('user@visa.com', 'Page');
    const row = toFilterSessionRow(ctx);
    expect(row.SessionId).toBe(ctx.sessionId);
    expect(row.UserId).toBe('user@visa.com');
  });
});

// ---------------------------------------------------------------------------
// buildPbiFilters
// ---------------------------------------------------------------------------

describe('buildPbiFilters', () => {
  it('returns empty array when filters object is empty', () => {
    expect(buildPbiFilters({})).toEqual([]);
  });

  it('returns empty array when all arrays are empty', () => {
    expect(buildPbiFilters({ Year: [], CountryName: [] })).toEqual([]);
  });

  it('maps Year to Dim_Date[Year]', () => {
    const filters = buildPbiFilters({ Year: [2025] });
    expect(filters).toHaveLength(1);
    expect(filters[0].target.table).toBe('Dim_Date');
    expect(filters[0].target.column).toBe('Year');
    expect(filters[0].values).toEqual([2025]);
  });

  it('maps CountryName to Dim_Country[CountryName]', () => {
    const filters = buildPbiFilters({ CountryName: ['United States'] });
    expect(filters[0].target.table).toBe('Dim_Country');
    expect(filters[0].target.column).toBe('CountryName');
  });

  it('maps MCCDescription to Dim_MCC[MCCDescription]', () => {
    const filters = buildPbiFilters({ MCCDescription: ['Software'] });
    expect(filters[0].target.table).toBe('Dim_MCC');
    expect(filters[0].target.column).toBe('MCCDescription');
  });

  it('maps ApprovalStatus to Dim_ApprovalStatus[ApprovalStatus]', () => {
    const filters = buildPbiFilters({ ApprovalStatus: ['Approved'] });
    expect(filters[0].target.table).toBe('Dim_ApprovalStatus');
  });

  it('uses operator "In" and filterType 1 on all filters', () => {
    const filters = buildPbiFilters({ Year: [2024], CountryName: ['US'] });
    for (const f of filters) {
      expect(f.operator).toBe('In');
      expect(f.filterType).toBe(1);
    }
  });

  it('produces one filter per active dimension', () => {
    const input: FilterContextFilters = {
      Year: [2025],
      Quarter: ['Q1'],
      CountryName: ['United States'],
    };
    expect(buildPbiFilters(input)).toHaveLength(3);
  });

  it('uses the powerbi schema URI', () => {
    const filters = buildPbiFilters({ Year: [2025] });
    expect(filters[0].$schema).toBe('http://powerbi.com/product/schema#basic');
  });
});
