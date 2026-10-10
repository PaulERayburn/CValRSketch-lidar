import CoreGraphics
import Foundation
import RoomPlan
import simd

// Field assumptions until readings or the outside walk say otherwise.
enum Assume {
    static let partitionInches = 4.5    // 2×4 stud plus drywall both sides
    static let exteriorInches = 6.0     // 2×4 wall plus sheathing and siding
}

// One scanned wall as drawn: feet, rotated so the house sits square.
struct PlanWall: Identifiable {
    let id: UUID
    let story: Int
    let a: CGPoint
    let b: CGPoint
    let normal: CGVector         // (−dy, dx) of a→b, unit length; sideSign +1 means this side
    let labelSign: Int           // the side the scan was taken from
    let exterior: Bool           // floor on one side only
    let rooms: [Int: String]     // room name on each side, keyed by side sign
    let scanInches: Int

    var length: CGFloat { hypot(b.x - a.x, b.y - a.y) }
    var direction: CGVector { CGVector(dx: (b.x - a.x) / max(length, 0.001), dy: (b.y - a.y) / max(length, 0.001)) }
    func sideVector(_ sign: Int) -> CGVector { CGVector(dx: normal.dx * CGFloat(sign), dy: normal.dy * CGFloat(sign)) }
    func roomName(_ sign: Int) -> String { rooms[sign] ?? (sign == labelSign ? "this side" : "the other side") }
}

struct PlanFeature {
    enum Kind { case door, entrance, window, opening }
    let kind: Kind
    let story: Int
    let a: CGPoint
    let b: CGPoint
    var id: UUID? = nil          // the scan's door or opening
    var wall: UUID? = nil        // the wall it is in
    var hingeAtB = false         // doors: which end the leaf turns on
    var side = 1                 // doors: +1 opens to the normal (−dy, dx) side of a→b
    var style = DoorStyle.swing
}

// A stretch of one face that a single laser reading covers: collinear
// segments joined where nothing meets them on the measured side.
struct WallRun {
    var walls: [PlanWall]
    var start: CGPoint
    var end: CGPoint
    var startWall: PlanWall?     // the wall closing each end of the face
    var endWall: PlanWall?
    var sign: Int
    var outside: Bool
}

// A floor edge with no wall along it (feet, as drawn), and what fills it.
struct PlanGap: Identifiable {
    let id: Int
    let story: Int
    let a: CGPoint
    let b: CGPoint
    let worldA: SIMD2<Double>
    let worldB: SIMD2<Double>
    var depth: GapDepth?
    var filled = false

    var length: CGFloat { hypot(b.x - a.x, b.y - a.y) }
    var direction: CGVector { CGVector(dx: (b.x - a.x) / max(length, 0.001), dy: (b.y - a.y) / max(length, 0.001)) }
    var middle: CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
}

// A wall the scan missed, placed from a marked point or a laser depth.
struct HiddenLine {
    let story: Int
    let a: CGPoint
    let b: CGPoint
    var wallPoint: Int? = nil        // index into wallPoints, when a marked point placed it
    var depth: GapDepth? = nil       // the laser depth, when one placed it
}

struct PlanGeometry {
    var walls: [PlanWall] = []
    var features: [PlanFeature] = []
    var floors: [(story: Int, points: [CGPoint])] = []
    var photos: [(id: String, story: Int, at: CGPoint, dir: CGVector)] = []
    // Stairs on each floor they touch (Stairs.swift): pieces, and walking lines with UP or DN.
    var stairPieces: [(id: UUID, index: Int, story: Int, outline: [CGPoint], treads: [(CGPoint, CGPoint)])] = []
    var stairPaths: [(story: Int, points: [CGPoint], label: String)] = []
    var sections: [(story: Int, label: String, center: CGPoint)] = []
    var exteriorLines: [(a: CGPoint, b: CGPoint)] = []
    var gaps: [PlanGap] = []
    var rooms: [(story: Int, name: String, center: CGPoint, source: RoomSource)] = []
    var addedOpenings: [(index: Int, story: Int, a: CGPoint, b: CGPoint)] = []
    var hiddenLines: [HiddenLine] = []
    var wallPoints: [(story: Int, point: CGPoint)] = []
    var spans: [(a: CGPoint, b: CGPoint, reading: SpanReading)] = []
    var angle = 0.0                            // radians the world turns to sit square
    var stories: [Int] { Array(Set(walls.map(\.story))).sorted() }
    var openGaps: [PlanGap] { gaps.filter { !$0.filled } }

    // World metres (x, z) to plan feet, and back.
    func plan(_ w: SIMD2<Double>) -> CGPoint {
        let c = cos(angle), s = sin(angle), ft = 3.28084
        return CGPoint(x: (w.x * c - w.y * s) * ft, y: (w.x * s + w.y * c) * ft)
    }

    func world(_ p: CGPoint) -> SIMD2<Double> {
        let c = cos(angle), s = sin(angle), ft = 3.28084
        let x = Double(p.x) / ft, y = Double(p.y) / ft
        return SIMD2(x * c + y * s, -x * s + y * c)
    }

    // The corners a reading can run between: where scanned walls end, and where
    // two walls cross or meet partway along. RoomPlan often runs a wall past the
    // corner it turns at, so the real corner is only where the two lines cross.
    // The floor above, to draw faintly under this one and snap to: its walls
    // and the edges and corners of its floor.
    func aboveLines(story: Int) -> [(CGPoint, CGPoint)] {
        walls.filter { $0.story == story + 1 }.map { ($0.a, $0.b) }
            + floors.filter { $0.story == story + 1 }.flatMap { f in f.points.indices.map { (f.points[$0], f.points[($0 + 1) % f.points.count]) } }
    }
    func aboveCorners(story: Int) -> [CGPoint] { aboveLines(story: story).flatMap { [$0.0, $0.1] } }

    func corners(story: Int) -> [CGPoint] {
        var out: [CGPoint] = []
        func add(_ p: CGPoint) {
            if !out.contains(where: { hypot($0.x - p.x, $0.y - p.y) < 0.3 }) { out.append(p) }
        }
        let ws = walls.filter { $0.story == story }
        for w in ws { add(w.a); add(w.b) }
        // Walls the scan missed have corners too: where a gap in the floor
        // outline ends (a closet the coats hid), and a hidden wall's ends.
        for g in gaps where g.story == story { add(g.a); add(g.b) }
        for l in hiddenLines where l.story == story { add(l.a); add(l.b) }
        for i in ws.indices {
            for j in ws.indices where j > i {
                let p = ws[i], q = ws[j]
                let d1 = CGVector(dx: p.b.x - p.a.x, dy: p.b.y - p.a.y)
                let d2 = CGVector(dx: q.b.x - q.a.x, dy: q.b.y - q.a.y)
                let den = d1.dx * d2.dy - d1.dy * d2.dx
                // Nearly parallel walls don't make a corner.
                guard abs(den) > 0.2 * p.length * q.length else { continue }
                let t = ((q.a.x - p.a.x) * d2.dy - (q.a.y - p.a.y) * d2.dx) / den
                let u = ((q.a.x - p.a.x) * d1.dy - (q.a.y - p.a.y) * d1.dx) / den
                // On both walls, allowing a few inches past either end.
                let st = 0.3 / max(p.length, 0.01), su = 0.3 / max(q.length, 0.01)
                guard t > -st, t < 1 + st, u > -su, u < 1 + su else { continue }
                add(CGPoint(x: p.a.x + d1.dx * t, y: p.a.y + d1.dy * t))
            }
        }
        return out
    }

    // Feet between two corners along the house's main direction (the plan is
    // drawn square), the way a laser is run along a wall.
    static func along(_ a: CGPoint, _ b: CGPoint) -> CGFloat { max(abs(b.x - a.x), abs(b.y - a.y)) }

    // What a reading between two scanned (inside) corners should be. Inside,
    // face to face. Outside, siding corner to siding corner: one wall thickness
    // further at an outside corner, where the house ends; nothing extra at an
    // inside corner, where the house carries on past it (the step in an L), as
    // the siding there is set in by the same thickness as the wall it meets.
    func spanEstimate(_ a: CGPoint, _ b: CGPoint, story: Int, outside: Bool) -> Int {
        var inches = Double(Self.along(a, b)) * 12
        guard outside else { return Int(inches.rounded()) }
        let polys = floors.filter { $0.story == story }.map(\.points)
        func inside(_ p: CGPoint) -> Bool { polys.contains { ScanController.inside(p, $0) } }
        let horizontal = abs(b.x - a.x) >= abs(b.y - a.y)
        // Which side of the measured line the house is on.
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let n: CGVector = horizontal ? CGVector(dx: 0, dy: 1) : CGVector(dx: 1, dy: 0)
        let sign: CGFloat = inside(CGPoint(x: mid.x + n.dx * 0.75, y: mid.y + n.dy * 0.75)) ? 1 : -1
        for (end, other) in [(a, b), (b, a)] {
            let ux: CGFloat = horizontal ? (end.x > other.x ? 1 : -1) : 0
            let uy: CGFloat = horizontal ? 0 : (end.y > other.y ? 1 : -1)
            let past = CGPoint(x: end.x + ux * 0.75 + n.dx * sign * 0.75, y: end.y + uy * 0.75 + n.dy * sign * 0.75)
            inches += inside(past) ? 0 : Assume.exteriorInches
        }
        return Int(inches.rounded())
    }

    static let touch: CGFloat = 0.35          // feet: ends this close count as meeting

    func wall(_ id: UUID) -> PlanWall? { walls.first { $0.id == id } }

    private func distance(_ p: CGPoint, toSegment w: PlanWall) -> CGFloat {
        let dx = w.b.x - w.a.x, dy = w.b.y - w.a.y
        let len2 = max(dx * dx + dy * dy, 0.0001)
        let t = min(max(((p.x - w.a.x) * dx + (p.y - w.a.y) * dy) / len2, 0), 1)
        return hypot(p.x - (w.a.x + t * dx), p.y - (w.a.y + t * dy))
    }

    private func far(_ w: PlanWall, from p: CGPoint) -> CGPoint {
        hypot(w.a.x - p.x, w.a.y - p.y) > hypot(w.b.x - p.x, w.b.y - p.y) ? w.a : w.b
    }

    private func reach(_ w: PlanWall, from p: CGPoint, toward s: CGVector) -> CGFloat {
        let f = far(w, from: p)
        return (f.x - p.x) * s.dx + (f.y - p.y) * s.dy
    }

    func run(from w: PlanWall, sign: Int, outside: Bool) -> WallRun {
        let s = w.sideVector(sign)
        var members = [w]
        var ids: Set<UUID> = [w.id]
        let dir = w.direction
        func extend(from start: CGPoint, away: CGFloat) -> (CGPoint, PlanWall?) {
            var q = start
            while true {
                let near = walls.filter { $0.story == w.story && !ids.contains($0.id) && distance(q, toSegment: $0) < Self.touch }
                let collinear = near.filter { abs($0.direction.dx * dir.dx + $0.direction.dy * dir.dy) > 0.995 }
                let turning = near.filter { abs($0.direction.dx * dir.dx + $0.direction.dy * dir.dy) <= 0.995 }
                // A wall heading into the measured side closes the face here.
                if let closer = turning.filter({ reach($0, from: q, toward: s) > 0.3 })
                    .max(by: { $0.length < $1.length }) {
                    return (q, closer)
                }
                guard let next = collinear.first(where: {
                    let f = far($0, from: q)
                    return ((f.x - q.x) * dir.dx + (f.y - q.y) * dir.dy) * away > 0.1
                }) else {
                    return (q, turning.max(by: { $0.length < $1.length }))
                }
                members.append(next)
                ids.insert(next.id)
                q = far(next, from: q)
            }
        }
        let (start, startWall) = extend(from: w.a, away: -1)
        let (end, endWall) = extend(from: w.b, away: 1)
        return WallRun(walls: members, start: start, end: end, startWall: startWall,
                       endWall: endWall, sign: sign, outside: outside)
    }

    // What a laser should read along the run, face to face. Inside, a
    // partition closing the face is assumed to sit centred on its scanned
    // line; outside, each corner adds or removes an exterior wall thickness.
    func estimateInches(_ r: WallRun) -> Int {
        var inches = Double(hypot(r.end.x - r.start.x, r.end.y - r.start.y)) * 12
        guard let w = r.walls.first else { return 0 }
        let s = w.sideVector(r.sign)
        for (q, e) in [(r.start, r.startWall), (r.end, r.endWall)] {
            guard let e else { continue }
            let into = reach(e, from: q, toward: s) > 0
            if r.outside {
                inches += into ? -Assume.exteriorInches : Assume.exteriorInches
            } else if into, !e.exterior {
                inches -= Assume.partitionInches / 2
            }
        }
        return Int(inches.rounded())
    }

    // Single-segment estimate used for the plan's labels.
    func labelInches(_ w: PlanWall) -> Int {
        estimateInches(WallRun(walls: [w], start: w.a, end: w.b,
                               startWall: closingWall(at: w.a, of: w, sign: w.labelSign),
                               endWall: closingWall(at: w.b, of: w, sign: w.labelSign),
                               sign: w.labelSign, outside: false))
    }

    private func closingWall(at q: CGPoint, of w: PlanWall, sign: Int) -> PlanWall? {
        let s = w.sideVector(sign), dir = w.direction
        return walls.filter {
            $0.story == w.story && $0.id != w.id && distance(q, toSegment: $0) < Self.touch
                && abs($0.direction.dx * dir.dx + $0.direction.dy * dir.dy) <= 0.995
                && reach($0, from: q, toward: s) > 0.3
        }.max { $0.length < $1.length }
    }

    // The less trusted end gives way: a wall with its own reading beats an
    // exterior wall, which beats a partition. Equal trust splits the change.
    func autoMoving(_ r: WallRun, measured: Set<UUID>) -> [UUID] {
        func trust(_ w: PlanWall?) -> Int {
            guard let w else { return 99 }
            return (measured.contains(w.id) ? 2 : 0) + (w.exterior ? 1 : 0)
        }
        let ts = trust(r.startWall), te = trust(r.endWall)
        if ts < te { return [r.startWall!.id] }
        if te < ts { return [r.endWall!.id] }
        return Array(Set([r.startWall?.id, r.endWall?.id].compactMap { $0 }))
    }

    // "left end", "top end"… on the squared plan as drawn (y grows down).
    func endName(_ r: WallRun, start: Bool) -> String {
        let p = start ? r.start : r.end, o = start ? r.end : r.start
        if abs(r.end.x - r.start.x) >= abs(r.end.y - r.start.y) {
            return p.x < o.x ? "left end" : "right end"
        }
        return p.y < o.y ? "top end" : "bottom end"
    }

    // The scanned wall a laser depth across a gap starts from: parallel to
    // the gap, facing it across the floor, nearest first, within 12 ft.
    // `toward` points from that wall to the gap.
    func referenceWall(for gap: PlanGap) -> (wall: PlanWall, toward: CGVector)? {
        let d = gap.direction, m = gap.middle
        var n = CGVector(dx: -d.dy, dy: d.dx)
        let probe = CGPoint(x: m.x + n.dx * 0.5, y: m.y + n.dy * 0.5)
        if !floors.contains(where: { $0.story == gap.story && ScanController.inside(probe, $0.points) }) {
            n = CGVector(dx: -n.dx, dy: -n.dy)
        }
        var best: (wall: PlanWall, t: CGFloat)?
        for w in walls where w.story == gap.story && abs(w.direction.dx * d.dx + w.direction.dy * d.dy) > 0.95 {
            let t = (w.a.x - m.x) * n.dx + (w.a.y - m.y) * n.dy
            guard t > 0.3, t < 12 else { continue }
            let hit = CGPoint(x: m.x + n.dx * t, y: m.y + n.dy * t)
            let along = (hit.x - w.a.x) * w.direction.dx + (hit.y - w.a.y) * w.direction.dy
            guard along > -0.5, along < w.length + 0.5 else { continue }
            if best == nil || t < best!.t { best = (w, t) }
        }
        return best.map { ($0.wall, CGVector(dx: -n.dx, dy: -n.dy)) }
    }

    // The hidden wall a laser depth puts across a gap: the reference wall's
    // line moved toward the gap by half a partition (the reading starts at
    // its face) plus the reading, spanning the gap.
    func depthLine(_ gap: PlanGap, _ depth: GapDepth) -> HiddenLine? {
        guard let ref = referenceWall(for: gap), ref.wall.id == depth.from else { return nil }
        let w = ref.wall, n = w.normal
        let offset = (Double(depth.inches) + Assume.partitionInches / 2) / 12
        func place(_ p: CGPoint) -> CGPoint {
            let onLine = (p.x - w.a.x) * n.dx + (p.y - w.a.y) * n.dy
            return CGPoint(x: p.x - n.dx * onLine + ref.toward.dx * offset,
                           y: p.y - n.dy * onLine + ref.toward.dy * offset)
        }
        return HiddenLine(story: gap.story, a: place(gap.a), b: place(gap.b))
    }

    // Measured exterior wall thickness, when the outside walk has a line
    // parallel to this wall's outer side.
    func measuredThickness(_ w: PlanWall) -> Double? {
        guard w.exterior else { return nil }
        let out = w.sideVector(-w.labelSign), dir = w.direction
        let mid = CGPoint(x: (w.a.x + w.b.x) / 2, y: (w.a.y + w.b.y) / 2)
        var best: Double?
        for l in exteriorLines {
            let len = max(hypot(l.b.x - l.a.x, l.b.y - l.a.y), 0.001)
            let ld = CGVector(dx: (l.b.x - l.a.x) / len, dy: (l.b.y - l.a.y) / len)
            guard abs(ld.dx * dir.dx + ld.dy * dir.dy) > 0.98 else { continue }
            let gap = Double((l.a.x - mid.x) * out.dx + (l.a.y - mid.y) * out.dy) * 12
            let along = (mid.x - l.a.x) * ld.dx + (mid.y - l.a.y) * ld.dy
            guard gap > 1, gap < 24, along > -1, along < len + 1 else { continue }
            if best == nil || gap < best! { best = gap }
        }
        return best
    }
}

extension ScanController {
    var planGeometry: PlanGeometry {
        guard let structure else { return PlanGeometry() }
        let ft = 3.28084
        let segs = structure.walls.compactMap { w in edited(PlanExport.segment(w)).map { (w, $0) } }
        // Length-weighted mean of 4×angle finds the dominant wall direction
        // whatever quadrant the walls point in.
        var sx = 0.0, sy = 0.0
        for (_, s) in segs {
            let dx = s.b[0] - s.a[0], dy = s.b[1] - s.a[1]
            let len = hypot(dx, dy), t = atan2(dy, dx) * 4
            sx += len * cos(t)
            sy += len * sin(t)
        }
        let th = -atan2(sy, sx) / 4, c = cos(th), sn = sin(th)
        func rot(_ p: [Double]) -> CGPoint {
            CGPoint(x: (p[0] * c - p[1] * sn) * ft, y: (p[0] * sn + p[1] * c) * ft)
        }

        var g = PlanGeometry()
        g.angle = th
        g.floors = structure.floors.map { f in (f.story, PlanExport.floor(f).polygon.map(rot)) }
        g.rooms = resolvedRooms(structure).map { r in (r.story, r.name, rot([r.center.x, r.center.y]), r.source) }
        g.sections = g.rooms.map { ($0.story, $0.name, $0.center) }
        for (kind, list) in [(PlanFeature.Kind.door, structure.doors),
                             (.window, structure.windows), (.opening, structure.openings)] {
            g.features += list.filter { !hiddenOpenings.contains($0.identifier) }.map { s in
                let seg = PlanExport.segment(s)
                return PlanFeature(kind: kind, story: s.story, a: rot(seg.a), b: rot(seg.b),
                                   id: s.identifier, wall: s.parentIdentifier,
                                   side: kind == .door ? PlanExport.defaultSide(a: seg.a, b: seg.b, story: s.story,
                                                                               floors: structure.floors.map(PlanExport.floor)) : 1,
                                   style: kind == .door ? DoorStyle.forScanned(metres: hypot(seg.b[0] - seg.a[0], seg.b[1] - seg.a[1])) : .swing)
            }
        }
        for (i, o) in addedOpenings.enumerated() {
            let a = rot([o.a.x, o.a.y]), b = rot([o.b.x, o.b.y])
            g.features.append(PlanFeature(kind: o.kind == .entrance ? .entrance : o.kind == .interior ? .door : o.kind == .window ? .window : .opening,
                                          story: o.story, a: a, b: b, hingeAtB: o.hingeAtB, side: o.side, style: o.style))
            g.addedOpenings.append((i, o.story, a, b))
        }
        g.walls = segs.map { surface, s in
            let a = rot(s.a), b = rot(s.b)
            let len = max(hypot(b.x - a.x, b.y - a.y), 0.001)
            let n = CGVector(dx: -(b.y - a.y) / len, dy: (b.x - a.x) / len)
            let (labelSign, exterior, rooms) = Self.sides(a: a, b: b, n: n, story: s.story, geometry: g)
            return PlanWall(id: surface.identifier, story: s.story, a: a, b: b, normal: n,
                            labelSign: labelSign, exterior: exterior, rooms: rooms,
                            scanInches: Feet.inches(meters: Double(surface.dimensions.x)))
        }
        // Walls the user drew, alongside the scanned ones.
        for w in addedWalls {
            let a = rot([w.a.x, w.a.y]), b = rot([w.b.x, w.b.y])
            let len = max(hypot(b.x - a.x, b.y - a.y), 0.001)
            let n = CGVector(dx: -(b.y - a.y) / len, dy: (b.x - a.x) / len)
            let (labelSign, exterior, rooms) = Self.sides(a: a, b: b, n: n, story: w.story, geometry: g)
            g.walls.append(PlanWall(id: w.id, story: w.story, a: a, b: b, normal: n, labelSign: labelSign,
                                    exterior: exterior, rooms: rooms,
                                    scanInches: Feet.inches(meters: simd_distance(w.a, w.b))))
        }
        g.exteriorLines = exteriorPlanLines.map { line in
            (rot([line.a.x, line.a.y]), rot([line.b.x, line.b.y]))
        }
        addHiddenWalls(to: &g, structure: structure)
        let drawing = StairDrawing(chains: addedStairs, structure: structure, edits: stairEdits)
        g.stairPieces = drawing.pieces.map { p in (p.id, p.index, p.story, p.outline.map { g.plan($0) }, p.treads.map { (g.plan($0.0), g.plan($0.1)) }) }
        g.stairPaths = drawing.paths.map { ($0.story, $0.points.map { g.plan($0) }, $0.label) }
        // Photos go on the floor the phone stood over.
        let levels = structure.floors.map { ($0.story, $0.transform.columns.3.y) }
        g.photos = photos.map { p in
            let story = levels.filter { $0.1 <= p.point.y - 0.3 }.max { $0.1 < $1.1 }?.0
                ?? levels.min { $0.1 < $1.1 }?.0 ?? 0
            let at = g.plan(SIMD2(Double(p.point.x), Double(p.point.z)))
            let tip = g.plan(SIMD2(Double(p.point.x + p.facing.x), Double(p.point.z + p.facing.y)))
            let len = max(hypot(tip.x - at.x, tip.y - at.y), 0.001)
            return (p.id, story, at, CGVector(dx: (tip.x - at.x) / len, dy: (tip.y - at.y) / len))
        }
        g.spans = spans.map { (g.plan($0.a), g.plan($0.b), $0) }
        return g
    }

    // Gaps in the floor outline, filled by laser depths and by points marked
    // on hidden walls. A point's wall runs square to the house, along
    // whichever main direction is nearer its facing.
    private func addHiddenWalls(to g: inout PlanGeometry, structure: CapturedStructure) {
        // Walls the user drew close gaps too.
        let segments = (structure.walls + structure.doors + structure.windows + structure.openings)
            .map(PlanExport.segment)
            + addedWalls.map { PlanExport.Segment(id: $0.id.uuidString, story: $0.story, a: [$0.a.x, $0.a.y], b: [$0.b.x, $0.b.y],
                                                  height: 2.4, bottom: 0, wall: nil, curved: false) }
        let found = PlanExport.gaps(floors: structure.floors.map(PlanExport.floor), segments: segments)
        g.gaps = found.enumerated().map { i, gap in
            let a = SIMD2(gap.a[0], gap.a[1]), b = SIMD2(gap.b[0], gap.b[1])
            let depth = gapDepths.first { simd_distance($0.middle, (a + b) / 2) < 0.5 }
            return PlanGap(id: i, story: gap.story, a: g.plan(a), b: g.plan(b), worldA: a, worldB: b, depth: depth)
        }
        for i in g.gaps.indices {
            if let d = g.gaps[i].depth, var line = g.depthLine(g.gaps[i], d) {
                line.depth = d
                g.hiddenLines.append(line)
                g.gaps[i].filled = true
            }
        }
        let floorLevels = structure.floors.map { ($0.story, $0.transform.columns.3.y) }
        for (wpIndex, wp) in wallPoints.enumerated() {
            let story = floorLevels.filter { $0.1 <= wp.point.y + 0.3 }.max { $0.1 < $1.1 }?.0
                ?? floorLevels.first?.0 ?? 0
            let p = g.plan(SIMD2(Double(wp.point.x), Double(wp.point.z)))
            let o = g.plan(.zero), f = g.plan(SIMD2(Double(wp.normal.x), Double(wp.normal.z)))
            let facing = CGVector(dx: f.x - o.x, dy: f.y - o.y)
            let dir = abs(facing.dx) > abs(facing.dy) ? CGVector(dx: 0, dy: 1) : CGVector(dx: 1, dy: 0)
            g.wallPoints.append((story, p))
            func along(_ q: CGPoint) -> CGFloat { (q.x - p.x) * dir.dx + (q.y - p.y) * dir.dy }
            func across(_ q: CGPoint) -> CGFloat { (q.x - p.x) * dir.dy - (q.y - p.y) * dir.dx }
            // The nearest parallel gap within 3 ft is the one this point fills.
            let match = g.gaps.indices.filter { i in
                let gap = g.gaps[i]
                let lo = min(along(gap.a), along(gap.b)), hi = max(along(gap.a), along(gap.b))
                return gap.story == story && abs(gap.direction.dx * dir.dx + gap.direction.dy * dir.dy) > 0.9
                    && abs(across(gap.middle)) < 3 && lo < 1 && hi > -1
            }.min { abs(across(g.gaps[$0].middle)) < abs(across(g.gaps[$1].middle)) }
            var lo: CGFloat = -1.5, hi: CGFloat = 1.5
            if let i = match {
                lo = min(along(g.gaps[i].a), along(g.gaps[i].b), 0) - 0.5
                hi = max(along(g.gaps[i].a), along(g.gaps[i].b), 0) + 0.5
                g.gaps[i].filled = true
            }
            g.hiddenLines.append(HiddenLine(story: story,
                                            a: CGPoint(x: p.x + dir.dx * lo, y: p.y + dir.dy * lo),
                                            b: CGPoint(x: p.x + dir.dx * hi, y: p.y + dir.dy * hi),
                                            wallPoint: wpIndex))
        }
    }

    // The side with floor is the side that was scanned. With floor on both
    // sides (a partition), the label goes to the side of the nearer room name.
    private static func sides(a: CGPoint, b: CGPoint, n: CGVector, story: Int,
                              geometry g: PlanGeometry) -> (Int, Bool, [Int: String]) {
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let p1 = CGPoint(x: mid.x + n.dx * 0.75, y: mid.y + n.dy * 0.75)
        let p2 = CGPoint(x: mid.x - n.dx * 0.75, y: mid.y - n.dy * 0.75)
        let floors = g.floors.filter { $0.story == story }.map(\.points)
        let in1 = floors.contains { inside(p1, $0) }, in2 = floors.contains { inside(p2, $0) }
        var rooms: [Int: String] = [:]
        for sign in [1, -1] {
            let named = g.sections.filter {
                $0.story == story && !$0.label.isEmpty
                    && (($0.center.x - mid.x) * n.dx + ($0.center.y - mid.y) * n.dy) * CGFloat(sign) > 0
            }
            if let room = named.min(by: { hypot($0.center.x - mid.x, $0.center.y - mid.y)
                    < hypot($1.center.x - mid.x, $1.center.y - mid.y) }) {
                rooms[sign] = room.label
            }
        }
        if in1 != in2 {
            let sign = in1 ? 1 : -1
            return (sign, true, rooms.filter { $0.key == sign })
        }
        let centers = g.sections.filter { $0.story == story }.map(\.center)
        func nearest(_ p: CGPoint) -> CGFloat { centers.map { hypot($0.x - p.x, $0.y - p.y) }.min() ?? 0 }
        return (nearest(p1) <= nearest(p2) ? 1 : -1, !in1 && !in2, rooms)
    }

    nonisolated static func inside(_ p: CGPoint, _ poly: [CGPoint]) -> Bool {
        var result = false
        var j = poly.count - 1
        for i in poly.indices {
            let a = poly[i], b = poly[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x {
                result.toggle()
            }
            j = i
        }
        return result
    }

    // The scan's room names with the user's renames, removals and additions.
    func resolvedRooms(_ structure: CapturedStructure) -> [ResolvedRoom] {
        var out: [ResolvedRoom] = []
        for (i, s) in structure.sections.enumerated() where !roomLabels.contains(where: { $0.replaces == i }) {
            let name = Self.roomName(String(describing: s.label))
            if !name.isEmpty {
                out.append(ResolvedRoom(story: s.story, center: SIMD2(Double(s.center.x), Double(s.center.z)), name: name, source: .scanned(i)))
            }
        }
        for (i, l) in roomLabels.enumerated() where !l.name.isEmpty {
            out.append(ResolvedRoom(story: l.story, center: l.point, name: l.name, source: .label(i)))
        }
        return out
    }

    private static func roomName(_ label: String) -> String {
        switch label {
        case "livingRoom": return "Living"
        case "diningRoom": return "Dining"
        case "unidentified": return ""
        default: return label.prefix(1).uppercased() + label.dropFirst()
        }
    }
}
