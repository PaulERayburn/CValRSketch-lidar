import ARKit
import AVFoundation
import CoreMotion
import SwiftUI
import UIKit
import os
import simd

// Wide photo: a still from the 0.5× ultra-wide camera, which ARKit's world
// tracking never uses. The AR session is paused (not reset) while an
// ordinary camera session runs the ultra-wide, then run again with the same
// configuration and no reset options, so ARKit picks up its own world where
// it left off and everything scanned keeps its coordinates. Afterwards the
// phone's position is compared with where it was before the pause, to catch
// tracking that came back somewhere else. Only offered while RoomPlan is
// not capturing a room: RoomPlan owns the session then.

private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "CValRScan", category: "wide-photo")

@MainActor
final class WidePhoto: ObservableObject {
    enum Phase: Equatable { case idle, opening(String), live, capturing, saving, resuming }

    @Published private(set) var phase: Phase = .idle
    // Tracking didn't come back as it was: shown as an alert until dismissed.
    @Published var warning: String?
    // Where the flow was started (the outside walk, or the home screen), so
    // only that screen shows the camera and the warning.
    @Published private(set) var outside = false

    var active: Bool { phase != .idle }

    // Looked up once: hidden entirely on phones without an ultra-wide.
    static let isAvailable: Bool = WideCamera.device != nil

    let camera = WideCamera()
    private weak var scan: ScanController?
    private let motion = CMMotionManager()
    // Bumped whenever the flow moves on, so a late camera answer from an
    // earlier step (a Cancel meanwhile, say) is ignored.
    private var step = 0
    private var pose = matrix_identity_float4x4
    private var frameTime: TimeInterval = 0
    private var config: ARConfiguration?
    // The session's map, taken just before the pause: on resume ARKit is made to
    // find itself in it again. Resumed without one, it carried on from a guess
    // and could come back feet away from where the phone really was.
    private var map: ARWorldMap?
    private var arPaused = false
    private var depthWasRunning = false
    private var show: ((String) -> Void)?
    private var said: String?
    private var observers: [NSObjectProtocol] = []

    init(scan: ScanController) {
        self.scan = scan
        // Leaving the app with the camera up puts the AR session back. A
        // photo already being taken or saved finishes on its own.
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.leftApp() }
        })
    }

    // Why Wide photo can't be used now; nil when it can.
    static func refusal(_ scan: ScanController) -> String? {
        if scan.isScanning { return "Tap Done with room first" }
        if scan.isBusy { return "Wait for the room to finish processing" }
        if scan.isRelocalizing || scan.loadedFromFile || scan.recoveredNeedsResume { return "Resume on site first" }
        if scan.arSession.configuration == nil { return "Scan a room first" }
        return nil
    }

    // The values of the newest AR frame, never the frame itself: holding
    // frames starves tracking. nil when there is no frame newer than `after`.
    // The session's current map, or nil if ARKit can't give one within a few
    // seconds (too little seen yet).
    private static func currentMap(_ session: ARSession) async -> ARWorldMap? {
        await withCheckedContinuation { (done: CheckedContinuation<ARWorldMap?, Never>) in
            let once = OnceBox()
            session.getCurrentWorldMap { map, _ in once.run { done.resume(returning: map) } }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { once.run { done.resume(returning: nil) } }
        }
    }

    private func frameNow(after: TimeInterval? = nil) -> (pose: simd_float4x4, normal: Bool, time: TimeInterval, state: String)? {
        guard let f = scan?.arSession.currentFrame else { return nil }
        let t = f.timestamp
        if let after, t <= after { return nil }
        let state = f.camera.trackingState
        let normal: Bool
        if case .normal = state { normal = true } else { normal = false }
        return (f.camera.transform, normal, t, String(describing: state))
    }

    func begin(outside: Bool, show: @escaping (String) -> Void) {
        guard phase == .idle, Self.isAvailable, let scan else { return }
        if let why = Self.refusal(scan) { show(why); return }
        guard let now = frameNow() else { show("The camera isn't tracking yet. Try again in a moment."); return }
        guard now.normal else { show("Hold still until tracking settles, then try again."); return }
        guard let config = scan.arSession.configuration else { show("Scan a room first"); return }
        step += 1
        pose = now.pose
        frameTime = now.time
        self.config = config
        self.outside = outside
        self.show = show
        said = nil
        warning = nil
        phase = .opening("Opening the wide camera…")
        log.info("wide photo: start, outside \(outside)")
        let token = step
        Task { await open(token) }
    }

    private func open(_ token: Int) async {
        guard let scan else { phase = .idle; return }
        // A world map being saved needs the session running; it takes a few seconds.
        let wait = Date().addingTimeInterval(15)
        while scan.isSavingMap && Date() < wait {
            phase = .opening("Saving the AR session first…")
            try? await Task.sleep(for: .milliseconds(200))
            guard token == step else { return }
        }
        guard token == step else { return }
        phase = .opening("Saving where you are…")
        map = await Self.currentMap(scan.arSession)
        guard token == step else { return }
        if map == nil { log.warning("wide photo: no world map before the pause; resuming without one") }
        phase = .opening("Opening the wide camera…")
        depthWasRunning = scan.outsideDepth.running
        scan.outsideDepth.stop()
        scan.arPausedForWidePhoto = true
        scan.arSession.pause()
        arPaused = true
        if motion.isDeviceMotionAvailable { motion.startDeviceMotionUpdates() }
        // A moment for ARKit to let go of the camera.
        try? await Task.sleep(for: .milliseconds(300))
        guard token == step else { return }
        let ok = await camera.start()
        guard token == step else { return }
        if ok {
            phase = .live
        } else {
            log.error("wide photo: the ultra-wide camera wouldn't start")
            close("Couldn't open the wide camera")
        }
    }

    func shutter() {
        guard phase == .live, let scan else { return }
        phase = .capturing
        let token = step
        // Which way up, from how the phone is held now; else as it was at the tap.
        let turn = motion.deviceMotion.map { d in
            PhotoMath.uprightTurn(gravity: SIMD3(d.gravity.x, d.gravity.y, d.gravity.z))
        } ?? ScanController.uprightTurn(pose)
        let pose = pose, outside = outside
        Task {
            let data = await camera.capture()
            guard token == step, phase == .capturing else { return }
            phase = .saving
            let result = await scan.saveWidePhoto(data, turn: turn, camera: pose, outside: outside)
            guard token == step else { return }
            switch result {
            case .saved:
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                close("Wide photo \(scan.photos.count) saved")
            case .failed:
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                log.error("wide photo: capture or save failed")
                close("Couldn't take the wide photo. Try again.")
            }
        }
        // A capture that never answers mustn't leave the AR session paused.
        Task {
            try? await Task.sleep(for: .seconds(12))
            if token == step, phase == .capturing {
                log.error("wide photo: no answer from the camera")
                close("The wide camera didn't answer. Try again.")
            }
        }
    }

    func cancel() {
        guard phase == .live || phase.isOpening else { return }
        close("Wide photo cancelled")
    }

    private func leftApp() {
        guard phase == .live || phase.isOpening else { return }
        log.info("wide photo: app left with the camera up")
        close("Wide photo cancelled")
    }

    // Camera off, AR session back on, then the alignment check.
    private func close(_ message: String) {
        guard phase != .idle, phase != .resuming else { return }
        step += 1
        let token = step
        said = message
        motion.stopDeviceMotionUpdates()
        guard arPaused else {
            // Still waiting on a world-map save: nothing was paused.
            finish()
            show?(message)
            return
        }
        phase = .resuming
        Task {
            await camera.stop()
            guard token == step else { return }
            resumeAR(token)
        }
    }

    private func resumeAR(_ token: Int) {
        guard let scan, let config else { finish(); return }
        // With the map, ARKit relocalizes into it (as Resume on site does), so the
        // world keeps its coordinates and tracking only reads normal once found.
        // Without one, it is run on unreset and carries on as best it can.
        let relocalize: Bool
        if let map, let c = config.copy() as? ARWorldTrackingConfiguration {
            c.initialWorldMap = map
            scan.arSession.run(c, options: [.resetTracking, .removeExistingAnchors])
            relocalize = true
        } else {
            scan.arSession.run(config)
            relocalize = false
        }
        arPaused = false
        let before = SIMD3(pose.columns.3.x, pose.columns.3.y, pose.columns.3.z)
        var check = AlignmentCheck(before: before, start: ProcessInfo.processInfo.systemUptime,
                                   timeout: relocalize ? 15 : AlignmentCheck.timeout)
        let after = frameTime
        Task {
            var states: [String] = []
            while true {
                try? await Task.sleep(for: .milliseconds(100))
                guard token == step else { return }
                let now = frameNow(after: after)
                if let s = now?.state, states.last != s { states.append(s) }
                let position = now.map { SIMD3($0.pose.columns.3.x, $0.pose.columns.3.y, $0.pose.columns.3.z) }
                let outcome = check.feed(normal: now?.normal ?? false, position: position,
                                         at: ProcessInfo.processInfo.systemUptime)
                if outcome == .waiting { continue }
                report(outcome, states: states)
                return
            }
        }
    }

    private func report(_ outcome: AlignmentCheck.Outcome, states: [String]) {
        let message = said ?? ""
        let trail = states.joined(separator: " → ")
        switch outcome {
        case .waiting:
            return
        case .steady(let jump):
            log.info("wide photo: tracking back, moved \(jump, format: .fixed(precision: 3)) m; \(trail, privacy: .public)")
        case .moved(let jump):
            log.warning("wide photo: tracking moved \(jump, format: .fixed(precision: 3)) m; \(trail, privacy: .public)")
            warning = "Tracking moved \(AlignmentCheck.said(jump)) while the wide camera was up. If you stood still, "
                + (outside
                   ? "points marked from here may be off by that much. Check the orange dots still sit on the siding before marking more."
                   : "rooms scanned from here may not line up with the earlier ones. Point the phone at a room you've scanned and move it slowly for a few seconds before the next room.")
        case .lost:
            log.warning("wide photo: tracking not back in time; \(trail, privacy: .public)")
            warning = "Tracking hasn't come back after the wide photo. Move the phone slowly around "
                + (outside ? "the siding near you" : "the room")
                + " until it settles, then check "
                + (outside ? "the orange dots still sit on the siding before marking more." : "before scanning the next room.")
        }
        finish()
        show?(message)
    }

    private func finish() {
        scan?.arPausedForWidePhoto = false
        if depthWasRunning, outside, scan?.isOutside == true { scan?.outsideDepth.start() }
        depthWasRunning = false
        config = nil
        arPaused = false
        phase = .idle
    }
}

private extension WidePhoto.Phase {
    var isOpening: Bool { if case .opening = self { return true } else { return false } }
}

// The ultra-wide camera's own capture session. Everything on it runs on one
// serial queue, never the main thread; answers come back through async calls.
final class WideCamera: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    static var device: AVCaptureDevice? { AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back) }

    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "CValRScan.wide-camera")
    // Only touched on `queue`.
    private var output: AVCapturePhotoOutput?
    private var configured = false
    private var pending: ((Data?) -> Void)?

    func start() async -> Bool {
        await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            queue.async {
                if !self.configured { self.configured = self.configure() }
                guard self.configured else { c.resume(returning: false); return }
                if !self.session.isRunning { self.session.startRunning() }
                c.resume(returning: self.session.isRunning)
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.async {
                // A capture still out never answers once stopped.
                self.answer(nil)
                if self.session.isRunning { self.session.stopRunning() }
                c.resume()
            }
        }
    }

    func capture() async -> Data? {
        await withCheckedContinuation { (c: CheckedContinuation<Data?, Never>) in
            queue.async {
                guard self.pending == nil, let output = self.output, self.session.isRunning else { c.resume(returning: nil); return }
                let settings: AVCapturePhotoSettings
                if output.availablePhotoCodecTypes.contains(.hevc) {
                    settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
                } else {
                    settings = AVCapturePhotoSettings()
                }
                settings.maxPhotoDimensions = output.maxPhotoDimensions
                settings.photoQualityPrioritization = output.maxPhotoQualityPrioritization
                // The sensor's own way round, as AR frames come: the save turns it upright.
                if let conn = output.connection(with: .video), conn.isVideoRotationAngleSupported(0) { conn.videoRotationAngle = 0 }
                self.pending = { c.resume(returning: $0) }
                output.capturePhoto(with: settings, delegate: self)
            }
        }
    }

    // On `queue`: the session with the ultra-wide in and a photo output at
    // its largest size and best quality.
    private func configure() -> Bool {
        guard let device = Self.device, let input = try? AVCaptureDeviceInput(device: device) else { return false }
        let out = AVCapturePhotoOutput()
        session.beginConfiguration()
        if session.canSetSessionPreset(.photo) { session.sessionPreset = .photo }
        guard session.canAddInput(input), session.canAddOutput(out) else {
            session.commitConfiguration()
            return false
        }
        session.addInput(input)
        session.addOutput(out)
        session.commitConfiguration()
        // Only once committed is the camera's format the one the photo is
        // taken in; a size it doesn't list would stop the app.
        out.maxPhotoQualityPrioritization = .quality
        let sizes = device.activeFormat.supportedMaxPhotoDimensions
        if let biggest = sizes.max(by: { Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height) }) {
            out.maxPhotoDimensions = biggest
        }
        output = out
        return true
    }

    // On `queue`: hands the photo (or nil) to the one capture waiting, once.
    private func answer(_ data: Data?) {
        let p = pending
        pending = nil
        p?(data)
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let data = error == nil ? photo.fileDataRepresentation() : nil
        if let error { log.error("wide photo: \(error.localizedDescription, privacy: .public)") }
        queue.async { self.answer(data) }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        // Normally answered already; this catches a capture that ended with no photo.
        queue.async { self.answer(nil) }
    }
}

// The 0.5× button, beside the ordinary photo button. Hidden on phones
// without an ultra-wide camera.
struct WidePhotoButton: View {
    @ObservedObject var scan: ScanController
    @ObservedObject var wide: WidePhoto
    let outside: Bool
    let show: (String) -> Void

    var body: some View {
        if WidePhoto.isAvailable {
            Button {
                wide.begin(outside: outside, show: show)
            } label: {
                Text("0.5×").font(.headline.monospacedDigit()).padding(.vertical, 12).padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(.teal)
            .disabled(wide.active)
            .accessibilityLabel("Wide photo")
        }
    }
}

// The camera screen and the tracking warning, laid over the screen that
// started Wide photo (an overlay, not a cover, so that screen stays put).
struct WideCameraHost: View {
    @ObservedObject var wide: WidePhoto
    let outside: Bool

    var body: some View {
        ZStack {
            if wide.active && wide.outside == outside {
                WideCameraView(wide: wide).ignoresSafeArea()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert("Check tracking", isPresented: Binding(get: { wide.warning != nil && wide.outside == outside },
                                                      set: { if !$0 { wide.warning = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(wide.warning ?? "")
        }
    }
}

struct WideCameraView: View {
    @ObservedObject var wide: WidePhoto

    private var status: String? {
        switch wide.phase {
        case .opening(let s): s
        case .capturing, .saving: "Saving…"
        case .resuming: "Finding your place again: point at what you just scanned…"
        case .idle, .live: nil
        }
    }

    var body: some View {
        ZStack {
            Color.black
            WidePreview(session: wide.camera.session)
            VStack(spacing: 10) {
                Text("Wide photo · 0.5×")
                    .font(.headline)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.thinMaterial, in: Capsule())
                Text("Stay where you are: tracking picks up again from here when the camera closes.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .padding(8)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal)
                Spacer()
                if let status {
                    HStack(spacing: 8) { ProgressView(); Text(status) }
                        .padding(10)
                        .background(.thinMaterial, in: Capsule())
                }
                ZStack {
                    Button { wide.shutter() } label: {
                        Circle().strokeBorder(.white, lineWidth: 4)
                            .background(Circle().fill(wide.phase == .live ? Color.white : Color.gray))
                            .frame(width: 72, height: 72)
                    }
                    .disabled(wide.phase != .live)
                    .accessibilityLabel("Take wide photo")
                    HStack {
                        Button("Cancel", role: .cancel) { wide.cancel() }
                            .buttonStyle(.bordered)
                            .tint(.white)
                            .disabled(wide.phase != .live && !isOpening)
                        Spacer()
                    }
                }
                .padding(.horizontal)
            }
            .padding(.vertical, 60)
        }
    }

    private var isOpening: Bool { if case .opening = wide.phase { return true } else { return false } }
}

// The live picture, aspect-fit so the whole frame shows.
struct WidePreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var preview: AVCaptureVideoPreviewLayer? { layer as? AVCaptureVideoPreviewLayer }

        override func layoutSubviews() {
            super.layoutSubviews()
            // The picture turned to match the screen (portrait on iPhone).
            let angle: CGFloat = switch window?.windowScene?.interfaceOrientation {
            case .landscapeRight: 0
            case .landscapeLeft: 180
            case .portraitUpsideDown: 270
            default: 90
            }
            if let c = preview?.connection, c.isVideoRotationAngleSupported(angle) { c.videoRotationAngle = angle }
        }
    }

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.backgroundColor = .black
        v.preview?.session = session
        v.preview?.videoGravity = .resizeAspect
        return v
    }

    func updateUIView(_ uiView: PreviewView, context: Context) { uiView.setNeedsLayout() }
}

// Runs its block at most once, from whichever caller gets there first.
private final class OnceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ body: () -> Void) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { body() }
    }
}
