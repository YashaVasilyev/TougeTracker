// Autocomplete sources, merged and ranked in the UI:
//  1. your recent searches from this page (localStorage, instant, offline)
//  2. Google suggest via the local proxy (what the web gets)
// Ranking happens in rankSuggestions() so a URL-shaped entry can outrank a
// plain search suggestion.

const RECENT_KEY = 'startpage.recent.v1';
const MAX_RECENT = 8;

export function loadRecent() {
  try {
    const raw = localStorage.getItem(RECENT_KEY);
    const list = raw ? JSON.parse(raw) : [];
    return Array.isArray(list) ? list : [];
  } catch {
    return [];
  }
}

export function rememberSearch(term) {
  const t = term.trim();
  if (t.length < 2) return;
  const next = [t, ...loadRecent().filter((x) => x.toLowerCase() !== t.toLowerCase())].slice(
    0,
    MAX_RECENT,
  );
  try {
    localStorage.setItem(RECENT_KEY, JSON.stringify(next));
  } catch {
    /* private mode — recents just won't persist */
  }
}

export function clearRecent() {
  try {
    localStorage.removeItem(RECENT_KEY);
  } catch {
    /* ignore */
  }
}

export async function fetchSuggestions(query) {
  const q = query.trim();
  if (!q) return [];
  const res = await fetch(`/api/suggest?q=${encodeURIComponent(q)}`);
  if (!res.ok) return [];
  const data = await res.json();
  return Array.isArray(data.suggestions) ? data.suggestions : [];
}

// Score a candidate against what the user has typed so far. Higher is better.
// Safari history and bookmarks, via the local server. The server reads
// ~/Library/Safari, which needs Full Disk Access; when it is missing this
// resolves to an empty list and the other sources carry on unaffected.
export async function fetchHistory(query) {
  const q = query.trim();
  if (!q) return { available: true, items: [] };
  try {
    const res = await fetch(`/api/history?q=${encodeURIComponent(q)}&limit=8`);
    if (!res.ok) return { available: true, items: [] };
    return await res.json();
  } catch {
    return { available: true, items: [] };
  }
}

export async function fetchHistoryStatus() {
  try {
    const res = await fetch('/api/history?q=');
    if (!res.ok) return { available: false };
    return await res.json();
  } catch {
    return { available: false };
  }
}

export function scoreSuggestion(text, query) {
  const t = text.toLowerCase();
  const q = query.toLowerCase().trim();
  let score = 0;

  if (t === q) score += 100;
  else if (t.startsWith(q)) score += 60;
  else if (t.includes(q)) score += 25;

  // Prefer shorter completions when everything else ties.
  score -= Math.min(text.length - q.length, 20);
  return score;
}

// `recents` is still accepted for API compatibility but never produces a row.
export function rankSuggestions({ query, recents = [], google = [], history = [], limit = 10 }) {
  const q = query.trim();
  if (!q) return [];

  const seen = new Set();
  const out = [];

  // `title` is kept as secondary text for display only. `serverScore` is the
  // host-aware relevance the server computed; it dominates the local score so
  // a deep page cannot outrank a site's home page.
  const push = (text, kind, extraScore = 0, url = null, title = null, serverScore = 0) => {
    const label = text.trim();
    if (!label) return;
    // Dedupe on the label, which is the URL, so each distinct page appears
    // once even if visited many times.
    const key = label.toLowerCase();
    if (seen.has(key)) return;
    seen.add(key);
    out.push({
      text: label,
      kind,
      url,
      title,
      score: scoreSuggestion(label, q) + extraScore + serverScore,
    });
  };

  // History and bookmark rows are labelled by URL (the way Chrome's omnibox
  // does) rather than the page title, so each distinct page shows separately
  // instead of several pages collapsing under one site name.
  history.forEach((h) => {
    push(
      prettifyUrl(h.url),
      h.bookmark ? 'bookmark' : 'history',
      60,
      h.url,
      h.title,
      h.score ?? 0,
    );
  });
  // Recent searches are recorded in localStorage but deliberately not rendered:
  // one row per past search just duplicates history and pushes real matches
  // off screen.
  void recents;
  google.forEach((g) => push(g, 'google', 0));

  return out.sort((a, b) => b.score - a.score).slice(0, limit);
}

// Display label for a history/bookmark row: host + path, with the scheme,
// leading "www." and trailing slash removed. Very long paths are truncated
// with an ellipsis rather than dropped, so the row still identifies the site
// without pushing everything else off screen.
const MAX_LABEL = 60;

function prettifyUrl(url) {
  try {
    const u = new URL(url);
    const host = u.hostname.replace(/^www\./, '');
    const path = u.pathname.replace(/^\//, '').replace(/\/$/, '');
    const full = host + (path ? '/' + path : '');
    if (full.length <= MAX_LABEL) return full;

    // Keep the host, then as much of the leading path as fits.
    const room = MAX_LABEL - host.length - 1;
    if (room <= 4) return host.slice(0, MAX_LABEL - 1) + '…';
    return host + '/' + path.slice(0, room - 1) + '…';
  } catch {
    return url;
  }
}
