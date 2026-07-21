import { createRequire } from 'module';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';
import { readFileSync } from 'fs';

const __dirname = dirname(fileURLToPath(import.meta.url));
const fieldMap = JSON.parse(
  readFileSync(join(__dirname, '../../semantic/metadata/field_map.json'), 'utf8')
);

/**
 * Translate a raw PBIE field name to a business-friendly name using field_map.json.
 */
const translate = (name) => fieldMap[name] || name;

/**
 * Convert raw PBIE context (from captureContext.js) into a flat business context object.
 */
export function normalizeContext(rawContext) {
  const businessContext = {
    page: rawContext.page?.displayName || rawContext.page?.name || null,
    filters: {},
    slicers: {},
    selections: {}
  };

  for (const filter of rawContext.filters || []) {
    if (filter.column && filter.values?.length > 0) {
      businessContext.filters[translate(filter.column)] = filter.values;
    }
  }

  for (const slicer of rawContext.slicers || []) {
    if (slicer.field && slicer.selected?.length > 0) {
      businessContext.slicers[translate(slicer.field)] = slicer.selected.join(', ');
    }
  }

  return businessContext;
}

/**
 * Render the business context as a plain-text block for the agent user turn.
 */
export function buildContextBlock(businessContext) {
  const lines = [];

  if (businessContext.page) lines.push(`Page: ${businessContext.page}`);

  for (const [k, v] of Object.entries(businessContext.slicers)) {
    lines.push(`${k}: ${v}`);
  }

  for (const [k, v] of Object.entries(businessContext.filters)) {
    lines.push(`${k}: ${Array.isArray(v) ? v.join(', ') : v}`);
  }

  return lines.join('\n');
}
