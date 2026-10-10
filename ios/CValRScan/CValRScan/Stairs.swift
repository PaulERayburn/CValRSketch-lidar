import RoomPlan
import SwiftUI
import simd

// Stairs RoomPlan found, drawn on the floor they rise from (UP) and the one
// they come down from (DN), the way appraisal plans show them. RoomPlan says
// where a flight is but not which way it climbs, so the user can flip it, or
// hide one it got wrong.

struct StairEdit: Equatable {
    var flip = false
    var hidden = false
    var turn = false             // the climb runs along the other side
    var run: Double?             // metres, when set by the user; kept centred
}

extension PlanExport {
    struct StairOut: Encodable {
        let id: String
        let story: Int
        let corners: [[Double]]      // x, z, round the flight
        let up: [Double]             // level direction of climb
    }

    // A flight's footprint and climb, world x, z. Its run is along the longer
    // side; it climbs toward +run unless flipped.
    static func flight(_ o: CapturedRoom.Object, edit: StairEdit?) -> (corners: [SIMD2<Double>], up: SIMD2<Double>) {
        let t = o.transform, d = o.dimensions
        let c = SIMD2(Double(t.columns.3.x), Double(t.columns.3.z))
        let ax = simd_normalize(SIMD2(Double(t.columns.0.x), Double(t.columns.0.z))) * Double(d.x) / 2
        let az = simd_normalize(SIMD2(Double(t.columns.2.x), Double(t.columns.2.z))) * Double(d.z) / 2
        // The climb runs along the longer side unless turned.
        let alongZ = (d.z >= d.x) != (edit?.turn == true)
        var runHalf = alongZ ? az : ax
        let wide = alongZ ? ax : az
        if let run = edit?.run, run > 0.2 { runHalf = simd_normalize(runHalf) * run / 2 }
        let corners = [c - wide - runHalf, c + wide - runHalf, c + wide + runHalf, c - wide + runHalf]
        var up = simd_normalize(runHalf)
        if edit?.flip == true { up = -up }
        return (corners, up)
    }

    static func stairs(_ s: CapturedStructure, edits: [UUID: StairEdit]) -> [StairOut] {
        s.objects.filter { $0.category == .stairs && edits[$0.identifier]?.hidden != true }.map { o in
            let f = flight(o, edit: edits[o.identifier])
            func r(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
            return StairOut(id: o.identifier.uuidString, story: o.story, corners: f.corners.map { [r($0.x), r($0.y)] },
                            up: [r(f.up.x), r(f.up.y)])
        }
    }
}

extension PlanView {
    // Outline, treads about every 10″, and an arrow from the end you'd start
    // at on this floor, with UP or DN beside it. Screen points.
    static func drawStairs(_ ctx: GraphicsContext, corners: [CGPoint], up: CGVector, label: String, colour: Color) {
        guard corners.count == 4 else { return }
        var outline = Path()
        outline.addLines(corners)
        outline.closeSubpath()
        ctx.fill(outline, with: .color(colour.opacity(0.08)))
        ctx.stroke(outline, with: .color(colour), lineWidth: 1.5)
        // Which pair of opposite sides runs along the climb.
        let e0 = CGVector(dx: corners[1].x - corners[0].x, dy: corners[1].y - corners[0].y)
        let e1 = CGVector(dx: corners[3].x - corners[0].x, dy: corners[3].y - corners[0].y)
        let along0 = abs(e0.dx * up.dx + e0.dy * up.dy) >= abs(e1.dx * up.dx + e1.dy * up.dy)
        let run = along0 ? e0 : e1, across = along0 ? e1 : e0
        let runLen = hypot(run.dx, run.dy)
        guard runLen > 4 else { return }
        let steps = max(3, min(16, Int(runLen / 9)))
        var treads = Path()
        for i in 1..<steps {
            let f = CGFloat(i) / CGFloat(steps)
            let p = CGPoint(x: corners[0].x + run.dx * f, y: corners[0].y + run.dy * f)
            treads.move(to: p)
            treads.addLine(to: CGPoint(x: p.x + across.dx, y: p.y + across.dy))
        }
        ctx.stroke(treads, with: .color(colour.opacity(0.6)), lineWidth: 0.8)
        // The arrow runs down the middle, start to finish in the climb's direction.
        let mid = CGPoint(x: corners[0].x + across.dx / 2, y: corners[0].y + across.dy / 2)
        let forward = (run.dx * up.dx + run.dy * up.dy) >= 0
        let start = forward ? mid : CGPoint(x: mid.x + run.dx, y: mid.y + run.dy)
        let end = forward ? CGPoint(x: mid.x + run.dx, y: mid.y + run.dy) : mid
        let ux = (end.x - start.x) / runLen, uy = (end.y - start.y) / runLen
        let s = CGPoint(x: start.x + ux * runLen * 0.12, y: start.y + uy * runLen * 0.12)
        let e = CGPoint(x: end.x - ux * runLen * 0.08, y: end.y - uy * runLen * 0.08)
        var arrow = Path()
        arrow.move(to: s)
        arrow.addLine(to: e)
        let h: CGFloat = min(8, runLen * 0.15)
        arrow.move(to: CGPoint(x: e.x - ux * h - uy * h * 0.6, y: e.y - uy * h + ux * h * 0.6))
        arrow.addLine(to: e)
        arrow.addLine(to: CGPoint(x: e.x - ux * h + uy * h * 0.6, y: e.y - uy * h - ux * h * 0.6))
        ctx.stroke(arrow, with: .color(colour), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
        ctx.draw(Text(label).font(.caption2.bold()).foregroundStyle(colour),
                 at: CGPoint(x: s.x - ux * 7, y: s.y - uy * 7))
    }
}
