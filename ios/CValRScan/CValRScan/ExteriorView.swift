import ARKit
import AudioToolbox
import SceneKit
import SwiftUI
import UIKit

// The outside walk. RoomPlan has stopped, but its AR session keeps tracking,
// so points marked on the siding land in the same coordinates as the rooms.
struct ExteriorView: View {
    @ObservedObject var scan: ScanController
    @ObservedObject var depth: OutsideDepth
    @Environment(\.dismiss) private var dismiss
    @State private var flash: String?
    // A wall whose points turn a corner, waiting for the user to say
    // whether to split it; then Next wall goes ahead if that was tapped.
    @State private var corner: (splits: [Int], next: Bool)?
    // A start-spot check that landed far from the start spot, waiting for the user.
    @State private var farEnd: (point: SIMD3<Float>, feet: Double)?

    private var pointCount: Int { scan.exteriorWalls.reduce(0) { $0 + $1.count } }
    private var wallCount: Int { scan.exteriorWalls.filter { !$0.isEmpty }.count }
    private var walking: Bool { scan.anchorStart != nil && scan.anchorEnd == nil }
    // Why Mark point can't be used now, from the live LiDAR reading.
    private var markRefusal: String? {
        guard depth.running else { return nil }
        return depth.reading.map { $0.refusal } ?? CrosshairReading.noReading
    }

    var body: some View {
        ZStack {
            SessionView(session: scan.arSession).ignoresSafeArea()
            MarkedPointsOverlay(session: scan.arSession, points: scan.exteriorWalls.flatMap { $0.map(\.point) }, colour: .orange)
                .ignoresSafeArea()
            // The start spot, so it can be found again coming back in.
            MarkedPointsOverlay(session: scan.arSession, points: scan.anchorEnd == nil ? [scan.anchorStart].compactMap { $0 } : [],
                                colour: .green)
                .ignoresSafeArea()
            Image(systemName: "plus")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.white)
                .shadow(color: .black, radius: 2)
                .allowsHitTesting(false)
            if walking && depth.running { readout.offset(y: 44).allowsHitTesting(false) }
            VStack(spacing: 10) {
                Text(instructions)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .padding(10)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal)
                if let flash {
                    Text(flash).padding(8).background(.thinMaterial, in: Capsule())
                }
                Spacer()
                // Outside photos for the report (front, rear, street), pinned
                // on the plan where they were taken.
                if scan.anchorStart != nil {
                    HStack {
                        Spacer()
                        PhotoButton(scan: scan, outside: true) { show($0) }
                    }
                    .padding(.horizontal)
                }
                controls.padding()
            }
            .padding(.top)
        }
        .onAppear { scan.startOutsideWalk() }
        .onDisappear { scan.stopOutsideWalk() }
        .alert("Wall \(wallCount) turns a corner",
               isPresented: Binding(get: { corner != nil }, set: { if !$0 { corner = nil } }),
               presenting: corner) { c in
            Button("Split into \(c.splits.count + 1) walls") {
                scan.splitLastExteriorWall(at: c.splits)
                if c.next { nextWall() }
            }
            Button("Keep as one wall", role: .cancel) {
                if c.next { nextWall() }
            }
        } message: { c in
            Text("Its points fit \(c.splits.count + 1) walls better than one. Did you miss Next wall at a corner?")
        }
        .alert(String(format: "That's %.0f ft from your start spot", farEnd?.feet ?? 0),
               isPresented: Binding(get: { farEnd != nil }, set: { if !$0 { farEnd = nil } }),
               presenting: farEnd) { f in
            Button("Try again", role: .cancel) {}
            Button("Use it anyway") {
                scan.acceptAnchorEnd(f.point)
                checkCorner(next: false)
            }
        } message: { _ in
            Text("Aim at the same spot you set before going out (the green dot): the light switch or door-frame corner. A real check lands within a few inches.")
        }
    }

    // Before leaving a wall, check its points lie on one line.
    private func checkCorner(next: Bool) {
        let splits = scan.cornerSplits
        if splits.isEmpty {
            if next { nextWall() }
        } else {
            corner = (splits, next)
        }
    }

    private func nextWall() {
        scan.nextExteriorWall()
        show("Wall \(wallCount + 1)")
    }

    // Distance and squareness under the crosshair: green is good, orange
    // usable, red can't be marked.
    private var readout: some View {
        let r = depth.reading
        let colour: Color = switch r?.quality {
        case .good: .green
        case .fair: .orange
        default: .red
        }
        return Text(r.map { $0.refusal ?? $0.text } ?? CrosshairReading.noReading)
            .font(.callout.weight(.semibold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(colour.opacity(0.85), in: Capsule())
    }

    private func markPoint() {
        if let why = markRefusal {
            MarkFeedback.refused()
            show(why)
            return
        }
        switch scan.markExteriorPoint() {
        case .marked(let p):
            MarkFeedback.good()
            let n = scan.exteriorWalls.last?.count ?? 0
            show(p.distance.map { String(format: "Point %d marked, %.1f ft away", n, $0 * 3.28084) } ?? "Point marked")
        case .refused(let why):
            MarkFeedback.refused()
            show(why)
        }
    }

    private var instructions: String {
        if scan.anchorStart == nil {
            return "Before going out: aim at a fixed spot by the door you'll use (a light switch or door-frame corner) and tap Set start spot."
        }
        if scan.anchorEnd != nil {
            return "Walk finished. Drift over the walk: \(driftText). Tap Done."
        }
        let current = scan.exteriorWalls.last?.count ?? 0
        let aim = depth.running ? "Stand close and face the siding: green under the crosshair is best. " : ""
        return "Walk out slowly. " + aim + "For each outside wall, mark 2 or more points on the siding, then tap Next wall at the corner. "
            + "Wall \(max(wallCount, 1)): \(current) point\(current == 1 ? "" : "s"). "
            + "Back inside, aim at the start spot (green dot) and tap Check start spot."
    }

    private var driftText: String {
        guard let d = scan.drift else { return "–" }
        let inches = Double(simd_length(SIMD2(d.x, d.z))) * 39.37
        return String(format: "%.1f″", inches)
    }

    @ViewBuilder private var controls: some View {
        if scan.anchorStart == nil {
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }.buttonStyle(.bordered)
                Spacer()
                Button {
                    feedback(scan.markAnchor(), ok: "Start spot set", fail: "No surface under the crosshair")
                } label: { Label("Set start spot", systemImage: "door.left.hand.open") }
                .buttonStyle(.borderedProminent)
            }
        } else if scan.anchorEnd == nil {
            VStack(spacing: 10) {
                HStack {
                    Button("Undo", systemImage: "arrow.uturn.backward") { scan.undoExteriorPoint() }
                        .buttonStyle(.bordered)
                        .disabled(pointCount == 0)
                    Spacer()
                    Button { markPoint() } label: { Label("Mark point", systemImage: "scope") }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .disabled(markRefusal != nil)
                    Spacer()
                    Button("Next wall") { checkCorner(next: true) }
                    .buttonStyle(.bordered)
                    .disabled(scan.exteriorWalls.last?.isEmpty ?? true)
                }
                HStack {
                    Button("Pause") { dismiss() }.buttonStyle(.bordered)
                    Spacer()
                    Button {
                        switch scan.checkAnchor() {
                        case .none:
                            feedback(false, ok: "", fail: "No surface under the crosshair")
                        case .checked:
                            feedback(true, ok: "Start spot checked", fail: "")
                            checkCorner(next: false)
                        case .far(let p, let feet):
                            UINotificationFeedbackGenerator().notificationOccurred(.warning)
                            farEnd = (p, feet)
                        }
                    } label: { Label("Check start spot", systemImage: "checkmark.circle") }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .disabled(pointCount == 0)
                }
            }
        } else {
            HStack {
                Spacer()
                Button("Done") {
                    scan.isOutside = false
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func feedback(_ ok: Bool, ok okText: String, fail: String) {
        UINotificationFeedbackGenerator().notificationOccurred(ok ? .success : .error)
        show(ok ? okText : fail)
    }

    private func show(_ text: String) {
        flash = text
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if flash == text { flash = nil }
        }
    }
}

// Shows the camera for an existing AR session without reconfiguring it.
struct SessionView: UIViewRepresentable {
    let session: ARSession
    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.session = session
        view.automaticallyUpdatesLighting = false
        return view
    }
    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}

// Feedback for marking at arm's length or on a stick: a tap you can feel and
// a sound you can hear when the phone is out of reach.
enum MarkFeedback {
    static func good() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        AudioServicesPlaySystemSound(1054)
    }
    static func refused() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        AudioServicesPlaySystemSound(1053)
    }
}
