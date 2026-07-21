/**
 * VISA Commercial Spend Analytics — Power BI Embedded setFilters() Helper
 *
 * Maps host-app FilterContextFilters to Power BI Embedded IBasicFilter objects
 * and applies them to the embedded report via report.setFilters().
 *
 * Dependency: powerbi-client v2 (loaded via CDN in the host page).
 * The PowerBIReport interface below is compatible with the window.powerbi
 * embed object without requiring the npm package at build time.
 */

import type { FilterContextFilters } from './filterContextContract.js';

// ---------------------------------------------------------------------------
// Minimal Power BI Embedded types (compatible with powerbi-client v2 CDN)
// ---------------------------------------------------------------------------

/** Minimal interface for the embedded Power BI report object. */
export interface PowerBIReport {
  setFilters(filters: IBasicFilter[]): Promise<void>;
  getFilters(): Promise<IBasicFilter[]>;
  getPages(): Promise<Array<{ isActive: boolean; setFilters(f: IBasicFilter[]): Promise<void> }>>;
}

/** powerbi-models IBasicFilter shape (no npm dependency required). */
export interface IBasicFilter {
  $schema: 'http://powerbi.com/product/schema#basic';
  target: { table: string; column: string };
  operator: 'In' | 'NotIn' | 'All';
  values: (string | number | boolean)[];
  filterType: 1; // models.FilterType.Basic
}

// ---------------------------------------------------------------------------
// Table/column mapping — filter key → semantic model address
// ---------------------------------------------------------------------------

const FILTER_TARGET_MAP: Record<
  keyof FilterContextFilters,
  { table: string; column: string }
> = {
  Year:           { table: 'Dim_Date',           column: 'Year'            },
  Quarter:        { table: 'Dim_Date',           column: 'Quarter'         },
  CountryName:    { table: 'Dim_Country',        column: 'CountryName'     },
  ClientName:     { table: 'Dim_Client',         column: 'ClientName'      },
  SegmentName:    { table: 'Dim_Segment',        column: 'SegmentName'     },
  ProductName:    { table: 'Dim_Product',        column: 'ProductName'     },
  MCCDescription: { table: 'Dim_MCC',            column: 'MCCDescription'  },
  MerchantName:   { table: 'Dim_Merchant',       column: 'MerchantName'    },
  ApprovalStatus: { table: 'Dim_ApprovalStatus', column: 'ApprovalStatus'  },
};

// ---------------------------------------------------------------------------
// Filter builder
// ---------------------------------------------------------------------------

/**
 * Convert a FilterContextFilters object to an array of IBasicFilter objects
 * ready to pass to report.setFilters().
 *
 * Dimensions with no selected values are omitted (no filter applied).
 */
export function buildPbiFilters(filters: FilterContextFilters): IBasicFilter[] {
  const result: IBasicFilter[] = [];

  for (const [key, values] of Object.entries(filters) as [keyof FilterContextFilters, unknown[]][]) {
    if (!values || values.length === 0) continue;

    const target = FILTER_TARGET_MAP[key];
    if (!target) {
      console.warn(`[setFiltersHelper] Unknown filter key: ${key}`);
      continue;
    }

    result.push({
      $schema: 'http://powerbi.com/product/schema#basic',
      target: { table: target.table, column: target.column },
      operator: 'In',
      values: values as (string | number | boolean)[],
      filterType: 1,
    });
  }

  return result;
}

// ---------------------------------------------------------------------------
// Report-level apply / clear
// ---------------------------------------------------------------------------

/**
 * Apply the host-app filter state to the embedded Power BI report.
 * Replaces all existing report-level filters.
 */
export async function applyFiltersToReport(
  report: PowerBIReport,
  filters: FilterContextFilters,
): Promise<void> {
  const pbiFilters = buildPbiFilters(filters);
  await report.setFilters(pbiFilters);
}

/**
 * Apply filter state to the currently active page only.
 * Leaves report-level filters untouched.
 */
export async function applyFiltersToActivePage(
  report: PowerBIReport,
  filters: FilterContextFilters,
): Promise<void> {
  const pages = await report.getPages();
  const activePage = pages.find((p) => p.isActive);
  if (!activePage) {
    console.warn('[setFiltersHelper] No active page found — skipping page-level filter apply.');
    return;
  }
  const pbiFilters = buildPbiFilters(filters);
  await activePage.setFilters(pbiFilters);
}

/**
 * Clear all report-level filters.
 */
export async function clearReportFilters(report: PowerBIReport): Promise<void> {
  await report.setFilters([]);
}
