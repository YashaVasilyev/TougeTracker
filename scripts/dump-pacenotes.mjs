#!/usr/bin/env node
/**
 * Dumps golden-test fixtures for the Swift PacenoteGenerator port.
 *
 * Runs Tougefinder's JS algorithm (src/services/pacenotes.js) on a spread of
 * real roads from public/data/touges_db.json plus synthetic shapes (hairpin,
 * square, sweep, zigzag, circle, esses) and writes a single JSON fixture file
 * consumed by PacenoteGoldenTests.
 *
 * WARNING: this REPLACES the fixture set wholesale. It picks roads from
 * Tougefinder's live database, which has changed since the current fixtures
 * were generated, so running it today swaps every road in the suite for a
 * different set and breaks the tests that name them.
 *
 * To refresh expectations for the roads already in the suite, use
 * `scripts/dumpgoldens` instead — it leaves the corpus alone.
 *
 * Usage:  node scripts/dump-pacanotes.mjs --replace-corpus
 * Requires: a sibling ../Tougefinder checkout with node_modules installed.
 */
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { fileURLToPath, pathToFileURL } from "node:url";
import { dirname, join } from "node:path";

if (!process.argv.includes("--replace-corpus")) {
  console.error("Refusing to run: this replaces the whole fixture corpus.\n" +
    "To refresh expectations without changing which roads are tested, run:\n" +
    "  scripts/dumpgoldens\n" +
    "Pass --replace-corpus if you really mean to build a new corpus.");
  process.exit(2);
}

const here = dirname(fileURLToPath(import.meta.url));
const tougefinderRoot = join(here, "..", "..", "Tougefinder");
const outDir = join(here, "..", "TougeTrackerTests", "Fixtures");

const { generatePacenotes } = await import(
  pathToFileURL(join(tougefinderRoot, "src", "services", "pacenotes.js")).href
);

const R = 6371008.8;
const deg2rad = (d) => (d * Math.PI) / 180;

function dest(lat, lon, distM, bearingDeg) {
  const lat1 = deg2rad(lat), lon1 = deg2rad(lon), th = deg2rad(bearingDeg), d = distM / R;
  const lat2 = Math.asin(Math.sin(lat1) * Math.cos(d) + Math.cos(lat1) * Math.sin(d) * Math.cos(th));
  const lon2 = lon1 + Math.atan2(Math.sin(th) * Math.sin(d) * Math.cos(lat1),
                                 Math.cos(d) - Math.sin(lat1) * Math.sin(lat2));
  return [lon2 * 180 / Math.PI, lat2 * 180 / Math.PI];
}
function walk(start, steps) {
  const pts = [start];
  let cur = start;
  for (const [dist, bearing] of steps) { cur = dest(cur[1], cur[0], dist, bearing); pts.push(cur); }
  return pts;
}
const ORIGIN = [-121.65, 37.35];
const circle = (radius, steps, startBearing = 0) => {
  const len = 2 * Math.PI * radius;
  const seg = len / steps;
  const a = (360 / steps);
  const s = [];
  for (let i = 0; i < steps; i++) s.push([seg, startBearing + a * i]);
  return s;
};
const arcSteps = (totalAngleDeg, radius, stepM, startBearing = 0) => {
  const len = (totalAngleDeg / 360) * 2 * Math.PI * radius;
  const n = Math.max(2, Math.round(len / stepM));
  const seg = len / n, a = totalAngleDeg / n;
  const s = [];
  for (let i = 0; i < n; i++) s.push([seg, startBearing + a * (i + 0.5)]);
  return s;
};
const straight = (len, bearing, seg = 10) => {
  const s = [];
  for (let d = 0; d < len; d += seg) s.push([seg, bearing]);
  return s;
};

const shapes = {
  syn_straight:       walk(ORIGIN, straight(1000, 45)),
  syn_too_short:      walk(ORIGIN, straight(280, 45)),
  syn_circle_r25:     walk(ORIGIN, circle(25, 32)),
  syn_circle_r100:    walk(ORIGIN, circle(100, 40)),
  syn_hairpin:        walk(ORIGIN, [...straight(300, 20), ...arcSteps(178, 12, 3, 20), ...straight(300, 200)]),
  syn_square_r8:      walk(ORIGIN, [...straight(400, 20), ...arcSteps(90, 8, 3, 20), ...straight(400, 110)]),
  syn_sweeper_r60_long: walk(ORIGIN, [...straight(200, 0), ...arcSteps(100, 60, 5, 0), ...straight(200, 100)]),
  syn_zigzag_sharp:   walk(ORIGIN, Array.from({length:30}, (_,i)=> i%2===0 ? [12,60] : [12,0])),
  syn_squiggle_gentle: walk(ORIGIN, Array.from({length:40}, (_,i)=> i%2===0 ? [15,12] : [15,0])),
  synesses:           walk(ORIGIN, [...arcSteps(120, 60, 3, 30), ...arcSteps(120, 60, 3, -30)]),
};
const syntheticKeys = Object.keys(shapes);

// Load roads from the DB.
const db = JSON.parse(readFileSync(join(tougefinderRoot, "public", "data", "touges_db.json"), "utf8"));
const roads = Array.isArray(db.roads) ? db.roads.filter(r => Array.isArray(r.coordinates) && r.coordinates.length >= 20) : [];

// Run the generator over a sample of roads to pick ones with interesting pacenotes.
const sampleSize = Math.min(600, roads.length);
const candidates = [];
for (let i = 0; i < sampleSize; i++) {
  const idx = (i * 7 + 13) % roads.length;          // deterministic spread
  const r = roads[idx];
  if (!r || candidates.includes(r.id)) continue;
  candidates.push(r);
  const res = generatePacenotes(r.coordinates, { returnObject: true });
  const txt = res.turns.map(t => t.text).join(" ");
  const flags = {
    HP: txt.includes("HP"), Square: txt.includes("Square"),
    into: txt.includes("into"), and: txt.includes("and"),
    long: txt.includes("long"),
  };
  r._flags = flags;
}
const byCurv = [...candidates].sort((a, b) => (b.curvatureScore ?? 0) - (a.curvatureScore ?? 0));

const pick = (pred) => candidates.find(pred);
const picks = [];
const wanted = [
  ["db0",            byCurv[0]],
  ["db1",            byCurv[1]],
  ["db2",            byCurv[2]],
  ["db3",            byCurv[3]],
  ["db_long",        pick(r => r._flags.long && r.coordinates.length > 300)],
  ["db_square",      pick(r => r._flags.Square)],
  ["db_into",        pick(r => r._flags.into)],
  ["db_and",         pick(r => r._flags.and)],
  ["db_low_score",   [...candidates].sort((a,b)=>(a.curvatureScore??0)-(b.curvatureScore??0))[0]],
];
for (const [name, r] of wanted) {
  if (!r) continue;
  const slug = (r.name || "unnamed").replace(/[^a-z0-9]+/gi, "_").slice(0, 30);
  picks.push({ file: `db_${name}_${r.id}_${slug}`, coordinates: r.coordinates });
}
const top = byCurv[0];
if (top) {
  picks.push({ file: "db_top_reverse", coordinates: top.coordinates, reverse: true });
  picks.push({ file: "db_top_descriptive", coordinates: top.coordinates, format: "descriptive" });
}

const cases = [...picks];
for (const key of syntheticKeys) cases.push({ file: key, coordinates: shapes[key] });

const fixtures = cases.map(c => {
  const res = generatePacenotes(c.coordinates, {
    reverse: !!c.reverse, format: c.format || "rally", returnObject: true,
  });
  return { name: c.file, reverse: !!c.reverse, format: c.format || "rally",
           totalLength: Number((res.turns.reduce((s,t)=>s+t.length,0))),
           coordinates: c.coordinates,
           expectedText: res.text,
           expectedTurns: res.turns.map(t => ({ text: t.text, coordinate: t.coordinate })) };
});

mkdirSync(outDir, { recursive: true });
writeFileSync(join(outDir, "pacenote_fixtures.json"), JSON.stringify(fixtures));
console.log(`Wrote ${fixtures.length} fixtures to ${outDir}/pacenote_fixtures.json`);
const hp = fixtures.filter(x => x.expectedTurns.some(t => t.text.includes("HP"))).length;
const sq = fixtures.filter(x => x.expectedTurns.some(t => t.text.includes("Square"))).length;
console.log(`  HP-containing: ${hp}, Square-containing: ${sq}, into-connectors: ${fixtures.filter(x=>x.expectedText.includes("into")).length}`);
