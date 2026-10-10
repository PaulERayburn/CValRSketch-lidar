import RoomPlan
import SwiftUI
import simd

// Space nobody scanned, found two ways, so it can be fixed before leaving:
//  - a door (or opening) with scanned floor on one side and none on the
//    other: a closet, room or stairwell that wasn't walked into, unless it's
//    an outside door (the user can say so);
//  - on a lower floor, area under the floor above with no floor scanned: a
//    missed room, or slab, crawlspace or unexcavated (the user can say so).
// All in world metres (x, z).

struct UnscannedDoor: Identifiable, Equatable {
    let id: UUID
    let story: Int
    let at: SIMD2<Double>        // middle of the door
    let beyond: SIMD2<Double>    // a point on the unscanned side
    var a = SIMD2<Double>(0, 0), b = SIMD2<Double>(0, 0)   // its ends
    var wall: UUID?              // the wall it's in
}

struct UnscannedArea: Identifiable, Equatable {
    let id: Int
    let story: Int
    let centre: SIMD2<Double>
    let squareFeet: Int
    let cells: [[SIMD2<Double>]] // squares to shade, corners
}

// An unscanned area filled in from the floor above: the grid squares
// (lower-left corners, world) that make it up.
struct AreaFill: Equatable {
    var story: Int
    var centre: SIMD2<Double>
    var cell: Double
    var cells: [[SIMD2<Double>]]   // squares, corners (world), square to the house
}

enum Unscanned {
    private static func polygons(_ floors: [CapturedRoom.Surface]) -> [Int: [[SIMD2<Double>]]] {
        var out: [Int: [[SIMD2<Double>]]] = [:]
        for f in floors {
            let poly = PlanExport.floor(f).polygon.map { SIMD2($0[0], $0[1]) }
            if poly.count >= 3 { out[f.story, default: []].append(poly) }
        }
        return out
    }

    static func inside(_ p: SIMD2<Double>, _ poly: [SIMD2<Double>]) -> Bool {
        var result = false
        var j = poly.count - 1
        for i in poly.indices {
            let a = poly[i], b = poly[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { result.toggle() }
            j = i
        }
        return result
    }

    // Doors and openings with floor on one side only, 2 ft either side of
    // the middle.
    // `extra`: more floor per story, e.g. areas filled in from the floor above.
    static func doors(floors: [CapturedRoom.Surface], doors: [CapturedRoom.Surface], skip: Set<UUID>,
                      extra: [Int: [[SIMD2<Double>]]] = [:]) -> [UnscannedDoor] {
        let polys = polygons(floors).merging(extra) { $0 + $1 }
        var out: [UnscannedDoor] = []
        for d in doors where !skip.contains(d.identifier) {
            let s = PlanExport.segment(d)
            let a = SIMD2(s.a[0], s.a[1]), b = SIMD2(s.b[0], s.b[1])
            guard simd_distance(a, b) > 0.3 else { continue }
            let m = (a + b) / 2, u = simd_normalize(b - a), n = SIMD2(-u.y, u.x)
            let p1 = m + n * 0.6, p2 = m - n * 0.6
            let here = polys[d.story] ?? []
            let in1 = here.contains { inside(p1, $0) }, in2 = here.contains { inside(p2, $0) }
            if in1 != in2 { out.append(UnscannedDoor(id: d.identifier, story: d.story, at: m, beyond: in1 ? p2 : p1, a: a, b: b, wall: d.parentIdentifier)) }
        }
        return out
    }

    // Under each floor above, ground the floor below has none of, on a 6 in
    // grid; slivers along the walls are dropped, and pieces under 16 sf.
    // `angle` turns world into the house's square frame (PlanGeometry.angle),
    // so the squares, and any outline made from them, run square to the house.
    static func areas(floors: [CapturedRoom.Surface], ignored: [SIMD2<Double>], angle: Double = 0) -> [UnscannedArea] {
        let c = cos(angle), s = sin(angle)
        func toHouse(_ p: SIMD2<Double>) -> SIMD2<Double> { SIMD2(p.x * c - p.y * s, p.x * s + p.y * c) }
        func toWorld(_ p: SIMD2<Double>) -> SIMD2<Double> { SIMD2(p.x * c + p.y * s, -p.x * s + p.y * c) }
        let polys = polygons(floors).mapValues { $0.map { $0.map(toHouse) } }
        let cell = 0.1524
        var out: [UnscannedArea] = []
        for (story, below) in polys.sorted(by: { $0.key < $1.key }) {
            guard let above = polys[story + 1] else { continue }
            let pts = above.flatMap { $0 }
            guard let x0 = pts.map(\.x).min(), let x1 = pts.map(\.x).max(),
                  let y0 = pts.map(\.y).min(), let y1 = pts.map(\.y).max() else { continue }
            let W = Int((x1 - x0) / cell) + 1, H = Int((y1 - y0) / cell) + 1
            guard W * H < 400_000 else { continue }
            var miss = [Bool](repeating: false, count: W * H)
            for j in 0..<H {
                for i in 0..<W {
                    let p = SIMD2(x0 + (Double(i) + 0.5) * cell, y0 + (Double(j) + 0.5) * cell)
                    miss[j * W + i] = above.contains { inside(p, $0) } && !below.contains { inside(p, $0) }
                }
            }
            // Drop slivers: keep a cell only if the 2-cell square round it is all missing.
            var core = [Bool](repeating: false, count: W * H)
            for j in 2..<max(2, H - 2) {
                for i in 2..<max(2, W - 2) where miss[j * W + i] {
                    var all = true
                    for dj in -2...2 where all { for di in -2...2 where !miss[(j + dj) * W + i + di] { all = false; break } }
                    core[j * W + i] = all
                }
            }
            var seen = [Bool](repeating: false, count: W * H)
            for k0 in 0..<(W * H) where core[k0] && !seen[k0] {
                // A piece of core, grown back over the missing cells round it.
                var piece = [k0]
                seen[k0] = true
                var q = 0
                while q < piece.count {
                    let k = piece[q]; q += 1
                    let i = k % W, j = k / W
                    for (di, dj) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                        let a = i + di, b = j + dj
                        guard a >= 0, b >= 0, a < W, b < H else { continue }
                        let m = b * W + a
                        if !seen[m] && miss[m] && (core[m] || core[k]) { seen[m] = true; piece.append(m) }
                    }
                }
                let sf = Int((Double(piece.count) * cell * cell * 10.7639).rounded())
                guard sf >= 16 else { continue }
                let centre = toWorld(piece.reduce(SIMD2<Double>(0, 0)) { t, k in
                    t + SIMD2(x0 + (Double(k % W) + 0.5) * cell, y0 + (Double(k / W) + 0.5) * cell)
                } / Double(piece.count))
                if ignored.contains(where: { simd_distance($0, centre) < 1 }) { continue }
                let cells = piece.map { k -> [SIMD2<Double>] in
                    let x = x0 + Double(k % W) * cell, y = y0 + Double(k / W) * cell
                    return [SIMD2(x, y), SIMD2(x + cell, y), SIMD2(x + cell, y + cell), SIMD2(x, y + cell)].map(toWorld)
                }
                out.append(UnscannedArea(id: out.count, story: story, centre: centre, squareFeet: sf, cells: cells))
            }
        }
        return out
    }
}
