// Search URL building. Google "AI mode" is the udm=50 query parameter.

export function isUrlLike(text) {
  const t = text.trim();
  if (!t) return false;
  // Google operators (site:, inurl:, ...) are searches, not addresses.
  if (/^(site|inurl|intitle|allintext|filetype|related|define|glossary):/i.test(t)) return false;
  if (/^(https?:\/\/|www\.)/i.test(t)) return true;
  if (/^[\w-]+(\.[\w-]+)+(\/\S*)?$/.test(t)) return true;
  return /^[a-z][a-z0-9+.-]*:\/\//i.test(t);
}

// Only called when isUrlLike() is true; adds a scheme when one is missing.
export function buildUrl(text) {
  const t = text.trim();
  if (!t) return null;
  return /^[a-z][a-z0-9+.-]*:\/\//i.test(t) ? t : `https://${t}`;
}

export function buildSearchUrl(query, aiMode) {
  const q = query.trim();
  if (!q) return null;
  return aiMode
    ? `https://www.google.com/search?q=${encodeURIComponent(q)}&udm=50`
    : `https://www.google.com/search?q=${encodeURIComponent(q)}`;
}
