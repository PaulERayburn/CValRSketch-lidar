import Foundation
import ImageIO
import simd

// The plain arithmetic behind photos: which way up a picture goes, and
// whether tracking came back where it was after the wide camera. No ARKit,
// AVFoundation or UIKit, so it builds on a Mac for testing.
enum PhotoMath {
    // An angle brought into −π…π.
    static func wrap(_ a: Double) -> Double { atan2(sin(a), cos(a)) }

    // The back camera's picture is landscape, its +y up when the phone lies
    // sideways with the charging port on the right. `upX`/`upY` say how far
    // the picture's x and y axes point up (−1…1): turn by whichever is
    // nearer upright, so a photo taken sideways stays landscape and one taken
    // upright stays portrait, whatever way the screen is locked.
    static func uprightTurn(upX x: Float, upY y: Float) -> CGImagePropertyOrientation {
        if abs(y) >= abs(x) { return y >= 0 ? .up : .down }
        return x <= 0 ? .right : .left
    }

    // The same from Core Motion's gravity (device axes: x right and y up the
    // screen held upright, z out of it; gravity points down). The picture's
    // x runs along the device's −y and its y along the device's +x, so how
    // far each points up is −(axis · gravity).
    static func upAxes(gravity g: SIMD3<Double>) -> (x: Float, y: Float) {
        (Float(g.y), Float(-g.x))
    }

    static func uprightTurn(gravity g: SIMD3<Double>) -> CGImagePropertyOrientation {
        let a = upAxes(gravity: g)
        return uprightTurn(upX: a.x, upY: a.y)
    }
}

// After the AR session resumes from the wide camera: wait for tracking to be
// normal and stay so for a moment, then compare where the phone is now with
// where it was before the pause. The user stands still, so a jump of more
// than 10 cm means tracking re-settled somewhere else; no normal tracking
// within 5 s means it hasn't found its place yet.
struct AlignmentCheck {
    // How far the phone may be from where the wide camera opened before the
    // check warns. The phone swings with the body when the user turns on the
    // spot (a half-turn moves it ~2 ft), so this can't be inches. Relocalized
    // into the map, the coordinates are already right and only a gross jump
    // means a wrong match; resumed without a map, allow a turn on the spot.
    static let relocalizedLimit: Float = 1.5   // m, about 5 ft
    static let unmappedLimit: Float = 0.6      // m, about 2 ft
    static let timeout: TimeInterval = 5
    static let settle: TimeInterval = 0.5

    enum Outcome: Equatable { case waiting, steady(Float), moved(Float), lost }

    let before: SIMD3<Float>
    let start: TimeInterval
    let limit: TimeInterval
    let jumpLimit: Float
    private var normalSince: TimeInterval?

    init(before: SIMD3<Float>, start: TimeInterval, timeout: TimeInterval = AlignmentCheck.timeout,
         jumpLimit: Float = AlignmentCheck.unmappedLimit) {
        self.before = before
        self.start = start
        self.limit = timeout
        self.jumpLimit = jumpLimit
    }

    // One look at the tracking: `position` nil when there is no new frame yet.
    mutating func feed(normal: Bool, position: SIMD3<Float>?, at t: TimeInterval) -> Outcome {
        let timedOut = t - start >= limit
        if normal, let p = position {
            let since = normalSince ?? t
            normalSince = since
            if t - since >= Self.settle || timedOut { return judge(simd_distance(p, before)) }
        } else {
            normalSince = nil
        }
        return timedOut ? .lost : .waiting
    }

    func judge(_ jump: Float) -> Outcome { jump > jumpLimit ? .moved(jump) : .steady(jump) }

    // "4″", "1′ 3″": how the jump is said to the user.
    static func said(_ metres: Float) -> String {
        let inches = Int((Double(metres) * 39.37).rounded())
        return inches < 12 ? "\(inches)″" : "\(inches / 12)′ \(inches % 12)″"
    }
}
