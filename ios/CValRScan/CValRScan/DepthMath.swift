import Foundation
import simd

// The geometry behind LiDAR marking on the outside walk, kept free of ARKit
// so it can be checked on a Mac against made-up points. World coordinates
// are ARKit's: metres, y up, plan x = world x and plan y = world z.
enum DepthMath {
    // n·p = d, with n of unit length.
    struct Plane: Equatable {
        var normal: SIMD3<Double>
        var d: Double
        func distance(_ p: SIMD3<Double>) -> Double { simd_dot(normal, p) - d }
        // Degrees between the plane and upright: 0 for a plumb wall.
        var tilt: Double { asin(min(abs(normal.y), 1)) * 180 / .pi }
    }

    // ARKit camera space: x right, y up, looking down −z, in the sensor's
    // own (landscape) orientation, with depth measured along −z. Pixel rows
    // grow downwards, hence the flipped y.
    static func unproject(u: Double, v: Double, depth: Double,
                          fx: Double, fy: Double, cx: Double, cy: Double,
                          camera: simd_double4x4) -> SIMD3<Double> {
        let local = SIMD4((u - cx) * depth / fx, -(v - cy) * depth / fy, -depth, 1)
        let w = camera * local
        return SIMD3(w.x, w.y, w.z)
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    // Least squares: through the centroid, facing along the covariance's
    // weakest direction.
    static func fitPlane(_ pts: [SIMD3<Double>]) -> (plane: Plane, rms: Double)? {
        guard pts.count >= 3 else { return nil }
        let c = pts.reduce(SIMD3<Double>.zero, +) / Double(pts.count)
        var m = simd_double3x3()
        for p in pts {
            let q = p - c
            m += simd_double3x3(rows: [q * q.x, q * q.y, q * q.z])
        }
        let (values, vectors) = symmetricEigen(m)
        let k = values.indices.min { values[$0] < values[$1] }!
        let n = simd_normalize(vectors[k])
        guard n.x.isFinite, n.y.isFinite, n.z.isFinite else { return nil }
        let plane = Plane(normal: n, d: simd_dot(n, c))
        let rms = (pts.reduce(0) { $0 + pow(plane.distance($1), 2) } / Double(pts.count)).squareRoot()
        return (plane, rms)
    }

    // Jacobi rotations; three by three converges in a handful of sweeps.
    static func symmetricEigen(_ input: simd_double3x3) -> (values: [Double], vectors: [SIMD3<Double>]) {
        var a = [[Double]](repeating: [0, 0, 0], count: 3)
        for i in 0..<3 { for j in 0..<3 { a[i][j] = input[j][i] } }
        var v: [[Double]] = [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
        for _ in 0..<30 {
            let off = a[0][1] * a[0][1] + a[0][2] * a[0][2] + a[1][2] * a[1][2]
            if off < 1e-24 { break }
            for (p, q) in [(0, 1), (0, 2), (1, 2)] where abs(a[p][q]) > 1e-30 {
                let theta = (a[q][q] - a[p][p]) / (2 * a[p][q])
                let t = (theta >= 0 ? 1 : -1) / (abs(theta) + (theta * theta + 1).squareRoot())
                let c = 1 / (t * t + 1).squareRoot(), s = t * c
                for k in 0..<3 {
                    let akp = a[k][p], akq = a[k][q]
                    a[k][p] = c * akp - s * akq
                    a[k][q] = s * akp + c * akq
                }
                for k in 0..<3 {
                    let apk = a[p][k], aqk = a[q][k]
                    a[p][k] = c * apk - s * aqk
                    a[q][k] = s * apk + c * aqk
                }
                for k in 0..<3 {
                    let vkp = v[k][p], vkq = v[k][q]
                    v[k][p] = c * vkp - s * vkq
                    v[k][q] = s * vkp + c * vkq
                }
            }
        }
        return ([a[0][0], a[1][1], a[2][2]], (0..<3).map { SIMD3(v[0][$0], v[1][$0], v[2][$0]) })
    }

    // Repeatable pseudo-random numbers, so the same samples always give the same fit.
    struct SplitMix: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    // RANSAC over near-upright planes only, so a strip that catches some
    // ground or a soffit still finds the wall; then refitted to its inliers
    // and trimmed twice. Trees, downpipes and the fence behind fall out as
    // samples more than `tolerance` off.
    static func uprightPlane(_ pts: [SIMD3<Double>], tolerance: Double = 0.03,
                             maxTilt: Double = 15, iterations: Int = 200) -> (plane: Plane, inliers: [SIMD3<Double>], rms: Double)? {
        guard pts.count >= 3 else { return nil }
        var rng = SplitMix(state: UInt64(pts.count))
        let probe = pts.count > 1500 ? (0..<1500).map { _ in pts[Int.random(in: 0..<pts.count, using: &rng)] } : pts
        let maxNy = sin(maxTilt * .pi / 180)
        var best: (plane: Plane, score: Int)?
        for _ in 0..<iterations {
            let a = probe[Int.random(in: 0..<probe.count, using: &rng)]
            let b = probe[Int.random(in: 0..<probe.count, using: &rng)]
            let c = probe[Int.random(in: 0..<probe.count, using: &rng)]
            let cross = simd_cross(b - a, c - a)
            let len = simd_length(cross)
            guard len > 1e-6 else { continue }
            let n = cross / len
            guard abs(n.y) <= maxNy else { continue }
            let plane = Plane(normal: n, d: simd_dot(n, a))
            let score = probe.reduce(0) { abs(plane.distance($1)) <= tolerance ? $0 + 1 : $0 }
            if score > (best?.score ?? 0) { best = (plane, score) }
        }
        guard var plane = best?.plane else { return nil }
        var inliers: [SIMD3<Double>] = []
        var rms = 0.0
        for _ in 0..<3 {
            inliers = pts.filter { abs(plane.distance($0)) <= tolerance }
            guard let fit = fitPlane(inliers) else { return nil }
            plane = fit.plane
            rms = fit.rms
        }
        inliers = pts.filter { abs(plane.distance($0)) <= tolerance }
        return (plane, inliers, rms)
    }

    static func rayPlane(origin: SIMD3<Double>, direction: SIMD3<Double>, plane: Plane) -> SIMD3<Double>? {
        let denom = simd_dot(plane.normal, direction)
        guard abs(denom) > 1e-6 else { return nil }
        let t = (plane.d - simd_dot(plane.normal, origin)) / denom
        return t > 0 ? origin + direction * t : nil
    }

    // Degrees between the line of sight and the surface's facing: 0 when square on.
    static func incidence(direction: SIMD3<Double>, normal: SIMD3<Double>) -> Double {
        acos(min(abs(simd_dot(simd_normalize(direction), simd_normalize(normal))), 1)) * 180 / .pi
    }

    struct Strip {
        var point: SIMD3<Double>          // on the wall, under the crosshair
        var dir: SIMD2<Double>            // the wall's run in plan (x, z), unit
        var span: (SIMD2<Double>, SIMD2<Double>)
        var rms: Double
        var count: Int
        var distance: Double
        var angle: Double
        var tilt: Double
    }

    enum StripFailure: Error, Equatable {
        case tooFewSamples, noWall, notUpright, tooFar, offWall
    }

    // A strip of siding seen across the screen, as a wall line in plan.
    // `aim`, when known, is the depth point at the crosshair: the wall found
    // must be the one under it, not a fence or the house next door.
    static func wallStrip(_ pts: [SIMD3<Double>], cameraOrigin: SIMD3<Double>, cameraForward: SIMD3<Double>,
                          aim: SIMD3<Double>? = nil, maxDistance: Double = 5) -> Result<Strip, StripFailure> {
        guard pts.count >= 60 else { return .failure(.tooFewSamples) }
        guard let fit = uprightPlane(pts) else { return .failure(.noWall) }
        guard fit.inliers.count >= max(60, pts.count * 3 / 10) else { return .failure(.noWall) }
        guard fit.plane.tilt <= 10 else { return .failure(.notUpright) }
        if let aim, abs(fit.plane.distance(aim)) > 0.1 { return .failure(.offWall) }
        guard let point = rayPlane(origin: cameraOrigin, direction: simd_normalize(cameraForward), plane: fit.plane)
        else { return .failure(.offWall) }
        let distance = simd_distance(point, cameraOrigin)
        guard distance <= maxDistance else { return .failure(.tooFar) }
        let n2 = simd_normalize(SIMD2(fit.plane.normal.x, fit.plane.normal.z))
        let dir = SIMD2(-n2.y, n2.x)
        let p2 = SIMD2(point.x, point.z)
        // The strip's ends, ignoring the outermost 2% of samples either way.
        let ts = fit.inliers.map { simd_dot(SIMD2($0.x, $0.z) - p2, dir) }.sorted()
        let lo = ts[Int(Double(ts.count - 1) * 0.02)], hi = ts[Int(Double(ts.count - 1) * 0.98)]
        return .success(Strip(point: point, dir: dir, span: (p2 + dir * lo, p2 + dir * hi), rms: fit.rms,
                              count: fit.inliers.count, distance: distance,
                              angle: incidence(direction: cameraForward, normal: fit.plane.normal), tilt: fit.plane.tilt))
    }
}
