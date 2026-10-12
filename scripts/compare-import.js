// CValRSketch — compare a LiDAR scan import with a laser-walked sketch.
// Copyright (C) 2026 CAA-EBV-CO-OP and the CValRSketch contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Runs the importer (lidar-import.mjs, the same readCvalrScan the desktop page
// calls) on a scan, takes the main floor's outline as the page would make it a
// shape, and lines it up with the main area of a CValRSketch sketch of the
// same house walked with a laser. Prints the walls side by side, the areas,
// and PASS when every wall is within the tolerance and the area within 1%.
//
//   jsc -m scripts/compare-import.js -- scan.cvalrscan.json truth-sketch.json [tolerance-inches]
//
// (jsc: /System/Library/Frameworks/JavaScriptCore.framework/Versions/A/Helpers/jsc;
// see scripts/README.md.)

import { readCvalrScan } from '../lidar-import.mjs';

// jsc's own: the arguments after --, readFile and print.
const args = [...arguments], read = readFile, say = print;
if (args.length < 2) { say('usage: jsc -m scripts/compare-import.js -- scan.cvalrscan.json truth-sketch.json [tolerance-inches]'); throw new Error('missing arguments'); }
const tolIn = args[2] != null ? +args[2] : 1;

const scan = JSON.parse(read(args[0]));
const truthSketch = JSON.parse(read(args[1]));

// The import: the main floor, largest if the scan has several pieces.
const res = readCvalrScan(scan);
if (!res.ok) { say('import failed: ' + res.message); throw new Error(res.reason); }
const mains = res.floors.filter(f => f.kind === 'floor' && f.floor === 'main');
const got = (mains.length ? mains : res.floors.filter(f => f.kind === 'floor')).sort((a, b) => b.traced - a.traced)[0];
// The truth: the sketch's largest living area on the main floor.
const truthShape = truthSketch.shapes.filter(s => s.floor === 'main' && (s.type || 'living') === 'living')
  .map(s => ({ s, a: Math.abs(area(open(s.points))) })).sort((p, q) => q.a - p.a)[0].s;

// Shapes repeat the first point at the end; the importer's outline doesn't.
function open(pts) {
  const p = pts.map(q => ({ x: q.x, y: q.y }));
  if (p.length > 1 && Math.hypot(p[0].x - p.at(-1).x, p[0].y - p.at(-1).y) < 1e-6) p.pop();
  return p;
}
function area(pts) {
  let a = 0;
  for (let i = 0; i < pts.length; i++) { const p = pts[i], q = pts[(i + 1) % pts.length]; a += p.x * q.y - q.x * p.y; }
  return a / 2;
}
// Walls as vectors, a straight run of several walls (three lefts) as one.
function walls(pts) {
  let v = pts.map((p, i) => { const q = pts[(i + 1) % pts.length]; return { x: q.x - p.x, y: q.y - p.y }; })
    .filter(w => Math.hypot(w.x, w.y) > 1e-4);
  for (let changed = true; changed && v.length > 3;) {
    changed = false;
    for (let i = 0; i < v.length; i++) {
      const a = v[i], b = v[(i + 1) % v.length];
      const cross = a.x * b.y - a.y * b.x, dot = a.x * b.x + a.y * b.y;
      if (dot > 0 && Math.abs(cross) / (Math.hypot(a.x, a.y) * Math.hypot(b.x, b.y)) < 1e-3) {
        v[i] = { x: a.x + b.x, y: a.y + b.y }; v.splice((i + 1) % v.length, 1); changed = true; break;
      }
    }
  }
  return v;
}

const truthPts = open(truthShape.points), gotPts = open(got.points);
const truthArea = Math.abs(area(truthPts)), gotArea = Math.abs(area(gotPts));
const T = walls(truthPts);

// The eight turns and mirrors of the import, each walked the way the truth is.
// Walls are matched in order, a run of up to three on either side standing for
// one on the other (a false jog, or a jog the import missed); the best
// match over every starting wall wins.
const turns = [];
for (const mirror of [false, true]) for (let q = 0; q < 4; q++) turns.push({ mirror, q });
const xf = ({ mirror, q }, p) => {
  let x = mirror ? -p.x : p.x, y = p.y;
  for (let k = 0; k < q; k++) [x, y] = [-y, x];
  return { x, y };
};
const JOIN_FT = 0.25;              // matching one wall with a run of several costs this per extra wall
function match(G) {
  const n = T.length, m = G.length;
  let best = null;
  for (let k = 0; k < m; k++) {
    const g = j => G[(k + j) % m];
    const D = Array.from({ length: n + 1 }, () => new Array(m + 1).fill(Infinity)), from = D.map(r => r.map(() => null));
    D[0][0] = 0;
    for (let i = 0; i <= n; i++) for (let j = 0; j <= m; j++) {
      if (D[i][j] === Infinity) continue;
      for (let a = 1; a <= 3 && i + a <= n; a++) for (let b = 1; b <= 3 && j + b <= m; b++) {
        if (a > 1 && b > 1) continue;
        let tx = 0, ty = 0, gx = 0, gy = 0;
        for (let t = 0; t < a; t++) { tx += T[i + t].x; ty += T[i + t].y; }
        for (let t = 0; t < b; t++) { gx += g(j + t).x; gy += g(j + t).y; }
        const c = D[i][j] + Math.hypot(tx - gx, ty - gy) + JOIN_FT * (a + b - 2);
        if (c < D[i + a][j + b]) { D[i + a][j + b] = c; from[i + a][j + b] = [a, b]; }
      }
    }
    if (D[n][m] < (best ? best.cost : Infinity)) {
      const rows = [];
      for (let i = n, j = m; i > 0;) { const [a, b] = from[i][j]; rows.unshift({ t: T.slice(i - a, i), g: Array.from({ length: b }, (_, t) => g(j - b + t)) }); i -= a; j -= b; }
      best = { cost: D[n][m], rows, start: k };
    }
  }
  return best;
}
let found = null;
for (const turn of turns) {
  let pts = gotPts.map(p => xf(turn, p));
  if (Math.sign(area(pts)) !== Math.sign(area(truthPts))) pts = pts.slice().reverse();
  const r = match(walls(pts));
  if (r && (!found || r.cost < found.cost)) found = { ...r, turn, reversed: Math.sign(area(gotPts.map(p => xf(turn, p)))) !== Math.sign(area(truthPts)) };
}

const fmt = ft => { const n = Math.round(Math.abs(ft) * 12); return `${Math.floor(n / 12)}'${n % 12}"`; };
const dir = v => Math.abs(v.x) >= Math.abs(v.y) ? (v.x > 0 ? 'r' : 'l') : (v.y > 0 ? 'd' : 'u');
const word = v => `${fmt(Math.hypot(v.x, v.y))} ${dir(v)}`;
const pad = (s, w) => (s + ' '.repeat(w)).slice(0, Math.max(w, s.length));
const lpad = (s, w) => (' '.repeat(w) + s).slice(-Math.max(w, s.length));

say(`Import: ${got.title}, ${gotPts.length} corners; laser truth: ${truthShape.label || 'main'}, ${truthPts.length} corners.`);
say(`Lined up turned ${found.turn.q * 90}°${found.turn.mirror ? ', mirrored' : ''}${found.reversed ? ', walked the other way' : ''}.`);
say('');
say(`${pad('#', 3)} ${pad('laser', 18)} ${pad('import', 30)} ${lpad('diff', 7)}`);
let worst = 0, jogs = 0;
found.rows.forEach((r, i) => {
  const tv = r.t.reduce((s, v) => ({ x: s.x + v.x, y: s.y + v.y }), { x: 0, y: 0 });
  const gv = r.g.reduce((s, v) => ({ x: s.x + v.x, y: s.y + v.y }), { x: 0, y: 0 });
  // The difference along the laser wall; a run's sideways step is a jog.
  const L = Math.hypot(tv.x, tv.y), ux = tv.x / L, uy = tv.y / L;
  const diffIn = ((gv.x * ux + gv.y * uy) - L) * 12;
  const extra = r.g.length > 1 ? '  false jog' : r.t.length > 1 ? '  jog missed' : '';
  if (r.g.length !== r.t.length) jogs++;
  worst = Math.max(worst, Math.abs(diffIn));
  say(`${pad(String(i + 1), 3)} ${pad(r.t.map(word).join(' + '), 18)} ${pad(r.g.map(word).join(' + '), 30)} ${lpad((diffIn >= 0 ? '+' : '−') + Math.abs(diffIn).toFixed(1) + '″', 7)}${extra}`);
});
const areaPct = (gotArea / truthArea - 1) * 100;
say('');
say(`Area: laser ${truthArea.toFixed(1)} sf, import ${gotArea.toFixed(1)} sf (${areaPct >= 0 ? '+' : '−'}${Math.abs(areaPct).toFixed(2)}%).`);
say(`Worst wall: ${worst.toFixed(1)}″${jogs ? `; ${jogs} wall${jogs > 1 ? 's' : ''} with a jog one side has and the other doesn't` : ''}.`);
const pass = worst <= tolIn && !jogs && Math.abs(areaPct) <= 1;
say(pass ? `PASS (every wall within ${tolIn}″, area within 1%)` : `FAIL (tolerance ${tolIn}″ per wall, 1% area)`);
