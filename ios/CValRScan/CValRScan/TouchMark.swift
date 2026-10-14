import Foundation
import simd

// Touch marks: where a corner can't be seen or aimed at (a rose bush against
// it), the phone is pushed flat on the siding, sideways, back to the wall,
// camera end at the corner, and its own pose is the measurement. Kept free of
// ARKit so it can be checked on a Mac against made-up poses.
//
// ARKit camera space: x along the phone's long axis from the front camera
// toward the bottom (Home button) end, y up in that landscape orientation,
// +z out of the screen. So, back to the wall, +z is the wall's outward
// normal and the camera (top) end of the phone is −x.
enum TouchMath {
    // Where the 1× (ARKit) camera sits in the body, millimetres. The phone
    // rests on the camera bump at its top end and on the back glass's edge
    // at the bottom, so it leans off the wall a little; that lean is taken out.
    struct Offsets: Equatable {
        var toFace: Double    // lens centre to the bump's face, along the camera axis
        var toTop: Double     // lens centre to the top edge, along the long axis
        var toSide: Double    // lens centre to the nearer long side
        var bump: Double      // how far the bump stands off the back glass
        var bumpEnd: Double   // lens centre to the bump's edge toward the bottom
        var length: Double    // body, top to bottom
        var width: Double     // body, side to side

        // How far the long axis leans off the wall (radians).
        var lean: Double { atan2(bump, length - toTop - bumpEnd) }
    }

    // Estimates from Apple's published body sizes and the camera layout in
    // its photos: the main (1×) lens is the lower left of the three seen from
    // the back on 13 Pro to 16 Pro. Good to a few millimetres if so; check
    // on a seen corner (see the README) before relying on a new model.
    static func offsets(model: String) -> Offsets {
        func m(_ face: Double, _ top: Double, _ side: Double, _ bump: Double, _ end: Double, _ len: Double, _ w: Double) -> Offsets {
            Offsets(toFace: face, toTop: top, toSide: side, bump: bump, bumpEnd: end, length: len, width: w)
        }
        switch model {
        case "iPhone13,3": return m(4.0, 25.0, 11.0, 1.5, 7.5, 146.7, 71.5)    // 12 Pro
        case "iPhone13,4": return m(4.0, 27.0, 12.0, 1.8, 8.5, 160.8, 78.1)    // 12 Pro Max
        case "iPhone14,2": return m(5.0, 30.0, 13.0, 3.6, 9.0, 146.7, 71.5)    // 13 Pro
        case "iPhone14,3": return m(5.0, 31.0, 13.5, 3.6, 9.5, 160.8, 78.1)    // 13 Pro Max
        case "iPhone15,2": return m(5.5, 30.5, 13.5, 4.2, 9.5, 147.5, 71.5)    // 14 Pro
        case "iPhone15,3": return m(5.5, 31.5, 14.0, 4.2, 10.0, 160.7, 77.6)   // 14 Pro Max
        case "iPhone16,1": return m(5.5, 30.0, 13.5, 4.0, 9.5, 146.6, 70.6)    // 15 Pro
        case "iPhone16,2": return m(5.5, 31.0, 14.0, 4.0, 10.0, 159.9, 76.7)   // 15 Pro Max
        case "iPhone17,1": return m(5.5, 31.0, 14.0, 4.3, 10.0, 149.6, 71.5)   // 16 Pro
        case "iPhone17,2": return m(5.5, 32.0, 14.5, 4.3, 10.5, 163.0, 77.6)   // 16 Pro Max
        default: return m(5.5, 30.0, 13.5, 4.0, 9.5, 146.6, 70.6)              // as a 15 Pro
        }
    }

    // "iPhone16,1"; the simulator says so instead.
    static var modelIdentifier: String {
        if let sim = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return sim }
        var u = utsname()
        uname(&u)
        return withUnsafeBytes(of: &u.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    struct Touch: Equatable {
        var point: SIMD3<Double>      // the siding at the phone's camera end, world
        var dir: SIMD2<Double>        // the face's run in plan, unit, away from the corner
        var normal: SIMD3<Double>     // the wall's outward facing, world
    }

    enum Failure: Error, Equatable { case notUpright, notSideways }

    static let uprightDeg = 10.0, levelDeg = 20.0

    // `camera` is ARCamera.transform. Lengths in metres from here on.
    static func touch(camera: simd_double4x4, offsets o: Offsets) -> Result<Touch, Failure> {
        let mm = 0.001
        let run = o.length - o.toTop - o.bumpEnd
        // In camera space, the wall's line in the x–z plane: through the
        // bump's lower edge, leaning out toward the bottom end.
        let along = simd_normalize(SIMD3(run, 0, o.bump))
        let facing = simd_normalize(SIMD3(-o.bump, 0, run))
        let zTop = -o.toFace - (o.toTop + o.bumpEnd) * o.bump / run
        // The middle of the top edge, so a phone not quite level is out by half its width's tilt at most.
        let tip = SIMD4(-o.toTop * mm, (o.toSide - o.width / 2) * mm, zTop * mm, 1)
        func world(_ v: SIMD3<Double>) -> SIMD3<Double> {
            let w = camera * SIMD4(v, 0)
            return SIMD3(w.x, w.y, w.z)
        }
        let n = simd_normalize(world(facing)), u = simd_normalize(world(along))
        guard abs(n.y) <= sin(uprightDeg * .pi / 180) else { return .failure(.notUpright) }
        guard abs(u.y) <= sin(levelDeg * .pi / 180) else { return .failure(.notSideways) }
        let p = camera * tip
        // The face's run is level across the wall's facing, which holds on
        // lap siding (tipped out) and with the phone not quite level; the
        // long axis says only which way is away from the corner.
        var dir = simd_normalize(SIMD2(-n.z, n.x))
        if simd_dot(dir, SIMD2(u.x, u.z)) < 0 { dir = -dir }
        return .success(Touch(point: SIMD3(p.x, p.y, p.z), dir: dir, normal: n))
    }

    struct Corner: Equatable {
        var point: SIMD3<Double>
        var dirs: [SIMD2<Double>]     // as touched: first, then second
        var angle: Double             // degrees between the faces
        var rms: Double               // half the gap between the two touches
    }

    enum PairFailure: Error, Equatable { case apart, sameWall }

    static let pairMetres = 0.3, pairMinDeg = 60.0, pairMaxDeg = 120.0

    // Two touches, one on each wall of a corner: where the faces' lines meet.
    // `.apart` means they are two touches, not one corner.
    static func corner(_ a: Touch, _ b: Touch) -> Result<Corner, PairFailure> {
        let pa = SIMD2(a.point.x, a.point.z), pb = SIMD2(b.point.x, b.point.z)
        let gap = simd_distance(pa, pb)
        guard gap <= pairMetres else { return .failure(.apart) }
        let angle = acos(min(max(simd_dot(a.dir, b.dir), -1), 1)) * 180 / .pi
        guard angle >= pairMinDeg, angle <= pairMaxDeg else { return .failure(.sameWall) }
        // pa + s·da = pb + t·db
        let det = a.dir.x * -b.dir.y - a.dir.y * -b.dir.x
        let r = pb - pa
        let s = (r.x * -b.dir.y - r.y * -b.dir.x) / det
        let c = pa + s * a.dir
        return .success(Corner(point: SIMD3(c.x, (a.point.y + b.point.y) / 2, c.y), dirs: [a.dir, b.dir],
                               angle: angle, rms: gap / 2))
    }
}
