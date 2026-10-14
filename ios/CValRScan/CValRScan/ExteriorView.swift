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
    @ObservedObject var wide: WidePhoto
    @Environment(\.dismiss) private var dismiss
    @State private var flash: String?
    // A wall whose points turn a corner, waiting for the user to say
    // whether to split it; then Next wall goes ahead if that was tapped.
    @State private var corner: (splits: [Int], next: Bool, note: String?)?
    // A start-spot check that landed far from the start spot, waiting for the user.
    @State private var farEnd: (point: SIMD3<Float>, feet: Double)?
    // Touch: the volume button marks where the phone itself lies, for a
    // corner that can't be aimed at (TouchMath). Explained once.
    @State private var touchMode = false
    @State private var touchHelp = false
    @AppStorage("touchExplained") private var touchExplained = false

    private var pointCount: Int { scan.exteriorWalls.reduce(0) { $0 + $1.count } }
    private var wallNumber: Int { max(scan.exteriorWalls.count, 1) }
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
            if walking && depth.running {
                VStack(spacing: 6) {
                    readout
                    if touchMode { touchStatus }
                }
                .offset(y: touchMode ? 62 : 44)
                .allowsHitTesting(false)
            }
            // A selfie-stick remote (or either volume button) marks a point;
            // not while the wide camera is up (the AR session is paused).
            if walking && corner == nil && farEnd == nil && !wide.active && !touchHelp {
                VolumeButtonCatcher { if touchMode { markTouch() } else { markPoint() } }
                    .frame(width: 1, height: 1)
                    .allowsHitTesting(false)
            }
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
                if let wallStatus {
                    Text(wallStatus)
                        .font(.footnote.weight(.medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(.thinMaterial, in: Capsule())
                        .padding(.horizontal)
                }
                // Outside photos for the report (front, rear, street), pinned
                // on the plan where they were taken.
                if scan.anchorStart != nil {
                    HStack {
                        Spacer()
                        WidePhotoButton(scan: scan, wide: wide, outside: true) { show($0) }
                        PhotoButton(scan: scan, outside: true) { show($0) }
                    }
                    .padding(.horizontal)
                }
                controls.padding()
            }
            .padding(.top)
            WideCameraHost(wide: wide, outside: true)
        }
        .sheet(isPresented: $touchHelp) { touchSheet }
        .onAppear { scan.startOutsideWalk() }
        .onDisappear { scan.stopOutsideWalk() }
        .alert("Wall \(wallNumber) turns a corner",
               isPresented: Binding(get: { corner != nil }, set: { if !$0 { corner = nil } }),
               presenting: corner) { c in
            Button("Split into \(c.splits.count + 1) walls") {
                scan.splitLastExteriorWall(at: c.splits)
                if c.next { nextWall(c.note) }
            }
            Button("Keep as one wall", role: .cancel) {
                if c.next { nextWall(c.note) }
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
    private func checkCorner(next: Bool, note: String? = nil) {
        let splits = scan.cornerSplits
        if splits.isEmpty {
            if next { nextWall(note) }
        } else {
            corner = (splits, next, note)
        }
    }

    private func nextWall(_ note: String? = nil) {
        scan.nextExteriorWall()
        show(note ?? "Wall \(wallNumber)")
    }

    // One line on the wall being walked: whether it has enough points yet,
    // or that the aim has turned onto another wall.
    private var wallStatus: String? {
        guard walking else { return nil }
        let wall = scan.exteriorWalls.last ?? []
        let n = wallNumber
        if swungAway { return "New wall? Tap Next wall" + (depth.running ? " or Mark corner" : "") }
        switch wall.count {
        case 0: return "Wall \(n) · no points yet"
        case 1 where wall[0].isCorner: return "Wall \(n) · from the corner — mark a point along it"
        case 1 where wall[0].dir != nil: return "Wall \(n) · 1 point — step along 3 ft for another, or Mark corner"
        case 1: return "Wall \(n) · 1 point — needs another"
        default: return "Wall \(n) · \(wall.count) points ✓"
        }
    }

    // The wall under the crosshair runs more than 45° off the wall being walked.
    private var swungAway: Bool {
        guard let run = depth.aimRun, let along = currentWallRun else { return false }
        return abs(simd_dot(run, along)) < cos(45 * .pi / 180)
    }

    private var currentWallRun: SIMD2<Double>? {
        let wall = scan.exteriorWalls.last ?? []
        // Just turned a corner: still facing the wall behind, so no hint yet.
        if wall.count == 1, wall[0].isCorner { return nil }
        if let d = wall.last(where: { !$0.isCorner && $0.dir != nil })?.dir { return d }
        if let ds = wall.first?.dirs, wall.first?.isCorner == true, ds.count == 2 { return ds[1] }
        let pts = wall.map { SIMD2(Double($0.point.x), Double($0.point.z)) }
        guard let a = pts.first, let b = pts.last, simd_distance(a, b) > 0.3 else { return nil }
        return simd_normalize(b - a)
    }

    // Distance and squareness under the crosshair: green is good, orange
    // usable, red can't be marked.
    // A corner in view takes the place of the wall's reading, so it shows
    // when Mark corner will work.
    private var readout: some View {
        let r = depth.reading, c = depth.corner
        let colour: Color = switch c?.quality ?? r?.quality {
        case .good: .green
        case .fair: .orange
        default: .red
        }
        return Text(c?.text ?? r.map { $0.refusal ?? $0.text } ?? CrosshairReading.noReading)
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

    private func markTouch() {
        switch scan.markTouch() {
        case .marked(let p):
            MarkFeedback.good()
            if p.isCorner {
                checkCorner(next: true, note: String(format: "Corner marked by touch, %.0f°", p.angle ?? 0))
            } else {
                show("Touch 1 of 2 — now the other wall")
            }
        case .refused(let why):
            MarkFeedback.refused()
            show(why)
        }
    }

    // Touch needs the phone's camera position in its body (TouchMath), known for iPhones only.
    private var touchAvailable: Bool { depth.running && UIDevice.current.userInterfaceIdiom == .phone }

    private func toggleTouch() {
        touchMode.toggle()
        if touchMode && !touchExplained {
            touchExplained = true
            touchHelp = true
        }
    }

    private var touchStatus: some View {
        let last = scan.exteriorWalls.last?.last
        let text = switch last?.method ?? "" {
        case "touch": "Touch: 1 of 2 at this corner — now the other wall"
        case "touch-corner": "Touch: corner marked — on to the next"
        default: "Touch: 0 of 2 — phone flat on one wall, camera end at the corner"
        }
        return Text(text)
            .font(.footnote.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.indigo.opacity(0.85), in: Capsule())
    }

    private var touchSheet: some View {
        VStack(spacing: 16) {
            Image(systemName: "hand.point.up.left").font(.largeTitle)
            Text("Touch a corner").font(.title2.bold())
            Text("For a corner you can't see or aim at. Hold the phone flat on the siding, sideways, back to the wall, "
                 + "with its camera end right at the corner. Hold it still and press volume up. "
                 + "Then do the same on the other wall of the corner.")
            Text("Two touches make the corner. Press as soon as the phone is still: against the wall the camera sees nothing, "
                 + "and the phone only trusts its position for a moment. A low beep means try again.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Got it") { touchHelp = false }.buttonStyle(.borderedProminent)
        }
        .multilineTextAlignment(.center)
        .padding()
        .presentationDetents([.medium])
    }

    private func markCorner() {
        switch scan.markExteriorCorner() {
        case .marked(let p):
            MarkFeedback.good()
            checkCorner(next: true, note: String(format: "Corner marked, %.0f°, %.1f ft away", p.angle ?? 0, (p.distance ?? 0) * 3.28084))
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
        if depth.running && touchMode {
            return "Touch: hold the phone flat on the siding, sideways, back to the wall, camera end at the corner, "
                + "and press volume up. Then the same on the other wall of the corner. Tap Touch again to aim and mark."
        }
        if depth.running {
            return "Walk out slowly. Stand close and face the siding: green under the crosshair is best. "
                + "Mark 2 points on each outside wall (1 will do on a short wall), then tap Next wall at the corner. "
                + "Or aim at the corner itself and tap Mark corner: it ends this wall and starts the next. "
                + "A volume button or selfie-stick remote marks a point. "
                + "Back inside, aim at the start spot (green dot) and tap Check start spot."
        }
        return "Walk out slowly. For each outside wall, mark 2 or more points on the siding, then tap Next wall at the corner. "
            + "A volume button or selfie-stick remote marks a point too. "
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
                    if touchMode {
                        Button { markTouch() } label: { Label("Mark touch", systemImage: "hand.point.up.left.fill") }
                        .buttonStyle(.borderedProminent)
                        .tint(.indigo)
                    } else {
                        Button { markPoint() } label: { Label("Mark point", systemImage: "scope") }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .disabled(markRefusal != nil)
                        // Without LiDAR there is no depth to find two faces in.
                        if depth.running {
                            Button { markCorner() } label: { Label("Mark corner", systemImage: "square.split.bottomrightquarter") }
                            .buttonStyle(.borderedProminent)
                            .tint(depth.corner != nil ? .teal : .gray)
                        }
                    }
                    if touchAvailable {
                        Button { toggleTouch() } label: { Label("Touch", systemImage: "hand.point.up.left") }
                        .buttonStyle(.bordered)
                        .tint(touchMode ? .indigo : nil)
                    }
                }
                HStack {
                    Button("Undo", systemImage: "arrow.uturn.backward") { scan.undoExteriorPoint() }
                        .buttonStyle(.bordered)
                        .disabled(pointCount == 0)
                    Spacer()
                    Button("Next wall") { checkCorner(next: true) }
                    .buttonStyle(.bordered)
                    .disabled(scan.exteriorWalls.last.map { $0.isEmpty || ($0.count == 1 && $0[0].isCorner) } ?? true)
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
