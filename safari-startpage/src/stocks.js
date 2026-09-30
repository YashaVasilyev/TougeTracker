// Quotes come from the local server's /api/quotes proxy (Yahoo Finance sends no
// CORS headers, so the browser can't call it directly). Symbols are Yahoo
// tickers: AAPL, MSFT, ^GSPC, etc.
//
// The server answers from its own on-disk cache, so this is fast, and the last
// good payload is also kept here so the very first paint already has numbers.

const DEV_PROXY = 'http://localhost:8787';
const QUOTES_KEY = 'startpage.quotes.v1';
const QUOTES_MAX_AGE_MS = 60 * 1000;

function readQuoteCache() {
  const parsed = readQuoteCacheAll();
  return parsed.at && Date.now() - parsed.at < QUOTES_MAX_AGE_MS ? parsed.quotes : [];
}

function readQuoteCacheAll() {
  try {
    const raw = localStorage.getItem(QUOTES_KEY);
    const parsed = raw ? JSON.parse(raw) : null;
    return parsed?.quotes ? parsed : { at: 0, quotes: [] };
  } catch {
    return { at: 0, quotes: [] };
  }
}

function writeQuoteCache(quotes) {
  try {
    localStorage.setItem(QUOTES_KEY, JSON.stringify({ at: Date.now(), quotes }));
  } catch {
    /* private mode — quotes just won't be pre-warmed */
  }
}

// Synchronous, so the stock card can render from cache before any request.
export function loadCachedQuotes(stocks) {
  const byKey = new Map(readQuoteCache().map((q) => [q.symbol.toUpperCase(), q]));
  return stocks.map((s) => byKey.get(s.symbol.toUpperCase()) ?? null).filter(Boolean);
}

export async function fetchQuotes(stocks) {
  const symbols = stocks.map((s) => s.symbol).join(',');
  if (!symbols) return [];

  const base = import.meta.env?.DEV ? DEV_PROXY : '';
  const res = await fetch(`${base}/api/quotes?symbols=${encodeURIComponent(symbols)}`);
  if (!res.ok) throw new Error(`Quotes API ${res.status}`);

  const { quotes } = await res.json();
  const bySymbol = new Map(quotes.map((q) => [q.symbol.toUpperCase(), q]));
  // Keep the short label the user configured; the API returns long legal names.
  const out = stocks.map((s) => {
    const q = bySymbol.get(s.symbol.toUpperCase());
    if (!q) return { ...s, error: true };
    return { ...q, name: s.name || q.name };
  });
  // Only cache real numbers; a pending/error row is worse than nothing.
  const solid = out.filter((q) => q.price != null);
  if (solid.length) {
    const fresh = new Set(solid.map((q) => q.symbol.toUpperCase()));
    const kept = readQuoteCacheAll().quotes.filter((q) => !fresh.has(q.symbol.toUpperCase()));
    writeQuoteCache([...kept, ...solid]);
  }
  return out;
}
