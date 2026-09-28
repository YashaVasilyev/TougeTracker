/// Splits Tougefinder's touges_db.json into 0.25°-grid tile files for
/// bundling in the iOS app. Each tile contains roads whose centerLat/centerLon
/// falls within that grid cell. Unnecessary fields (tags, etc.) are stripped
/// and coordinates are rounded to 6 decimal places (~0.1m precision) to reduce
/// bundle size while maintaining map fidelity.

import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));

const INPUT = resolve(__dirname, '../../Tougefinder/public/data/touges_db.json');
const OUT_DIR = resolve(__dirname, '../TougeTracker/Resources/tiles');

// Fields kept in the condensed tile output (everything else is stripped —
// tags, CIV, maxIntensity, etc. are not used by the iOS map view)
const KEEP_FIELDS = [
  'id', 'name', 'type', 'coordinates',
  'lengthMiles',
  'curvatureScore', 'flowScore', 'totalScore',
  'centerLat', 'centerLon',
];

const TILE_SIZE = 0.25;

function tileKey(lat, lon) {
  return `t_${Math.floor(lat / TILE_SIZE)}_${Math.floor(lon / TILE_SIZE)}`;
}

function roundCoords(coords) {
  return coords.map(c => [Math.round(c[0] * 1e6) / 1e6, Math.round(c[1] * 1e6) / 1e6]);
}

function main() {
  if (!existsSync(INPUT)) {
    console.error(`Input DB not found at ${INPUT}`);
    process.exit(1);
  }

  console.log('Loading DB...');
  const db = JSON.parse(readFileSync(INPUT, 'utf8'));
  const roads = db.roads || [];
  console.log(`Loaded ${roads.length} roads`);

  if (!existsSync(OUT_DIR)) {
    mkdirSync(OUT_DIR, { recursive: true });
  }

  const tiles = new Map();
  let tileCount = 0;

  for (const road of roads) {
    const lat = road.centerLat ?? 0;
    const lon = road.centerLon ?? 0;
    const key = tileKey(lat, lon);

    if (!tiles.has(key)) {
      tiles.set(key, []);
      tileCount++;
    }

    const condensed = {};
    for (const field of KEEP_FIELDS) {
      if (road[field] !== undefined) {
        if (field === 'coordinates') {
          condensed[field] = roundCoords(road[field]);
        } else if (field === 'lengthMiles' && typeof road[field] === 'string') {
          condensed[field] = parseFloat(road[field]);
        } else {
          condensed[field] = road[field];
        }
      }
    }
    tiles.get(key).push(condensed);
  }

  // Write tile files (compact JSON, no whitespace)
  let totalBytes = 0;
  const index = [];
  for (const [key, tileRoads] of tiles) {
    const content = JSON.stringify(tileRoads);
    writeFileSync(resolve(OUT_DIR, `${key}.json`), content);
    totalBytes += content.length;
    index.push(key);
  }

  // Write tile index manifest
  writeFileSync(resolve(OUT_DIR, 'tile_index.json'), JSON.stringify({
    version: db.version || 'unknown',
    totalRoads: roads.length,
    tileCount,
    totalBytes,
    tiles: index.sort(),
  }, null, 2));

  console.log(`Wrote ${tileCount} tile files (${(totalBytes / 1024 / 1024).toFixed(1)} MB total)`);
}

main();
