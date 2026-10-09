import ARKit
import SwiftUI
import simd

// Walls the scan missed, typically a closet back hidden by coats. Closets
// are square to the house, so all a hidden wall needs is how far away it
// is: one point anywhere on it, or a laser depth from a scanned wall.

// A point aimed at on a wall, with the wall's facing (horizontal, world).
struct WallPoint: Equatable {
    var point: SIMD3<Float>
    var normal: SIMD3<Float>
}

// A laser reading across a gap: from a scanned wall, square across to the
// missing one. The gap is kept in world metres (x, z) so the reading
// follows it when the plan is rebuilt.
struct GapDepth: Equatable {
    var gapA: SIMD2<Double>
    var gapB: SIMD2<Double>
    var from: UUID
    var inches: Int

    var middle: SIMD2<Double> { (gapA + gapB) / 2 }
}

extension PlanExport {
    // A stretch of floor edge with no wall, door, window or opening along it.
    struct Gap: Encodable {
        let story: Int
        let a: [Double]
        let b: [Double]
    }

    // Walks each floor outline in 5 cm steps; stretches over 30 cm that sit
    // more than 15 cm from anything scanned are gaps.
    static func gaps(floors: [Floor], segments: [Segment]) -> [Gap] {
        func distance(_ p: SIMD2<Double>, _ a: [Double], _ b: [Double]) -> Double {
            let a = SIMD2(a[0], a[1]), d = SIMD2(b[0], b[1]) - a
            let t = min(max(simd_dot(p - a, d) / max(simd_length_squared(d), 1e-9), 0), 1)
            return simd_distance(p, a + d * t)
        }
        func rounded(_ p: SIMD2<Double>) -> [Double] { [(p.x * 1000).rounded() / 1000, (p.y * 1000).rounded() / 1000] }
        var out: [Gap] = []
        for f in floors where f.polygon.count >= 3 {
            let near = segments.filter { $0.story == f.story }
            for i in f.polygon.indices {
                let a = SIMD2(f.polygon[i][0], f.polygon[i][1])
                let n = f.polygon[(i + 1) % f.polygon.count]
                let b = SIMD2(n[0], n[1])
                let len = simd_distance(a, b)
                let steps = max(2, Int(len / 0.05))
                var start: Double?
                for j in 0...steps {
                    let t = Double(j) / Double(steps)
                    let open = !near.contains { distance(a + (b - a) * t, $0.a, $0.b) <= 0.15 }
                    if open, start == nil { start = t }
                    if let s = start, !open || j == steps {
                        let e = open ? 1 : t
                        if (e - s) * len > 0.3 {
                            out.append(Gap(story: f.story, a: rounded(a + (b - a) * s), b: rounded(a + (b - a) * e)))
                        }
                        start = nil
                    }
                }
            }
        }
        return out
    }
}

// Dots where points were marked, drawn over the camera so you can see each
// one landed where you aimed.
struct MarkedPointsOverlay: View {
    let session: ARSession
    let points: [SIMD3<Float>]
    let colour: Color

    // Redrawn ten times a second, and only while there are dots: drawing on
    // every display frame, and holding ARFrames to do it, starves RoomPlan's
    // tracking ("World tracking failure").
    var body: some View {
        if points.isEmpty {
            Color.clear.allowsHitTesting(false)
        } else {
            dots
        }
    }

    private var dots: some View {
        GeometryReader { box in
            TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                Canvas { ctx, size in
                    // Take only the camera, so no ARFrame is kept between draws.
                    guard let camera = session.currentFrame?.camera else { return }
                    let view = camera.viewMatrix(for: .portrait)
                    for (i, p) in points.enumerated() {
                        // Only points in front of the camera.
                        guard (view * SIMD4(p, 1)).z < 0 else { continue }
                        let s = camera.projectPoint(p, orientation: .portrait, viewportSize: size)
                        guard s.x > -20, s.y > -20, s.x < size.width + 20, s.y < size.height + 20 else { continue }
                        let latest = i == points.count - 1
                        let r: CGFloat = latest ? 9 : 6
                        let dot = Path(ellipseIn: CGRect(x: s.x - r, y: s.y - r, width: 2 * r, height: 2 * r))
                        ctx.fill(dot, with: .color(colour))
                        ctx.stroke(dot, with: .color(.white), lineWidth: 2)
                    }
                }
                .frame(width: box.size.width, height: box.size.height)
            }
        }
        .allowsHitTesting(false)
    }
}

// Tapped a red gap on the plan: explains it, and takes a laser depth.
struct GapSheet: View {
    let gap: PlanGap
    let geo: PlanGeometry
    let onSave: (GapDepth?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        let reference = geo.referenceWall(for: gap)
        let parsed = LengthParser.inches(from: text)
        NavigationStack {
            Form {
                Section {
                    Text("\(Feet.text(Int((gap.length * 12).rounded()))) of floor edge with no wall along it, probably a closet back or side the scan couldn't see.")
                }
                Section("Fix it on site") {
                    Text("Resume this scan, tap Scan a room, and aim at any bare spot on the hidden wall: above the shelf, between hangers or low behind the shoes. Tap Mark wall. One point per hidden wall is enough; the app squares it to the room.")
                        .font(.callout)
                }
                if let reference {
                    Section {
                        HStack {
                            TextField("e.g. 2 0  or  24 in", text: $text)
                                .keyboardType(.numbersAndPunctuation)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                            if let parsed { Text("= \(Feet.text(parsed))").bold() }
                        }
                        if parsed == nil && !text.isEmpty {
                            Text("Not understood. Try feet then inches, like 2 0, or 24 in.").foregroundStyle(.red)
                        }
                    } header: {
                        Text("Or enter a laser depth")
                    } footer: {
                        Text("Hold the laser against the gap side of the \(Feet.text(reference.wall.scanInches)) wall shown in blue (for a closet, the inside edge of the door frame) and shoot square across to the hidden wall.")
                    }
                }
                if gap.depth != nil {
                    Button("Remove depth", role: .destructive) {
                        onSave(nil)
                        dismiss()
                    }
                }
            }
            .navigationTitle("Missing wall")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let parsed, let reference {
                            onSave(GapDepth(gapA: gap.worldA, gapB: gap.worldB, from: reference.wall.id, inches: parsed))
                        }
                        dismiss()
                    }
                    .disabled(parsed == nil || reference == nil)
                }
            }
            .onAppear {
                if let d = gap.depth { text = "\(d.inches) in" }
            }
        }
    }
}
