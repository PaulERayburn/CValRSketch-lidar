import RoomPlan
import SwiftUI
import simd

// Stairs on the plan. RoomPlan finds stairs as rough boxes, often only part
// of a flight and never which way it climbs, so a scanned flight can be
// flipped, turned, lengthened or removed; and the user can draw a stair as a
// chain of pieces: straight flights, and turns that are either a flat landing
// or winders (pie-shaped treads) through 90° or 180°.
//
// A stair is drawn on the floor it was drawn from (UP or DN beside its start)
// and again on the floor at its other end, with the arrow reversed.

struct StairEdit: Equatable {
    var flip = false
    var hidden = false
    var turn = false             // the climb runs along the other side
    var run: Double?             // metres, when set by the user; kept centred
}

// A drawn stair: where it starts on the floor it was drawn from, which way,
// and its pieces in walking order. Positions follow from these, so a change
// of width or steps reflows the rest of the stair.
struct StairChain: Equatable, Identifiable {
    struct Piece: Equatable {
        enum Kind: String { case flight, turn }
        var kind: Kind
        var length = 0.0         // flight, metres
        var degrees = 90         // turn: 90 or 180, signed: + to the left
        var steps = 0            // flight: risers; turn: 0 a flat landing, else winders
    }
    var id = UUID()
    var story: Int               // the floor it was drawn from
    var down = false             // drawn going down from that floor
    var start: SIMD2<Double>     // world x, z, centre of the first tread
    var dir: SIMD2<Double>       // unit, walking direction
    var width = 0.914            // 36 in
    var pieces: [Piece] = []

    static func defaultSteps(metres: Double) -> Int { max(1, Int((metres / 0.254).rounded())) }   // 10 in treads
}

// What to draw for stairs, world x, z.
struct StairDrawing {
    struct Piece { let id: UUID; let index: Int; let story: Int; let outline: [SIMD2<Double>]; let treads: [(SIMD2<Double>, SIMD2<Double>)] }
    struct Path { let story: Int; let points: [SIMD2<Double>]; let label: String }
    var pieces: [Piece] = []
    var paths: [Path] = []
}

extension StairChain {
    private static func left(_ u: SIMD2<Double>) -> SIMD2<Double> { SIMD2(-u.y, u.x) }

    // Each piece's outline and treads, the walking line, and where it ends.
    func layout() -> (pieces: [(outline: [SIMD2<Double>], treads: [(SIMD2<Double>, SIMD2<Double>)])],
                      path: [SIMD2<Double>], end: SIMD2<Double>, dir: SIMD2<Double>,
                      frames: [(start: SIMD2<Double>, dir: SIMD2<Double>)]) {
        var cur = start, u = simd_normalize(dir)
        let w = width
        var out: [(outline: [SIMD2<Double>], treads: [(SIMD2<Double>, SIMD2<Double>)])] = []
        var path = [cur]
        var frames: [(start: SIMD2<Double>, dir: SIMD2<Double>)] = []
        for p in pieces {
            frames.append((cur, u))
            let n = Self.left(u)
            switch p.kind {
            case .flight:
                let b = cur + u * p.length
                var treads: [(SIMD2<Double>, SIMD2<Double>)] = []
                if p.steps > 1 {
                    for i in 1..<p.steps {
                        let q = cur + (b - cur) * Double(i) / Double(p.steps)
                        treads.append((q - n * w / 2, q + n * w / 2))
                    }
                }
                out.append(([cur - n * w / 2, cur + n * w / 2, b + n * w / 2, b - n * w / 2], treads))
                path.append(b)
                cur = b
            case .turn:
                let s: Double = p.degrees >= 0 ? 1 : -1, m = n * s
                let half = abs(p.degrees) >= 180
                let pivot = cur + m * w / 2
                let outline = half
                    ? [cur - m * w / 2, cur - m * w / 2 + u * w, cur + m * (1.5 * w) + u * w, cur + m * (1.5 * w)]
                    : [pivot, cur - m * w / 2, cur - m * w / 2 + u * w, pivot + u * w]
                let sweep = half ? Double.pi : Double.pi / 2
                // Winders radiate from the pivot out to the edge of the turn.
                var treads: [(SIMD2<Double>, SIMD2<Double>)] = []
                if p.steps > 1 {
                    for i in 1..<p.steps {
                        let phi = sweep * Double(i) / Double(p.steps)
                        let d = -m * cos(phi) + u * sin(phi)
                        let across = abs(simd_dot(d, m)), fwd = simd_dot(d, u)
                        let t = min(across > 1e-6 ? w / across : .infinity, fwd > 1e-6 ? w / fwd : .infinity)
                        treads.append((pivot, pivot + d * t))
                    }
                }
                out.append((outline, treads))
                for i in 1...12 {
                    let phi = sweep * Double(i) / 12
                    path.append(pivot + (-m * cos(phi) + u * sin(phi)) * w / 2)
                }
                cur = path.last!
                u = half ? -u : m
            }
        }
        return (out, path, cur, u, frames)
    }

    // Dots to drag on the plan: the start (moves the stair), the far end of
    // each flight (its length) and the side of the first piece (the width).
    enum Handle: Equatable { case move, end(Int), width }

    func handles() -> [(handle: Handle, at: SIMD2<Double>)] {
        let f = layout().frames
        guard let first = f.first else { return [] }
        var out: [(handle: Handle, at: SIMD2<Double>)] = [(.move, start)]
        for (i, p) in pieces.enumerated() where p.kind == .flight {
            out.append((.end(i), f[i].start + f[i].dir * p.length))
        }
        let along = pieces.first?.kind == .flight ? min(pieces[0].length / 2, 0.6) : width / 2
        out.append((.width, first.start + first.dir * along + Self.left(first.dir) * width / 2))
        return out
    }

    // This stair with a dot dragged from `from` to `to` (world x, z). A
    // flight's step count follows its length unless it was set by hand.
    func dragged(_ h: Handle, from: SIMD2<Double>, to: SIMD2<Double>) -> StairChain {
        var c = self
        let f = layout().frames
        switch h {
        case .move:
            c.start = start + (to - from)
        case .end(let i):
            let len = max(0.15, simd_dot(to - f[i].start, f[i].dir))
            if pieces[i].steps == Self.defaultSteps(metres: pieces[i].length) { c.pieces[i].steps = Self.defaultSteps(metres: len) }
            c.pieces[i].length = len
        case .width:
            guard let first = f.first else { return c }
            c.width = max(0.5, 2 * abs(simd_dot(to - first.start, Self.left(first.dir))))
        }
        return c
    }
}

extension StairDrawing {
    // Drawn stairs and the scan's own (unless hidden), on every floor they touch.
    init(chains: [StairChain], structure: CapturedStructure, edits: [UUID: StairEdit]) {
        let stories = Set(structure.floors.map(\.story))
        for c in chains {
            let l = c.layout()
            let other = c.story + (c.down ? -1 : 1)
            for (i, p) in l.pieces.enumerated() {
                pieces.append(Piece(id: c.id, index: i, story: c.story, outline: p.outline, treads: p.treads))
                if stories.contains(other) { pieces.append(Piece(id: c.id, index: i, story: other, outline: p.outline, treads: p.treads)) }
            }
            guard l.path.count > 1 else { continue }
            paths.append(Path(story: c.story, points: l.path, label: c.down ? "DN" : "UP"))
            if stories.contains(other) { paths.append(Path(story: other, points: l.path.reversed(), label: c.down ? "UP" : "DN")) }
        }
        for o in structure.objects where o.category == .stairs && edits[o.identifier]?.hidden != true {
            let f = PlanExport.flight(o, edit: edits[o.identifier])
            let c = f.corners
            // Treads every 10 in along the climb.
            let e0 = c[1] - c[0], e1 = c[3] - c[0]
            let along0 = abs(simd_dot(e0, f.up)) >= abs(simd_dot(e1, f.up))
            let run = along0 ? e0 : e1, across = along0 ? e1 : e0
            let steps = StairChain.defaultSteps(metres: simd_length(run))
            let treads = steps > 1 ? (1..<steps).map { i -> (SIMD2<Double>, SIMD2<Double>) in
                let q = c[0] + run * Double(i) / Double(steps); return (q, q + across)
            } : []
            let mid = c[0] + across / 2
            let line = simd_dot(run, f.up) >= 0 ? [mid, mid + run] : [mid + run, mid]
            pieces.append(Piece(id: o.identifier, index: -1, story: o.story, outline: c, treads: treads))
            paths.append(Path(story: o.story, points: line, label: "UP"))
            if stories.contains(o.story + 1) {
                pieces.append(Piece(id: o.identifier, index: -1, story: o.story + 1, outline: c, treads: treads))
                paths.append(Path(story: o.story + 1, points: line.reversed(), label: "DN"))
            }
        }
    }
}

extension PlanExport {
    // Stairs as drawn, for the importer: outline and treads per piece, and
    // the walking line with its label, per floor.
    struct StairPieceOut: Encodable { let story: Int; let outline: [[Double]]; let treads: [[[Double]]] }
    struct StairPathOut: Encodable { let story: Int; let path: [[Double]]; let label: String }
    struct StairChainOut: Codable {
        struct PieceOut: Codable { let kind: String; let length: Double; let degrees: Int; let steps: Int }
        let id: String; let story: Int; let down: Bool; let start: [Double]; let dir: [Double]; let width: Double
        let pieces: [PieceOut]
    }

    static func chainOut(_ c: StairChain) -> StairChainOut {
        StairChainOut(id: c.id.uuidString, story: c.story, down: c.down, start: [c.start.x, c.start.y], dir: [c.dir.x, c.dir.y],
                      width: c.width, pieces: c.pieces.map { .init(kind: $0.kind.rawValue, length: $0.length, degrees: $0.degrees, steps: $0.steps) })
    }

    static func chainIn(_ o: StairChainOut) -> StairChain? {
        guard o.start.count == 2, o.dir.count == 2 else { return nil }
        return StairChain(id: UUID(uuidString: o.id) ?? UUID(), story: o.story, down: o.down,
                          start: SIMD2(o.start[0], o.start[1]), dir: SIMD2(o.dir[0], o.dir[1]), width: o.width,
                          pieces: o.pieces.map { .init(kind: .init(rawValue: $0.kind) ?? .flight, length: $0.length, degrees: $0.degrees, steps: $0.steps) })
    }

    static func stairOut(_ d: StairDrawing) -> (pieces: [StairPieceOut], paths: [StairPathOut]) {
        func r(_ v: SIMD2<Double>) -> [Double] { [(v.x * 1000).rounded() / 1000, (v.y * 1000).rounded() / 1000] }
        return (d.pieces.map { StairPieceOut(story: $0.story, outline: $0.outline.map(r), treads: $0.treads.map { [r($0.0), r($0.1)] }) },
                d.paths.map { StairPathOut(story: $0.story, path: $0.points.map(r), label: $0.label) })
    }

    // A scanned flight's footprint and climb, world x, z. Its run is along the
    // longer side unless turned; it climbs toward +run unless flipped.
    static func flight(_ o: CapturedRoom.Object, edit: StairEdit?) -> (corners: [SIMD2<Double>], up: SIMD2<Double>) {
        let t = o.transform, d = o.dimensions
        let c = SIMD2(Double(t.columns.3.x), Double(t.columns.3.z))
        let ax = simd_normalize(SIMD2(Double(t.columns.0.x), Double(t.columns.0.z))) * Double(d.x) / 2
        let az = simd_normalize(SIMD2(Double(t.columns.2.x), Double(t.columns.2.z))) * Double(d.z) / 2
        let alongZ = (d.z >= d.x) != (edit?.turn == true)
        var runHalf = alongZ ? az : ax
        let wide = alongZ ? ax : az
        if let run = edit?.run, run > 0.2 { runHalf = simd_normalize(runHalf) * run / 2 }
        let corners = [c - wide - runHalf, c + wide - runHalf, c + wide + runHalf, c - wide + runHalf]
        var up = simd_normalize(runHalf)
        if edit?.flip == true { up = -up }
        return (corners, up)
    }
}

extension PlanView {
    // A stair piece: outline and treads. Screen points.
    static func drawStairPiece(_ ctx: GraphicsContext, outline: [CGPoint], treads: [(CGPoint, CGPoint)], colour: Color) {
        guard outline.count >= 3 else { return }
        var o = Path()
        o.addLines(outline)
        o.closeSubpath()
        ctx.fill(o, with: .color(colour.opacity(0.08)))
        ctx.stroke(o, with: .color(colour), lineWidth: 1.5)
        var t = Path()
        for (a, b) in treads { t.move(to: a); t.addLine(to: b) }
        ctx.stroke(t, with: .color(colour.opacity(0.6)), lineWidth: 0.8)
    }

    // The walking line: from the start, with UP or DN there, to an arrowhead.
    static func drawStairPath(_ ctx: GraphicsContext, points: [CGPoint], label: String, colour: Color) {
        guard points.count > 1, let first = points.first, let last = points.last else { return }
        var p = Path()
        p.addLines(points)
        let prev = points[points.count - 2]
        let L = max(hypot(last.x - prev.x, last.y - prev.y), 0.001)
        let ux = (last.x - prev.x) / L, uy = (last.y - prev.y) / L, h: CGFloat = 7
        p.move(to: CGPoint(x: last.x - ux * h - uy * h * 0.6, y: last.y - uy * h + ux * h * 0.6))
        p.addLine(to: last)
        p.addLine(to: CGPoint(x: last.x - ux * h + uy * h * 0.6, y: last.y - uy * h - ux * h * 0.6))
        ctx.stroke(p, with: .color(colour), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
        let next = points[1]
        let L0 = max(hypot(next.x - first.x, next.y - first.y), 0.001)
        ctx.draw(Text(label).font(.caption2.bold()).foregroundStyle(colour),
                 at: CGPoint(x: first.x - (next.x - first.x) / L0 * 9, y: first.y - (next.y - first.y) / L0 * 9))
    }
}
