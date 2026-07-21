/**
 * captureContext.js — reads current PBIE report state from the embedded report object.
 * Returns a raw context object matching the Pattern 1 spec in pattern1_iframe_injection.md.
 */
export async function captureContext(report) {
  if (!report) return null;

  const [pages, reportFilters] = await Promise.all([
    report.getPages(),
    report.getFilters()
  ]);

  const activePage = pages.find((p) => p.isActive) ?? pages[0];
  if (!activePage) return null;

  const [pageFilters, visuals] = await Promise.all([
    activePage.getFilters(),
    activePage.getVisuals()
  ]);

  const allFilters = [...reportFilters, ...pageFilters].map(normalizeFilter);

  const slicerData = await Promise.all(
    visuals
      .filter((v) => v.type === 'slicer')
      .map(async (v) => {
        try {
          const state = await v.getSlicerState();
          return { visual: v.title, state };
        } catch {
          return null;
        }
      })
  );

  return {
    reportId: report.config?.id,
    page: {
      name: activePage.name,
      displayName: activePage.displayName
    },
    filters: allFilters,
    slicers: slicerData.filter(Boolean).map(normalizeSlicerState),
    visualSelections: [] // Sprint 5: extend to cross-filter selections
  };
}

function normalizeFilter(filter) {
  return {
    table: filter.target?.table ?? null,
    column: filter.target?.column ?? null,
    operator: filter.operator ?? null,
    values: filter.values ?? []
  };
}

function normalizeSlicerState(item) {
  return {
    visual: item.visual,
    field: item.state?.targets?.[0]?.column ?? null,
    selected: item.state?.filters?.[0]?.values ?? []
  };
}
