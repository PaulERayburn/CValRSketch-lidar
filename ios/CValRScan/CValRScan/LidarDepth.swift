import ARKit
import Foundation
import simd

// LiDAR depth for the outside walk. Raycasts against estimated planes come
// from camera features, which plain siding seen at a slant has few of: on a
// real house they landed 10–30″ off the wall. The depth map measures the
// siding itself, and is best close up, which is how side yards are walked.
struct CrosshairReading: Equatable {
    var point: SIMD3<Double>
    var distance: Double      // metres
    var angle: Double         // degrees between the line of sight and the wall's facing

    enum Quality { case good, fair, poor }

    static let goodFeet = 12.0, fairFeet = 16.0
    static let goodAngle = 30.0, fairAngle = 50.0

    var feet: Double { distance * 3.28084 }
    var text: String { String(format: "%.1f ft · %.0f° off square", feet, angle) }
    var quality: Quality {
        if feet <= Self.goodFeet && angle <= Self.goodAngle { return .good }
        if feet <= Self.fairFeet && angle <= Self.fairAngle { return .fair }
        return .poor
    }
    // Why a poor reading can't be marked.
    var refusal: String? {
        guard quality == .poor else { return nil }
        return feet > Self.fairFeet ? Self.tooFar : "Face the wall more squarely"
    }
    static let tooFar = "Too far — move within 12 ft"
    static let noReading = "No LiDAR reading — aim at the siding"
}

// Two faces of siding meeting under the crosshair: Mark corner will work.
struct CornerReading: Equatable {
    var distance: Double      // metres
    var angle: Double         // degrees between the faces
    var convex: Bool
    var feet: Double { distance * 3.28084 }
    var text: String { String(format: "%@ · %.1f ft · %.0f°", convex ? "Corner" : "Inside corner", feet, angle) }
    var quality: CrosshairReading.Quality { feet <= CrosshairReading.goodFeet ? .good : .fair }
}

// A point marked on the siding. Older scans have the point only; newer ones
// say how it was found and how good it was, so the importer can weigh it.
// A marked corner is a point too: the last of one wall and the first of the next.
struct ExteriorPoint: Equatable {
    var point: SIMD3<Float>
    var kind: String?                 // "corner", or nil for a point on a wall
    var method: String?               // "lidar" (depth strip), "plane" (estimated plane) or "lidar-corner"
    var distance: Double?             // metres from the phone
    var angle: Double?                // degrees off square; for a corner, between its faces
    var rms: Double?                  // metres, the strip's fit
    var n: Int?                       // depth samples in the fit
    var camera: SIMD2<Double>?        // where the phone was, plan x, z
    var dir: SIMD2<Double>?           // the wall's run, plan, unit
    var span: [SIMD2<Double>]?        // the strip's two ends, plan
    var dirs: [SIMD2<Double>]?        // a corner's faces, plan, unit, each away from the corner:
                                      // the wall it ends first, then the wall it starts

    var isCorner: Bool { kind == "corner" }

    // Moved by a drift correction, along with everything else it located.
    func shifted(by d: SIMD3<Float>) -> ExteriorPoint {
        var p = self
        let d2 = SIMD2(Double(d.x), Double(d.z))
        p.point += d
        p.camera = camera.map { $0 + d2 }
        p.span = span?.map { $0 + d2 }
        return p
    }
}

// One depth frame's samples, already in world coordinates, so no ARFrame is
// held: holding frames starves the session (see MarkedPointsOverlay).
private struct DepthSample {
    var time: TimeInterval
    var origin: SIMD3<Double>
    var forward: SIMD3<Double>
    var band: [SIMD3<Double>]
    var aim: SIMD3<Double>?
    var reading: CrosshairReading?
    var run: SIMD2<Double>?
}

@MainActor
final class OutsideDepth: ObservableObject {
    static var isSupported: Bool { ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) }

    @Published private(set) var reading: CrosshairReading?
    @Published private(set) var corner: CornerReading?
    // The run in plan of the wall under the crosshair, to tell when the aim
    // has moved on to another wall.
    @Published private(set) var aimRun: SIMD2<Double>?
    @Published private(set) var running = false

    private let session: ARSession
    private var timer: Timer?
    private var recent: [DepthSample] = []
    private var ticks = 0

    init(session: ARSession) { self.session = session }

    func start() {
        guard Self.isSupported, timer == nil else { return }
        running = true
        // Ten samples a second is plenty for a phone held still on a wall,
        // and leaves the session's frames alone in between.
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        recent = []
        reading = nil
        corner = nil
        aimRun = nil
        running = false
    }

    private func sample() {
        ticks += 1
        let s = session.currentFrame.flatMap(Self.extract)
        // A gap in depth (tracking lost, phone covered) starts afresh, so a
        // mark never uses siding seen before it.
        if let s { recent.append(s) } else { recent = [] }
        // Read the newest time first: reading `recent` inside its own removeAll
        // is an overlapping access, which Swift stops the app for.
        let cutoff = (recent.last?.time ?? 0) - 0.6
        recent.removeAll { $0.time < cutoff }
        // The readout changes four times a second at most, so the view
        // doesn't redraw on every sample.
        if ticks % 3 == 0 {
            let r = s?.reading
            if r?.text != reading?.text || r?.quality != reading?.quality { reading = r }
            switch (s?.run, aimRun) {
            case (nil, nil): break
            case (let a?, let b?) where abs(simd_dot(a, b)) > cos(5 * .pi / 180): break
            case (let a, _): aimRun = a
            }
            // A couple of milliseconds on the band, so it is figured with the readout, not every sample.
            var c: CornerReading?
            if case .success(let k) = cornerFit() { c = CornerReading(distance: k.distance, angle: k.angle, convex: k.convex) }
            if c?.text != corner?.text { corner = c }
        }
    }

    // Where the phone was for the latest sample, plan x, z.
    var cameraPlan: SIMD2<Double>? { recent.last.map { SIMD2($0.origin.x, $0.origin.z) } }

    // The wall under the crosshair from the last ~0.6 s of depth: many
    // frames' worth of siding fitted as one plane.
    func strip() -> Result<DepthMath.Strip, DepthMath.StripFailure> {
        guard let last = recent.last else { return .failure(.tooFewSamples) }
        return DepthMath.wallStrip(recent.flatMap(\.band), cameraOrigin: last.origin, cameraForward: last.forward,
                                   aim: last.aim)
    }

    // Two faces meeting, from the same depth as `strip`.
    func cornerFit() -> Result<DepthMath.Corner, DepthMath.CornerFailure> {
        guard let last = recent.last else { return .failure(.tooFewSamples) }
        return DepthMath.corner(recent.flatMap(\.band), cameraOrigin: last.origin, cameraForward: last.forward,
                                maxDistance: CrosshairReading.fairFeet / 3.28084)
    }

    // The way the phone faces in plan: the screen's right is to the right of it.
    var forwardPlan: SIMD2<Double>? { recent.last.map { SIMD2($0.forward.x, $0.forward.z) } }

    // MARK: Reading the depth map

    private static func extract(_ frame: ARFrame) -> DepthSample? {
        guard let depth = frame.smoothedSceneDepth ?? frame.sceneDepth,
              let confidence = depth.confidenceMap,
              case .normal = frame.camera.trackingState else { return nil }
        let map = depth.depthMap
        CVPixelBufferLockBaseAddress(map, .readOnly)
        CVPixelBufferLockBaseAddress(confidence, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(map, .readOnly)
            CVPixelBufferUnlockBaseAddress(confidence, .readOnly)
        }
        let w = CVPixelBufferGetWidth(map), h = CVPixelBufferGetHeight(map)
        guard w > 20, h > 20, CVPixelBufferGetWidth(confidence) == w, CVPixelBufferGetHeight(confidence) == h,
              let dBase = CVPixelBufferGetBaseAddress(map), let cBase = CVPixelBufferGetBaseAddress(confidence) else { return nil }
        let dRow = CVPixelBufferGetBytesPerRow(map), cRow = CVPixelBufferGetBytesPerRow(confidence)
        func depthAt(_ u: Int, _ v: Int) -> Double? {
            let c = cBase.advanced(by: v * cRow + u).assumingMemoryBound(to: UInt8.self).pointee
            guard c == UInt8(ARConfidenceLevel.high.rawValue) else { return nil }
            let d = Double(dBase.advanced(by: v * dRow + u * 4).assumingMemoryBound(to: Float32.self).pointee)
            return d.isFinite && d > 0.1 ? d : nil
        }
        // Intrinsics are for the camera image; the depth map is the same view, smaller.
        let k = frame.camera.intrinsics
        let sx = Double(w) / Double(frame.camera.imageResolution.width)
        let sy = Double(h) / Double(frame.camera.imageResolution.height)
        let fx = Double(k[0][0]) * sx, fy = Double(k[1][1]) * sy
        let cx = Double(k[2][0]) * sx, cy = Double(k[2][1]) * sy
        let t = frame.camera.transform
        let cam = simd_double4x4(SIMD4<Double>(t.columns.0), SIMD4<Double>(t.columns.1),
                                 SIMD4<Double>(t.columns.2), SIMD4<Double>(t.columns.3))
        func world(_ u: Int, _ v: Int, _ d: Double) -> SIMD3<Double> {
            DepthMath.unproject(u: Double(u), v: Double(v), depth: d, fx: fx, fy: fy, cx: cx, cy: cy, camera: cam)
        }
        let origin = SIMD3(cam.columns.3.x, cam.columns.3.y, cam.columns.3.z)
        let forward = -SIMD3(cam.columns.2.x, cam.columns.2.y, cam.columns.2.z)
        let mu = w / 2, mv = h / 2

        // Crosshair: the screen's centre is the image's centre whatever the
        // orientation, since the view crops the image evenly.
        var centre: [Double] = []
        for v in (mv - 2)...(mv + 2) { for u in (mu - 2)...(mu + 2) { if let d = depthAt(u, v) { centre.append(d) } } }
        var aim: SIMD3<Double>?
        if centre.count >= 8, let d = DepthMath.median(centre) { aim = world(mu, mv, d) }

        // A band across the screen, level in the world: the image is in the
        // sensor's landscape orientation, so pick whichever image axis lies
        // flatter, which covers portrait, landscape and a stick held sideways.
        let uLevel = abs(cam.columns.0.y) <= abs(cam.columns.1.y)
        let (along, across) = uLevel ? (w, h) : (h, w)
        let half = Int(Double(along) * 0.35), thick = Int(Double(across) * 0.12)
        var band: [SIMD3<Double>] = []
        for a in stride(from: -half, through: half, by: 3) {
            for b in stride(from: -thick, through: thick, by: 3) {
                let u = uLevel ? mu + a : mu + b, v = uLevel ? mv + b : mv + a
                guard u >= 0, u < w, v >= 0, v < h, let d = depthAt(u, v) else { continue }
                band.append(world(u, v, d))
            }
        }
        // The readout: depth at the centre and, from a plane through a
        // slightly larger patch, how square on the wall is.
        var reading: CrosshairReading?
        var run: SIMD2<Double>?
        if let aim {
            var patch: [SIMD3<Double>] = []
            for v in stride(from: mv - 9, through: mv + 9, by: 2) {
                for u in stride(from: mu - 9, through: mu + 9, by: 2) { if let d = depthAt(u, v) { patch.append(world(u, v, d)) } }
            }
            if patch.count >= 40, var fit = DepthMath.fitPlane(patch) {
                // One trim, so a window edge or downpipe in the patch doesn't tip it.
                let kept = patch.filter { abs(fit.plane.distance($0)) <= max(0.02, 2 * fit.rms) }
                if kept.count >= 30, let again = DepthMath.fitPlane(kept) { fit = again }
                reading = CrosshairReading(point: aim, distance: simd_distance(aim, origin),
                                           angle: DepthMath.incidence(direction: aim - origin, normal: fit.plane.normal))
                let n2 = SIMD2(fit.plane.normal.x, fit.plane.normal.z)
                if simd_length(n2) > 0.5 { run = simd_normalize(SIMD2(-n2.y, n2.x)) }
            }
        }
        return DepthSample(time: frame.timestamp, origin: origin, forward: forward, band: band, aim: aim, reading: reading, run: run)
    }
}
