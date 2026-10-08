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

const FT = 3.28084;
const SQUARE_DEG = 8;             // sides within this of the house's main directions are squared
const MERGE_FT = 0.25;            // neighbouring squared sides closer than this are one side
const MIN_SIDE_FT = 0.15;         // shorter sides are noise in the outline
const WALK_SPLIT_IN = 6;          // outside-walk points further than this off one line turned a corner
const THICKNESS_RANGE_IN = [2, 16];
export const DEFAULT_EXTERIOR_IN = 6;

export function readCvalrScan(d, opts = {}) {
  if (!d || d.format !== 'cvalrscan') {
    return { ok: false, reason: 'unknown-format', message: 'This is not a CValRScan plan (cvalrscan JSON).' };
  }
  if ((d.version || 0) > 5) {
    return { ok: false, reason: 'newer-version', message: `This scan is format version ${d.version}; this CValRSketch reads up to version 5. Update the app.` };
  }
  const defaultIn = opts.exteriorInches ?? DEFAULT_EXTERIOR_IN;
  const turn = houseAngle(d.walls || []);
  const plan = ([x, y]) => rotate({ x: x * FT, y: y * FT }, turn);
  const warnings = [];

  const walk = outsideWalk(d.exterior, plan);
  if (walk.split) warnings.push(`${walk.split} outside-walk wall${walk.split > 1 ? 's' : ''} turned a corner without Next wall; split at the corner.`);
  if (walk.driftIn != null && walk.driftIn > 6) warnings.push(`The outside walk drifted ${walk.driftIn.toFixed(1)}″; its wall thicknesses are less certain.`);

  const hidden = hiddenWalls(d, plan, turn);
  const floors = [];
  const stories = [...new Set((d.floors || []).map(f => f.story))].sort((a, b) => a - b);
  for (const story of stories) {
    for (const f of d.floors.filter(f => f.story === story)) {
      if (!f.polygon || f.polygon.length < 3) continue;
      let sides = squareSides(f.polygon.map(plan));
      const gaps = (d.gaps || []).filter(g => g.story === story).map(g => ({ a: plan(g.a), b: plan(g.b) }));
      const filled = fillHidden(sides, gaps, hidden.filter(h => h.story === story));
      const open = gaps.length - filled;
      if (open > 0) warnings.push(`${floorTitle(story)}: ${open} missing wall${open > 1 ? 's' : ''} in the scan (closet backs?) kept where the scan's floor stopped; check ${open > 1 ? 'them' : 'it'}.`);
      const inside = outline(sides);
      const thick = thicknesses(sides, walk.lines, defaultIn);
      const measured = thick.filter(t => t.measured);
      const outer = tidy(outline(sides.map((s, i) => offsetSide(s, outwardSign(inside), thick[i].inches / 12))));
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
        areas: {}, stated: null, excludedTraced: null, placement: 'reference', turned: 0,
      });
    }
  }
  if (!floors.length) return { ok: false, reason: 'no-floors', message: 'The scan has no floor outline to import.', warnings };
  if (!(d.measurements || []).length && !(d.spans || []).length) warnings.push('No laser readings in the scan, so nothing checks its overall size. Enter one in CValRScan (Measure walls).');
  return { ok: true, format: 'CValRScan', profileId: 'cvalrscan', address: '', floors, warnings, buildings: [] };
}

// Corner-to-corner readings against the imported outline: an outside reading
// is compared with the outer corners beside its two scanned corners, an inside
// one with the inside outline, along the house's main direction.
function checkSpans(d, story, plan, inside, outer, warnings) {
  const fmt = inches => `${Math.floor(inches / 12)}′ ${Math.round(inches % 12)}″`;
  for (const sp of (d.spans || []).filter(s => s.story === story)) {
    const pts = sp.face === 'outside' ? outer : inside;
    const near = p => pts.reduce((best, q) => Math.hypot(q.x - p.x, q.y - p.y) < Math.hypot(best.x - p.x, best.y - p.y) ? q : best, pts[0]);
    const a = near(plan(sp.a)), b = near(plan(sp.b));
    const got = Math.max(Math.abs(b.x - a.x), Math.abs(b.y - a.y)) * 12;
    const diff = Math.round(got - sp.inches);
    warnings.push(`${floorTitle(story)}: ${sp.face} reading ${fmt(sp.inches)}${sp.entered && /[+\-−]/.test(sp.entered) ? ` (${sp.entered})` : ''} between two corners; the import measures ${fmt(got)} there (${diff === 0 ? 'matches' : (diff > 0 ? '+' : '−') + Math.abs(diff) + '″'}).`);
  }
}

function floorTitle(story) {
  return story === 0 ? 'Scanned floor' : story > 0 ? `Scanned floor +${story}` : `Scanned floor ${story}`;
}

// RoomPlan numbers floors from where scanning began; the lowest of several is a
// basement only when the user says so, so the start floor is main.
function classifyStory(story, stories) {
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
