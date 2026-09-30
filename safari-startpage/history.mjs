// Local browsing data: Safari history (History.db) and bookmarks
// (Bookmarks.plist). Both live in ~/Library/Safari, which macOS protects with
// Full Disk Access. Without that grant every read fails with EPERM, so we
// detect it and report it rather than throwing.
//
// Nothing leaves the machine: we only return a ranked list of titles/URLs for
// the current keystrokes.
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { DatabaseSync } from 'node:sqlite';

// --- Minimal binary-plist (bplist00) reader -------------------------------
// Bookmarks.plist is a binary plist. Full Disk Access is granted per-binary, so
// shelling out to /usr/bin/plutil is not an option: that binary is denied even
// when this process can read the file. We decode the subset of the format Apple
// actually uses for bookmarks (dict, array, ASCII/UTF-16 strings, ints, bools).
export function readBinaryPlist(buf) {
  if (buf.subarray(0, 8).toString('latin1') !== 'bplist00') {
    throw new Error('not a binary plist');
  }
  const trailer = buf.subarray(buf.length - 32);
  // Trailer layout (Apple's CFBinaryPList.c, last 32 bytes):
  //   [0..4] unused, [5] sortVersion, [6] offsetIntSize, [7] objectRefSize,
  //   [8..15]  numObjects     (uint64 BE)
  //   [16..23] topObject      (uint64 BE)
  //   [24..31] offsetTableOffset (uint64 BE)
  const hdr = buf.subarray(buf.length - 32);
  const offsetSize = hdr[6];
  const objectRefSize = hdr[7];
  const numObjects = Number(hdr.readBigUInt64BE(8));
  const topObject = Number(hdr.readBigUInt64BE(16));
  const offsetTableOffset = Number(hdr.readBigUInt64BE(24));
  if (!numObjects || !offsetTableOffset || !offsetSize || !objectRefSize) {
    throw new Error(
      `bad plist trailer (n=${numObjects}, off=${offsetTableOffset}, os=${offsetSize}, rs=${objectRefSize})`,
    );
  }

  const readOffset = (i) => {
    const base = offsetTableOffset + i * offsetSize;
    let v = 0;
    for (let b = 0; b < offsetSize; b++) v = v * 256 + buf[base + b];
    return v;
  };  const readRef = (pos) => {
    let v = 0;
    for (let b = 0; b < objectRefSize; b++) v = v * 256 + buf[pos + b];
    return v;
  };

  // When a collection/string's length marker is 0xf, the real length follows as
  // an *integer object* (type 1), whose size is encoded in its own low nibble.
  // It is not an object ref, so it must be decoded from the bytes, not readRef'd.
  const readLength = (pos) => {
    const marker = buf[pos];
    if ((marker >> 4) !== 0x1) return readRef(pos);
    const size = 1 << (marker & 0x0f);
    let v = 0;
    for (let i = 0; i < size; i++) v = v * 256 + buf[pos + 1 + i];
    return v;
  };

  const cache = new Map();
  function parseRef(index) {
    if (cache.has(index)) return cache.get(index);
    const start = readOffset(index);
    const marker = buf[start];
    const type = marker >> 4;
    const info = marker & 0x0f;
    const long = info === 0xf;
    // For long forms the data starts after the extra length object.
    const dataStart = start + 1 + (long ? 1 + (1 << (buf[start + 1] & 0x0f)) : 0);

    if (type === 0x0) {
      const v =
        info === 0x0 ? null
        : info === 0x8 ? false
        : info === 0x9 ? true
        : info === 0xf ? null
        : buf[start + 1];
      cache.set(index, v);
      return v;
    }
    if (type === 0x1) {
      // int
      const len = 1 << info;
      let v = 0;
      const neg = buf[start + 1] === 1;
      for (let i = 0; i < len; i++) v = v * 256 + buf[start + 1 + i];
      if (neg && info === 3) v = v - 0x100000000; // 64-bit not needed here
      cache.set(index, v);
      return v;
    }
    if (type === 0x2 && info === 0x4) {
      // real
      const v = buf.readDoubleBE(start + 1);
      cache.set(index, v);
      return v;
    }
    if (type === 0x4) {
      // data -> Buffer
      const len = long ? readLength(start + 1) : info;
      const v = buf.subarray(dataStart, dataStart + len);
      cache.set(index, v);
      return v;
    }
    if (type === 0x5) {
      // ASCII string
      const len = long ? readLength(start + 1) : info;
      const v = buf.toString('latin1', dataStart, dataStart + len);
      cache.set(index, v);
      return v;
    }
    if (type === 0x6) {
      // UTF-16BE string. Node has no utf16be decoder, so swap to LE first.
      const len = long ? readLength(start + 1) : info;
      const swapped = Buffer.from(buf.subarray(dataStart, dataStart + len * 2));
      swapped.swap16();
      const v = swapped.toString('utf16le');
      cache.set(index, v);
      return v;
    }
    if (type === 0xa || type === 0xc) {
      // array / set
      const len = long ? readLength(start + 1) : info;
      const arr = [];
      cache.set(index, arr);
      for (let i = 0; i < len; i++) arr.push(parseRef(readRef(dataStart + i * objectRefSize)));
      return arr;
    }
    if (type === 0xd) {
      // dict
      const len = long ? readLength(start + 1) : info;
      const obj = {};
      cache.set(index, obj);
      for (let i = 0; i < len; i++) {
        const key = parseRef(readRef(dataStart + i * objectRefSize));
        const val = parseRef(readRef(dataStart + (len + i) * objectRefSize));
        obj[key] = val;
      }
      return obj;
    }
    const v = null;
    cache.set(index, v);
    return v;
  }

  if (!numObjects) throw new Error('empty plist');
  return parseRef(topObject);
}


// Overridable for testing against a fixture DB; production always uses Safari's.
const HISTORY_DB =
  process.env.HISTORY_DB ?? path.join(os.homedir(), 'Library', 'Safari', 'History.db');
const BOOKMARKS_PLIST =
  process.env.BOOKMARKS_PLIST ?? path.join(os.homedir(), 'Library', 'Safari', 'Bookmarks.plist');

const CACHE_MS = 60 * 1000;
const cache = new Map(); // prefix -> { at, items }

// The underlying data is re-read at most this often, then ranking runs purely
// in memory. Previously every new prefix re-scanned the history table AND
// re-parsed the whole bookmarks plist, which cost ~80ms per keystroke.
const DATA_TTL_MS = 30 * 1000;

// null = unchecked, true/false = whether Safari's data is readable.
let access = null;

export async function canReadSafari() {
  if (access !== null) return access;
  try {
    await fs.promises.access(HISTORY_DB, fs.constants.R_OK);
    access = true;
  } catch {
    access = false;
  }
  return access;
}

// A single stable snapshot object. It is mutated in place rather than replaced,
// so a request that captured a reference always sees current data and never
// races with a refresh swapping the object out.
const snapshot = { at: 0, rows: null, bookmarks: [], loading: null };

// Returns the cached dataset, refreshing in the background when stale so a
// keystroke never waits on disk.
async function getSnapshot() {
  if (snapshot.rows && Date.now() - snapshot.at < DATA_TTL_MS) return snapshot;

  if (!snapshot.rows) {
    // Cold start: we have to wait for the first read.
    if (!snapshot.loading) {
      snapshot.loading = refreshSnapshot().finally(() => {
        snapshot.loading = null;
      });
    }
    await snapshot.loading;
  } else {
    // Stale but usable: serve it now, refresh behind the scenes.
    refreshSoon();
  }
  return snapshot;
}

let refreshTimer = null;
function refreshSoon() {
  if (refreshTimer || snapshot.loading) return;
  refreshTimer = setTimeout(() => {
    refreshTimer = null;
    snapshot.loading = refreshSnapshot()
      .catch(() => {
        // Keep serving the previous snapshot.
      })
      .finally(() => {
        snapshot.loading = null;
      });
  }, 50);
  // Don't hold the process open just to refresh.
  refreshTimer.unref?.();
}

async function loadSnapshot() {
  const rows = await queryHistory();

  // Collapse repeat visits once, here, so ranking does no dedupe work.
  const byUrl = new Map();
  for (const r of rows) {
    const prev = byUrl.get(r.url);
    if (!prev) byUrl.set(r.url, r);
    else {
      prev.visitCount = Math.max(prev.visitCount, r.visitCount);
      prev.lastVisit = Math.max(prev.lastVisit, r.lastVisit);
      prev.visitCountScore = Math.max(prev.visitCountScore, r.visitCountScore);
      if (!prev.title) prev.title = r.title;
    }
  }

  let bookmarks = [];
  try {
    bookmarks = await queryBookmarks();
  } catch {
    // Bookmarks are a bonus; history alone is still useful.
  }

  return { rows: [...byUrl.values()], bookmarks };
}

// Loads and installs a fresh snapshot, mutating the stable object in place.
async function refreshSnapshot() {
  const fresh = await loadSnapshot();
  snapshot.rows = fresh.rows;
  snapshot.bookmarks = fresh.bookmarks;
  snapshot.at = Date.now();
}

// Ranks like a browser's own URL bar. The important detail is that matching is
// done on the HOST first: a browser shows "github.com" for "git", not some deep
// page whose path happens to contain those letters. Deep pages are also
// penalised so a single site cannot flood the list.
export function scoreRow({ title, url, visitCount, visitCountScore, lastVisit }, prefix) {
  const p = prefix.toLowerCase();
  if (!p) return 0;
  const t = (title || '').trim().toLowerCase();
  const u = (url || '').trim().toLowerCase();

  let host = u;
  let path = '';
  try {
    const parsed = new URL(u);
    host = parsed.hostname.replace(/^www\./, '');
    path = parsed.pathname.replace(/^\//, '');
  } catch {
    // Not a parseable URL; fall back to matching the whole string.
    host = u;
  }

  // A browser matches from the start of a word in the URL. Substring hits
  // buried mid-token are what surface junk (typing "twi" matching a Reddit
  // thread's path), so those are rejected outright.
  const segs = path.split('/').filter(Boolean);
  const segPrefixHit = segs.some((s) => s.startsWith(p));
  const tWords = t.split(/[\s\-_/|]+/).filter(Boolean);
  const titleWordHit = tWords.some((w) => w.startsWith(p));

  let score = 0;
  if (host === p) score = 130;
  else if (host.startsWith(p)) score = 115;
  else if (titleWordHit) score = 100;
  else if (segPrefixHit) score = 75;
  else if (host.includes(p)) score = 60;
  else return 0;

  // Prefer Safari's own relevance score, else fall back to the visit count.
  const weight = visitCountScore || Math.min(visitCount || 0, 50) * 0.35;
  score += Math.min(weight, 40);

  // Boost recent entries; the bonus decays to zero over roughly 180 days.
  if (lastVisit) {
    const days = (Date.now() / 1000 - lastVisit) / 86400;
    if (days < 180) score += Math.max(0, 18 - days / 10);
  }

  // Penalise deep links so the site's home page outranks a specific page, and
  // so 200-character URLs sink below readable ones.
  const depth = path ? path.split('/').filter(Boolean).length : 0;
  score -= depth * 8;
  score -= Math.min(host.length + path.length, 120) * 0.12;

  return score;
}

async function queryHistory() {
  // Read with Node's built-in SQLite rather than the /usr/bin/sqlite3 CLI:
  // Full Disk Access is granted per-binary, so a child process would be denied
  // even though this process can read the file. Opened read-only so we never
  // risk locking Safari out of its own database.
  //
  // Current Safari keeps `title` on history_visits (there is no
  // history_titles table any more), and exposes visit_count_score, which is
  // Safari's own relevance score — we prefer it and fall back to visit_count.
  //
  // Every column is aliased because node:sqlite keys results by column name.
  const db = new DatabaseSync(HISTORY_DB, { readOnly: true });
  try {
    const stmt = db.prepare(`SELECT i.url AS url,
       i.visit_count AS visit_count,
       i.visit_count_score AS visit_count_score,
       v.visit_time AS visit_time,
       COALESCE(v.title, '') AS title
FROM history_items i
JOIN history_visits v ON v.history_item = i.id
WHERE i.url LIKE 'http%'
ORDER BY v.visit_time DESC
LIMIT 4000`);

    return stmt.all().map((r) => ({
      url: String(r.url ?? '').trim(),
      visitCount: Number(r.visit_count) || 0,
      // Safari's own score, when present, is a better relevance signal than
      // a raw visit count.
      visitCountScore: Number(r.visit_count_score) || 0,
      lastVisit: Number(r.visit_time) || 0,
      title: String(r.title ?? '').trim(),
    }));
  } finally {
    db.close();
  }
}

// Bookmarks.plist is a binary plist, decoded in-process by readBinaryPlist()
// (see the note at the top of this file about per-binary Full Disk Access).
// Exported for tests: exercises the binary-plist reader end to end.
export function parseBookmarksPlist(buf) {
  const tree = readBinaryPlist(buf);
  const out = [];
  const walk = (node) => {
    if (Array.isArray(node)) {
      for (const n of node) walk(n);
      return;
    }
    if (!node || typeof node !== 'object') return;

    // Bookmarks come in a few shapes across Safari versions and iCloud sync:
    //   URL        — the usual key on a WebBookmarkTypeLeaf
    //   URLString  — used by Reading List / Favorites entries
    // and the title may sit in Title or in URIDictionary.title.
    if (node.URL || node.URLString) {
      const url = String(node.URL ?? node.URLString);
      if (/^https?:/i.test(url)) {
        out.push({
          url,
          title: String(node.URIDictionary?.title ?? node.Title ?? ''),
          bookmark: true,
        });
      }
    }
    if (node.Children) walk(node.Children);
  };
  walk(tree);
  return out;
}

export async function queryBookmarks() {
  return parseBookmarksPlist(fs.readFileSync(BOOKMARKS_PLIST));
}

async function itemsFor(prefix, limit) {
  const key = prefix.toLowerCase();
  const hit = cache.get(key);
  if (hit && Date.now() - hit.at < CACHE_MS) return { items: hit.items };

  let snap;
  try {
    snap = await getSnapshot();
  } catch (e) {
    const msg = String(e?.message ?? e);
    console.error('[history] query failed:', msg);
    const denied = /not permitted|authorization denied|unable to open/i.test(msg);
    return { error: denied ? 'permission' : 'query' };
  }

  const matched = snap.rows
    .map((r) => ({ ...r, score: scoreRow(r, key) }))
    .filter((r) => r.score > 0)
    .sort((a, b) => b.score - a.score);

  // Cap how many rows one host can contribute, so a single frequently-visited
  // site cannot fill the whole list the way it would in a naive sort.
  const perHost = new Map();
  const items = [];
  for (const r of matched) {
    let host = r.url;
    try {
      host = new URL(r.url).hostname.replace(/^www\./, '');
    } catch {
      /* keep raw */
    }
    const seen = perHost.get(host) ?? 0;
    if (seen >= 2) continue;
    perHost.set(host, seen + 1);
    items.push(r);
    if (items.length >= limit) break;
  }

  if (key && snap.bookmarks.length) {
    // Reserve part of the list for bookmarks so they are not crowded out by
    // heavily-visited history entries.
    const bmBudget = Math.max(2, Math.ceil(limit / 3));
    const seenUrls = new Set(snap.rows.map((r) => r.url));
    const bm = [];
    for (const m of snap.bookmarks) {
      const score = scoreRow({ ...m, visitCount: 0, lastVisit: 0 }, key);
      if (score <= 0) continue;
      // A URL that is both bookmarked and visited keeps the bookmark badge
      // rather than appearing as two separate rows.
      if (!seenUrls.has(m.url)) {
        bm.push({ ...m, bookmark: true, score: score + 15 });
      }
    }
    bm.sort((a, b) => b.score - a.score);
    const top = items.slice(0, Math.max(1, limit - bmBudget));
    const merged = [...top, ...bm.slice(0, bmBudget)];
    items.length = 0;
    items.push(...merged.sort((a, b) => b.score - a.score).slice(0, limit));
  }

  cache.set(key, { at: Date.now(), items });
  return { items };
}

export async function warmHistory() {
  try {
    await getSnapshot();
  } catch {
    // Autocomplete will surface the real error on first use.
  }
}

export async function handleHistory(res, url) {
  const q = (url.searchParams.get('q') || '').trim().slice(0, 128);
  const limit = Math.min(Number(url.searchParams.get('limit')) || 12, 30);
  const send = (obj) =>
    res
      .writeHead(200, {
        'Content-Type': 'application/json; charset=utf-8',
        'Access-Control-Allow-Origin': '*',
        'Cache-Control': 'no-store',
      })
      .end(JSON.stringify(obj));

  if (!(await canReadSafari())) {
    return send({
      available: false,
      reason: 'Safari history is unreadable — grant Full Disk Access to Node',
      items: [],
    });
  }

  const { items, error } = await itemsFor(q, limit);
  if (error) {
    return send({ available: false, reason: error, items: [] });
  }
  send({ available: true, items });
}

