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
    enum Kind { case door, window, opening }
    let kind: Kind
    let story: Int
    let a: CGPoint
    let b: CGPoint
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

struct PlanGeometry {
    var walls: [PlanWall] = []
    var features: [PlanFeature] = []
    var floors: [(story: Int, points: [CGPoint])] = []
    var sections: [(story: Int, label: String, center: CGPoint)] = []
    var exteriorLines: [(a: CGPoint, b: CGPoint)] = []
    var stories: [Int] { Array(Set(walls.map(\.story))).sorted() }

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
        let segs = structure.walls.map { ($0, PlanExport.segment($0)) }
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
        g.floors = structure.floors.map { f in (f.story, PlanExport.floor(f).polygon.map(rot)) }
        g.sections = structure.sections.map { s in
            (s.story, Self.roomName(String(describing: s.label)),
             rot([Double(s.center.x), Double(s.center.z)]))
        }
        for (kind, list) in [(PlanFeature.Kind.door, structure.doors),
                             (.window, structure.windows), (.opening, structure.openings)] {
            g.features += list.map { s in
                let seg = PlanExport.segment(s)
                return PlanFeature(kind: kind, story: s.story, a: rot(seg.a), b: rot(seg.b))
            }
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
        g.exteriorLines = exteriorPlanLines.map { line in
            (rot([line.a.x, line.a.y]), rot([line.b.x, line.b.y]))
        }
        return g
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

    private static func inside(_ p: CGPoint, _ poly: [CGPoint]) -> Bool {
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

    private static func roomName(_ label: String) -> String {
        switch label {
        case "livingRoom": return "Living"
        case "diningRoom": return "Dining"
        case "unidentified": return ""
        default: return label.prefix(1).uppercased() + label.dropFirst()
        }
    }
}
