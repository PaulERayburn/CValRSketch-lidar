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
        static let formatVersion = 7
        var format = "cvalrscan"
        var version = formatVersion
        var app = "CValRScan " + ScanController.appVersion
        var units = "m"
        // The user's name for the scan, usually the address. Only in files
        // the user keeps or shares; never in this repository's test scans.
        var name: String?
        var photoFolder: String?
        var photos: [PhotoOut]?
        var addedWalls: [AddedWallOut]?
        var wallsShapeFloor: Bool?      // false: drawn or moved walls don't change the floor outline
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
        let wallEdits: [WallEditOut]
        let hiddenOpenings: [String]
        let roomLabels: [RoomLabelOut]
        let addedOpenings: [OpeningOut]
        let rooms: [RoomOut]
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
        var type: String? = nil   // added doors: "entrance" or "interior"
        var hinge: String? = nil  // doors: "a" or "b", the end the leaf turns on
        var side: Int? = nil      // doors: +1 opens to the normal (−dy, dx) side of a→b, −1 the other
        var style: String? = nil  // doors: swing, pocket, bifold or sliding
    }

    // The side a door opens to by default: into the floor (a room), from the
    // middle of the door a foot each way; +1 when both sides are floor.
    static func defaultSide(a: [Double], b: [Double], story: Int, floors: [Floor]) -> Int {
        let dx = b[0] - a[0], dy = b[1] - a[1], L = max(hypot(dx, dy), 1e-6)
        let nx = -dy / L, ny = dx / L, mx = (a[0] + b[0]) / 2, my = (a[1] + b[1]) / 2
        func inFloor(_ x: Double, _ y: Double) -> Bool {
            floors.filter { $0.story == story }.contains { f in
                var r = false, j = f.polygon.count - 1
                for i in f.polygon.indices {
                    let p = f.polygon[i], q = f.polygon[j]
                    if (p[1] > y) != (q[1] > y), x < (q[0] - p[0]) * (y - p[1]) / (q[1] - p[1]) + p[0] { r.toggle() }
                    j = i
                }
                return r
            }
        }
        return inFloor(mx + nx * 0.3, my + ny * 0.3) || !inFloor(mx - nx * 0.3, my - ny * 0.3) ? 1 : -1
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

    // A scanned wall the user deleted or whose ends they moved (world x, z),
    // already applied to `walls`; kept so the app can reopen and undo it.
    struct AddedWallOut: Codable { let id: String; let story: Int; let a: [Double]; let b: [Double] }
    struct WallEditOut: Encodable {
        let wall: String
        let hidden: Bool
        let a: [Double]?
        let b: [Double]?
    }

    // Room names the user gave, renamed, or (empty name) removed.
    struct RoomLabelOut: Encodable { let story: Int; let point: [Double]; let name: String; let replaces: Int? }
    // Doors and openings the user added on a wall; also in doors / openings.
    struct OpeningOut: Encodable {
        let story: Int; let wall: String?; let a: [Double]; let b: [Double]; let kind: String; let hingeAtB: Bool; let side: Int
        let style: String
    }
    // Every room name as it stands, scanned or the user's, for the importer.
    struct RoomOut: Encodable { let story: Int; let center: [Double]; let name: String }

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
                     measurements: [UUID: WallMeasurement], spans: [SpanReading], wallEdits: [UUID: WallEdit],
                     roomLabels: [RoomLabel], addedOpenings: [AddedOpening], rooms: [ResolvedRoom],
                     hiddenOpenings: Set<UUID>,
                     exterior: [[SIMD3<Float>]],
                     anchorStart: SIMD3<Float>?, anchorEnd: SIMD3<Float>?, name: String = "",
                     photos: [ScanPhoto] = [], photoFolder: String = "", addedWalls: [AddedWall] = [],
                     wallsShapeFloor: Bool = true) throws -> Data {
        func corner(_ p: SIMD3<Float>) -> Corner { Corner(point: [r(p.x), r(p.z)], elevation: r(p.y)) }
        // Drawn walls go in with the scanned ones, at the height of that floor's walls.
        let drawn = addedWalls.map { w -> Segment in
            let same = s.walls.filter { $0.story == w.story }
            let bottom = same.isEmpty ? 0 : Double(same.map { $0.transform.columns.3.y - $0.dimensions.y / 2 }.sorted()[same.count / 2])
            return Segment(id: w.id.uuidString, story: w.story, a: [w.a.x, w.a.y], b: [w.b.x, w.b.y],
                           height: 2.4, bottom: (bottom * 1000).rounded() / 1000, wall: nil, curved: false)
        }
        let walls = s.walls.compactMap { WallEdit.apply(wallEdits, to: segment($0)) } + drawn
        // Added doors and openings take their height from a standard door and
        // sit on the floor of the wall they are in.
        func added(_ door: Bool) -> [Segment] {
            addedOpenings.enumerated().filter { ($0.element.kind != .opening) == door }.map { i, o in
                let w = o.wall.flatMap { id in walls.first { $0.id == id.uuidString } }
                return Segment(id: "added-\(o.kind.rawValue)-\(i)", story: o.story, a: [o.a.x, o.a.y], b: [o.b.x, o.b.y],
                               height: 2.03, bottom: w?.bottom ?? 0, wall: o.wall?.uuidString, curved: false,
                               type: door ? o.kind.rawValue : nil,
                               hinge: door ? (o.hingeAtB ? "b" : "a") : nil, side: door ? o.side : nil,
                               style: door ? o.style.rawValue : nil)
            }
        }
        let kept = { (l: [CapturedRoom.Surface]) in l.filter { !hiddenOpenings.contains($0.identifier) }.map(segment) }
        let floors = s.floors.map(floor)
        let doors = kept(s.doors).map { d in
            var d = d
            d.hinge = "a"
            d.side = defaultSide(a: d.a, b: d.b, story: d.story, floors: floors)
            let style = DoorStyle.forScanned(metres: hypot(d.b[0] - d.a[0], d.b[1] - d.a[1]))
            if style != .swing { d.style = style.rawValue }
            return d
        } + added(true)
        let windows = s.windows.map(segment), openings = kept(s.openings) + added(false)
        var plan = Plan(
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
            wallEdits: wallEdits.sorted { $0.key.uuidString < $1.key.uuidString }.map { id, e in
                WallEditOut(wall: id.uuidString, hidden: e.hidden, a: e.a.map { [$0.x, $0.y] }, b: e.b.map { [$0.x, $0.y] })
            },
            hiddenOpenings: hiddenOpenings.map(\.uuidString).sorted(),
            roomLabels: roomLabels.map { RoomLabelOut(story: $0.story, point: [$0.point.x, $0.point.y], name: $0.name, replaces: $0.replaces) },
            addedOpenings: addedOpenings.map { OpeningOut(story: $0.story, wall: $0.wall?.uuidString, a: [$0.a.x, $0.a.y], b: [$0.b.x, $0.b.y], kind: $0.kind.rawValue,
                                                             hingeAtB: $0.hingeAtB, side: $0.side, style: $0.style.rawValue) },
            rooms: rooms.map { RoomOut(story: $0.story, center: [$0.center.x, $0.center.y], name: $0.name) },
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
        if !name.isEmpty { plan.name = name }
        if !photos.isEmpty { plan.photos = photos.map(photoOut); plan.photoFolder = photoFolder }
        if !wallsShapeFloor { plan.wallsShapeFloor = false }
        if !addedWalls.isEmpty {
            plan.addedWalls = addedWalls.map { AddedWallOut(id: $0.id.uuidString, story: $0.story, a: [$0.a.x, $0.a.y], b: [$0.b.x, $0.b.y]) }
        }
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

// A user's clean-up of one scanned wall: deleted, or one or both ends moved
// (world metres x, z). Applied wherever scanned walls are read.
struct WallEdit: Equatable {
    var hidden = false
    var a: SIMD2<Double>?
    var b: SIMD2<Double>?

    static func apply(_ edits: [UUID: WallEdit], to s: PlanExport.Segment) -> PlanExport.Segment? {
        guard let id = UUID(uuidString: s.id), let e = edits[id] else { return s }
        if e.hidden { return nil }
        return PlanExport.Segment(id: s.id, story: s.story, a: e.a.map { [$0.x, $0.y] } ?? s.a,
                                  b: e.b.map { [$0.x, $0.y] } ?? s.b, height: s.height, bottom: s.bottom,
                                  wall: s.wall, curved: s.curved)
    }
}

// A room name the user gave at a spot (world x, z), or a rename (or, with an
// empty name, removal) of the scan's own name with that index.
struct RoomLabel: Equatable {
    var story: Int
    var point: SIMD2<Double>
    var name: String
    var replaces: Int?
}

// A wall the user drew where the scan saw none (world x, z ends): a closet
// back behind a door left shut, say.
struct AddedWall: Equatable {
    var id = UUID()
    var story: Int
    var a: SIMD2<Double>
    var b: SIMD2<Double>
}

// A door or opening the user added on a wall (world x, z ends).
struct AddedOpening: Equatable {
    var story: Int
    var wall: UUID?
    var a: SIMD2<Double>
    var b: SIMD2<Double>
    var kind: OpeningKind
    // Door swing: the hinge at end b instead of a, and the side it opens to:
    // +1 the side the normal (−dy, dx) of a→b points to, −1 the other.
    var hingeAtB = false
    var side = 1
    var style = DoorStyle.swing
}

// How a door opens. Pocket slides into the wall at the hinge end; bifold
// folds toward its side; sliding (bypass) panels overlap.
enum DoorStyle: String, CaseIterable {
    case swing, double, pocket, bifold, sliding, overhead
    // Doors wider than this are taken as garage (overhead) doors: nobody hangs
    // a swing door over 6 ft.
    static let overheadMetres = 1.83
    // A scanned door from 4 to 6 ft wide is a pair (a closet or French door).
    static let doubleMetres = 1.2
    static func forScanned(metres: Double) -> DoorStyle {
        metres > overheadMetres ? .overhead : metres >= doubleMetres ? .double : .swing
    }
}

// An added door's type: an exterior (entrance) door, an interior (privacy)
// door, or an opening with no door.
enum OpeningKind: String { case entrance, interior, opening }

// Where a room name on the plan comes from.
enum RoomSource: Equatable { case new, scanned(Int), label(Int) }

struct ResolvedRoom {
    let story: Int
    let center: SIMD2<Double>
    let name: String
    let source: RoomSource
}

// Which door or opening an edit is about.
enum OpeningRef: Equatable { case new, added(Int), scanned(UUID) }
