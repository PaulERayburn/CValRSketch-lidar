import Foundation
import RoomPlan
import simd

// Flattens a RoomPlan structure into the small top-down JSON that
// lidar-import.mjs reads (format described in ios/CValRScan/README.md).
// Plan coordinates: x = world x, y = world z, so +y points "down" the page,
// matching CValRSketch's Y-down convention. All lengths are metres, except
// meter readings, which are whole inches as entered (ANSI Z765 precision).
enum PlanExport {
    struct Plan: Encodable {
        var format = "cvalrscan"
        var version = 3
        var units = "m"
        let createdAt: String
        let walls: [Segment]
        let doors: [Segment]
        let windows: [Segment]
        let openings: [Segment]
        let floors: [Floor]
        let sections: [Section]
        let corners: [Corner]
        let measurements: [Measurement]
        let exterior: Exterior
    }

    // Outside walk: siding points per exterior wall in the order taken, and
    // the door-side spot marked going out and coming back (their difference
    // is the tracking drift, to be spread over the walk).
    struct Exterior: Encodable {
        let walls: [[Corner]]
        let anchorStart: Corner?
        let anchorEnd: Corner?
    }

    struct Segment: Encodable {
        let id: String
        let story: Int
        let a: [Double]
        let b: [Double]
        let height: Double
        let bottom: Double        // world height of the lower edge
        let wall: String?         // parent wall id for doors, windows, openings
        let curved: Bool
    }

    struct Floor: Encodable {
        let id: String
        let story: Int
        let elevation: Double     // world height of the floor surface
        let polygon: [[Double]]
    }

    struct Section: Encodable {
        let label: String
        let story: Int
        let center: [Double]
    }

    struct Corner: Encodable {
        let point: [Double]
        let elevation: Double     // world height where the corner was aimed
    }

    // A face-to-face reading. `side` is +1 for the side the normal (−dy, dx)
    // of the wall's a→b points to, −1 for the other; `walls` is every scanned
    // segment the reading spans; `moving` the end walls that may shift to fit it.
    struct Measurement: Encodable {
        let wall: String
        let inches: Int
        let face: String          // "inside" or "outside"
        let side: Int
        let room: String
        let walls: [String]
        let move: String          // auto, start, end or both
        let moving: [String]
    }

    static func data(for s: CapturedStructure, corners: [SIMD3<Float>],
                     measurements: [UUID: WallMeasurement], exterior: [[SIMD3<Float>]],
                     anchorStart: SIMD3<Float>?, anchorEnd: SIMD3<Float>?) throws -> Data {
        func corner(_ p: SIMD3<Float>) -> Corner { Corner(point: [r(p.x), r(p.z)], elevation: r(p.y)) }
        let plan = Plan(
            createdAt: ISO8601DateFormatter().string(from: Date()),
            walls: s.walls.map(segment),
            doors: s.doors.map(segment),
            windows: s.windows.map(segment),
            openings: s.openings.map(segment),
            floors: s.floors.map(floor),
            sections: s.sections.map {
                Section(label: String(describing: $0.label), story: $0.story,
                        center: [r($0.center.x), r($0.center.z)])
            },
            corners: corners.map(corner),
            measurements: measurements
                .sorted { $0.key.uuidString < $1.key.uuidString }
                .map { id, m in
                    Measurement(wall: id.uuidString, inches: m.inches, face: m.face.rawValue,
                                side: m.sideSign, room: m.room,
                                walls: (m.walls.isEmpty ? [id] : m.walls).map(\.uuidString),
                                move: m.move.rawValue, moving: m.moving.map(\.uuidString))
                },
            exterior: Exterior(walls: exterior.filter { !$0.isEmpty }.map { $0.map(corner) },
                               anchorStart: anchorStart.map(corner), anchorEnd: anchorEnd.map(corner)))
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(plan)
    }

    // A wall-like surface is a rectangle centred on its transform, with its
    // width along the local x axis.
    static func segment(_ s: CapturedRoom.Surface) -> Segment {
        let t = s.transform
        let c = t.columns.3
        let dir = t.columns.0
        let half = s.dimensions.x / 2
        return Segment(
            id: s.identifier.uuidString,
            story: s.story,
            a: [r(c.x - dir.x * half), r(c.z - dir.z * half)],
            b: [r(c.x + dir.x * half), r(c.z + dir.z * half)],
            height: r(s.dimensions.y),
            bottom: r(c.y - s.dimensions.y / 2),
            wall: s.parentIdentifier?.uuidString,
            curved: s.curve != nil)
    }

    static func floor(_ s: CapturedRoom.Surface) -> Floor {
        var corners = s.polygonCorners
        if corners.isEmpty {
            let w = s.dimensions.x / 2, d = s.dimensions.y / 2
            corners = [[-w, -d, 0], [w, -d, 0], [w, d, 0], [-w, d, 0]]
        }
        let world = corners.map { s.transform * SIMD4<Float>($0, 1) }
        return Floor(
            id: s.identifier.uuidString,
            story: s.story,
            elevation: r(s.transform.columns.3.y),
            polygon: world.map { [r($0.x), r($0.z)] })
    }

    // Millimetre precision keeps the files small and readable.
    private static func r(_ v: Float) -> Double { (Double(v) * 1000).rounded() / 1000 }
}
