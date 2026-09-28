/// Builds the bundled road tiles from roadcurvature.com KML/KMZ data.
///
/// Replaces `split-db-into-tiles.mjs`, which sliced Tougefinder's
/// `touges_db.json` into the same 0.25°-grid tiles. The output format is
/// unchanged — `LocalRoadSource` still reads `Resources/tiles/t_<lat>_<lon>.json`
/// as arrays of `TougeRoad` — so only this script and the data source change.
///
/// Usage:
///   node scripts/fetch-curvature-tiles.mjs                 # all US states, both bands
///   node scripts/fetch-curvature-tiles.mjs new-hampshire   # one state, for iteration
///
/// Each Placemark gives us a name, a LineString, and a description carrying
/// curvature / distance / road type / surface. roadcurvature has no flow data,
/// so `flowScore` is left null and `totalScore` is derived from curvature.

import { execFileSync } from 'node:child_process';
import { mkdirSync, writeFileSync, readdirSync, rmSync, existsSync } from 'node:fs';
import { resolve, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const OUT_DIR = resolve(__dirname, '../TougeTracker/Resources/tiles');
const CACHE_DIR = resolve(__dirname, '../.curvature-cache');

const BASE = 'https://kml.roadcurvature.com';
const US_INDEX = `${BASE}/north_america/us/`;

// Curvature value (degrees per mile) at which a road earns a perfect score.
// roadcurvature's own c_1000 threshold is "very twisty", so anything well
// past that is the top tier.
const CURVATURE_TOP = 3000;
const TILE_SIZE = 0.25;

/// Max deviation, in metres, allowed when simplifying road geometry. 5m is
/// well under a map pixel at any zoom the app offers, and is the difference
/// between a 1.8 GB and a shippable bundle.
const SIMPLIFY_METERS = Number(process.env.SIMPLIFY_METERS ?? 5);

/// Which curvature bands to ingest. `c_1000` is "very twisty" only; `c_300` is
/// the much larger "moderately twisty" set and dominates bundle size. Override
/// with `BANDS=c_1000 node scripts/fetch-curvature-tiles.mjs`.
const BANDS = (process.env.BANDS ?? 'c_300,c_1000').split(',').filter(Boolean);

function tileKey(lat, lon) {
  return `t_${Math.floor(lat / TILE_SIZE)}_${Math.floor(lon / TILE_SIZE)}`;
}

function round6(n) {
  return Math.round(n * 1e6) / 1e6;
}

/// Douglas–Peucker. roadcurvature emits every OSM node, so a long road can
/// carry tens of thousands of coordinates; dropping the ones that do not change
/// the shape cuts bundle size by roughly an order of magnitude with no visible
/// difference at map zooms. `toleranceMeters` is the max allowed deviation.
function simplify(points, toleranceMeters) {
  if (points.length < 3 || toleranceMeters <= 0) return points;

  const keep = new Uint8Array(points.length);
  keep[0] = keep[points.length - 1] = 1;
  const stack = [[0, points.length - 1]];

  // Work in a local metre frame so the tolerance is not distorted by latitude.
  const latScale = 111320;
  const lonScale = 111320 * Math.cos((points[0][1] * Math.PI) / 180);
  const sqTol = toleranceMeters * toleranceMeters;

  while (stack.length) {
    const [lo, hi] = stack.pop();
    if (hi - lo < 2) continue;

    const [ax, ay] = [points[lo][0] * lonScale, points[lo][1] * latScale];
    const [bx, by] = [points[hi][0] * lonScale, points[hi][1] * latScale];
    const dx = bx - ax;
    const dy = by - ay;
    const lenSq = dx * dx + dy * dy;

    let worst = -1;
    let worstIdx = -1;
    for (let i = lo + 1; i < hi; i++) {
      const px = points[i][0] * lonScale;
      const py = points[i][1] * latScale;
      let distSq;
      if (lenSq === 0) {
        distSq = (px - ax) ** 2 + (py - ay) ** 2;
      } else {
        let t = ((px - ax) * dx + (py - ay) * dy) / lenSq;
        t = t < 0 ? 0 : t > 1 ? 1 : t;
        distSq = (px - (ax + t * dx)) ** 2 + (py - (ay + t * dy)) ** 2;
      }
      if (distSq > worst) { worst = distSq; worstIdx = i; }
    }

    if (worst > sqTol) {
      keep[worstIdx] = 1;
      stack.push([lo, worstIdx], [worstIdx, hi]);
    }
  }

  return points.filter((_, i) => keep[i]);
}

/// FNV-1a over the UTF-8 bytes, matching `TougeRoad.stableId` in Swift so a
/// hashed string id would resolve identically on both sides. roadcurvature
/// exposes no numeric road id and OSM way ids would collide with the previous
/// Tougefinder dataset, so ids are hashed from the road's identity instead.
///
/// The modulus is 2^48 rather than Int64.max so the result survives a JSON
/// round-trip through JavaScript, which cannot represent integers past 2^53.
function stableId(text) {
  let hash = 0xcbf29ce484222325n;
  for (const byte of Buffer.from(text, 'utf8')) {
    hash ^= BigInt(byte);
    hash = (hash * 0x100000001b3n) & 0xffffffffffffffffn;
  }
  return Number(hash % (2n ** 48n));
}

/// Maps curvature onto the app's 0–100 score. Logarithmic because curvature
/// spans nearly three orders of magnitude across the c_300 and c_1000 bands;
/// a linear map would flatten every c_300 road to the bottom tier.
function scoreFor(curvature) {
  if (!(curvature > 0)) return 0;
  const floor = Math.log10(150);
  const ceiling = Math.log10(CURVATURE_TOP);
  const t = (Math.log10(curvature) - floor) / (ceiling - floor);
  return Math.max(0, Math.min(100, Math.round(20 + 60 * t)));
}

function haversineMiles(a, b) {
  const R = 3958.7613;
  const dLat = (b[1] - a[1]) * Math.PI / 180;
  const dLon = (b[0] - a[0]) * Math.PI / 180;
  const la1 = a[1] * Math.PI / 180;
  const la2 = b[1] * Math.PI / 180;
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(la1) * Math.cos(la2) * Math.sin(dLon / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(h));
}

function parseDescription(html) {
  const out = {};
  const text = html.replace(/<br\s*\/?>/gi, '\n').replace(/<[^>]+>/g, ' ');

  let m = text.match(/Curvature:\s*([\d.]+)/i);
  if (m) out.curvature = parseFloat(m[1]);

  m = text.match(/Distance:\s*([\d.]+)\s*mi/i);
  if (m) out.distanceMiles = parseFloat(m[1]);

  m = text.match(/Type:\s*([^\n]+)/i);
  if (m) out.type = m[1].replace(/\s+/g, ' ').trim();

  m = text.match(/Surface:\s*([^\n]+)/i);
  if (m) out.surface = m[1].replace(/\s+/g, ' ').trim();

  return out;
}

function decodeEntities(s) {
  return s
    .replace(/<!\[CDATA\[([\s\S]*?)\]\]>/g, '$1')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#39;|&apos;/g, "'")
    .replace(/&amp;/g, '&')
    .trim();
}

/// Pulls every Placemark out of a `doc.kml` body.
function parsePlacemarks(kml) {
  const out = [];
  const placemarkRe = /<Placemark>([\s\S]*?)<\/Placemark>/g;
  let pm;

  while ((pm = placemarkRe.exec(kml)) !== null) {
    const body = pm[1];

    const styleMatch = body.match(/<styleUrl>#([a-z]+)(\d+)<\/styleUrl>/i);
    const nameMatch = body.match(/<name>([\s\S]*?)<\/name>/i);
    const descMatch = body.match(/<description>([\s\S]*?)<\/description>/i);
    const lineMatch = body.match(/<LineString>([\s\S]*?)<\/LineString>/i);
    if (!lineMatch) continue;

    const coordsRaw = decodeEntities(
      lineMatch[1].match(/<coordinates>([\s\S]*?)<\/coordinates>/i)?.[1] ?? ''
    );
    const coordinates = coordsRaw
      .split(/\s+/)
      .map(t => t.trim())
      .filter(Boolean)
      .map(t => t.split(',').map(Number))
      .filter(p => p.length >= 2 && Number.isFinite(p[0]) && Number.isFinite(p[1]));

    if (coordinates.length < 2) continue;

    const meta = parseDescription(descMatch ? decodeEntities(descMatch[1]) : '');
    const style = styleMatch ? styleMatch[1].toLowerCase() : 'unknown';

    out.push({
      name: nameMatch ? decodeEntities(nameMatch[1]) : null,
      type: meta.type || (style === 'unknown' ? 'unknown' : style),
      surface: meta.surface,
      coordinates,
      curvature: meta.curvature,
      distanceMiles: meta.distanceMiles,
      surfaceClass: style,
    });
  }

  return out;
}

/// Downloads (and caches) a KMZ and returns its doc.kml text.
function fetchDocKml(url) {
  const file = join(CACHE_DIR, url.replace(/^https?:\/\//, '').replace(/\//g, '__'));
  if (!existsSync(file)) {
    console.log(`  download ${url}`);
    execFileSync('curl', ['-fsSL', '-o', file, url], { stdio: 'inherit' });
  }
  // A .kmz is a zip whose member is <region>/doc.kml.
  return execFileSync('unzip', ['-p', file, '*/doc.kml'], { maxBuffer: 512 * 1024 * 1024 })
    .toString('utf8');
}

/// Every state/country slug linked from the US index page.
function stateSlugs() {
  const html = execFileSync('curl', ['-fsSL', US_INDEX], { encoding: 'utf8' });
  const slugs = new Set();
  for (const m of html.matchAll(/href="([a-z0-9-]+)\.html"/g)) slugs.add(m[1]);
  slugs.delete('index');
  return [...slugs].sort();
}


function main() {
  const only = process.argv.slice(2);
  const states = only.length ? only : stateSlugs();

  mkdirSync(CACHE_DIR, { recursive: true });
  mkdirSync(OUT_DIR, { recursive: true });

  // Wipe the old Tougefinder tiles so a stale tile can never be read at runtime.
  for (const f of readdirSync(OUT_DIR)) {
    if (f.startsWith('t_') && f.endsWith('.json')) rmSync(join(OUT_DIR, f));
  }
  rmSync(join(OUT_DIR, 'tile_index.json'), { force: true });

  // Roads are buffered only for the state currently being processed and flushed
  // to disk afterwards. Holding the whole country in memory OOMs Node (see the
  // per-state flush below), and a 0.25° tile rarely spans two states, so
  // rewriting the touched tiles is cheap.
  let tiles = new Map();
  const seen = new Set();
  const dirty = new Set();
  let total = 0;
  let skipped = 0;
  let bytes = 0;
  const allTileKeys = new Set();

  const flush = () => {
    for (const key of dirty) {
      const content = JSON.stringify(tiles.get(key) ?? []);
      writeFileSync(resolve(OUT_DIR, `${key}.json`), content);
      bytes += content.length;
    }
    dirty.clear();
    tiles = new Map();
  };

  for (const state of states) {
    // The bigger band first, so the dedupe below keeps its copy of any road
    // that appears in both.
    for (const band of [...BANDS].sort((a, b) => (a === 'c_300' ? -1 : 1))) {
      const url = `${US_INDEX}${state}.${band}.kmz`;
      let kml;
      try {
        kml = fetchDocKml(url);
      } catch (e) {
        console.warn(`  ! ${state} ${band}: ${e.message}`);
        continue;
      }

      for (const road of parsePlacemarks(kml)) {
        const first = road.coordinates[0];
        const key = `${road.name ?? ''}|${first[0].toFixed(5)},${first[1].toFixed(5)}`;
        if (seen.has(key)) { skipped++; continue; }
        seen.add(key);

        const sumLat = road.coordinates.reduce((s, c) => s + c[1], 0);
        const sumLon = road.coordinates.reduce((s, c) => s + c[0], 0);
        const centerLat = round6(sumLat / road.coordinates.length);
        const centerLon = round6(sumLon / road.coordinates.length);

        let lengthMiles = road.distanceMiles;
        if (!(lengthMiles > 0)) {
          let m = 0;
          for (let i = 1; i < road.coordinates.length; i++) {
            m += haversineMiles(road.coordinates[i - 1], road.coordinates[i]);
          }
          lengthMiles = m;
        }

        const curvature = Math.round(road.curvature ?? 0);
        const tk = tileKey(centerLat, centerLon);
        allTileKeys.add(tk);
        if (!tiles.has(tk)) tiles.set(tk, []);

        // Simplify for storage only — length and center are computed from the
        // full geometry above so they stay exact.
        const shape = simplify(road.coordinates, SIMPLIFY_METERS);

        tiles.get(tk).push({
          id: stableId(key),
          name: road.name,
          type: road.surfaceClass === 'unknown' ? (road.type ?? 'unknown') : road.surfaceClass,
          coordinates: shape.map(c => [round6(c[0]), round6(c[1])]),
          lengthMiles: round6(lengthMiles),
          curvatureScore: curvature,
          totalScore: scoreFor(curvature),
          centerLat,
          centerLon,
        });
        dirty.add(tk);
        total++;
      }
    }
    flush();
    console.log(`${state}: ${total} roads so far`);
  }

  writeFileSync(resolve(OUT_DIR, 'tile_index.json'), JSON.stringify({
    version: 'roadcurvature',
    source: BASE,
    totalRoads: total,
    dedupedAway: skipped,
    tileCount: allTileKeys.size,
    totalBytes: bytes,
    tiles: [...allTileKeys].sort(),
  }, null, 2));

  console.log(`\nWrote ${allTileKeys.size} tiles, ${total} roads (${skipped} dupes), ${(bytes / 1024 / 1024).toFixed(1)} MB`);
}

main();
