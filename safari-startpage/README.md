# Safari Start Page

A Bonjour-style start page for Safari: greeting, weather, stock quotes, and a
Google search field that grabs your keystrokes the moment the page opens.

Built with Vite + React. Served by a small dependency-free Node server that also
proxies stock quotes.

## Install

```bash
cd safari-startpage
bash scripts/install.sh
```

This builds the app, registers a LaunchAgent (`com.yasha.safari-startpage`) that
starts the server at login on port 8787, and opens `http://localhost:8787` in
Safari.

Undo with:

```bash
bash scripts/uninstall.sh
```

## Keyboard behavior

| Key | Action |
| --- | --- |
| *(any typing)* | Goes into the search field — it is autofocused on load |
| `/` or `⌘K` | Focus and select the search field |
| `↓` / `↑` | Move through autocomplete suggestions (wraps) |
| `→` | Accept the inline completion shown in the field |
| `Tab` | Fill the highlighted suggestion |
| `↵` | Go to the top suggestion / inline completion, or search |
| `⌥↵` | Same search, but the *other* mode (AI Mode ↔ plain Google) |
| `Esc` | Close the dropdown, then blur the field |

Typing something that looks like a URL (`github.com`, `https://…`) navigates
there instead of searching, and a **Go to** entry is offered at the top of the
list. Google operators like `site:apple.com` are treated as searches.

### Inline completion

Once a top suggestion is known, the rest of it appears inline in grey behind
your text, like Chrome's omnibox — typing continues to replace it, `→` accepts
it, and `↵` goes straight to it. It is suppressed while a dropdown row is
highlighted, and for URLs that are already complete.

## Autocomplete

Suggestions are merged from three sources and ranked:

1. **Safari history and bookmarks** — pages you've actually visited, ranked the
   way a browser's URL bar does: the **host** is matched first (typing `git`
   gives `github.com`, not a deep page whose path happens to contain those
   letters), matches must start at a word boundary, and deep or very long URLs
   are penalised so a site's home page outranks one specific page. At most two
   rows per host, so one site can't flood the list. Labelled by URL with the
   page title beneath, marked ◷ history / ★ bookmark.
2. **Recent searches** — your last searches from this page, stored in
   localStorage. Instant and works offline.
3. **Google suggestions** — via `/api/suggest`, which proxies
   `suggestqueries.google.com`. Debounced 90ms and cached server-side for 10
   minutes per prefix.

Typing a URL offers a **Go to** entry at the very top.

The full list of recent searches appears when the field is empty.

### Enabling Safari history (one-time, manual)

macOS protects `~/Library/Safari` behind Full Disk Access, and there is no other
way to read history — no API, no AppleScript command, no Spotlight index. Until
you grant it, autocomplete silently falls back to Google suggestions only.

```bash
bash scripts/enable-history.sh
```

The script checks access and, if blocked, prints the steps:

1. **System Settings > Privacy & Security > Full Disk Access**
2. Click **+** and add the Node binary it prints (use the resolved path, not a
   symlink — macOS matches on the real binary)
3. Toggle it on, then restart the server:
   ```bash
   launchctl kickstart -k gui/$(id -u)/com.yasha.safari-startpage
   ```

The server logs `Safari history: available` or `BLOCKED` on startup, and
`/api/history` returns `{"available": false, ...}` when it cannot read the DB.

This grant is scoped to Node, and this app only ever queries titles/URLs for the
current keystrokes — nothing is written and nothing leaves the machine.

## Data sources

- **Weather** — [Open-Meteo](https://open-meteo.com), no API key. Called directly
  from the browser (it sends permissive CORS headers).
- **Quotes** — [Nasdaq](https://www.nasdaq.com) via `/api/quotes`, with
  [Yahoo Finance](https://finance.yahoo.com) as a fallback. A server-side proxy is
  required because neither endpoint sends CORS headers, so the browser cannot
  call them directly. Quotes are refreshed in the background every 30s and never
  block the response, so the card paints from cache instantly.

### Instant load

The page renders real numbers on the first frame rather than skeletons, because
nothing on the critical path waits on the network:

- **Quotes** — the server keeps every quote in memory *and* on disk
  (`cache/quotes.json`, gitignored), so a reload — even after a restart or a
  reboot — already has prices. `/api/quotes` only reads that cache and schedules a
  background refresh; the sequential 700ms upstream gap now happens off the
  response path. Twelve common tickers are pre-warmed at boot, off the
  critical path.
- **Weather** — the last Open-Meteo reading is kept in `localStorage` and used
  as the initial state; the live fetch replaces it when it lands. A failed
  refresh no longer blanks a card that already has data.
- **Quotes in the browser** — the last good payload is mirrored to
  `localStorage` (60s) so the first frame has prices even before the request
  returns.
- **Static assets** — Vite fingerprinted files under `/assets/` are served
  `immutable` for a year; `index.html` stays `no-cache` so a rebuild always
  shows.
- **History** — snapshot is warmed at boot, but warming is no longer awaited, so
  the server accepts requests immediately.

Measured in Chrome on a warm profile: weather and all quotes visible ~26ms after
navigation start (was ~600ms / ~4.2s respectively).

Stock symbols must be Nasdaq-listed tickers. Index symbols like `^GSPC` depend on
the Yahoo fallback and may show a dash while Yahoo is rate-limiting.

## Dev

```bash
npm run dev        # Vite dev server; quotes proxy expected on :8787
node server.mjs    # serve the production build + quote proxy
```

## Layout

```
src/
  App.jsx      UI, keyboard handling, hooks
  api.js       weather (Open-Meteo)
  stocks.js    quote fetching
  search.js    URL vs. search detection, AI Mode URL building
  suggest.js   autocomplete merging, ranking, recent searches
  settings.js  localStorage-backed preferences
  styles.css   theming, light/dark via prefers-color-scheme
server.mjs     static server + /api/quotes and /api/suggest proxies
history.mjs    Safari history + bookmark reader (needs Full Disk Access)
scripts/       install.sh / uninstall.sh
```

### Dow chart

The card to the right of Markets is a Dow Jones intraday line/area chart
(`^DJI`, 1D at 5-minute intervals) with a price axis, exchange-time labels, and
a dashed previous-close reference line so the day's direction is readable at a
glance. It is served by `/api/chart`, which uses the same stale-while-revalidate
and on-disk cache as the quotes.

Two Yahoo quirks are handled explicitly:

- The chart endpoint returns 429 to `node:https` but serves undici, so it uses
  global `fetch`. This is the opposite of the quote and suggest endpoints, which
  are the reason `https.get` exists here at all.
- Yahoo throttles bursts, so the fetch retries with exponential backoff. The
  series is warmed at boot **before** the quote prewarm, because the chart has
  no alternative provider and must not lose the race for the rate-limit budget.
