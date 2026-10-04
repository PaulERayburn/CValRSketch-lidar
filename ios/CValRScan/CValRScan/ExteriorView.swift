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

    private var pointCount: Int { scan.exteriorWalls.reduce(0) { $0 + $1.count } }
    private var wallCount: Int { scan.exteriorWalls.filter { !$0.isEmpty }.count }

    var body: some View {
        ZStack {
            SessionView(session: scan.arSession).ignoresSafeArea()
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
    }

    private var instructions: String {
        if scan.anchorStart == nil {
            return "Before going out: aim at a fixed spot by the door you'll use (a light switch or door-frame corner) and tap Set start spot."
        }
        if scan.anchorEnd != nil {
            return "Walk finished. Drift over the walk: \(driftText). Tap Done."
        }
        let current = scan.exteriorWalls.last?.count ?? 0
        return "Walk out slowly. For each outside wall, mark 2 or more points on the siding, then tap Next wall. "
            + "Wall \(max(wallCount, 1)): \(current) point\(current == 1 ? "" : "s"). "
            + "Back inside, aim at the start spot and tap Check start spot."
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
                    Button("Next wall") {
                        scan.nextExteriorWall()
                        show("Wall \(wallCount + 1)")
                    }
                    .buttonStyle(.bordered)
                    .disabled(scan.exteriorWalls.last?.isEmpty ?? true)
                }
                HStack {
                    Button("Pause") { dismiss() }.buttonStyle(.bordered)
                    Spacer()
                    Button {
                        feedback(scan.markAnchor(), ok: "Start spot checked", fail: "No surface under the crosshair")
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
