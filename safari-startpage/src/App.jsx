import { useEffect, useMemo, useRef, useState, useCallback } from 'react';
import { loadSettings, saveSettings } from './settings.js';
import { fetchWeather, describeWeather, loadCachedWeather } from './api.js';
import { fetchQuotes, loadCachedQuotes } from './stocks.js';
import { fetchChart, loadCachedChart } from './chart.js';
import { buildUrl, buildSearchUrl, isUrlLike } from './search.js';
import { rememberSearch, fetchSuggestions, fetchHistory, rankSuggestions } from './suggest.js';

export function greeting(date) {
  const h = date.getHours();
  if (h < 5) return 'Good night';
  if (h < 12) return 'Good morning';
  if (h < 18) return 'Good afternoon';
  return 'Good evening';
}

export function clockString(date) {
  return date.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
}

export function dateString(date) {
  return date.toLocaleDateString([], { weekday: 'long', month: 'long', day: 'numeric' });
}

export function useWeather({ lat, lon, units }) {
  // Seeded synchronously from the last reading, so the card paints real numbers
  // on the first frame instead of a skeleton.
  const key = `${lat.toFixed(2)},${lon.toFixed(2)},${units}`;
  const [weather, setWeather] = useState(() => loadCachedWeather(key)?.data ?? null);
  const [error, setError] = useState(null);
  // Read inside load() without making it a dependency, which would re-trigger
  // the effect every time the data arrives.
  const hasWeather = useRef(weather != null);
  hasWeather.current = weather != null;

  const load = useCallback(async () => {
    try {
      setError(null);
      setWeather(await fetchWeather({ lat, lon, units }));
    } catch (e) {
      // Keep whatever is on screen; a transient failure isn't worth blanking
      // the card for.
      setError((prev) => (hasWeather.current ? prev : e.message));
    }
  }, [lat, lon, units]);

  useEffect(() => {
    // Re-seed when the location changes, so switching cities is also instant.
    setWeather(loadCachedWeather(key)?.data ?? null);
    load();
    const id = setInterval(load, 10 * 60 * 1000);
    return () => clearInterval(id);
  }, [key, load]);

  return { weather, error, reload: load };
}

export function useQuotes(stocks) {
  const key = stocks.map((s) => s.symbol).join(',');
  // Seeded synchronously from the last response, so the first frame has prices.
  const [quotes, setQuotes] = useState(() => loadCachedQuotes(stocks));

  useEffect(() => {
    let alive = true;
    const cached = loadCachedQuotes(stocks);
    setQuotes(cached);
    const pull = () => {
      fetchQuotes(stocks)
        .then((q) => {
          if (alive) setQuotes(q);
        })
        .catch(() => {
          // Keep whatever we have rather than replacing real numbers with dashes.
          if (alive && !cached.length) setQuotes(stocks.map((s) => ({ ...s, error: true })));
        });
    };
    pull();
    const id = setInterval(pull, 60 * 1000);
    return () => {
      alive = false;
      clearInterval(id);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [key]);

  return quotes;
}

export function useChart(opts = CHART_OPTS) {
  const key = `${opts.symbol}:${opts.range}:${opts.interval}`;
  // Seeded synchronously from the last series, so the card draws a line on the
  // first frame rather than "Loading chart…".
  const [series, setSeries] = useState(() => loadCachedChart(opts));
  const [error, setError] = useState(null);

  useEffect(() => {
    let alive = true;
    setSeries(loadCachedChart(opts));
    fetchChart(opts)
      .then((s) => {
        if (alive) setSeries(s);
      })
      .catch((e) => {
        // Keep whatever is already drawn; a failed refresh is not worth blanking.
        if (alive) setError(e.message);
      });
    // Refresh once mid-session so the line doesn't go stale while the tab is open.
    const id = setInterval(() => {
      fetchChart(opts)
        .then((s) => alive && setSeries(s))
        .catch(() => {});
    }, 60 * 1000);
    return () => {
      alive = false;
      clearInterval(id);
    };
  }, [key]);

  return { series, error };
}

export function WeatherCard({ weather, error, city, onRetry }) {
  if (error)
    return (
      <div className="card">
        <div>Weather unavailable</div>
        <button className="link" onClick={onRetry}>
          Retry
        </button>
      </div>
    );
  if (!weather) return <div className="card skeleton">Loading weather…</div>;

  const [label, icon] = describeWeather(weather.code);
  return (
    <div className="card weather">
      <div className="weather-main">
        <div className="weather-icon">{icon}</div>
        <div>
          <div className="weather-temp">
            {weather.temp}
            {weather.unit}
          </div>
          <div className="weather-desc">{label}</div>
        </div>
      </div>
      <div className="weather-meta">
        <div>
          <span className="label">Feels like</span>
          <span>
            {weather.feelsLike}
            {weather.unit}
          </span>
        </div>
        <div>
          <span className="label">High / Low</span>
          <span>
            {Math.round(weather.high ?? 0)}° / {Math.round(weather.low ?? 0)}°
          </span>
        </div>
        <div>
          <span className="label">City</span>
          <span>{city}</span>
        </div>
      </div>
      {weather.days?.length > 1 && (
        <div className="forecast">
          {weather.days.slice(1, 5).map((d) => {
            const [l, ic] = describeWeather(d.code);
            return (
              <div className="forecast-day" key={d.date}>
                <div className="f-label">
                  {new Date(d.date + 'T12:00:00').toLocaleDateString([], { weekday: 'short' })}
                </div>
                <div className="f-icon">{ic}</div>
                <div className="f-range">
                  {Math.round(d.high ?? 0)}° <span className="dim">{Math.round(d.low ?? 0)}°</span>
                </div>
                <div className="f-desc dim">{l}</div>
              </div>
            );
          })}
        </div>
      )}
    </div>
  );
}

export function StocksCard({ quotes }) {
  return (
    <div className="card stocks">
      <div className="card-title">Markets</div>
      {quotes.length === 0 && <div className="skeleton">Loading quotes…</div>}
      <ul>
        {quotes.map((q) => {
          const up = (q.change ?? 0) >= 0;
          return (
            <li key={q.symbol}>
              <span className="sym">
                <strong>{q.symbol.replace('^', '')}</strong>
                <span className="dim name">{q.name || q.symbol}</span>
              </span>
              {q.price == null ? (
                <span className="dim">—</span>
              ) : (
                <span className="quote">
                  {q.price.toFixed(2)}
                  <span className={up ? 'up' : 'down'}>
                    {up ? '▲' : '▼'} {Math.abs(q.changePct ?? 0).toFixed(2)}%
                  </span>

                </span>
              )}
            </li>
          );
        })}
      </ul>
      <div className="foot dim">Quotes via Nasdaq · may be delayed</div>
    </div>
  );
}

export const CHART_OPTS = { symbol: '^DJI', range: '1d', interval: '5m' };

// Drawn with a fixed viewBox and preserveAspectRatio="none" so the SVG scales
// to whatever width the card gets without re-measuring the DOM.
const CHART_W = 600;
const CHART_H = 240;

export function buildChartPath(points, pad) {
  const values = points.map((p) => p.v);
  const lo = Math.min(...values);
  const hi = Math.max(...values);
  // A flat series would divide by zero; give it a nominal 1-point range.
  const span = hi - lo || 1;
  const innerW = CHART_W - pad.l - pad.r;
  const innerH = CHART_H - pad.t - pad.b;

  const coords = points.map((p, i) => {
    const x = pad.l + (i / (points.length - 1)) * innerW;
    const y = pad.t + (1 - (p.v - lo) / span) * innerH;
    return [x, y];
  });

  // Straight segments: with ~78 five-minute bars the raw data is already
  // smooth, and this keeps the path cheap to recompute on every render.
  const line = coords
    .map(([x, y], i) => `${i ? 'L' : 'M'}${x.toFixed(1)},${y.toFixed(1)}`)
    .join('');
  const area = `${line}L${coords[coords.length - 1][0].toFixed(1)},${CHART_H - pad.b}L${coords[0][0].toFixed(1)},${CHART_H - pad.b}Z`;

  return { line, area, lo, hi, span, last: coords[coords.length - 1] };
}

// Exchange time, so the x-axis reads as the trading day rather than the
// viewer's local clock.
function clockLabel(ms) {
  return new Date(ms).toLocaleTimeString([], {
    hour: 'numeric',
    minute: '2-digit',
    timeZone: 'America/New_York',
  });
}

// The chart body, split out so ChartCard stays readable. `preserveAspectRatio`
// is "none" so the SVG stretches to the card's width; every stroke therefore
// uses vectorEffect to keep its width in screen pixels instead of being scaled.
function Sparkline({
  line,
  area,
  last,
  stroke,
  lo,
  hi,
  pad,
  innerH,
  prev,
  prevY,
  ticks,
  fmt,
  up,
  changePct,
}) {
  return (
    <svg
      className="chart-svg"
      viewBox={`0 0 ${CHART_W} ${CHART_H}`}
      preserveAspectRatio="none"
      role="img"
      aria-label={`Dow Jones intraday chart, ${up ? 'up' : 'down'} ${Math.abs(changePct).toFixed(2)} percent`}
    >
      <defs>
        <linearGradient id="chartFill" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0%" stopColor={stroke} stopOpacity="0.28" />
          <stop offset="100%" stopColor={stroke} stopOpacity="0" />
        </linearGradient>
      </defs>

      {/* Horizontal gridlines, each labelled with the price it represents. */}
      {[0, 0.5, 1].map((f) => {
        const y = pad.t + f * innerH;
        return (
          <g key={f}>
            <line
              x1={pad.l}
              x2={CHART_W - pad.r}
              y1={y}
              y2={y}
              className="chart-grid"
            />
            <text x={pad.l - 8} y={y + 4} className="chart-axis" textAnchor="end">
              {fmt(hi - f * (hi - lo))}
            </text>
          </g>
        );
      })}

      {prev != null && (
        <>
          <line
            x1={pad.l}
            x2={CHART_W - pad.r}
            y1={prevY}
            y2={prevY}
            className="chart-prev"
          />
          <text x={CHART_W - pad.r - 4} y={prevY - 6} className="chart-axis" textAnchor="end">
            prev {fmt(prev)}
          </text>
        </>
      )}

      <path d={area} fill="url(#chartFill)" />
      <path d={line} fill="none" stroke={stroke} className="chart-line" />

      <circle cx={last[0]} cy={last[1]} r="4" fill={stroke} className="chart-dot" />

      {ticks.map((t, i) => (
        <text
          key={i}
          x={t.x}
          y={CHART_H - 8}
          className="chart-axis"
          textAnchor={i === 0 ? 'start' : i === ticks.length - 1 ? 'end' : 'middle'}
        >
          {t.label}
        </text>
      ))}
    </svg>
  );
}

export function ChartCard({ series, error }) {
  const points = series?.points ?? [];

  if (!points.length) {
    return (
      <div className="card chart">
        <div className="card-title">Dow Jones</div>
        <div className="skeleton">{error ? 'Chart unavailable' : 'Loading chart…'}</div>
      </div>
    );
  }

  const pad = { t: 16, r: 16, b: 26, l: 56 };
  const { line, area, lo, hi, span, last } = buildChartPath(points, pad);

  const first = points[0].v;
  const price = series.price ?? points[points.length - 1].v;
  const change = series.change ?? price - first;
  const changePct = series.changePct ?? (change / (price - change || 1)) * 100;
  const up = change >= 0;
  const stroke = up ? 'var(--up)' : 'var(--down)';
  const innerH = CHART_H - pad.t - pad.b;

  // Five evenly spaced time labels along the x-axis.
  const ticks = [0, 0.25, 0.5, 0.75, 1].map((f) => {
    const i = Math.min(points.length - 1, Math.round(f * (points.length - 1)));
    const x = pad.l + (i / (points.length - 1)) * (CHART_W - pad.l - pad.r);
    return { x, label: clockLabel(points[i].t) };
  });

  // Previous close as a dashed reference line, the baseline "up/down" is judged
  // against. Only drawn when it falls inside the plotted range.
  const prev = series.previousClose;
  const prevVisible = prev != null && prev >= lo && prev <= hi;
  const prevY = prevVisible ? pad.t + (1 - (prev - lo) / span) * innerH : 0;

  const fmt = (n) => n.toLocaleString([], { maximumFractionDigits: 0 });

  return (
    <div className="card chart">
      <div className="chart-head">
        <div className="card-title">Dow Jones Industrial Average</div>
        <div className="chart-range dim">1D · 5m</div>
      </div>
      <div className="chart-price">
        {price.toLocaleString([], { minimumFractionDigits: 2, maximumFractionDigits: 2 })}
        <span className={up ? 'up' : 'down'}>
          {up ? '▲' : '▼'} {change >= 0 ? '+' : ''}
          {change.toFixed(2)} ({changePct >= 0 ? '+' : ''}
          {changePct.toFixed(2)}%)
        </span>
      </div>
      <Sparkline
        line={line}
        area={area}
        last={last}
        stroke={stroke}
        lo={lo}
        hi={hi}
        pad={pad}
        innerH={innerH}
        prev={prevVisible ? prev : null}
        prevY={prevY}
        ticks={ticks}
        fmt={fmt}
        up={up}
        changePct={changePct}
      />
      <div className="foot dim">Intraday via Yahoo Finance · may be delayed</div>
    </div>
  );
}


const KIND_META = {
  url: { icon: '↗', label: 'Go to' },
  bookmark: { icon: '★', label: 'Bookmark' },
  history: { icon: '◷', label: 'History' },
  google: { icon: '🔍', label: 'Google' },
};

export function SuggestionList({ items, activeIndex, onPick, onHover }) {
  if (!items.length) return null;
  return (
    <ul className="suggestions" role="listbox" id="suggestions">
      {items.map((s, i) => {
        const meta = KIND_META[s.kind] ?? KIND_META.google;
        return (
          <li key={s.text + i}>
            <button
              type="button"
              role="option"
              aria-selected={i === activeIndex}
              className={i === activeIndex ? 'active' : ''}
              onMouseEnter={() => onHover(i)}
              onMouseDown={(e) => {
                // mousedown fires before the input blurs, so the click survives.
                e.preventDefault();
                onPick(s);
              }}
            >
              <span className={`s-icon k-${s.kind}`}>{meta.icon}</span>
              <span className="s-text">
                {s.text}
                {s.title && s.title !== s.text && (
                  <span className="s-url dim">{s.title}</span>
                )}
              </span>
              <span className="s-kind dim">{meta.label}</span>
            </button>
          </li>
        );
      })}
    </ul>
  );
}

export function SettingsPanel({ settings, setSettings, onClose }) {
  const [cityText, setCityText] = useState(settings.city);
  const [symbols, setSymbols] = useState(settings.stocks.map((s) => s.symbol).join(', '));

  const geocode = async () => {
    try {
      const res = await fetch(
        `https://geocoding-api.open-meteo.com/v1/search?name=${encodeURIComponent(cityText)}&count=1`,
      );
      const data = await res.json();
      const hit = data.results?.[0];
      if (!hit) return alert('City not found');
      setSettings({ ...settings, city: hit.name, lat: hit.latitude, lon: hit.longitude });
    } catch {
      alert('Could not look up city');
    }
  };

  const applyStocks = () => {
    const list = symbols
      .split(',')
      .map((s) => s.trim().toUpperCase())
      .filter(Boolean)
      .map((s) => ({ symbol: s, name: s }));
    if (list.length) setSettings({ ...settings, stocks: list });
  };

  return (
    <div className="settings">
      <div className="row">
        <input value={cityText} onChange={(e) => setCityText(e.target.value)} placeholder="City" />
        <select
          value={settings.units}
          onChange={(e) => setSettings({ ...settings, units: e.target.value })}
        >
          <option value="imperial">°F</option>
          <option value="metric">°C</option>
        </select>
        <button onClick={geocode}>Set</button>
      </div>
      <div className="row">
        <input
          value={symbols}
          onChange={(e) => setSymbols(e.target.value)}
          placeholder="AAPL, MSFT"
        />
        <button onClick={applyStocks}>Apply</button>
      </div>
      <label className="row check">
        <input
          type="checkbox"
          checked={settings.aiMode}
          onChange={(e) => setSettings({ ...settings, aiMode: e.target.checked })}
        />
        Use Google AI Mode
      </label>
      <button className="link" onClick={onClose}>
        Done
      </button>
    </div>
  );
}

export function useSuggestions(query, open) {
  const [google, setGoogle] = useState([]);
  const [history, setHistory] = useState([]);
  const [activeIndex, setActiveIndex] = useState(-1);

  // Debounced so we don't hit the suggest/history endpoints on every keystroke.
// Kept short (25ms): the server answers from an in-memory snapshot, so a longer
// wait would only add latency.
  // Both fire together and are merged during ranking.
  useEffect(() => {
    const q = query.trim();
    if (!open || !q) return;

    let alive = true;
    const id = setTimeout(() => {
      fetchSuggestions(q)
        .then((items) => {
          if (!alive) return;
          setGoogle(items);
          setActiveIndex(-1);
        })
        .catch(() => alive && setGoogle([]));
      fetchHistory(q)
        .then((res) => {
          if (!alive) return;
          setHistory(Array.isArray(res.items) ? res.items : []);
        })
        .catch(() => alive && setHistory([]));
    }, 25);

    return () => {
      alive = false;
      clearTimeout(id);
    };
  }, [query, open]);

  const items = useMemo(() => {
    // An empty field shows nothing: past searches as rows add no value over
    // history/bookmarks and just clutter the start page.
    if (!query.trim()) return [];

    // Guard against suggestions from a previous prefix lingering after a clear.
    const q = query.trim().toLowerCase();
    const fresh = google.filter((g) => g.toLowerCase().startsWith(q));
    // The server already decided what matches, using browser-style word-start
    // matching, and sends results for exactly this query. Re-filtering here
    // would only re-admit rows the server rejected, so the history list is
    // used as-is.
    const list = rankSuggestions({ query, google: fresh, history });

    // If what they typed looks like an address, offer to go there directly.
    // Scored above everything else so it's the top hit.
    if (isUrlLike(query)) {
      const url = buildUrl(query);
      if (url) {
        list.unshift({ text: url, kind: 'url', url, score: 1000 });
      }
    }
    return list;
  }, [query, google, history]);

  useEffect(() => setActiveIndex(-1), [query]);

  // Searches are still written to localStorage recents (harmless, and used if
  // rows are ever re-enabled), but they no longer drive any rendered row.
  const remember = (text) => {
    rememberSearch(text);
  };

  // Chrome-style inline completion: once a top suggestion is known, put the
  // rest of it in the field as selected text, so typing continues to replace
  // it and Enter submits the full value.
  const completion = useMemo(() => {
    if (!open || !query.trim() || activeIndex >= 0) return null;
    const top = items[0];
    if (!top) return null;
    if (top.kind === 'url') return null; // nothing to add to a complete URL
    const typed = query;
    if (!top.text.toLowerCase().startsWith(typed.toLowerCase())) return null;
    if (top.text.length <= typed.length) return null;
    return top;
  }, [items, query, open, activeIndex]);

  return { items, activeIndex, setActiveIndex, remember, completion };
}

export default function App() {
  const [settings, setSettings] = useState(loadSettings);
  const [query, setQuery] = useState('');
  const [now, setNow] = useState(() => new Date());
  const [showSettings, setShowSettings] = useState(false);
  const [suggestOpen, setSuggestOpen] = useState(false);
  const inputRef = useRef(null);
  const searchWrapRef = useRef(null);

  const { weather, error, reload } = useWeather(settings);
  const quotes = useQuotes(settings.stocks);
  const { series: chart, error: chartError } = useChart();
  const { items, activeIndex, setActiveIndex, remember, completion } = useSuggestions(
    query,
    suggestOpen,
  );

  // Close the dropdown when focus or a click leaves the search area.
  useEffect(() => {
    if (!suggestOpen) return;
    const onDown = (e) => {
      if (!searchWrapRef.current?.contains(e.target)) setSuggestOpen(false);
    };
    document.addEventListener('mousedown', onDown);
    return () => document.removeEventListener('mousedown', onDown);
  }, [suggestOpen]);

  useEffect(() => {
    const id = setInterval(() => setNow(new Date()), 1000);
    return () => clearInterval(id);
  }, []);

  // Auto-focus: whatever you type on load lands in the search field.
  useEffect(() => {
    inputRef.current?.focus();
  }, []);

  const update = (s) => {
    setSettings(s);
    saveSettings(s);
  };

  useEffect(() => {
    const onKey = (e) => {
      if (e.key === 'Escape') {
        if (showSettings) return setShowSettings(false);
        if (suggestOpen) return setSuggestOpen(false);
        inputRef.current?.blur();
        return;
      }
      const inField = e.target instanceof HTMLElement && ['INPUT', 'TEXTAREA'].includes(e.target.tagName);
      if ((e.key === 'k' || e.key === '/') && (e.metaKey || !inField)) {
        e.preventDefault();
        inputRef.current?.focus();
        inputRef.current?.select();
      }
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [showSettings, suggestOpen]);

  // Chrome does not implicitly submit a form on Cmd/Ctrl+Enter, so we handle
  // that combination ourselves for the "plain Google search" shortcut.
  const submit = (text, useAI) => {
    const q = text.trim();
    if (!q) return;
    remember(q);
    // URLs always win over search, regardless of AI mode.
    const target = isUrlLike(q) ? buildUrl(q) : buildSearchUrl(q, useAI);
    if (target) window.location.href = target;
  };

  const pick = (item) => {
    setSuggestOpen(false);
    setActiveIndex(-1);
    // History and bookmark rows point at a URL, so choosing one goes there.
    if (item.url) {
      window.location.href = item.url;
      return;
    }
    setQuery(item.text);
    inputRef.current?.focus();
  };

  const onKeyDown = (e) => {
    const count = items.length;

    // Right arrow at the end of the typed text accepts the inline completion,
    // the same way it does in Chrome's omnibox.
    if (e.key === 'ArrowRight' && completion) {
      const atEnd = e.currentTarget.selectionStart === e.currentTarget.value.length;
      if (atEnd) {
        e.preventDefault();
        setQuery(completion.text);
        return;
      }
    }

    if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
      if (!count) return;
      e.preventDefault();
      // -1 means "nothing highlighted". From there, Down selects index 0 and
      // Up selects the last item; further presses cycle with wraparound.
      setActiveIndex((i) => {
        if (i === -1) return e.key === 'ArrowDown' ? 0 : count - 1;
        const next = i + (e.key === 'ArrowDown' ? 1 : -1);
        return next < 0 ? count - 1 : next >= count ? 0 : next;
      });
      return;
    }

    if (e.key === 'Tab' && activeIndex >= 0 && count) {
      e.preventDefault();
      pick(items[activeIndex]);
      return;
    }

    if (e.key === 'Enter') {
      // A highlighted suggestion wins over the raw text.
      if (!e.metaKey && !e.ctrlKey && activeIndex >= 0 && count) {
        e.preventDefault();
        const chosen = items[activeIndex];
        pick(chosen);
        // Tab-like completion keeps focus in the field; a URL navigates away.
        if (!chosen.url) inputRef.current?.select();
        return;
      }
      // ⌥/Alt+Enter (or Ctrl) toggles to the other search mode.
      if (e.altKey || e.ctrlKey) {
        e.preventDefault();
        submit(e.currentTarget.value, !settings.aiMode);
        return;
      }
      if (e.metaKey) {
        e.preventDefault();
        submit(e.currentTarget.value, settings.aiMode);
        return;
      }

      // Nothing highlighted but an inline completion is showing: accept it and
      // go there, exactly like Chrome.
      if (completion) {
        e.preventDefault();
        pick(completion);
      }
    }
  };

  const onSubmit = (e) => {
    e.preventDefault();
    submit(query, settings.aiMode);
  };

  return (
    <div className="app">
      <div className="inner">
        <header>
          <div className="hello">
            <h1>{greeting(now)}</h1>
            <p className="dim">
              {dateString(now)} · {clockString(now)}
            </p>
          </div>
          <button className="gear" onClick={() => setShowSettings((v) => !v)} aria-label="Settings">
            ⚙︎
          </button>
        </header>

        <div className="search-wrap" ref={searchWrapRef}>
          <form className="search" onSubmit={onSubmit}>
            <span className="mag">🔍</span>
            <div className="field">
              <input
                ref={inputRef}
                value={query}
                onChange={(e) => {
                  setQuery(e.target.value);
                  setSuggestOpen(true);
                }}
                onFocus={() => setSuggestOpen(true)}
                onKeyDown={onKeyDown}
                placeholder="Search Google or type a URL"
                spellCheck="false"
                autoComplete="off"
                autoCorrect="off"
                autoCapitalize="off"
                role="combobox"
                aria-expanded={suggestOpen && items.length > 0}
                aria-autocomplete="list"
                aria-controls="suggestions"
              />
              {/* Chrome-style inline completion. Rendered after the input so it
                  paints on top; only the tail is visible, aligned by the
                  transparent leading characters. */}
              {completion && (
                <span className="ghost" aria-hidden="true">
                  {query}
                  <span className="ghost-tail">{completion.text.slice(query.length)}</span>
                </span>
              )}
            </div>
            {query && (
              <button
                type="button"
                className="clear"
                onClick={() => {
                  setQuery('');
                  setSuggestOpen(false);
                  inputRef.current?.focus();
                }}
                aria-label="Clear"
              >
                ✕
              </button>
            )}
            <button type="submit" className="go">
              {settings.aiMode ? 'Ask AI' : 'Search'}
            </button>
          </form>

          {suggestOpen && items.length > 0 && (
            <SuggestionList
              items={items}
              activeIndex={activeIndex}
              onPick={pick}
              onHover={setActiveIndex}
            />
          )}
        </div>

        <p className="hint dim">
          <kbd>/</kbd> or <kbd>⌘K</kbd> focus · <kbd>↑</kbd><kbd>↓</kbd> autocomplete ·{' '}
          <kbd>↵</kbd> {settings.aiMode ? 'Google AI Mode' : 'search'} · <kbd>⌥↵</kbd>{' '}
          {settings.aiMode ? 'plain Google' : 'AI Mode'}
        </p>

        <div className="grid">
          <div className="grid-top">
            <WeatherCard
              weather={weather}
              error={error}
              city={settings.city}
              onRetry={reload}
            />
          </div>
          <div className="grid-row">
            <StocksCard quotes={quotes} />
            <ChartCard series={chart} error={chartError} />
          </div>
        </div>

        {showSettings && (
          <SettingsPanel
            settings={settings}
            setSettings={update}
            onClose={() => setShowSettings(false)}
          />
        )}
      </div>
    </div>
  );
}

