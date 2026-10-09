import SceneKit
import SwiftUI

// The scan's 3-D model on a plain background: drag to turn, pinch to zoom,
// two fingers to move. For checking a scan, so no camera and no AR, which
// would place the house at full size around the user.
struct ModelView: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var scene: SCNScene?
    @State private var failed = false

    var body: some View {
        NavigationStack {
            Group {
                if let scene {
                    SceneView(scene: scene, pointOfView: scene.rootNode.childNode(withName: "viewer", recursively: false),
                              options: [.allowsCameraControl, .autoenablesDefaultLighting])
                        .ignoresSafeArea(edges: .bottom)
                } else if failed {
                    Text("Couldn't open the 3-D model.").foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("3-D model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .safeAreaInset(edge: .bottom) {
                Text("Drag to turn · pinch to zoom · two fingers to move")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 6)
            }
        }
        .task { load() }
    }

    // Looks down at the house from a corner, far enough back to see all of it.
    private func load() {
        guard let s = try? SCNScene(url: url) else { failed = true; return }
        let (mn, mx) = s.rootNode.boundingBox
        let c = SCNVector3((mn.x + mx.x) / 2, (mn.y + mx.y) / 2, (mn.z + mx.z) / 2)
        let span = max(mx.x - mn.x, mx.z - mn.z, 1)
        let cam = SCNNode()
        cam.name = "viewer"
        cam.camera = SCNCamera()
        cam.camera?.zFar = Double(span) * 20
        cam.position = SCNVector3(c.x + span * 0.6, c.y + span * 1.1, c.z + span * 0.9)
        cam.look(at: c)
        s.rootNode.addChildNode(cam)
        scene = s
    }
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}
