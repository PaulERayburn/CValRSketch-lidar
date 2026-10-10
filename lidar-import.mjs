// CValRSketch — LiDAR scan import.
// Copyright (C) 2026 CAA-EBV-CO-OP and the CValRSketch contributors.
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Reads a CValRScan plan (`cvalrscan` JSON, ios/CValRScan/README.md) and returns
// the same result readFloorPlanPdf does, so the PDF import window and merge code
// take it unchanged. Runs in the browser; the scan never leaves the machine.
//
// A scan is taken inside, so its floor outline runs along the interior faces of
// the outside walls. Per floor the outline is squared to the house, walls the scan
// missed (closet backs) are moved out to where the app placed them, and each side
// is pushed out by that wall's thickness: measured where the outside walk marked
// the siding beside it, otherwise the default. GLA is figured from the result.
//
// The outside walk is first lined up with the scan (tracking can re-settle
// between the two, leaving the walk turned or shifted). Floor the scan carried
// outdoors through an edge with no wall (an open porch seen through a glass
// entry) is cut back to where the walk shows the house ends; floor it never
// reached inside the walk (a closet behind a door left shut) is added out to
// the walk; and the floor the walk went around is the main floor.

const FT = 3.28084;
const SQUARE_DEG = 8;             // sides within this of the house's main directions are squared
const MERGE_FT = 0.25;            // neighbouring squared sides closer than this are one side
const MIN_SIDE_FT = 0.15;         // shorter sides are noise in the outline
const WALK_SPLIT_IN = 6;          // outside-walk points further than this off one line turned a corner
const THICKNESS_RANGE_IN = [2, 16];
const WALK_TILT_FIX_DEG = 1.5;    // an outside walk turned more than this from the scan is turned back
const CELL_FT = 0.1;              // grid for finding floor that lies outside the outside walk
const MIN_CUT_SF = 4;             // smaller pieces outside the walk are noise
export const DEFAULT_EXTERIOR_IN = 6;

// The floor the outside walk was taken beside is the main floor; floors are
// named from it. Set per scan by readCvalrScan.
let mainStory = 0;

export function readCvalrScan(d, opts = {}) {
  if (!d || d.format !== 'cvalrscan') {
    return { ok: false, reason: 'unknown-format', message: 'This is not a CValRScan plan (cvalrscan JSON).' };
  }
  if ((d.version || 0) > 7) {
    return { ok: false, reason: 'newer-version', message: `This scan is format version ${d.version}; this CValRSketch reads up to version 7. Update the app.` };
  }
  const defaultIn = opts.exteriorInches ?? DEFAULT_EXTERIOR_IN;
  const turn = houseAngle(d.walls || []);
  const plan = ([x, y]) => rotate({ x: x * FT, y: y * FT }, turn);
  const warnings = [];
  if (d.app) warnings.push(`Scanned with ${d.app}, scan format ${d.version}.`);

  const walk = outsideWalk(d.exterior, plan);
  mainStory = walkStory(d) ?? 0;
  // An outside walk can sit turned or shifted from the scan (tracking that
  // re-settled between the two). Line it up with the walk's floor first.
  const mainSides = (d.floors || []).filter(f => f.story === mainStory && (f.polygon || []).length >= 3)
    .flatMap(f => { const ss = squareSides(f.polygon.map(plan)), out = outwardSign(outline(ss)); return ss.map(s => ({ ...s, out })); });
  if (walk.lines.length >= 3) {
    const fit = registerWalk(walk, mainSides);
    if (fit) {
      walk.lines = fit.lines;
      warnings.push(`The outside walk sat ${Math.abs(fit.tiltDeg).toFixed(1)}° turned and ${Math.hypot(fit.dx, fit.dy).toFixed(1)} ft off from the scan; it was lined up with the scanned walls.`);
    }
  }
  if (walk.split) warnings.push(`${walk.split} outside-walk wall${walk.split > 1 ? 's' : ''} turned a corner without Next wall; split at the corner.`);
  if (walk.driftIn != null && walk.driftIn > 6) warnings.push(`The outside walk drifted ${walk.driftIn.toFixed(1)}″; its wall thicknesses are less certain.`);

  const hidden = hiddenWalls(d, plan, turn);
  const floors = [];
  const stories = [...new Set((d.floors || []).map(f => f.story))].sort((a, b) => a - b);
  for (const story of stories) {
    for (const f of d.floors.filter(f => f.story === story)) {
      if (!f.polygon || f.polygon.length < 3) continue;
      let poly = f.polygon.map(plan);
      let gaps = (d.gaps || []).filter(g => g.story === story).map(g => ({ a: plan(g.a), b: plan(g.b) }));
      // Floor the scan carried out through an edge with no wall (a porch seen
      // through a glass door) that the outside walk shows is outdoors.
      if (story === mainStory && walk.lines.length >= 3) {
        const cut = cutOutside(poly, d, story, plan, walk.lines, walkThickness(walk.lines, mainSides) ?? DEFAULT_EXTERIOR_IN / 12);
        if (cut) {
          poly = cut.poly;
          gaps = gaps.filter(g => onOutline(poly, { x: (g.a.x + g.b.x) / 2, y: (g.a.y + g.b.y) / 2 }, 0.4));
          if (cut.sf >= MIN_CUT_SF) warnings.push(`${floorTitle(story)}: ${Math.round(cut.sf)} sf of scanned floor lies outside the outside walk (an open porch or entry seen through glass?) and was left out. Check it.`);
          if (cut.grownSf >= MIN_CUT_SF) warnings.push(`${floorTitle(story)}: ${Math.round(cut.grownSf)} sf inside the outside walk that the scan didn't reach (a closet, chase or alcove behind a wall it missed) was added, out to the walk. Check it.`);
        }
      }
      // Walls the user drew or moved can close in floor the scan never reached
      // (a closet behind a shut door). Unless turned off for the scan.
      if (d.wallsShapeFloor !== false) {
        const grown = growToWalls(poly, d, story, plan);
        if (grown) {
          poly = grown.poly;
          gaps = gaps.filter(g => onOutline(poly, { x: (g.a.x + g.b.x) / 2, y: (g.a.y + g.b.y) / 2 }, 0.4));
          warnings.push(`${floorTitle(story)}: ${Math.round(grown.sf)} sf the scan didn't reach, closed in by walls drawn or moved in CValRScan, was added. Check it.`);
        }
      }
      let sides = squareSides(poly);
      const filled = fillHidden(sides, gaps, hidden.filter(h => h.story === story));
      const open = gaps.length - filled;
      if (open > 0) warnings.push(`${floorTitle(story)}: ${open} missing wall${open > 1 ? 's' : ''} in the scan (closet backs?) kept where the scan's floor stopped; check ${open > 1 ? 'them' : 'it'}.`);
      const inside = outline(sides);
      const thick = thicknesses(sides, walk.lines, defaultIn);
      const measured = thick.filter(t => t.measured);
      const scanned = sides.map((s, i) => offsetSide(s, outwardSign(inside), thick[i].inches / 12));
      const fit = applyReadings(d, story, plan, scanned, warnings);
      const outer = tidy(outline(fit.sides));
      // The outline's edges that are calculated walls: an edge through the
      // midpoint of a calculated wall, along it.
      const calcWalls = [];
      fit.walls.filter(w => w.kind === 'calculated').forEach(w => {
        outer.forEach((a, i) => {
          const b = outer[(i + 1) % outer.length], L = Math.hypot(b.x - a.x, b.y - a.y);
          if (L < 0.1) return;
          const t = ((w.at.x - a.x) * (b.x - a.x) + (w.at.y - a.y) * (b.y - a.y)) / (L * L);
          const off = Math.abs((w.at.x - a.x) * (b.y - a.y) - (w.at.y - a.y) * (b.x - a.x)) / L;
          if (t > 0.05 && t < 0.95 && off < 0.1 && !calcWalls.includes(i)) calcWalls.push(i);
        });
      });
      if (measured.length) {
        const list = [...new Set(measured.map(t => Math.round(t.inches)))].sort((a, b) => a - b).join('″, ') + '″';
        warnings.push(`${floorTitle(story)}: wall thickness measured on ${measured.length} of ${sides.length} sides from the outside walk (${list}); the rest use ${defaultIn}″.`);
      } else {
        warnings.push(`${floorTitle(story)}: no outside walk beside the walls; every wall is taken as ${defaultIn}″ thick. Check against a tape measurement.`);
      }
      checkSpans(d, story, plan, inside, outer, warnings);
      const [floor, type] = classifyStory(story, stories);
      floors.push({
        page: story + 1, building: null, kind: 'floor', floor, type,
        title: floorTitle(story) + (d.floors.filter(g => g.story === story).length > 1 ? ` (${floors.filter(g => g.page === story + 1).length + 1})` : ''),
        points: outer, traced: Math.abs(signedArea(outer)),
        interior: Math.abs(signedArea(inside)), interiorPoints: tidy(inside),
        sides: thick.map(t => ({ inches: +t.inches.toFixed(1), measured: t.measured })),
        scanTraced: Math.abs(signedArea(tidy(outline(scanned)))), walls: fit.walls, calcWalls,
        detail: interiorDetail(d, story, plan, scanned, fit.sides),
        areas: {}, stated: null, excludedTraced: null, placement: 'reference', turned: 0,
      });
    }
  }
  if (!floors.length) return { ok: false, reason: 'no-floors', message: 'The scan has no floor outline to import.', warnings };
  if (!(d.measurements || []).length && !(d.spans || []).length) warnings.push('No laser readings in the scan, so nothing checks its overall size. Enter one in CValRScan (Measure walls).');
  // Where the plan came from goes in the page subtitle, not on the areas.
  const readings = (d.measurements || []).length + (d.spans || []).length;
  const subtitle = 'Measured by LiDAR scan' + (readings ? `, fitted to ${readings} laser reading${readings > 1 ? 's' : ''}` : '');
  return { ok: true, format: 'CValRScan', profileId: 'cvalrscan', address: '', subtitle, floors, warnings, buildings: [] };
}

// ---------------------------------------------------------------------------
// Laser readings: the outline is fitted to them. On a squared outline every
// side is a constant x or y, and a side's length is the gap between its two
// neighbours, so an outside reading fixes the gap between two parallel sides.
// Least squares over all readings, held loosely to the scan, then: sides a
// reading set are "measured", the rest "calculated" (they are whatever closes
// the house), each calculated side checked against the scan.
// ---------------------------------------------------------------------------
const SCAN_WEIGHT = 0.01;          // a reading outweighs the scan 100 to 1
const FLAG_IN = 2;                 // readings that can't both hold
const CALC_FLAG_IN = 6;            // calculated side this far from the scan

function applyReadings(d, story, plan, sides, warnings) {
  const n = sides.length;
  const lengthOf = (ss, i) => {
    const p = ss[(i + n - 1) % n], q = ss[(i + 1) % n];
    return ss[i].kind === 'free' || p.kind === 'free' || q.kind === 'free' ? null : Math.abs(q.c - p.c);
  };
  // Corners: where side i meets side i+1.
  const corner = i => {
    const s = sides[i], t = sides[(i + 1) % n];
    if (s.kind === 'h' && t.kind === 'v') return { x: t.c, y: s.c };
    if (s.kind === 'v' && t.kind === 'h') return { x: s.c, y: t.c };
    return null;
  };
  const corners = sides.map((_, i) => corner(i));
  const nearestCorner = p => {
    let best = -1, bd = Infinity;
    corners.forEach((c, i) => { if (c) { const dd = Math.hypot(c.x - p.x, c.y - p.y); if (dd < bd) { bd = dd; best = i; } } });
    return bd < 3 ? best : -1;
  };
  // Constraints c[j] - c[i] = sign * L, keeping the order the scan has.
  const cons = [];
  const add = (i, j, inches, label) => {
    if (i < 0 || j < 0 || i === j || sides[i].kind !== sides[j].kind || sides[i].kind === 'free') return false;
    const sign = Math.sign(sides[j].c - sides[i].c) || 1;
    cons.push({ i, j, L: sign * inches / 12, label, inches });
    return true;
  };
  const fmt = inches => { const v = Math.round(inches); return `${Math.floor(v / 12)}′ ${v % 12}″`; };
  let skipped = 0;
  for (const sp of (d.spans || []).filter(s => s.story === story)) {
    if (sp.face !== 'outside') { skipped++; continue; }
    const ka = nearestCorner(plan(sp.a)), kb = nearestCorner(plan(sp.b));
    if (ka < 0 || kb < 0) { skipped++; continue; }
    const pa = corners[ka], pb = corners[kb];
    const horizontal = Math.abs(pb.x - pa.x) >= Math.abs(pb.y - pa.y);
    const sideAt = k => [k, (k + 1) % n].find(i => sides[i].kind === (horizontal ? 'v' : 'h'));
    if (!add(sideAt(ka), sideAt(kb), sp.inches, `${fmt(sp.inches)} corner to corner`)) skipped++;
  }
  const walls = new Map((d.walls || []).map(w => [w.id, w]));
  for (const m of d.measurements || []) {
    const w = walls.get(m.wall);
    if (!w || w.story !== story) continue;
    if (m.face !== 'outside') { skipped++; continue; }
    const a = plan(w.a), b = plan(w.b);
    const horizontal = Math.abs(b.x - a.x) >= Math.abs(b.y - a.y);
    const along = horizontal ? (a.x + b.x) / 2 : (a.y + b.y) / 2, at = horizontal ? (a.y + b.y) / 2 : (a.x + b.x) / 2;
    // The outer side parallel to the wall, a wall thickness out, beside it.
    let best = -1, bd = 2;
    sides.forEach((s, i) => {
      if (s.kind !== (horizontal ? 'h' : 'v')) return;
      const lo = Math.min(s.a[horizontal ? 'x' : 'y'], s.b[horizontal ? 'x' : 'y']) - 1;
      const hi = Math.max(s.a[horizontal ? 'x' : 'y'], s.b[horizontal ? 'x' : 'y']) + 1;
      const dd = Math.abs(s.c - at);
      if (along > lo && along < hi && dd < bd) { bd = dd; best = i; }
    });
    if (best < 0 || !add((best + n - 1) % n, (best + 1) % n, m.inches, `${fmt(m.inches)} wall`)) skipped++;
  }
  if (!cons.length) return { sides, walls: [] };

  // Normal equations, one unknown per squared side.
  const idx = [], col = new Map();
  sides.forEach((s, i) => { if (s.kind !== 'free') { col.set(i, idx.length); idx.push(i); } });
  const m = idx.length, A = Array.from({ length: m }, () => new Float64Array(m)), r = new Float64Array(m);
  idx.forEach((i, k) => { A[k][k] += SCAN_WEIGHT; r[k] += SCAN_WEIGHT * sides[i].c; });
  for (const c of cons) {
    const p = col.get(c.i), q = col.get(c.j);
    A[p][p] += 1; A[q][q] += 1; A[p][q] -= 1; A[q][p] -= 1;
    r[q] += c.L; r[p] -= c.L;
  }
  for (let k = 0; k < m; k++) {                      // Gauss-Jordan; A is positive definite
    let piv = k;
    for (let t = k + 1; t < m; t++) if (Math.abs(A[t][k]) > Math.abs(A[piv][k])) piv = t;
    [A[k], A[piv]] = [A[piv], A[k]]; [r[k], r[piv]] = [r[piv], r[k]];
    for (let t = 0; t < m; t++) {
      if (t === k) continue;
      const f = A[t][k] / A[k][k];
      if (!f) continue;
      for (let u = k; u < m; u++) A[t][u] -= f * A[k][u];
      r[t] -= f * r[k];
    }
  }
  const fitted = sides.map((s, i) => col.has(i) ? { ...s, c: r[col.get(i)] / A[col.get(i)][col.get(i)] } : s);
  // A jog under an inch left between two sides on (nearly) one line is scan
  // noise, not a wall: line the two sides up, weighted by length.
  for (let i = 0; i < n; i++) {
    const p = fitted[(i + n - 1) % n], q = fitted[(i + 1) % n], s = fitted[i];
    if (s.kind === 'free' || p.kind === 'free' || p.kind !== q.kind) continue;
    if (Math.abs(q.c - p.c) >= 1 / 12) continue;
    const lp = lengthOf(fitted, (i + n - 1) % n) || 0, lq = lengthOf(fitted, (i + 1) % n) || 0;
    const c = (p.c * lp + q.c * lq) / ((lp + lq) || 1);
    p.c = c; q.c = c;
  }

  // Readings that couldn't both be met.
  for (const c of cons) {
    const got = (fitted[c.j].c - fitted[c.i].c) * Math.sign(c.L) * 12;
    if (Math.abs(got - c.inches) > FLAG_IN) warnings.push(`${floorTitle(story)}: reading ${c.label} fits as ${fmt(got)}; another reading disagrees with it by ${Math.round(Math.abs(got - c.inches))}″. Check both.`);
  }
  // Which walls a reading fixed, and which close the house. A wall is a run
  // of sides on one line (a jog the fit closed to nothing joins two sides);
  // it is measured when a reading spans exactly its two end neighbours.
  const len = i => lengthOf(fitted, i);
  const seen = new Set(), out = [];
  let calc = 0;
  for (let i = 0; i < n; i++) {
    if (seen.has(i) || len(i) == null || len(i) < 0.05) continue;
    const run = [i];
    let k = i;
    while (len((k + 1) % n) != null && len((k + 1) % n) < 0.05 && (k + 2) % n !== i && fitted[(k + 2) % n].kind === fitted[i].kind) {
      run.push((k + 2) % n); k = (k + 2) % n;
    }
    run.forEach(r => seen.add(r));
    const p = (run[0] + n - 1) % n, q = (run[run.length - 1] + 1) % n;
    const measured = cons.some(c => (c.i === p && c.j === q) || (c.i === q && c.j === p));
    const after = Math.abs(fitted[q].c - fitted[p].c), before = Math.abs(sides[q].c - sides[p].c);
    const line = fitted[run[0]], mid = (fitted[p].c + fitted[q].c) / 2;
    const at = line.kind === 'v' ? { x: line.c, y: mid } : { x: mid, y: line.c };
    out.push({ sides: run, kind: measured ? 'measured' : 'calculated', inches: Math.round(after * 12), scanInches: Math.round(before * 12), at });
    if (!measured) {
      calc++;
      const diff = Math.round((after - before) * 12);
      if (Math.abs(diff) > CALC_FLAG_IN) warnings.push(`${floorTitle(story)}: a wall no reading covers works out at ${fmt(after * 12)} to close the house; the scan has ${fmt(before * 12)} (${diff > 0 ? '+' : '−'}${Math.abs(diff)}″). Check it.`);
    }
  }
  warnings.push(`${floorTitle(story)}: fitted to ${cons.length} laser reading${cons.length > 1 ? 's' : ''}${skipped ? ` (${skipped} not used: inside, or not at an outside corner)` : ''}; ${calc} wall${calc === 1 ? '' : 's'} calculated to close the house (${out.filter(w => w.kind === 'calculated').map(w => fmt(w.inches)).join(', ') || 'none'}).`);
  return { sides: fitted, walls: out };
}

// Corner-to-corner readings against the imported outline: an outside reading
// is compared with the outer corners beside its two scanned corners, an inside
// one with the inside outline, along the house's main direction.
function checkSpans(d, story, plan, inside, outer, warnings) {
  const fmt = inches => { const n = Math.round(inches); return `${Math.floor(n / 12)}′ ${n % 12}″`; };
  for (const sp of (d.spans || []).filter(s => s.story === story)) {
    const pts = sp.face === 'outside' ? outer : inside;
    const near = p => pts.reduce((best, q) => Math.hypot(q.x - p.x, q.y - p.y) < Math.hypot(best.x - p.x, best.y - p.y) ? q : best, pts[0]);
    const a = near(plan(sp.a)), b = near(plan(sp.b));
    const got = Math.max(Math.abs(b.x - a.x), Math.abs(b.y - a.y)) * 12;
    const diff = Math.round(got - sp.inches);
    warnings.push(`${floorTitle(story)}: ${sp.face} reading ${fmt(sp.inches)}${sp.entered && /[+\-−]/.test(sp.entered) ? ` (${sp.entered})` : ''} between two corners; the import measures ${fmt(got)} there (${diff === 0 ? 'matches' : (diff > 0 ? '+' : '−') + Math.abs(diff) + '″'}).`);
  }
}

// The interior from the scan, for a detailed plan: walls (their inside
// faces, so outside walls show their thickness), doors, windows, openings and
// room names. Moved with the outline's fit: along each axis, a point between
// two outer sides keeps its share of the gap between them.
const ROOM_NAMES = { livingRoom: 'Living', diningRoom: 'Dining', bedroom: 'Bedroom', bathroom: 'Bath',
  kitchen: 'Kitchen', laundryRoom: 'Laundry', garage: 'Garage', office: 'Office', hallway: 'Hall' };
function interiorDetail(d, story, plan, before, after) {
  const axis = kind => {
    const pairs = before.map((s, i) => s.kind === kind ? [s.c, after[i].c] : null).filter(Boolean)
      .sort((p, q) => p[0] - q[0]).filter((p, i, a) => i === 0 || p[0] - a[i - 1][0] > 1e-6);
    return v => {
      if (!pairs.length) return v;
      if (v <= pairs[0][0]) return v + pairs[0][1] - pairs[0][0];
      for (let i = 1; i < pairs.length; i++) {
        const [a0, a1] = pairs[i - 1], [b0, b1] = pairs[i];
        if (v <= b0) return a1 + (v - a0) * (b1 - a1) / (b0 - a0);
      }
      const last = pairs[pairs.length - 1];
      return v + last[1] - last[0];
    };
  };
  const mx = axis('v'), my = axis('h');
  const map = w => { const p = plan(w); return { x: +mx(p.x).toFixed(3), y: +my(p.y).toFixed(3) }; };
  const lines = [];
  for (const [list, kind] of [[d.walls, 'wall'], [d.doors, 'door'], [d.windows, 'window'], [d.openings, 'opening']]) {
    for (const s of (list || []).filter(s => s.story === story)) lines.push({ a: map(s.a), b: map(s.b), kind: s.type === 'entrance' ? 'entrance' : kind,
                                                                   ...(s.hinge ? { hinge: s.hinge, side: s.side || 1, style: doorStyle(s) } : {}) });
  }
  // Room names as the user left them (format 7), else the scan's own.
  const rooms = d.rooms
    ? d.rooms.filter(r => r.story === story && r.name).map(r => ({ ...map(r.center), name: r.name }))
    : (d.sections || []).filter(s => s.story === story && ROOM_NAMES[s.label])
        .map(s => ({ ...map(s.center), name: ROOM_NAMES[s.label] }));
  // Stairs as CValRScan drew them for each floor (format 7, 0.16+): pieces
  // with treads, and walking lines with UP or DN at their start.
  const stairs = {
    pieces: (d.stairs || []).filter(p => p.story === story && p.outline)
      .map(p => ({ outline: p.outline.map(map), treads: (p.treads || []).map(t => [map(t[0]), map(t[1])]) })),
    paths: (d.stairPaths || []).filter(p => p.story === story).map(p => ({ points: p.path.map(map), label: p.label })),
  };
  return { lines, rooms, stairs };
}

// A scanned door over 6 ft wide is a garage door, and one 4 to 6 ft a pair
// (closet or French doors), whatever older scans say.
function doorStyle(s) {
  if (s.style && s.style !== 'swing') return s.style;
  if (s.type) return 'swing';
  const m = Math.hypot(s.b[0] - s.a[0], s.b[1] - s.a[1]);
  return m > 1.83 ? 'overhead' : m >= 1.2 ? 'double' : 'swing';
}

// RoomPlan counts floors from where scanning began (0); appraisal plans name them.
function floorTitle(story) {
  story -= mainStory;
  const above = ['First floor', 'Second floor', 'Third floor', 'Fourth floor'];
  if (story >= 0) return above[story] || `Floor ${story + 1}`;
  return story === -1 ? 'Basement' : `Lower level ${-story}`;
}

// RoomPlan numbers floors from where scanning began; the lowest of several is a
// basement only when the user says so, so the start floor is main.
function classifyStory(story, stories) {
  story -= mainStory;
  if (story === 0 || stories.length === 1) return ['main', 'living'];
  return story > 0 ? ['upper', 'upper'] : ['basement', 'finished'];
}

// ---------------------------------------------------------------------------
// Geometry helpers (feet, y down)
// ---------------------------------------------------------------------------
function rotate(p, a) {
  const c = Math.cos(a), s = Math.sin(a);
  return { x: p.x * c - p.y * s, y: p.x * s + p.y * c };
}

function signedArea(pts) {
  let a = 0;
  for (let i = 0; i < pts.length; i++) {
    const p = pts[i], q = pts[(i + 1) % pts.length];
    a += p.x * q.y - q.x * p.y;
  }
  return a / 2;
}

// Length-weighted mean of 4×angle: the house's main direction whatever quadrant
// the walls point in. Turning by its negative sits the house square.
function houseAngle(walls) {
  let sx = 0, sy = 0;
  for (const w of walls) {
    const dx = w.b[0] - w.a[0], dy = w.b[1] - w.a[1];
    const len = Math.hypot(dx, dy), t = Math.atan2(dy, dx) * 4;
    sx += len * Math.cos(t); sy += len * Math.sin(t);
  }
  return -Math.atan2(sy, sx) / 4;
}

function fitLine(pts) {
  const n = pts.length;
  const mx = pts.reduce((a, p) => a + p.x, 0) / n, my = pts.reduce((a, p) => a + p.y, 0) / n;
  let sxx = 0, sxy = 0, syy = 0;
  for (const p of pts) { sxx += (p.x - mx) ** 2; sxy += (p.x - mx) * (p.y - my); syy += (p.y - my) ** 2; }
  const ang = 0.5 * Math.atan2(2 * sxy, sxx - syy);
  const ux = Math.cos(ang), uy = Math.sin(ang);
  const off = pts.map(p => -(p.x - mx) * uy + (p.y - my) * ux);
  const along = pts.map(p => (p.x - mx) * ux + (p.y - my) * uy);
  return { mx, my, ux, uy, worst: Math.max(...off.map(Math.abs)), squares: off.reduce((a, o) => a + o * o, 0),
           lo: Math.min(...along), hi: Math.max(...along) };
}

// A side of the outline: squared sides are a constant x ('v') or y ('h') between
// two extents; others keep their own line ('free').
function squareSides(pts) {
  const clean = pts.filter((p, i) => Math.hypot(p.x - pts[(i + 1) % pts.length].x, p.y - pts[(i + 1) % pts.length].y) > 0.01);
  let sides = clean.map((a, i) => {
    const b = clean[(i + 1) % clean.length];
    const len = Math.hypot(b.x - a.x, b.y - a.y);
    const deg = Math.abs(Math.atan2(b.y - a.y, b.x - a.x) * 180 / Math.PI) % 180;
    if (Math.min(deg, 180 - deg) <= SQUARE_DEG) return { kind: 'h', c: (a.y + b.y) / 2, len, a, b };
    if (Math.abs(deg - 90) <= SQUARE_DEG) return { kind: 'v', c: (a.x + b.x) / 2, len, a, b };
    return { kind: 'free', len, a, b };
  });
  // Neighbouring sides of one kind on (nearly) one line are one side.
  for (let changed = true; changed && sides.length > 3;) {
    changed = false;
    for (let i = 0; i < sides.length && sides.length > 3; i++) {
      const s = sides[i], t = sides[(i + 1) % sides.length];
      const tiny = t.kind !== 'free' && t.len < MIN_SIDE_FT;
      if (s.kind !== 'free' && s.kind === t.kind && Math.abs(s.c - t.c) < MERGE_FT) {
        s.c = (s.c * s.len + t.c * t.len) / (s.len + t.len); s.len += t.len; s.b = t.b;
        sides.splice((i + 1) % sides.length, 1); changed = true;
      } else if (tiny) {
        sides.splice((i + 1) % sides.length, 1); changed = true;
      }
    }
  }
  return sides;
}

// Two sides pushed out by different thicknesses can end up in line, leaving a
// zero-length wall or a corner on a straight line; neither belongs in a sketch.
function tidy(pts) {
  let out = pts.slice();
  for (let changed = true; changed && out.length > 3;) {
    changed = false;
    for (let i = 0; i < out.length && out.length > 3; i++) {
      const p = out[(i + out.length - 1) % out.length], q = out[i], r = out[(i + 1) % out.length];
      const cross = (q.x - p.x) * (r.y - q.y) - (q.y - p.y) * (r.x - q.x);
      if (Math.hypot(q.x - p.x, q.y - p.y) < 0.05 || Math.abs(cross) < 0.01) { out.splice(i, 1); changed = true; }
    }
  }
  return out;
}

function lineOf(s) {
  if (s.kind === 'h') return { px: 0, py: s.c, dx: 1, dy: 0 };
  if (s.kind === 'v') return { px: s.c, py: 0, dx: 0, dy: 1 };
  return { px: s.a.x, py: s.a.y, dx: s.b.x - s.a.x, dy: s.b.y - s.a.y };
}

// Corners where neighbouring sides' lines cross. Two parallel neighbours (a jog
// whose short side was dropped) are joined at the first side's end.
function outline(sides) {
  const pts = [];
  for (let i = 0; i < sides.length; i++) {
    const s = sides[i], t = sides[(i + 1) % sides.length];
    const l1 = lineOf(s), l2 = lineOf(t);
    const den = l1.dx * l2.dy - l1.dy * l2.dx;
    if (Math.abs(den) < 1e-6) {
      const e = s.kind === 'h' ? { x: s.b.x, y: s.c } : s.kind === 'v' ? { x: s.c, y: s.b.y } : s.b;
      const f = t.kind === 'h' ? { x: e.x, y: t.c } : t.kind === 'v' ? { x: t.c, y: e.y } : t.a;
      pts.push(e, f);
      continue;
    }
    const u = ((l2.px - l1.px) * l2.dy - (l2.py - l1.py) * l2.dx) / den;
    pts.push({ x: l1.px + l1.dx * u, y: l1.py + l1.dy * u });
  }
  return pts.map(p => ({ x: +p.x.toFixed(4), y: +p.y.toFixed(4) }));
}

// With y down, a positive shoelace area means the outline runs clockwise on
// screen, so outward is to the left of each side's direction: sign +1.
function outwardSign(pts) { return signedArea(pts) > 0 ? 1 : -1; }

function outwardNormal(s, sign) {
  const dx = s.b.x - s.a.x, dy = s.b.y - s.a.y, len = Math.hypot(dx, dy) || 1;
  return { x: dy / len * sign, y: -dx / len * sign };
}

function offsetSide(s, sign, ft) {
  const n = outwardNormal(s, sign);
  if (s.kind === 'h') return { ...s, c: s.c + Math.sign(n.y) * ft };
  if (s.kind === 'v') return { ...s, c: s.c + Math.sign(n.x) * ft };
  return { ...s, a: { x: s.a.x + n.x * ft, y: s.a.y + n.y * ft }, b: { x: s.b.x + n.x * ft, y: s.b.y + n.y * ft } };
}

// ---------------------------------------------------------------------------
// Outside walk: siding points per wall, drift spread over the walk in order, a
// wall whose points turn a corner split there, each wall fitted with a line.
// ---------------------------------------------------------------------------
function outsideWalk(ext, plan) {
  if (!ext || !(ext.walls || []).length) return { lines: [], split: 0, driftIn: null };
  const total = ext.walls.reduce((a, w) => a + w.length, 0);
  const drift = ext.anchorStart && ext.anchorEnd
    ? [ext.anchorEnd.point[0] - ext.anchorStart.point[0], ext.anchorEnd.point[1] - ext.anchorStart.point[1]] : [0, 0];
  let k = 0, split = 0;
  const lines = [];
  for (const w of ext.walls) {
    const pts = w.map(p => { k++; const f = k / (total + 1); return plan([p.point[0] - drift[0] * f, p.point[1] - drift[1] * f]); });
    const parts = splitWalk(pts);
    if (parts.length > 1) split++;
    for (const part of parts) if (part.length >= 2) lines.push(fitLine(part));
  }
  return { lines, split, driftIn: ext.anchorStart && ext.anchorEnd ? Math.hypot(...drift) * 39.37 : null };
}

// The story the walk was taken beside: the highest floor at least a foot below
// the phone's median height on the walk.
function walkStory(d) {
  const els = (d.exterior?.walls || []).flat().map(p => p.elevation).filter(Number.isFinite).sort((a, b) => a - b);
  if (!els.length || !(d.floors || []).length) return null;
  const phone = els[Math.floor(els.length / 2)];
  const below = d.floors.filter(f => Number.isFinite(f.elevation) && f.elevation <= phone - 0.3)
    .sort((a, b) => b.elevation - a.elevation)[0];
  return below ? below.story : null;
}

// Turns and slides the walk's lines to sit evenly outside the scanned sides.
// The turn is the walk's typical angle off square; the slide is the one that
// puts the most walk length a wall's thickness outside a parallel side, taken
// at the middle of the range of equally good slides. Returns null when the
// walk already fits as well as anything found.
function registerWalk(walk, sides) {
  const angleOff = l => { let a = Math.atan2(l.uy, l.ux) * 180 / Math.PI; a = ((a % 90) + 90) % 90; return a > 45 ? a - 90 : a; };
  const long = walk.lines.filter(l => l.hi - l.lo >= 4);
  if (long.length < 3) return null;
  const sorted = long.map(l => ({ a: angleOff(l), w: l.hi - l.lo })).sort((p, q) => p.a - q.a);
  const half = sorted.reduce((t, x) => t + x.w, 0) / 2;
  let acc = 0, tilt = 0;
  for (const x of sorted) { acc += x.w; if (acc >= half) { tilt = x.a; break; } }
  const turnLines = deg => {
    if (Math.abs(deg) < WALK_TILT_FIX_DEG) return walk.lines;
    const cx = walk.lines.reduce((t, l) => t + l.mx, 0) / walk.lines.length, cy = walk.lines.reduce((t, l) => t + l.my, 0) / walk.lines.length;
    const r = -deg * Math.PI / 180, c = Math.cos(r), s = Math.sin(r);
    return walk.lines.map(l => ({ ...l, mx: cx + (l.mx - cx) * c - (l.my - cy) * s, my: cy + (l.mx - cx) * s + (l.my - cy) * c,
                                  ux: l.ux * c - l.uy * s, uy: l.ux * s + l.uy * c }));
  };
  const score = (lines, dx, dy) => {
    let total = 0;
    for (const l of lines) {
      let best = 0;
      const lx = l.mx + dx, ly = l.my + dy;
      for (const s of sides) {
        if (s.kind === 'free') continue;
        const h = s.kind === 'h';
        if ((h ? Math.abs(l.ux) : Math.abs(l.uy)) < Math.cos(5 * Math.PI / 180)) continue;
        const n = outwardNormal(s, s.out);
        const gapIn = ((h ? ly - s.c : lx - s.c) * (h ? Math.sign(n.y) : Math.sign(n.x))) * 12;
        if (gapIn < 3 || gapIn > 20) continue;
        const u = h ? l.ux : l.uy, m = h ? lx : ly;
        const l0 = m + Math.min(l.lo * u, l.hi * u), l1 = m + Math.max(l.lo * u, l.hi * u);
        const lo = Math.min(s.a[h ? 'x' : 'y'], s.b[h ? 'x' : 'y']), hi = Math.max(s.a[h ? 'x' : 'y'], s.b[h ? 'x' : 'y']);
        best = Math.max(best, Math.min(hi, l1) - Math.max(lo, l0));
      }
      total += best;
    }
    return total;
  };
  const asIs = score(walk.lines, 0, 0);
  let found = null;
  for (const deg of Math.abs(tilt) >= WALK_TILT_FIX_DEG ? [0, tilt] : [0]) {
    const lines = turnLines(deg);
    const grid = [];
    let max = 0;
    for (let dx = -12; dx <= 12; dx += 0.25) for (let dy = -12; dy <= 12; dy += 0.25) {
      const v = score(lines, dx, dy);
      grid.push([dx, dy, v]);
      if (v > max) max = v;
    }
    const top = grid.filter(g => g[2] >= max * 0.97);
    const dx = top.reduce((t, g) => t + g[0], 0) / top.length, dy = top.reduce((t, g) => t + g[1], 0) / top.length;
    if (!found || max > found.max) found = { max, lines, dx, dy, tiltDeg: deg };
  }
  const total = walk.lines.reduce((t, l) => t + (l.hi - l.lo), 0);
  if (!found || found.max < asIs * 1.3 + 2 || found.max < total * 0.4 || (Math.hypot(found.dx, found.dy) < 0.3 && !found.tiltDeg)) return null;
  return { ...found, lines: found.lines.map(l => ({ ...l, mx: l.mx + found.dx, my: l.my + found.dy })) };
}

// Floor that lies outside the outside walk. On a grid, the outdoors is flooded
// in from the edge, stopped by scanned walls (with their doors and windows) and
// by the walk's lines; the flood reaches floor only where the scan's floor ran
// out past an edge with no wall. A flooded piece of floor is cut when it lies
// against the walk; then the floor is trimmed back from the walk by one wall
// thickness, to the inside face. Returns the new outline, or null.
function cutOutside(poly, d, story, plan, lines, thickFt) {
  const segs = ['walls', 'doors', 'windows', 'openings'].flatMap(k => (d[k] || []).filter(w => w.story === story))
    .map(w => [plan(w.a), plan(w.b)]);
  const walkSegs = lines.map(l => [
    { x: l.mx + l.ux * (l.lo - 1.5), y: l.my + l.uy * (l.lo - 1.5) },
    { x: l.mx + l.ux * (l.hi + 1.5), y: l.my + l.uy * (l.hi + 1.5) }]);
  const all = [...poly, ...walkSegs.flat()];
  const x0 = Math.min(...all.map(p => p.x)) - 2, y0 = Math.min(...all.map(p => p.y)) - 2;
  const W = Math.ceil((Math.max(...all.map(p => p.x)) + 2 - x0) / CELL_FT), H = Math.ceil((Math.max(...all.map(p => p.y)) + 2 - y0) / CELL_FT);
  if (W * H > 4e6) return null;
  const idx = (i, j) => j * W + i;
  // Floor cells: centres inside the polygon, row by row.
  const floor = new Uint8Array(W * H);
  for (let j = 0; j < H; j++) {
    const y = y0 + (j + 0.5) * CELL_FT, xs = [];
    for (let k = 0; k < poly.length; k++) {
      const a = poly[k], b = poly[(k + 1) % poly.length];
      if ((a.y <= y) !== (b.y <= y)) xs.push(a.x + (y - a.y) / (b.y - a.y) * (b.x - a.x));
    }
    xs.sort((p, q) => p - q);
    for (let k = 0; k + 1 < xs.length; k += 2) {
      for (let i = Math.max(0, Math.ceil((xs[k] - x0) / CELL_FT - 0.5)); i < W && x0 + (i + 0.5) * CELL_FT < xs[k + 1]; i++) floor[idx(i, j)] = 1;
    }
  }
  // Barriers: 1 a scanned wall, 2 the walk.
  const bar = new Uint8Array(W * H);
  const draw = ([a, b], v) => {
    const n = Math.ceil(Math.hypot(b.x - a.x, b.y - a.y) / (CELL_FT / 2)) + 1;
    for (let k = 0; k <= n; k++) {
      const ci = Math.floor((a.x + (b.x - a.x) * k / n - x0) / CELL_FT), cj = Math.floor((a.y + (b.y - a.y) * k / n - y0) / CELL_FT);
      for (let dj = -1; dj <= 1; dj++) for (let di = -1; di <= 1; di++) {
        const i = ci + di, j = cj + dj;
        if (i >= 0 && j >= 0 && i < W && j < H && (bar[idx(i, j)] === 0 || v === 1)) bar[idx(i, j)] = v;
      }
    }
  };
  walkSegs.forEach(s => draw(s, 2));
  segs.forEach(s => draw(s, 1));
  // Flood the outdoors from the grid's edge.
  const out = new Uint8Array(W * H), queue = [];
  const push = (i, j) => { const k = idx(i, j); if (!out[k] && !bar[k]) { out[k] = 1; queue.push(k); } };
  for (let i = 0; i < W; i++) { push(i, 0); push(i, H - 1); }
  for (let j = 0; j < H; j++) { push(0, j); push(W - 1, j); }
  const step = (k, f) => { const i = k % W, j = (k - i) / W; if (i > 0) f(i - 1, j); if (i < W - 1) f(i + 1, j); if (j > 0) f(i, j - 1); if (j < H - 1) f(i, j + 1); };
  // Diagonal steps too, so a distance measured with it keeps corners square.
  const step8 = (k, f) => {
    const i = k % W, j = (k - i) / W;
    for (let dj = -1; dj <= 1; dj++) for (let di = -1; di <= 1; di++) {
      const a = i + di, b = j + dj;
      if ((di || dj) && a >= 0 && b >= 0 && a < W && b < H) f(a, b);
    }
  };
  for (let q = 0; q < queue.length; q++) step(queue[q], push);
  // Inside the walk's loop, a straight line from a cell crosses the walk
  // whichever way it runs; outside, at least one way it reaches open ground.
  // A piece is outside when most of a sample of its cells are.
  // Walk crossed to the left, right, above and below each cell, in four sweeps.
  const seenL = new Uint8Array(W * H), seenR = new Uint8Array(W * H), seenU = new Uint8Array(W * H), seenD = new Uint8Array(W * H);
  for (let j = 0; j < H; j++) {
    let f = 0; for (let i = 0; i < W; i++) { seenL[idx(i, j)] = f; if (bar[idx(i, j)] === 2) f = 1; }
    f = 0; for (let i = W - 1; i >= 0; i--) { seenR[idx(i, j)] = f; if (bar[idx(i, j)] === 2) f = 1; }
  }
  for (let i = 0; i < W; i++) {
    let f = 0; for (let j = 0; j < H; j++) { seenU[idx(i, j)] = f; if (bar[idx(i, j)] === 2) f = 1; }
    f = 0; for (let j = H - 1; j >= 0; j--) { seenD[idx(i, j)] = f; if (bar[idx(i, j)] === 2) f = 1; }
  }
  const escapes = k => !(seenL[k] && seenR[k] && seenU[k] && seenD[k]);
  const outsideLoop = piece => {
    const n = Math.min(piece.length, 200);
    let outside = 0;
    for (let t = 0; t < n; t++) if (escapes(piece[Math.floor(t * piece.length / n)])) outside++;
    return outside > n / 2;
  };
  // Flooded floor in pieces; keep the pieces that lie against the walk.
  const cut = new Uint8Array(W * H), seen = new Uint8Array(W * H), strips = [];
  let cutCells = 0, floorCells = 0;
  for (let k = 0; k < W * H; k++) floorCells += floor[k];
  for (let k0 = 0; k0 < W * H; k0++) {
    if (!floor[k0] || !out[k0] || seen[k0]) continue;
    const piece = [k0];
    seen[k0] = 1;
    let byWalk = false;
    for (let q = 0; q < piece.length; q++) step(piece[q], (i, j) => {
      const k = idx(i, j);
      if (bar[k] === 2) byWalk = true;
      if (floor[k] && out[k] && !seen[k]) { seen[k] = 1; piece.push(k); }
    });
    if (byWalk && piece.length * CELL_FT * CELL_FT >= MIN_CUT_SF && outsideLoop(piece)) { piece.forEach(k => { cut[k] = 1; }); cutCells += piece.length; }
    else if (byWalk) strips.push(piece);
  }
  // A thin flooded strip lying wholly within a wall's thickness of the walk,
  // next to a cut, is the wall itself (the porch side of a garage wall).
  if (cutCells) {
    const nearWalk = new Int32Array(W * H).fill(-1), q = [];
    for (let k = 0; k < W * H; k++) if (bar[k] === 2) { nearWalk[k] = 0; q.push(k); }
    const lim = Math.round((thickFt + 0.5) / CELL_FT);
    for (let t = 0; t < q.length; t++) {
      const k0 = q[t];
      if (nearWalk[k0] >= lim) continue;
      step(k0, (i, j) => { const k = idx(i, j); if (nearWalk[k] === -1 && floor[k]) { nearWalk[k] = nearWalk[k0] + 1; q.push(k); } });
    }
    for (const piece of strips) {
      if (piece.every(k => nearWalk[k] !== -1)) { piece.forEach(k => { cut[k] = 1; }); cutCells += piece.length; }
    }
  }
  if (cutCells > floorCells * 0.3) { cut.fill(0); cutCells = 0; }
  // Trim back from the walk by a wall's thickness to the inside face: floor
  // reached from the cut across the walk line (never through a scanned wall).
  const reach = Math.round(thickFt / CELL_FT) + 2;
  const dist = new Int32Array(W * H).fill(-1), q2 = [];
  for (let k = 0; k < W * H; k++) if (cut[k]) { dist[k] = 0; q2.push(k); }
  for (let q = 0; q < q2.length; q++) {
    const k0 = q2[q];
    if (dist[k0] >= reach) continue;
    step8(k0, (i, j) => {
      const k = idx(i, j);
      if (dist[k] !== -1 || bar[k] === 1 || (!floor[k] && bar[k] !== 2)) return;
      dist[k] = dist[k0] + 1; q2.push(k);
    });
  }
  let keep = new Uint8Array(W * H);
  for (let k = 0; k < W * H; k++) keep[k] = floor[k] && dist[k] === -1 ? 1 : 0;
  // Floor the scan missed inside the walk (a closet, chase or alcove behind a
  // wall it didn't see): ground inside the walk's loop lying further from the
  // floor than a wall's thickness. It is added, out to the walk's inside face.
  const wallCells = Math.round(thickFt / CELL_FT);
  const far = wallCells + 6;
  const distFrom = (seed, through, limit) => {
    const dd = new Int32Array(W * H).fill(-1), q = [];
    for (let k = 0; k < W * H; k++) if (seed(k)) { dd[k] = 0; q.push(k); }
    for (let t = 0; t < q.length; t++) {
      const k0 = q[t];
      if (dd[k0] >= limit) continue;
      step8(k0, (i, j) => { const k = idx(i, j); if (dd[k] === -1 && through(k)) { dd[k] = dd[k0] + 1; q.push(k); } });
    }
    return dd;
  };
  const fromFloor = distFrom(k => keep[k], k => bar[k] !== 2, far);
  const fromWalk = distFrom(k => bar[k] === 2, () => true, wallCells + 1);
  const missing = new Uint8Array(W * H), seen2 = new Uint8Array(W * H);
  let grownCells = 0;
  for (let k0 = 0; k0 < W * H; k0++) {
    if (seen2[k0] || keep[k0] || bar[k0] === 2 || fromFloor[k0] !== -1 || escapes(k0)) continue;
    const piece = [k0];
    seen2[k0] = 1;
    let open = false;
    for (let q = 0; q < piece.length; q++) step(piece[q], (i, j) => {
      const k = idx(i, j);
      if (seen2[k] || keep[k] || bar[k] === 2 || fromFloor[k] !== -1) return;
      if (escapes(k)) { open = true; return; }
      seen2[k] = 1; piece.push(k);
    });
    if (open || piece.length * CELL_FT * CELL_FT < MIN_CUT_SF || piece.length > floorCells * 0.35) continue;
    // Out from the piece to the floor it lies against, short of the walk by a
    // wall's thickness.
    const pieceSet = new Uint8Array(W * H);
    piece.forEach(k => { pieceSet[k] = 1; });
    const grow = distFrom(k => pieceSet[k], k => !keep[k] && bar[k] !== 2, far);
    for (let k = 0; k < W * H; k++) {
      if (grow[k] !== -1 && !keep[k] && bar[k] !== 2 && fromWalk[k] === -1) { missing[k] = 1; grownCells++; }
    }
  }
  if (grownCells) for (let k = 0; k < W * H; k++) if (missing[k]) keep[k] = 1;
  // Smooth the new edges only (not the rest of the scan): drop nubs under
  // about a foot near where the floor was cut. (Filling nicks too would put
  // back the trimmed wall.)
  const zone = new Uint8Array(W * H);
  for (let k = 0; k < W * H; k++) if ((dist[k] > 0 || cut[k] || missing[k])) {
    const i = k % W, j = (k - i) / W;
    for (let dj = -8; dj <= 8; dj++) for (let di = -8; di <= 8; di++) {
      const a = i + di, b = j + dj;
      if (a >= 0 && b >= 0 && a < W && b < H) zone[idx(a, b)] = 1;
    }
  }
  const morph = (src, grow) => {
    const dst = src.slice();
    for (let k = 0; k < W * H; k++) {
      if (!zone[k]) continue;
      const i = k % W, j = (k - i) / W;
      let v = grow ? 0 : 1;
      for (let dj = -5; dj <= 5 && v === (grow ? 0 : 1); dj++) for (let di = -5; di <= 5; di++) {
        const a = i + di, b = j + dj;
        const c = a >= 0 && b >= 0 && a < W && b < H ? src[idx(a, b)] : 0;
        if (grow ? c : !c) { v = grow ? 1 : 0; break; }
      }
      dst[k] = v && (grow ? before[k] : 1) ? v : 0;
    }
    return dst;
  };
  const before = keep.slice();
  keep = morph(morph(keep, false), true);   // open: drop nubs
  if (!cutCells && !grownCells) return null;
  let removed = 0;
  for (let k = 0; k < W * H; k++) if (floor[k] && !keep[k]) removed++;
  const traced = traceCells(keep, W, H);
  if (!traced) return null;
  const pts = traced.map(([i, j]) => ({ x: x0 + i * CELL_FT, y: y0 + j * CELL_FT }));
  const sf = c => c * CELL_FT * CELL_FT;
  return { poly: pts, sf: sf(removed), grownSf: sf(grownCells) };
}

// The outer boundary of the largest piece of set cells, as corner points.
function traceCells(m, W, H) {
  // Directed cell edges with the piece on the right, joined into loops.
  const next = new Map();
  const key = (i, j) => j * (W + 1) + i;
  const at = (i, j) => i >= 0 && j >= 0 && i < W && j < H && m[j * W + i];
  let cells = 0;
  for (let j = 0; j < H; j++) for (let i = 0; i < W; i++) {
    if (!m[j * W + i]) continue;
    cells++;
    if (!at(i, j - 1)) next.set(key(i, j), key(i + 1, j));
    if (!at(i + 1, j)) next.set(key(i + 1, j), key(i + 1, j + 1));
    if (!at(i, j + 1)) next.set(key(i + 1, j + 1), key(i, j + 1));
    if (!at(i - 1, j)) next.set(key(i, j + 1), key(i, j));
  }
  let best = null, bestArea = 0;
  const done = new Set();
  for (const start of next.keys()) {
    if (done.has(start)) continue;
    const loop = [];
    for (let k = start; !done.has(k) && next.has(k); k = next.get(k)) { done.add(k); loop.push([k % (W + 1), Math.floor(k / (W + 1))]); }
    const area = Math.abs(signedArea(loop.map(([x, y]) => ({ x, y }))));
    if (area > bestArea) { bestArea = area; best = loop; }
  }
  if (!best) return null;
  // Corners only: drop points on a straight run.
  const pts = best.filter((p, n) => {
    const a = best[(n + best.length - 1) % best.length], b = best[(n + 1) % best.length];
    return (p[0] - a[0]) * (b[1] - p[1]) - (p[1] - a[1]) * (b[0] - p[0]) !== 0;
  });
  return Object.assign(pts, { cells });
}

// The walk's typical gap outside the scanned sides beside it: the wall
// thickness, in feet.
function walkThickness(lines, sides) {
  const gaps = [];
  for (const l of lines) for (const s of sides) {
    if (s.kind === 'free') continue;
    const h = s.kind === 'h';
    if ((h ? Math.abs(l.ux) : Math.abs(l.uy)) < Math.cos(5 * Math.PI / 180)) continue;
    const n = outwardNormal(s, s.out);
    const gapIn = ((h ? l.my - s.c : l.mx - s.c) * (h ? Math.sign(n.y) : Math.sign(n.x))) * 12;
    if (gapIn < THICKNESS_RANGE_IN[0] || gapIn > THICKNESS_RANGE_IN[1]) continue;
    const u = h ? l.ux : l.uy, m = h ? l.mx : l.my;
    const l0 = m + Math.min(l.lo * u, l.hi * u), l1 = m + Math.max(l.lo * u, l.hi * u);
    const lo = Math.min(s.a[h ? 'x' : 'y'], s.b[h ? 'x' : 'y']), hi = Math.max(s.a[h ? 'x' : 'y'], s.b[h ? 'x' : 'y']);
    if (Math.min(hi, l1) - Math.max(lo, l0) >= 1) gaps.push(gapIn);
  }
  if (!gaps.length) return null;
  gaps.sort((a, b) => a - b);
  return gaps[Math.floor(gaps.length / 2)] / 12;
}

// Floor closed in by walls the user drew or moved: on a grid, open ground is
// flooded in from the edge, stopped by the floor and every wall, door and
// window. Ground the flood can't reach that touches a drawn or moved wall is
// a pocket the scan missed; it joins the floor, up to the walls around it.
function growToWalls(poly, d, story, plan) {
  const mineIds = new Set([...(d.addedWalls || []).map(w => w.id), ...(d.wallEdits || []).filter(e => !e.hidden).map(e => e.wall)]);
  const all = ['walls', 'doors', 'windows', 'openings'].flatMap(k => (d[k] || []).filter(w => w.story === story));
  const mine = all.filter(w => mineIds.has(w.id));
  if (!mine.length) return null;
  const segs = all.map(w => ({ a: plan(w.a), b: plan(w.b), mine: mineIds.has(w.id) }));
  const pts = [...poly, ...segs.flatMap(s => [s.a, s.b])];
  const x0 = Math.min(...pts.map(p => p.x)) - 2, y0 = Math.min(...pts.map(p => p.y)) - 2;
  const W = Math.ceil((Math.max(...pts.map(p => p.x)) + 2 - x0) / CELL_FT), H = Math.ceil((Math.max(...pts.map(p => p.y)) + 2 - y0) / CELL_FT);
  if (W * H > 4e6) return null;
  const idx = (i, j) => j * W + i;
  const floor = new Uint8Array(W * H);
  for (let j = 0; j < H; j++) {
    const y = y0 + (j + 0.5) * CELL_FT, xs = [];
    for (let k = 0; k < poly.length; k++) {
      const a = poly[k], b = poly[(k + 1) % poly.length];
      if ((a.y <= y) !== (b.y <= y)) xs.push(a.x + (y - a.y) / (b.y - a.y) * (b.x - a.x));
    }
    xs.sort((p, q) => p - q);
    for (let k = 0; k + 1 < xs.length; k += 2)
      for (let i = Math.max(0, Math.ceil((xs[k] - x0) / CELL_FT - 0.5)); i < W && x0 + (i + 0.5) * CELL_FT < xs[k + 1]; i++) floor[idx(i, j)] = 1;
  }
  // 1 a wall, 2 a drawn or moved wall.
  const bar = new Uint8Array(W * H);
  for (const s of segs) {
    const n = Math.ceil(Math.hypot(s.b.x - s.a.x, s.b.y - s.a.y) / (CELL_FT / 2)) + 1;
    for (let k = 0; k <= n; k++) {
      const ci = Math.floor((s.a.x + (s.b.x - s.a.x) * k / n - x0) / CELL_FT), cj = Math.floor((s.a.y + (s.b.y - s.a.y) * k / n - y0) / CELL_FT);
      for (let dj = -1; dj <= 1; dj++) for (let di = -1; di <= 1; di++) {
        const i = ci + di, j = cj + dj;
        if (i >= 0 && j >= 0 && i < W && j < H) bar[idx(i, j)] = Math.max(bar[idx(i, j)], s.mine ? 2 : 1);
      }
    }
  }
  const open = k => !floor[k] && !bar[k];
  const step = (k, f) => { const i = k % W, j = (k - i) / W; if (i > 0) f(i - 1, j); if (i < W - 1) f(i + 1, j); if (j > 0) f(i, j - 1); if (j < H - 1) f(i, j + 1); };
  const out = new Uint8Array(W * H), q = [];
  const push = (i, j) => { const k = idx(i, j); if (!out[k] && open(k)) { out[k] = 1; q.push(k); } };
  for (let i = 0; i < W; i++) { push(i, 0); push(i, H - 1); }
  for (let j = 0; j < H; j++) { push(0, j); push(W - 1, j); }
  for (let t = 0; t < q.length; t++) step(q[t], push);
  let floorCells = 0;
  for (let k = 0; k < W * H; k++) floorCells += floor[k];
  const keep = floor.slice(), seen = new Uint8Array(W * H);
  let added = 0;
  for (let k0 = 0; k0 < W * H; k0++) {
    if (seen[k0] || !open(k0) || out[k0]) continue;
    const piece = [k0];
    seen[k0] = 1;
    let byMine = false, byFloor = false;
    for (let t = 0; t < piece.length; t++) step(piece[t], (i, j) => {
      const k = idx(i, j);
      if (bar[k] === 2) byMine = true;
      if (floor[k] || bar[k]) byFloor = byFloor || bar[k] === 1 || floor[k] === 1;
      if (!seen[k] && open(k) && !out[k]) { seen[k] = 1; piece.push(k); }
    });
    if (!byMine || !byFloor || piece.length * CELL_FT * CELL_FT < MIN_CUT_SF || piece.length > floorCells * 0.3) continue;
    // The piece, and the wall cells between it and the floor.
    const mark = new Uint8Array(W * H);
    piece.forEach(k => { mark[k] = 1; });
    for (let r = 0; r < 3; r++) {
      const grow = [];
      for (let k = 0; k < W * H; k++) if (mark[k]) step(k, (i, j) => { const m = idx(i, j); if (!mark[m] && bar[m] && !out[m]) grow.push(m); });
      grow.forEach(m => { mark[m] = 1; });
    }
    for (let k = 0; k < W * H; k++) if (mark[k] && !keep[k]) { keep[k] = 1; added++; }
  }
  if (!added) return null;
  const traced = traceCells(keep, W, H);
  if (!traced) return null;
  return { poly: traced.map(([i, j]) => ({ x: x0 + i * CELL_FT, y: y0 + j * CELL_FT })), sf: added * CELL_FT * CELL_FT };
}

function onOutline(poly, p, tol) {
  return poly.some((a, k) => {
    const b = poly[(k + 1) % poly.length], dx = b.x - a.x, dy = b.y - a.y, L2 = dx * dx + dy * dy || 1;
    const t = Math.max(0, Math.min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / L2));
    return Math.hypot(a.x + dx * t - p.x, a.y + dy * t - p.y) <= tol;
  });
}

function splitWalk(pts) {
  const tol = WALK_SPLIT_IN / 12;
  if (pts.length < 4 || fitLine(pts).worst <= tol) return [pts];
  let best = 2, bestCost = Infinity;
  for (let k = 2; k <= pts.length - 2; k++) {
    const cost = fitLine(pts.slice(0, k)).squares + fitLine(pts.slice(k)).squares;
    if (cost < bestCost) { bestCost = cost; best = k; }
  }
  return [...splitWalk(pts.slice(0, best)), ...splitWalk(pts.slice(best))];
}

// Each side's wall thickness: the gap to a parallel outside-walk line beside it
// (outside, overlapping along the side), else the default.
function thicknesses(sides, lines, defaultIn) {
  const inside = outline(sides), sign = outwardSign(inside);
  return sides.map(s => {
    if (s.kind === 'free') return { inches: defaultIn, measured: false };
    const n = outwardNormal(s, sign);
    let best = null;
    for (const l of lines) {
      const along = s.kind === 'h' ? Math.abs(l.ux) : Math.abs(l.uy);
      if (along < Math.cos(5 * Math.PI / 180)) continue;
      const gapIn = ((s.kind === 'h' ? l.my - s.c : l.mx - s.c) * (s.kind === 'h' ? Math.sign(n.y) : Math.sign(n.x))) * 12;
      if (gapIn < THICKNESS_RANGE_IN[0] || gapIn > THICKNESS_RANGE_IN[1]) continue;
      const lo = Math.min(s.a[s.kind === 'h' ? 'x' : 'y'], s.b[s.kind === 'h' ? 'x' : 'y']);
      const hi = Math.max(s.a[s.kind === 'h' ? 'x' : 'y'], s.b[s.kind === 'h' ? 'x' : 'y']);
      const u = s.kind === 'h' ? l.ux : l.uy, m = s.kind === 'h' ? l.mx : l.my;
      const l0 = m + Math.min(l.lo * u, l.hi * u), l1 = m + Math.max(l.lo * u, l.hi * u);
      if (Math.min(hi, l1) - Math.max(lo, l0) < 0.5) continue;
      if (!best || gapIn < best) best = gapIn;
    }
    return best ? { inches: best, measured: true } : { inches: defaultIn, measured: false };
  });
}

// ---------------------------------------------------------------------------
// Hidden walls: points marked on walls the scan missed, and laser depths across
// gaps, as squared lines. A side lying on a gap moves to the hidden wall there.
// ---------------------------------------------------------------------------
function hiddenWalls(d, plan, turn) {
  const levels = (d.floors || []).map(f => [f.story, f.elevation]);
  const storyAt = elev => (levels.filter(([, e]) => e <= elev + 0.3).sort((a, b) => b[1] - a[1])[0] || levels[0] || [0])[0];
  const out = [];
  for (const wp of d.wallPoints || []) {
    const p = plan(wp.point);
    const n = rotate({ x: wp.normal[0], y: wp.normal[1] }, turn);
    // A wall facing mostly along x runs along y, so it is a constant x.
    out.push(Math.abs(n.x) > Math.abs(n.y)
      ? { story: storyAt(wp.elevation), kind: 'v', c: p.x, at: p }
      : { story: storyAt(wp.elevation), kind: 'h', c: p.y, at: p });
  }
  const walls = new Map((d.walls || []).map(w => [w.id, w]));
  for (const g of d.gapDepths || []) {
    const w = walls.get(g.from);
    if (!w || g.gap.length !== 2) continue;
    const a = plan(w.a), b = plan(w.b), ga = plan(g.gap[0]), gb = plan(g.gap[1]);
    const horizontal = Math.abs(b.x - a.x) > Math.abs(b.y - a.y);
    const wallC = horizontal ? (a.y + b.y) / 2 : (a.x + b.x) / 2;
    const gapC = horizontal ? (ga.y + gb.y) / 2 : (ga.x + gb.x) / 2;
    // The reading starts at the wall's face, half a partition off its scanned line.
    const ft = (g.inches + 2.25) / 12;
    out.push({ story: w.story, kind: horizontal ? 'h' : 'v', c: wallC + Math.sign(gapC - wallC) * ft,
               at: { x: (ga.x + gb.x) / 2, y: (ga.y + gb.y) / 2 } });
  }
  return out;
}

function fillHidden(sides, gaps, hidden) {
  let filled = 0;
  for (const g of gaps) {
    const horizontal = Math.abs(g.b.x - g.a.x) > Math.abs(g.b.y - g.a.y);
    const kind = horizontal ? 'h' : 'v';
    const gc = horizontal ? (g.a.y + g.b.y) / 2 : (g.a.x + g.b.x) / 2;
    const mid = { x: (g.a.x + g.b.x) / 2, y: (g.a.y + g.b.y) / 2 };
    const side = sides.find(s => s.kind === kind && Math.abs(s.c - gc) < 0.4
      && between(horizontal ? mid.x : mid.y, s.a[horizontal ? 'x' : 'y'], s.b[horizontal ? 'x' : 'y'], 0.3));
    const h = hidden.filter(h => h.kind === kind && Math.abs(h.c - gc) < 3
      && between(horizontal ? h.at.x : h.at.y, g.a[horizontal ? 'x' : 'y'], g.b[horizontal ? 'x' : 'y'], 1))
      .sort((p, q) => Math.abs(p.c - gc) - Math.abs(q.c - gc))[0];
    if (side && h) { side.c = h.c; side.hidden = true; filled++; }
  }
  return filled;
}

function between(v, a, b, slack) { return v >= Math.min(a, b) - slack && v <= Math.max(a, b) + slack; }
