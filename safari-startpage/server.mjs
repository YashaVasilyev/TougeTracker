// Minimal zero-dependency server: serves the built app and proxies stock
// quotes. A proxy is required because Yahoo Finance sends no CORS headers,
// so the browser cannot call it directly from the page.
import http from 'node:http';
import https from 'node:https';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { handleHistory, canReadSafari, warmHistory } from './history.mjs';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const DIST = path.join(__dirname, 'dist');
const PORT = Number(process.env.PORT || 8787);

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.json': 'application/json; charset=utf-8',
  '.ico': 'image/x-icon',
};

const UA =
  'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 ' +
  '(KHTML, like Gecko) Version/17.0 Safari/605.1.15';

// Note: we deliberately use node:https rather than global fetch for the quote
// and suggest endpoints — Yahoo returns 429 to undici's default request shape
// but 200 to a plain https.get. The chart endpoint is the exception: it 429s
// https.get consistently and only serves undici, so it uses fetch instead.
function httpGetJson(host, urlPath, { timeout = 8000 } = {}) {
  return new Promise((resolve, reject) => {
    const req = https.get(
      { host, path: urlPath, headers: { 'User-Agent': UA, Accept: 'application/json' } },
      (res) => {
        const chunks = [];
        res.on('data', (c) => chunks.push(c));
        res.on('end', () => {
          const body = Buffer.concat(chunks).toString('utf8');
          if (res.statusCode !== 200) {
            return reject(new Error(`upstream ${res.statusCode}`));
          }
          try {
            resolve(JSON.parse(body));
          } catch {
            reject(new Error('bad json'));
          }
        });
      },
    );
    req.setTimeout(timeout, () => req.destroy(new Error('timeout')));
    req.on('error', reject);
  });
}

// Yahoo aggressively rate-limits by IP, so we:
//  - keep every quote in memory and on disk across restarts, so a reload
//    renders numbers immediately instead of waiting on the network
//  - refresh in the background (never blocking the response) and serve the
//    cached value straight away, even when stale
//  - fetch sequentially with a gap, and only retry on failure
const CACHE_MS = 30_000;
const UPSTREAM_GAP_MS = 700;
const CACHE_FILE = path.join(__dirname, 'cache', 'quotes.json');
const CHART_FILE = path.join(__dirname, 'cache', 'charts.json');
const cache = new Map(); // symbol -> { at, quote }

// Restore the on-disk cache at boot so the very first page load already has
// numbers to paint. A missing or corrupt file just means a cold start.
function loadQuoteCache() {
  try {
    const raw = JSON.parse(fs.readFileSync(CACHE_FILE, 'utf8'));
    for (const [symbol, entry] of Object.entries(raw)) {
      if (entry?.quote) cache.set(symbol, { at: entry.at ?? 0, quote: entry.quote });
    }
  } catch {
    /* no cache yet */
  }
}

// Written on a trailing timer so a burst of refreshes costs one disk write.
let saveTimer = null;
function saveQuoteCacheSoon() {
  if (saveTimer) return;
  saveTimer = setTimeout(() => {
    saveTimer = null;
    try {
      fs.mkdirSync(path.dirname(CACHE_FILE), { recursive: true });
      const out = {};
      for (const [symbol, entry] of cache) out[symbol] = entry;
      fs.writeFileSync(CACHE_FILE, JSON.stringify(out));
    } catch {
      /* cache is best-effort */
    }
  }, 1000);
  saveTimer.unref?.();
}

loadQuoteCache();

// Data sources, tried in order. Both are keyless public endpoints.
//  1. Nasdaq's quote API — primary; reliable, no throttling in practice.
//  2. Yahoo Finance chart API — fallback; aggressively rate-limits by IP.
async function fetchQuoteNasdaq(symbol) {
  const assetclass = symbol.startsWith('^') ? 'index' : 'stocks';
  const p = `/api/quote/${encodeURIComponent(symbol)}/info?assetclass=${assetclass}`;
  const json = await httpGetJson('api.nasdaq.com', p);
  const d = json?.data;
  const prim = d?.primaryData;
  if (!prim?.lastSalePrice) throw new Error('nasdaq: no price');

  const sec = d?.secondaryData ?? {};
  const num = (v) => {
    if (v == null) return null;
    const n = Number(String(v).replace(/[$,%+\s]/g, ''));
    return Number.isFinite(n) ? n : null;
  };

  const price = num(prim.lastSalePrice);
  const change = num(prim.netChange);
  let changePct = num(prim.percentageChange);
  if (changePct == null && change != null && price) {
    changePct = (change / (price - change)) * 100;
  }

  return {
    symbol,
    // Nasdaq returns e.g. "Apple Inc. Common Stock"; trim it for display.
    name: (d.companyName ?? d.symbol ?? symbol).replace(/\s+(Common Stock|Class [A-Z].*)$/i, ''),
    price,
    change,
    changePct,
    high: num(sec.high),
    low: num(sec.low),
    volume: num(prim.volume),
    updated: prim.lastTradeTimestamp ?? null,
    source: 'nasdaq',
  };
}

async function fetchQuoteYahoo(symbol) {
  const qp = `/v8/finance/chart/${encodeURIComponent(symbol)}?interval=1d&range=5d`;
  const hosts = ['query1.finance.yahoo.com', 'query2.finance.yahoo.com'];
  let lastErr;

  for (const host of hosts) {
    try {
      const json = await httpGetJson(host, qp);
      const result = json?.chart?.result?.[0];
      if (!result) throw new Error('no data');

      const meta = result.meta;
      const price = meta.regularMarketPrice ?? null;
      const prev = meta.chartPreviousClose ?? result.indicators?.quote?.[0]?.close?.[0] ?? null;
      const change = price != null && prev != null ? price - prev : null;

      return {
        symbol,
        name: meta.longName ?? meta.shortName ?? symbol,
        price,
        change,
        changePct: change != null && prev ? (change / prev) * 100 : null,
        high: meta.regularMarketDayHigh ?? null,
        low: meta.regularMarketDayLow ?? null,
        volume: meta.regularMarketVolume ?? null,
        updated: meta.regularMarketTime ?? null,
        source: 'yahoo',
      };
    } catch (e) {
      lastErr = e;
    }
  }
  throw lastErr ?? new Error('unavailable');
}

async function fetchQuoteFresh(symbol) {
  const errors = [];
  // Nasdaq's index coverage doesn't match Yahoo's (^GSPC, ^IXIC, ...), so
  // caret symbols go straight to Yahoo.
  const providers = symbol.startsWith('^')
    ? [fetchQuoteYahoo]
    : [fetchQuoteNasdaq, fetchQuoteYahoo];

  for (const fn of providers) {
    try {
      return await fn(symbol);
    } catch (e) {
      errors.push(String(e?.message ?? e));
    }
  }
  throw new Error(errors.join('; '));
}

// In-flight refreshes, so N concurrent requests for one symbol cause one fetch.
const inflight = new Map();

// Background refreshes run one at a time with a gap, because Yahoo rate-limits
// parallel bursts. This queue is off the response path, so the delay is
// invisible to the page.
let queue = Promise.resolve();
function enqueueRefresh(task) {
  queue = queue
    .then(() => new Promise((r) => setTimeout(r, UPSTREAM_GAP_MS)))
    .then(task);
  return queue;
}

function refreshQuote(symbol) {
  if (inflight.has(symbol)) return inflight.get(symbol);
  const p = enqueueRefresh(() => fetchQuoteFresh(symbol))
    .then((quote) => {
      cache.set(symbol, { at: Date.now(), quote });
      saveQuoteCacheSoon();
      return quote;
    })
    .catch((e) => {
      // Remember the failure time so we retry on the next request rather than
      // hammering a failing upstream on every page load.
      const hit = cache.get(symbol);
      cache.set(symbol, { at: Date.now() - CACHE_MS, quote: hit?.quote ?? { symbol, price: null, change: null, changePct: null, error: true, reason: String(e?.message ?? e) } });
      throw e;
    })
    .finally(() => inflight.delete(symbol));
  inflight.set(symbol, p);
  return p;
}

// Never blocks: returns the cached quote immediately (fresh or stale) and kicks
// off a background refresh if the entry is older than CACHE_MS. This is what
// makes the page paint instantly instead of waiting on the network.
function getQuote(symbol) {
  const hit = cache.get(symbol);

  if (hit && Date.now() - hit.at < CACHE_MS) return hit.quote;

  refreshQuote(symbol).catch(() => {
    // Keep the previous quote (or the error placeholder) on failure; there is
    // nothing to serve better.
  });

  if (hit) return hit.quote;
  return {
    symbol,
    price: null,
    change: null,
    changePct: null,
    pending: true,
  };
}

// Intraday chart series (the Dow sparkline). Same caching discipline as quotes:
// serve the last good series immediately, refresh it in the background, and
// persist to disk so a reload never waits on the network.
const CHART_CACHE_MS = 60_000;
const chartCache = new Map(); // `${symbol}:${range}:${interval}` -> { at, series }

function loadChartCache() {
  try {
    const raw = JSON.parse(fs.readFileSync(CHART_FILE, 'utf8'));
    for (const [key, entry] of Object.entries(raw)) {
      if (entry?.series) chartCache.set(key, { at: entry.at ?? 0, series: entry.series });
    }
  } catch {
    /* no chart cache yet */
  }
}

let chartSaveTimer = null;
function saveChartCacheSoon() {
  if (chartSaveTimer) return;
  chartSaveTimer = setTimeout(() => {
    chartSaveTimer = null;
    try {
      fs.mkdirSync(path.dirname(CHART_FILE), { recursive: true });
      const out = {};
      for (const [key, entry] of chartCache) out[key] = entry;
      fs.writeFileSync(CHART_FILE, JSON.stringify(out));
    } catch {
      /* best-effort */
    }
  }, 1000);
  chartSaveTimer.unref?.();
}

loadChartCache();

// Yahoo's chart endpoint is the only free intraday series available for the
// Dow, so it is the only source. Returns normalized points plus the day's
// change, which the card shows in its header.
// Yahoo throttles bursts, and its chart endpoint 429s fairly often. Retrying
// with backoff turns a transient throttle into a short delay instead of an
// empty chart; the caller decides whether to wait for the result or return
// whatever is cached.
async function fetchChartFresh(symbol, range, interval, { retries = 4, baseDelay = 1200 } = {}) {
  let lastErr;
  for (let attempt = 0; attempt <= retries; attempt += 1) {
    try {
      return await fetchChartOnce(symbol, range, interval);
    } catch (e) {
      lastErr = e;
      if (attempt < retries) {
        await new Promise((r) => setTimeout(r, baseDelay * 2 ** attempt));
      }
    }
  }
  throw lastErr;
}

async function fetchChartOnce(symbol, range, interval) {
  const p = `https://query1.finance.yahoo.com/v8/finance/chart/${encodeURIComponent(symbol)}?range=${range}&interval=${interval}`;
  const res = await fetch(p, {
    headers: { 'User-Agent': UA, Accept: 'application/json' },
    signal: AbortSignal.timeout(8000),
  });
  if (!res.ok) throw new Error(`upstream ${res.status}`);
  const json = await res.json();
  const result = json?.chart?.result?.[0];
  if (!result) throw new Error('chart: no result');

  const stamps = result.timestamp ?? [];
  const closes = result.indicators?.quote?.[0]?.close ?? [];
  // Yahoo pads the last bars with nulls while a bar is still forming; drop them
  // so the line does not dive to zero at the right edge.
  const points = [];
  for (let i = 0; i < stamps.length; i += 1) {
    const v = closes[i];
    if (v == null || !Number.isFinite(v)) continue;
    points.push({ t: stamps[i] * 1000, v });
  }
  if (points.length < 2) throw new Error('chart: too few points');

  const m = result.meta ?? {};
  return {
    points,
    price: m.regularMarketPrice ?? points[points.length - 1].v,
    change: m.fulldayChange ?? null,
    changePct: m.fulldayChangePercent ?? null,
    previousClose: m.chartPreviousClose ?? m.previousClose ?? null,
  };
}

async function handleChart(req, res, url) {
  const symbol = (url.searchParams.get('symbol') || '^DJI').slice(0, 16);
  const range = (url.searchParams.get('range') || '1d').slice(0, 8);
  const interval = (url.searchParams.get('interval') || '5m').slice(0, 8);
  const key = `${symbol}:${range}:${interval}`;

  const hit = chartCache.get(key);
  if (!hit || Date.now() - hit.at >= CHART_CACHE_MS) {
    // Fire and forget: the response below is already good enough to render.
    // Without a cached series there is nothing to show, so this one waits —
    // but only when it is actually a cold start.
    const refresh = () =>
      fetchChartFresh(symbol, range, interval)
        .then((series) => {
          chartCache.set(key, { at: Date.now(), series });
          saveChartCacheSoon();
        })
        .catch(() => {
          /* keep the previous series rather than blanking the card */
        });

    if (hit) refresh();
    else await refresh();
  }

  res.writeHead(200, {
    'Content-Type': 'application/json; charset=utf-8',
    'Access-Control-Allow-Origin': '*',
    'Cache-Control': 'no-store',
  });
  res.end(JSON.stringify(hit?.series ?? { points: [] }));
}

// Search suggestions from Google's public suggest endpoint. It sends no CORS
// headers, so the browser must go through us. Results are cached briefly and
// keyed by prefix, since a keystroke-by-keystroke stream would hammer upstream.
const SUGGEST_CACHE_MS = 10 * 60 * 1000;
const suggestCache = new Map(); // prefix -> { at, items }

function httpGetText(host, urlPath, { timeout = 5000 } = {}) {
  return new Promise((resolve, reject) => {
    const req = https.get(
      { host, path: urlPath, headers: { 'User-Agent': UA, Accept: 'application/json' } },
      (res) => {
        const chunks = [];
        res.on('data', (c) => chunks.push(c));
        res.on('end', () => {
          if (res.statusCode !== 200) return reject(new Error(`upstream ${res.statusCode}`));
          resolve(Buffer.concat(chunks).toString('utf8'));
        });
      },
    );
    req.setTimeout(timeout, () => req.destroy(new Error('timeout')));
    req.on('error', reject);
  });
}

async function handleSuggest(res, url) {
  const q = (url.searchParams.get('q') || '').trim().slice(0, 128);
  if (q.length < 1) {
    res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
    return res.end('{"suggestions":[]}');
  }

  const key = q.toLowerCase();
  let items = [];
  const hit = suggestCache.get(key);
  if (hit && Date.now() - hit.at < SUGGEST_CACHE_MS) {
    items = hit.items;
  } else {
    try {
      const path_ = `/complete/search?client=firefox&hl=en&q=${encodeURIComponent(q)}`;
      const body = await httpGetText('suggestqueries.google.com', path_);
      const parsed = JSON.parse(body);
      items = Array.isArray(parsed?.[1]) ? parsed[1].slice(0, 8) : [];
      suggestCache.set(key, { at: Date.now(), items });
    } catch {
      // Suggestions are a nicety; return empty rather than surfacing an error.
      items = hit?.items ?? [];
    }
  }

  res.writeHead(200, {
    'Content-Type': 'application/json; charset=utf-8',
    'Access-Control-Allow-Origin': '*',
    'Cache-Control': 'no-store',
  });
  res.end(JSON.stringify({ suggestions: items }));
}

// Synchronous from the caller's point of view: getQuote only reads the cache and
// schedules a background refresh, so this never waits on upstream.
function fetchAllQuotes(symbols) {
  return Promise.resolve(symbols.map((s) => getQuote(s)));
}

async function handleQuotes(req, res, url) {
  const symbols = (url.searchParams.get('symbols') || '')
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean)
    .slice(0, 12);

  if (!symbols.length) {
    res.writeHead(400).end('{"error":"no symbols"}');
    return;
  }

  const quotes = await fetchAllQuotes(symbols);

  res.writeHead(200, {
    'Content-Type': 'application/json; charset=utf-8',
    'Access-Control-Allow-Origin': '*',
    'Cache-Control': 'no-store',
  });
  res.end(JSON.stringify({ quotes }));
}

function serveStatic(req, res, url) {
  const rel = url.pathname === '/' ? 'index.html' : url.pathname.slice(1);
  const file = path.join(DIST, path.normalize(rel));
  if (!file.startsWith(DIST)) {
    res.writeHead(403).end('forbidden');
    return;
  }
  fs.readFile(file, (err, buf) => {
    if (err) {
      // SPA fallback
      fs.readFile(path.join(DIST, 'index.html'), (e2, html) => {
        if (e2) return res.writeHead(404).end('not found');
        res.writeHead(200, { 'Content-Type': MIME['.html'] }).end(html);
      });
      return;
    }
    res.writeHead(200, {
      'Content-Type': MIME[path.extname(file)] ?? 'application/octet-stream',
      // Vite fingerprints everything under /assets, so those files can be
      // cached forever; index.html must not be, or a rebuild would never show.
      'Cache-Control': url.pathname.startsWith('/assets/')
        ? 'public, max-age=31536000, immutable'
        : 'no-cache',
    });
    res.end(buf);
  });
}

const server = http.createServer((req, res) => {
  const url = new URL(req.url, `http://localhost:${PORT}`);

  if (url.pathname === '/api/health') {
    return res.writeHead(200, { 'Content-Type': 'application/json' }).end('{"ok":true}');
  }
  if (url.pathname === '/api/suggest') {
    return handleSuggest(res, url);
  }
  if (url.pathname === '/api/history') {
    return handleHistory(res, url);
  }
  if (url.pathname === '/api/chart') {
    return handleChart(req, res, url);
  }
  if (url.pathname === '/api/quotes') {
    return handleQuotes(req, res, url).catch((e) => {
      res.writeHead(502, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: e.message }));
    });
  }
  return serveStatic(req, res, url);
});

server.listen(PORT, '127.0.0.1', async () => {
  console.log(`Start page running at http://localhost:${PORT}`);
  const history = await canReadSafari();
  console.log(
    history
      ? 'Safari history: available (autocomplete will use it)'
      : 'Safari history: BLOCKED by macOS. Grant Full Disk Access to enable it:\n' +
          '  System Settings > Privacy & Security > Full Disk Access > add Node',
  );
  // Read history once at boot so the very first keystroke is already warm.
  // Quote warming is deliberately not awaited: it only fills the background
  // cache, and the server is already able to answer requests.
  if (history) {
    const t0 = Date.now();
    warmHistory()
      .then(() => console.log(`History cache warmed in ${Date.now() - t0}ms`))
      .catch((e) => console.log(`History warm failed: ${e.message}`));
  }

  // The chart is warmed first, on its own: it is the one thing that cannot fall
  // back to another provider, and the quote prewarm below would otherwise eat
  // Yahoo's rate-limit budget before this request is made.
  fetchChartFresh('^DJI', '1d', '5m')
    .then((series) => {
      chartCache.set('^DJI:1d:5m', { at: Date.now(), series });
      saveChartCacheSoon();
      console.log(`Chart cache warmed: ${series.points.length} points`);
    })
    .catch((e) => console.log(`Chart warm failed: ${e.message}`));

  // Only the symbols the default settings actually use, so the burst is small
  // enough that Yahoo keeps serving it.
  const prewarm = ['AAPL', 'MSFT', 'NVDA', 'TSLA', 'AMZN', 'GOOGL'];
  const t1 = Date.now();
  Promise.allSettled(prewarm.map((s) => refreshQuote(s))).then(() => {
    console.log(`Quote cache warmed in ${Date.now() - t1}ms`);
  });
});
