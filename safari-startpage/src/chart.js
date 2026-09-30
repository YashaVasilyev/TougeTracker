// Intraday index series for the chart card, via the local server's /api/chart
// proxy (Yahoo sends no CORS headers). The server already answers from its own
// disk cache, and we mirror the last series locally so the very first paint
// draws the line instead of an empty box.

const DEV_PROXY = 'http://localhost:8787';
const CHART_KEY = 'startpage.chart.v1';

function readAll() {
  try {
    const parsed = JSON.parse(localStorage.getItem(CHART_KEY) ?? '{}');
    return parsed && typeof parsed === 'object' ? parsed : {};
  } catch {
    return {};
  }
}

function write(key, series) {
  try {
    const all = readAll();
    all[key] = { at: Date.now(), series };
    localStorage.setItem(CHART_KEY, JSON.stringify(all));
  } catch {
    /* private mode — the chart just won't be pre-warmed */
  }
}

function chartKey({ symbol = '^DJI', range = '1d', interval = '5m' } = {}) {
  return `${symbol}:${range}:${interval}`;
}

// Synchronous, so the SVG can be drawn on the very first render.
export function loadCachedChart(opts) {
  return readAll()[chartKey(opts)]?.series ?? null;
}

export async function fetchChart(opts = {}) {
  const base = import.meta.env?.DEV ? DEV_PROXY : '';
  const qs = new URLSearchParams({
    symbol: opts.symbol ?? '^DJI',
    range: opts.range ?? '1d',
    interval: opts.interval ?? '5m',
  });
  const res = await fetch(`${base}/api/chart?${qs}`);
  if (!res.ok) throw new Error(`Chart API ${res.status}`);

  const series = await res.json();
  if (series?.points?.length > 1) write(chartKey(opts), series);
  return series;
}
