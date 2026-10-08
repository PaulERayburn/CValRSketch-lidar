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
        static let formatVersion = 5
        var format = "cvalrscan"
        var version = formatVersion
        var app = "CValRScan " + ScanController.appVersion
        var units = "m"
        let createdAt: String
        let walls: [Segment]
        let doors: [Segment]
        let windows: [Segment]
        let openings: [Segment]
        let floors: [Floor]
        let sections: [Section]
        let corners: [Corner]
        let wallPoints: [WallPointOut]
        let gaps: [Gap]
        let gapDepths: [GapDepthOut]
        let spans: [SpanOut]
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

    // A point on a wall the scan missed, with the wall's horizontal facing.
    struct WallPointOut: Encodable {
        let point: [Double]
        let elevation: Double
        let normal: [Double]
    }

    // A laser depth square across a gap, from the face of scanned wall `from`.
    struct GapDepthOut: Encodable {
        let gap: [[Double]]
        let from: String
        let inches: Int
    }

    // A reading between two scanned corners along the house's main direction:
    // outside, siding corner to siding corner; inside, face to face.
    struct SpanOut: Encodable {
        let a: [Double]
        let b: [Double]
        let story: Int
        let inches: Int
        let face: String
        let entered: String
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
        let entered: String       // as typed, e.g. "11 11 + 6 5 + 6 2"
    }

    static func data(for s: CapturedStructure, corners: [SIMD3<Float>],
                     wallPoints: [WallPoint], gapDepths: [GapDepth],
                     measurements: [UUID: WallMeasurement], spans: [SpanReading], exterior: [[SIMD3<Float>]],
                     anchorStart: SIMD3<Float>?, anchorEnd: SIMD3<Float>?) throws -> Data {
        func corner(_ p: SIMD3<Float>) -> Corner { Corner(point: [r(p.x), r(p.z)], elevation: r(p.y)) }
        let walls = s.walls.map(segment), doors = s.doors.map(segment)
        let windows = s.windows.map(segment), openings = s.openings.map(segment)
        let floors = s.floors.map(floor)
        let plan = Plan(
            createdAt: ISO8601DateFormatter().string(from: Date()),
            walls: walls,
            doors: doors,
            windows: windows,
            openings: openings,
            floors: floors,
            sections: s.sections.map {
                Section(label: String(describing: $0.label), story: $0.story,
                        center: [r($0.center.x), r($0.center.z)])
            },
            corners: corners.map(corner),
            wallPoints: wallPoints.map {
                WallPointOut(point: [r($0.point.x), r($0.point.z)], elevation: r($0.point.y),
                             normal: [r($0.normal.x), r($0.normal.z)])
            },
            gaps: gaps(floors: floors, segments: walls + doors + windows + openings),
            gapDepths: gapDepths.map {
                GapDepthOut(gap: [[$0.gapA.x, $0.gapA.y], [$0.gapB.x, $0.gapB.y]],
                            from: $0.from.uuidString, inches: $0.inches)
            },
            spans: spans.map {
                SpanOut(a: [$0.a.x, $0.a.y], b: [$0.b.x, $0.b.y], story: $0.story, inches: $0.inches,
                        face: $0.face.rawValue, entered: $0.entered)
            },
            measurements: measurements
                .sorted { $0.key.uuidString < $1.key.uuidString }
                .map { id, m in
                    Measurement(wall: id.uuidString, inches: m.inches, face: m.face.rawValue,
                                side: m.sideSign, room: m.room,
                                walls: (m.walls.isEmpty ? [id] : m.walls).map(\.uuidString),
                                move: m.move.rawValue, moving: m.moving.map(\.uuidString), entered: m.entered)
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
