// CValRSketch core — pure geometry / parsing / edit operations shared by the desktop and mobile UIs.
// Copyright (C) 2026 CAA-EBV-CO-OP and the CValRSketch contributors.
// Part of OSASI, the Open Source Appraisal Software Initiative (https://osasi.org).
// SPDX-License-Identifier: AGPL-3.0-or-later
// Free software under the GNU AGPL v3 (or later); distributed WITHOUT ANY WARRANTY.
// Additional terms under AGPL Section 7(b)/(c) (preserved attribution, no misrepresentation
// of origin) are stated in the NOTICE file; licence text in LICENSE. Source: https://github.com/CAA-EBV-CO-OP/CValRSketch
// =============================================================================
// CValRSketch core — pure logic shared by desktop and mobile UIs.
// No DOM access, no global state. Each function takes everything it needs
// as arguments and returns plain data. Load via <script src="core.js"> before
// any UI script so these symbols are available as window globals.
// =============================================================================

// ----- Configuration constants -----

const TYPES = {
  living:     { name: 'Enclosed living',    fill: '#f4f0e6', dashed: false },
  finished:   { name: 'Finished basement',  fill: '#eaf4ea', dashed: false },
  unfinished: { name: 'Unfinished (mech)',  fill: 'url(#unfinishedHatch)', dashed: false },
  porch:      { name: 'Open covered porch', fill: 'url(#porchHatch)', dashed: true },
  garage:     { name: 'Garage',             fill: '#e3e4e6', dashed: false },
  deck:       { name: 'Open deck',          fill: '#e8dcc8', dashed: true },
  upper:      { name: 'Upper floor area',   fill: '#f0e6f4', dashed: false },
  outbuilding:{ name: 'Outbuilding',        fill: '#e6e0d4', dashed: false },
  barn:       { name: 'Barn',               fill: '#e9d3c4', dashed: false },
  shed:       { name: 'Shed',               fill: '#dfe6d2', dashed: false },
  shop:       { name: 'Shop',               fill: '#d6e0e8', dashed: false },
  carport:    { name: 'Carport',            fill: '#e6ddec', dashed: true },
  misc:       { name: 'Misc / other',       fill: '#ededed', dashed: false },
};

// Building / dwelling grouping for shapes. A shape's `building` is a free label
// from this list; totals subtotal by building. New/legacy shapes default to the
// first entry. Baked in (like TYPES) so it's consistent across files.
const BUILDINGS = ['Dwelling 1', 'Dwelling 2', 'Dwelling 3', 'Outbuildings', 'Other'];
const DEFAULT_BUILDING = BUILDINGS[0];

const DIR_BASE = { r: 0, d: 90, l: 180, u: -90 };

const SETTINGS_DEFAULTS = {
  showSegmentLabels: true,
  showCentroidLabels: true,
  sketchFontScale: 1,   // global multiplier for on-drawing label sizes (dimensions, area, notes)
  ghostDimFloors: [],   // names of non-active floors whose dimension labels should still show
  showVertexDots: true,
  showFloorGhosts: true,
  ghostOpacity: 0.45,
  exportIncludeTitle: true,
  exportIncludeLegend: true,
  showDetail: true,        // interior detail (walls, doors, windows, room names) imported from a scan
  exportPageSize: 'auto',  // 'auto' | 'letter-portrait' | 'letter-landscape'
  exportLayout: 'active',  // 'active' (live canvas) | 'horizontal' | 'vertical' (every floor as its own panel)
  autosaveToFile: true,    // after Save As / Load via the picker, rewrite that file after every change (Chrome/Edge)
  typeStyles: {},          // fill palette overrides per area type: { [typeKey]: { color: '#rrggbb', pattern: 'none'|'planks'|'hatch'|'crosshatch'|'dots' } }
  confirmDelete: true,
  askOnLengthEdit: true,
  defaultLengthEditMode: 'stretch-end',
  snapAngleTo90: false,
  autoCloseFeet: 0.05,
};

const HISTORY_LIMIT = 100;

const EXPORT_PAGE_SIZES = {
  'auto':             null,
  'letter-portrait':  { w: 816,  h: 1056 }, // 8.5×11 in @ 96 DPI
  'letter-landscape': { w: 1056, h: 816 },
};

// ----- Parsing & formatting -----

function parseLength(s) {
  s = String(s).trim();
  if (s.includes('+')) {
    const parts = s.split('+').map(p => p.trim()).filter(Boolean);
    let total = 0;
    for (const p of parts) {
      const v = parseLength(p);
      if (isNaN(v)) return NaN;
      total += v;
    }
    return total;
  }
  if (s.includes("'")) {
    const idx = s.indexOf("'");
    const ftStr = s.slice(0, idx).trim();
    const inStr = s.slice(idx+1).replace('"','').trim();
    const ft = parseFloat(ftStr) || 0;
    const inches = inStr ? parseFloat(inStr) : 0;
    if (isNaN(ft) || isNaN(inches)) return NaN;
    return ft + inches/12;
  }
  if (s.includes('"')) return parseFloat(s.replace('"','')) / 12;
  return parseFloat(s);
}

// Heading of a segment in screen-coord degrees (0=east, 90=south, 180=west, -90=north).
function headingDeg(seg) {
  return Math.atan2(seg.dy, seg.dx) * 180 / Math.PI;
}

function parseSegment(text, priorHeadingDeg = null) {
  // Combined-components syntax: "5'd , 2'l" → one diagonal segment with summed dx/dy.
  // Comma is the separator (legacy '&' still accepted). Each side is parsed as its own
  // cardinal length+direction; angles aren't allowed here.
  if (text.includes(',') || text.includes('&')) {
    const parts = text.split(/[,&]/).map(p => p.trim()).filter(Boolean);
    if (parts.length < 2) throw new Error(`"${text}": ',' must combine two or more length-direction pairs`);
    let dx = 0, dy = 0;
    for (const part of parts) {
      const sub = parseSegment(part);
      if (sub.autoExtend) throw new Error(`"${text}": ',' requires an explicit length on every part`);
      if (sub.angle) throw new Error(`"${text}": ',' parts can't have angles — use a single diagonal segment instead`);
      dx += sub.dx;
      dy += sub.dy;
    }
    const length = Math.hypot(dx, dy);
    if (!(length > 0)) throw new Error(`"${text}": combined vector is zero`);
    const dir = Math.abs(dx) >= Math.abs(dy) ? (dx >= 0 ? 'r' : 'l') : (dy >= 0 ? 'd' : 'u');
    return { length, dir, angle: 0, dx, dy, raw: text.trim() };
  }

  let s = text.trim().toLowerCase()
    .replace(/→/g,' r').replace(/←/g,' l').replace(/↑/g,' u').replace(/↓/g,' d')
    .replace(/\bright\b/g, 'r').replace(/\bleft\b/g, 'l')   // accept full direction words
    .replace(/\bup\b/g, 'u').replace(/\bdown\b/g, 'd')
    .replace(/\s*\+\s*/g, '+')              // collapse spaces around + so "2'6 + 3'0" → "2'6+3'0"
    .replace(/([\d'"])([rlud])/g, '$1 $2')  // split length from direction: "3'0r" → "3'0 r"
    .replace(/([rlud])(-?\d)/g, '$1 $2');   // split direction from angle: "r90" → "r 90"
  const tokens = s.split(/\s+/).filter(Boolean);
  // Auto-extend: just a direction with no length → snap to next aligned vertex (resolved by caller).
  if (tokens.length === 1 && tokens[0] in DIR_BASE) {
    return { autoExtend: true, dir: tokens[0], raw: text.trim() };
  }
  if (tokens.length < 2) throw new Error(`"${text}": need length and direction`);
  // Implicit combined components: "5'd 3'l" (or "5'd3'l") → one diagonal segment.
  // Triggers when tokens are pairs of (length, direction) with no angle.
  if (tokens.length >= 4 && tokens.length % 2 === 0) {
    let allPairs = true;
    for (let i = 0; i < tokens.length; i += 2) {
      const len = parseLength(tokens[i]);
      if (!(len > 0) || !(tokens[i+1] in DIR_BASE)) { allPairs = false; break; }
    }
    if (allPairs) {
      let dx = 0, dy = 0;
      for (let i = 0; i < tokens.length; i += 2) {
        const len = parseLength(tokens[i]);
        const a = DIR_BASE[tokens[i+1]] * Math.PI / 180;
        dx += Math.cos(a) * len;
        dy += Math.sin(a) * len;
      }
      const length = Math.hypot(dx, dy);
      if (!(length > 0)) throw new Error(`"${text}": combined vector is zero`);
      const dir = Math.abs(dx) >= Math.abs(dy) ? (dx >= 0 ? 'r' : 'l') : (dy >= 0 ? 'd' : 'u');
      return { length, dir, angle: 0, dx, dy, raw: text.trim() };
    }
  }
  const length = parseLength(tokens[0]);
  if (!(length > 0)) throw new Error(`"${text}": invalid length`);
  const dir = tokens[1];
  if (!(dir in DIR_BASE)) throw new Error(`"${text}": direction must be r, l, u, or d`);
  const userAngle = tokens[2] !== undefined ? parseFloat(tokens[2]) : 0;
  if (isNaN(userAngle)) throw new Error(`"${text}": invalid angle`);
  // Angle interpretation:
  //  - r/l with explicit angle AND a known prior heading → relative turn from the
  //    previous segment (r = turn right/CW, l = turn left/CCW). Matches how you'd
  //    walk a perimeter: "after going east, l 45 = NE; r 45 = SE".
  //  - Otherwise → degrees CW from the cardinal base (DIR_BASE).
  const relative = tokens[2] !== undefined && priorHeadingDeg !== null && (dir === 'r' || dir === 'l');
  const totalDeg = relative
    ? priorHeadingDeg + (dir === 'r' ? userAngle : -userAngle)
    : DIR_BASE[dir] + userAngle;
  const total = totalDeg * Math.PI / 180;
  return {
    length, dir, angle: userAngle,
    dx: Math.cos(total) * length,
    dy: Math.sin(total) * length,
    raw: text.trim()
  };
}

function formatLength(ft) {
  if (ft < 0) return '-' + formatLength(-ft);
  const whole = Math.floor(ft);
  const inches = Math.round((ft - whole) * 12);
  if (inches === 12) return `${whole+1}'0"`;
  return `${whole}'${inches}"`;
}

// dx, dy = vector FROM pen end TO start (what a closing segment would travel).
function formatGapBreakdown(dx, dy) {
  const tol = 1/24; // ~1/2"
  const parts = [];
  if (Math.abs(dx) > tol) parts.push(`${formatLength(Math.abs(dx))} ${dx > 0 ? 'right' : 'left'}`);
  if (Math.abs(dy) > tol) parts.push(`${formatLength(Math.abs(dy))} ${dy > 0 ? 'down' : 'up'}`);
  return parts.length ? parts.join(' + ') : 'aligned';
}

// ----- Geometry -----

// Returns the sequence of points the pen visits, including start.
// `start` is { x, y }; `segs` is an array of { dx, dy, ... }.
function pathPoints(segs, start) {
  const pts = [{ ...start }];
  let x = start.x, y = start.y;
  for (const s of segs) { x += s.dx; y += s.dy; pts.push({ x, y }); }
  return pts;
}

function polygonArea(pts) {
  let sum = 0;
  for (let i = 0; i < pts.length - 1; i++) {
    const a = pts[i], b = pts[i+1];
    sum += a.x * b.y - b.x * a.y;
  }
  return Math.abs(sum) / 2;
}

function polygonCentroid(pts) {
  let cx = 0, cy = 0, a = 0;
  for (let i = 0; i < pts.length - 1; i++) {
    const p1 = pts[i], p2 = pts[i+1];
    const cross = p1.x * p2.y - p2.x * p1.y;
    cx += (p1.x + p2.x) * cross;
    cy += (p1.y + p2.y) * cross;
    a += cross;
  }
  a /= 2;
  if (Math.abs(a) < 1e-9) return { x: pts[0].x, y: pts[0].y };
  return { x: cx / (6 * a), y: cy / (6 * a) };
}

function wallVector(shape, i) {
  const a = shape.points[i], b = shape.points[i+1];
  return { x: b.x - a.x, y: b.y - a.y };
}
function wallLength(shape, i) {
  const v = wallVector(shape, i);
  return Math.hypot(v.x, v.y);
}
function wallUnit(shape, i) {
  const v = wallVector(shape, i);
  const len = Math.hypot(v.x, v.y) || 1;
  return { x: v.x / len, y: v.y / len };
}

// ----- Curved walls (circular arcs) -----
// A wall may bow into a circular arc. `shape.arcs = { [wallIdx]: rise }` where
// rise is the sagitta in feet: how far the wall's midpoint sits off the straight
// chord between its two vertices. Positive bows outward (away from the shape's
// interior), negative inward. The vertices stay the chord endpoints, so every
// vertex and wall edit keeps working unchanged; the curve is re-derived from
// the chord and rise each time it is drawn or measured.

// Positive when the ring runs clockwise on screen (Y grows downward).
function polygonSignedArea(pts) {
  let sum = 0;
  for (let i = 0; i < pts.length - 1; i++) {
    const a = pts[i], b = pts[i+1];
    sum += a.x * b.y - b.x * a.y;
  }
  return sum / 2;
}

// Geometry of wall i's arc, or null when the wall is straight.
function wallArc(shape, i) {
  const rise = shape.arcs && shape.arcs[i];
  if (!rise) return null;
  const a = shape.points[i], b = shape.points[i+1];
  if (!a || !b) return null;
  const dx = b.x - a.x, dy = b.y - a.y;
  const c = Math.hypot(dx, dy);
  if (c < 1e-9) return null;
  const s = Math.abs(rise);
  // Outward is left of travel on a clockwise ring, right of travel otherwise.
  const cw = polygonSignedArea(shape.points) >= 0;
  const side = (rise > 0) === cw ? 1 : -1;        // +1 → left normal (dy, -dx)
  const nx = dy / c * side, ny = -dx / c * side;   // unit normal the arc bows toward
  const r = (c * c + 4 * s * s) / (8 * s);
  const half = Math.acos(Math.max(-1, Math.min(1, (r - s) / r)));   // half the central angle
  const mx = (a.x + b.x) / 2, my = (a.y + b.y) / 2;
  return {
    rise, s, c, r, nx, ny,
    apex: { x: mx + nx * s, y: my + ny * s },
    center: { x: mx + nx * (s - r), y: my + ny * (s - r) },
    sweep: side === 1 ? 1 : 0,      // SVG sweep flag: 1 = clockwise on screen
    large: s > r ? 1 : 0,           // past a semicircle
    arcLength: 2 * r * half,
    segmentArea: r * r * half - (r - s) * Math.sqrt(Math.max(0, s * (2 * r - s))),
  };
}

// Set (or clear, with 0) the rise of wall i.
function setWallArc(shape, i, rise) {
  if (!shape.arcs) shape.arcs = {};
  if (rise && Math.abs(rise) > 1e-6) shape.arcs[i] = rise; else delete shape.arcs[i];
  if (!Object.keys(shape.arcs).length) delete shape.arcs;
}

// Re-key a { [wallIdx]: value } map after walls are inserted or removed.
// `fn(oldIdx)` returns the new index, or null to drop the entry.
function remapByWall(map, fn) {
  if (!map) return undefined;
  const o = {};
  for (const k in map) { const j = fn(+k); if (j != null) o[j] = map[k]; }
  return Object.keys(o).length ? o : undefined;
}

// Enclosed area: the polygon through the vertices, plus each outward arc's
// circular segment, minus each inward one.
function shapeArea(shape) {
  let area = polygonArea(shape.points);
  if (shape.arcs) for (const k in shape.arcs) {
    const arc = wallArc(shape, +k);
    if (arc) area += arc.rise > 0 ? arc.segmentArea : -arc.segmentArea;
  }
  return Math.max(0, area);
}

// Points that bound the shape when drawn: its vertices plus, for curved walls,
// the arc's apex and (past a semicircle) its widest points.
function shapeExtentPoints(shape) {
  const pts = shape.points.slice();
  if (shape.arcs) for (const k in shape.arcs) {
    const arc = wallArc(shape, +k);
    if (!arc) continue;
    pts.push(arc.apex);
    if (arc.large) {
      const ux = -arc.ny, uy = arc.nx;   // along the chord
      pts.push({ x: arc.center.x + ux * arc.r, y: arc.center.y + uy * arc.r });
      pts.push({ x: arc.center.x - ux * arc.r, y: arc.center.y - uy * arc.r });
    }
  }
  return pts;
}

// SVG path data for wall i, in whatever space `W` maps points into (screen
// for the canvas, identity for world-coordinate exports). W must be a uniform
// scale plus translation; the arc radius is scaled by the same factor as the chord.
function wallPathD(shape, i, W = p => p, moveTo = true) {
  const a = W(shape.points[i]), b = W(shape.points[i+1]);
  const d = moveTo ? `M${a.x} ${a.y} ` : '';
  const arc = wallArc(shape, i);
  if (!arc) return d + `L${b.x} ${b.y}`;
  const r = arc.r * Math.hypot(b.x - a.x, b.y - a.y) / arc.c;
  return d + `A${r} ${r} 0 ${arc.large} ${arc.sweep} ${b.x} ${b.y}`;
}

// Closed SVG path for the whole outline, curved walls included.
function shapePathD(shape, W = p => p) {
  const p0 = W(shape.points[0]);
  let d = `M${p0.x} ${p0.y}`;
  for (let i = 0; i < shape.points.length - 1; i++) d += ' ' + wallPathD(shape, i, W, false);
  return d + ' Z';
}

function findOpposingWall(shape, wallIdx) {
  const unit = wallUnit(shape, wallIdx);
  const n = shape.points.length - 1;
  let best = null, bestScore = -0.95; // require fairly antiparallel
  for (let j = 0; j < n; j++) {
    if (j === wallIdx) continue;
    const other = wallUnit(shape, j);
    const dot = unit.x * other.x + unit.y * other.y;
    if (dot < bestScore) { bestScore = dot; best = j; }
  }
  return best;
}

// One walk segment describing the straight line from a to b (nearest cardinal
// direction plus signed angle), in the same shape the parser produces.
function segmentBetween(a, b) {
  const dx = b.x - a.x, dy = b.y - a.y;
  const length = Math.hypot(dx, dy);
  const theta = Math.atan2(dy, dx) * 180 / Math.PI;
  const bases = [['r', 0], ['d', 90], ['l', 180], ['u', -90]];
  let best = bases[0], bestDiff = Infinity;
  for (const [d, ba] of bases) {
    let diff = ((theta - ba + 540) % 360) - 180;
    if (Math.abs(diff) < Math.abs(bestDiff)) { bestDiff = diff; best = [d, ba]; }
  }
  return {
    length, dir: best[0], angle: bestDiff, dx, dy,
    raw: `${formatLength(length)} ${best[0]}${Math.abs(bestDiff) > 0.5 ? ' ' + bestDiff.toFixed(1) : ''}`
  };
}

function rebuildSegments(shape) {
  shape.segments = [];
  for (let i = 0; i < shape.points.length - 1; i++) {
    shape.segments.push(segmentBetween(shape.points[i], shape.points[i+1]));
  }
}

function syncClosure(shape, movedIdx) {
  // If we moved the first vertex, copy to last (or vice versa).
  const n = shape.points.length;
  if (movedIdx === 0) shape.points[n-1] = { ...shape.points[0] };
  else if (movedIdx === n-1) shape.points[0] = { ...shape.points[n-1] };
}

// ----- Edit operations -----

function setWallLength(shape, wallIdx, newLength, mode) {
  const unit = wallUnit(shape, wallIdx);
  const curLen = wallLength(shape, wallIdx);
  const delta = newLength - curLen;
  const startIdx = wallIdx;
  const endIdx = wallIdx + 1;

  if (mode === 'stretch-end') {
    shape.points[endIdx].x += unit.x * delta;
    shape.points[endIdx].y += unit.y * delta;
    syncClosure(shape, endIdx);
  } else if (mode === 'stretch-symmetric') {
    shape.points[startIdx].x -= unit.x * delta/2;
    shape.points[startIdx].y -= unit.y * delta/2;
    shape.points[endIdx].x += unit.x * delta/2;
    shape.points[endIdx].y += unit.y * delta/2;
    syncClosure(shape, startIdx); syncClosure(shape, endIdx);
  } else if (mode === 'maintain-rect') {
    const opp = findOpposingWall(shape, wallIdx);
    if (opp === null) {
      setWallLength(shape, wallIdx, newLength, 'stretch-end');
      return;
    }
    // Move end of this wall AND start of opposing wall by delta along this unit.
    shape.points[endIdx].x += unit.x * delta;
    shape.points[endIdx].y += unit.y * delta;
    shape.points[opp].x += unit.x * delta;
    shape.points[opp].y += unit.y * delta;
    syncClosure(shape, endIdx); syncClosure(shape, opp);
  }
  rebuildSegments(shape);
}

function moveWallByVector(shape, wallIdx, vx, vy) {
  const startIdx = wallIdx;
  const endIdx = wallIdx + 1;
  shape.points[startIdx].x += vx;
  shape.points[startIdx].y += vy;
  shape.points[endIdx].x += vx;
  shape.points[endIdx].y += vy;
  syncClosure(shape, startIdx); syncClosure(shape, endIdx);
  rebuildSegments(shape);
}

function moveVertexByVector(shape, vIdx, vx, vy) {
  shape.points[vIdx].x += vx;
  shape.points[vIdx].y += vy;
  syncClosure(shape, vIdx);
  rebuildSegments(shape);
}

function insertVertexOnWall(shape, wallIdx, t = 0.5) {
  const a = shape.points[wallIdx], b = shape.points[wallIdx+1];
  const newP = { x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t };
  shape.points.splice(wallIdx + 1, 0, newP);
  // Keep manual dimension-label nudges with their walls: the split wall's own nudge
  // is dropped (its two halves get fresh auto placement), later walls shift by one.
  if (shape.dimOffsets) {
    const o = {};
    for (const k in shape.dimOffsets) { const i = +k; if (i < wallIdx) o[i] = shape.dimOffsets[k]; else if (i > wallIdx) o[i + 1] = shape.dimOffsets[k]; }
    shape.dimOffsets = Object.keys(o).length ? o : undefined;
  }
  shape.arcs = remapByWall(shape.arcs, i => i < wallIdx ? i : i > wallIdx ? i + 1 : null);
  rebuildSegments(shape);
}

// Returns true on success, false if the caller should bail (shape too small).
// Caller is responsible for confirming via UI; this function does not prompt.
function deleteVertex(shape, vIdx) {
  const n = shape.points.length;
  if (n <= 4) return false;
  // Handle closing vertex case
  if (vIdx === 0 || vIdx === n - 1) {
    shape.points.splice(n - 1, 1);
    shape.points.splice(0, 1);
    shape.points.push({ ...shape.points[0] });
  } else {
    shape.points.splice(vIdx, 1);
  }
  // Manual dimension-label nudges: the two walls that merge lose theirs, the rest
  // keep theirs under the shifted index.
  if (shape.dimOffsets) {
    const o = {};
    if (vIdx === 0 || vIdx === n - 1) {
      // walls 0 and n-2 merge into the new last wall (index n-3); walls 1..n-3 shift down
      for (const k in shape.dimOffsets) { const i = +k; if (i >= 1 && i <= n - 3) o[i - 1] = shape.dimOffsets[k]; }
    } else {
      // walls vIdx-1 and vIdx merge into wall vIdx-1; walls after vIdx shift down
      for (const k in shape.dimOffsets) { const i = +k; if (i < vIdx - 1) o[i] = shape.dimOffsets[k]; else if (i > vIdx) o[i - 1] = shape.dimOffsets[k]; }
    }
    shape.dimOffsets = Object.keys(o).length ? o : undefined;
  }
  shape.arcs = remapByWall(shape.arcs, (vIdx === 0 || vIdx === n - 1)
    ? (i => (i >= 1 && i <= n - 3) ? i - 1 : null)
    : (i => i < vIdx - 1 ? i : i > vIdx ? i - 1 : null));
  rebuildSegments(shape);
  return true;
}

// ----- Removing a wall: the ways an outline can close up without it ----------
// A wall shared with a neighbouring area (the cut a Split leaves) is best removed
// by merging the two areas back into one; otherwise its neighbours either meet
// where their lines cross, or are joined straight across one of its corners.
const WALL_TOL = 0.05;   // ft: points this close are the same point / on the line

function samePt(a, b) { return Math.hypot(a.x - b.x, a.y - b.y) < WALL_TOL; }
// Where p projects onto line a→b (t: 0 at a, 1 at b) and how far off the line it is.
function projectOnto(p, a, b) {
  const dx = b.x - a.x, dy = b.y - a.y, L2 = dx * dx + dy * dy || 1e-12;
  const t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / L2;
  return { t, off: Math.hypot(p.x - (a.x + dx * t), p.y - (a.y + dy * t)) };
}
function ringOf(shape) { return shape.points.slice(0, -1).map(p => ({ x: p.x, y: p.y })); }
// Make p a vertex of the ring (inserting it into the wall it lies on); its index.
function ringVertex(ring, p) {
  const i = ring.findIndex(q => samePt(q, p));
  if (i >= 0) return i;
  for (let k = 0; k < ring.length; k++) {
    const a = ring[k], b = ring[(k + 1) % ring.length], pr = projectOnto(p, a, b);
    if (pr.off < WALL_TOL && pr.t > 0 && pr.t < 1) { ring.splice(k + 1, 0, { x: p.x, y: p.y }); return k + 1; }
  }
  return -1;
}
// Drop the vertex at ring[i] if it is now just a point on a straight wall.
function dropIfStraight(ring, p) {
  const i = ring.findIndex(q => samePt(q, p));
  if (i < 0 || ring.length <= 3) return;
  const a = ring[(i - 1 + ring.length) % ring.length], b = ring[(i + 1) % ring.length];
  const pr = projectOnto(ring[i], a, b);
  if (pr.off < WALL_TOL && pr.t > 0 && pr.t < 1) ring.splice(i, 1);
}
// Curved walls survive a merge when the same wall (either direction) is in the result.
function carryArcs(points, sources) {
  const o = {};
  for (let i = 0; i < points.length - 1; i++) {
    const u = points[i], v = points[i + 1];
    for (const sh of sources) {
      if (!sh.arcs) continue;
      for (const k in sh.arcs) {
        const a = sh.points[+k], b = sh.points[+k + 1];
        if ((samePt(a, u) && samePt(b, v)) || (samePt(a, v) && samePt(b, u))) o[i] = sh.arcs[k];
      }
    }
  }
  return Object.keys(o).length ? o : undefined;
}

// The part of wall `wi` of `a` that also bounds `b` (collinear and overlapping by
// more than half a foot), as parameters along the wall, or null.
function sharedWallSpan(a, wi, b) {
  const p = a.points[wi], q = a.points[wi + 1], L = Math.hypot(q.x - p.x, q.y - p.y);
  if (L < WALL_TOL) return null;
  for (let j = 0; j < b.points.length - 1; j++) {
    const u = projectOnto(b.points[j], p, q), v = projectOnto(b.points[j + 1], p, q);
    if (u.off > WALL_TOL || v.off > WALL_TOL) continue;
    const t0 = Math.max(0, Math.min(u.t, v.t)), t1 = Math.min(1, Math.max(u.t, v.t));
    if ((t1 - t0) * L > 0.5) return { t0, t1 };
  }
  return null;
}

// One outline for `a` and `b` joined across wall `wi` of `a`, or null when they
// do not share it cleanly (the merged area must equal the two areas added up).
function mergeAcrossWall(a, wi, b) {
  const span = sharedWallSpan(a, wi, b);
  if (!span) return null;
  const p = a.points[wi], q = a.points[wi + 1];
  const at = t => ({ x: p.x + (q.x - p.x) * t, y: p.y + (q.y - p.y) * t });
  const s = at(span.t0), t = at(span.t1);
  const A = ringOf(a), B = ringOf(b);
  const as = ringVertex(A, s), atI = ringVertex(A, t);
  if (as < 0 || atI < 0) return null;
  const bs = ringVertex(B, s), bt = ringVertex(B, t);
  if (bs < 0 || bt < 0) return null;
  // Orient so A has the shared wall as head→tail; walk A from tail round to head,
  // then B (run the other way along the shared wall) from head round to tail.
  const n = A.length, m = B.length, idx = (R, p) => R.findIndex(r => samePt(r, p));
  let head = s, tail = t;
  if (!samePt(A[(idx(A, s) + 1) % n], t)) { if (!samePt(A[(idx(A, t) + 1) % n], s)) return null; head = t; tail = s; }
  let Bw = B;
  if (!samePt(Bw[(idx(Bw, tail) + 1) % m], head)) {
    Bw = B.slice().reverse();
    if (!samePt(Bw[(idx(Bw, tail) + 1) % m], head)) return null;
  }
  const out = [];
  for (let k = idx(A, tail); ; k = (k + 1) % n) { out.push(A[k]); if (samePt(A[k], head)) break; }
  for (let k = (idx(Bw, head) + 1) % m; !samePt(Bw[k], tail); k = (k + 1) % m) out.push(Bw[k]);
  dropIfStraight(out, s); dropIfStraight(out, t);
  for (let k = out.length - 1; k > 0; k--) if (samePt(out[k], out[k - 1])) out.splice(k, 1);
  if (out.length < 3) return null;
  const points = [...out, { ...out[0] }];
  const merged = { points, arcs: carryArcs(points, [a, b]) };
  if (Math.abs(shapeArea(merged) - shapeArea(a) - shapeArea(b)) > 1) return null;
  return merged;
}

// Wall `wi` removed by running its two neighbours on until their lines cross.
// Null when they are parallel or would meet unreasonably far away.
function extendNeighboursAcross(shape, wi) {
  const ring = ringOf(shape), n = ring.length;
  if (n < 4) return null;
  const p0 = ring[(wi - 1 + n) % n], p = ring[wi], q = ring[(wi + 1) % n], q1 = ring[(wi + 2) % n];
  const d1 = { x: p.x - p0.x, y: p.y - p0.y }, d2 = { x: q1.x - q.x, y: q1.y - q.y };
  const den = d1.x * d2.y - d1.y * d2.x;
  if (Math.abs(den) < 1e-9) return null;
  const k = ((q.x - p0.x) * d2.y - (q.y - p0.y) * d2.x) / den;
  const X = { x: p0.x + d1.x * k, y: p0.y + d1.y * k };
  const wl = Math.hypot(q.x - p.x, q.y - p.y);
  if (Math.hypot(X.x - p.x, X.y - p.y) > 3 * wl + 10 || Math.hypot(X.x - q.x, X.y - q.y) > 3 * wl + 10) return null;
  if (samePt(X, p) || samePt(X, q)) return null;   // that is just dropping a corner
  const out = ring.slice();
  out[wi] = X;
  out.splice((wi + 1) % n, 1);
  if (out.length < 3) return null;
  return [...out, { ...out[0] }];
}

// ----- Auto-extend (snap to next aligned vertex) -----
// Returns sorted candidates (closest first), each with { along, point, segment }.
function findAlignedCandidates(priorSegments, dir, start, shapes) {
  let x = start.x, y = start.y;
  const pts = [{ x, y }];
  for (const s of priorSegments) { x += s.dx; y += s.dy; pts.push({ x, y }); }
  const pen = pts[pts.length - 1];

  const rad = DIR_BASE[dir] * Math.PI / 180;
  const dx = Math.cos(rad), dy = Math.sin(rad);
  const tol = 0.05;
  const minForward = 0.01;

  const seen = new Set();
  const out = [];
  function add(p) {
    const key = `${p.x.toFixed(3)},${p.y.toFixed(3)}`;
    if (seen.has(key)) return;
    const along = (p.x - pen.x) * dx + (p.y - pen.y) * dy;
    const perp = Math.abs((p.x - pen.x) * (-dy) + (p.y - pen.y) * dx);
    if (along > minForward && perp < tol) {
      seen.add(key);
      out.push({
        along,
        point: { x: p.x, y: p.y },
        segment: { length: along, dir, angle: 0, dx: dx * along, dy: dy * along, raw: `${formatLength(along)} ${dir} (auto)` },
      });
    }
  }
  for (const sh of shapes) for (let i = 0; i < sh.points.length - 1; i++) add(sh.points[i]);
  for (const p of pts) add(p);

  // Perpendicular-projection candidates, ALWAYS merged in (not just a fallback).
  // A landing point where walking in `dir` brings the pen's MOVING coordinate in line
  // with another vertex — i.e. "walk up until my Y matches that vertex's Y". This gives
  // the nearer alignment options (e.g. line up with each step of a staircase) in addition
  // to any vertex sitting directly on the ray, so there's more than one candidate to
  // cycle through. On-ray hits already added above are de-duped by landing-point key.
  const isHoriz = Math.abs(dx) > Math.abs(dy);   // r/l move X; u/d move Y
  function addProj(p) {
    const perp = Math.abs((p.x - pen.x) * (-dy) + (p.y - pen.y) * dx);
    if (perp < tol) return;                      // already added as an on-ray candidate
    const landing = isHoriz ? { x: p.x, y: pen.y } : { x: pen.x, y: p.y };
    const along = (landing.x - pen.x) * dx + (landing.y - pen.y) * dy;
    if (along <= minForward) return;             // must be a forward walk in `dir`
    const key = `${landing.x.toFixed(3)},${landing.y.toFixed(3)}`;
    if (seen.has(key)) return;
    seen.add(key);
    out.push({
      along,
      point: landing,
      segment: { length: along, dir, angle: 0, dx: dx * along, dy: dy * along, raw: `${formatLength(along)} ${dir} (align)` },
    });
  }
  for (const sh of shapes) for (let i = 0; i < sh.points.length - 1; i++) addProj(sh.points[i]);
  for (const p of pts) addProj(p);

  out.sort((a, b) => a.along - b.along);
  return out;
}
