// Single source of truth for user-tunable settings, persisted in localStorage.
const DEFAULTS = {
  city: 'New York',
  lat: 40.7128,
  lon: -74.006,
  units: 'imperial', // 'imperial' | 'metric'
  // Symbols should be Nasdaq-listed tickers. Indices like ^GSPC rely on the
  // Yahoo fallback and can be blank while Yahoo is rate-limiting.
  stocks: [
    { symbol: 'AAPL', name: 'Apple' },
    { symbol: 'MSFT', name: 'Microsoft' },
    { symbol: 'NVDA', name: 'NVIDIA' },
    { symbol: 'TSLA', name: 'Tesla' },
    { symbol: 'AMZN', name: 'Amazon' },
    { symbol: 'GOOGL', name: 'Alphabet' },
  ],
  aiMode: true, // use Google AI Mode for search
};

const KEY = 'startpage.settings.v1';

export function loadSettings() {
  try {
    const raw = localStorage.getItem(KEY);
    if (!raw) return { ...DEFAULTS };
    return { ...DEFAULTS, ...JSON.parse(raw) };
  } catch {
    return { ...DEFAULTS };
  }
}

export function saveSettings(s) {
  try {
    localStorage.setItem(KEY, JSON.stringify(s));
  } catch {
    /* storage unavailable (private mode) — settings just won't persist */
  }
}

export { DEFAULTS };
