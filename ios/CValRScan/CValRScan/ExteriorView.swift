import ARKit
import SceneKit
import SwiftUI
import UIKit

// The outside walk. RoomPlan has stopped, but its AR session keeps tracking,
// so points marked on the siding land in the same coordinates as the rooms.
struct ExteriorView: View {
    @ObservedObject var scan: ScanController
    @Environment(\.dismiss) private var dismiss
    @State private var flash: String?
    // A wall whose points turn a corner, waiting for the user to say
    // whether to split it; then Next wall goes ahead if that was tapped.
    @State private var corner: (splits: [Int], next: Bool)?
    // A start-spot check that landed far from the start spot, waiting for the user.
    @State private var farEnd: (point: SIMD3<Float>, feet: Double)?

    private var pointCount: Int { scan.exteriorWalls.reduce(0) { $0 + $1.count } }
    private var wallCount: Int { scan.exteriorWalls.filter { !$0.isEmpty }.count }

    var body: some View {
        ZStack {
            SessionView(session: scan.arSession).ignoresSafeArea()
            MarkedPointsOverlay(session: scan.arSession, points: scan.exteriorWalls.flatMap { $0 }, colour: .orange)
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
                controls.padding()
            }
            .padding(.top)
        }
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

    private var instructions: String {
        if scan.anchorStart == nil {
            return "Before going out: aim at a fixed spot by the door you'll use (a light switch or door-frame corner) and tap Set start spot."
        }
        if scan.anchorEnd != nil {
            return "Walk finished. Drift over the walk: \(driftText). Tap Done."
        }
        let current = scan.exteriorWalls.last?.count ?? 0
        return "Walk out slowly. For each outside wall, mark 2 or more points on the siding, then tap Next wall at the corner. "
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
                    Button {
                        feedback(scan.markExteriorPoint(), ok: "Point marked", fail: "No surface under the crosshair")
                    } label: { Label("Mark point", systemImage: "scope") }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
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
