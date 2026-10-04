import ARKit
import AVFoundation
import Foundation
import RoomPlan

// Drives RoomPlan: scans rooms one after another in the same AR session so
// they share one coordinate system, then merges them into one structure.
// Marked corners and meter readings live in that same coordinate system.
@MainActor
final class ScanController: NSObject, ObservableObject, @preconcurrency RoomCaptureViewDelegate {
    @Published var rooms: [CapturedRoom] = []
    @Published var isScanning = false
    @Published var isBusy = false
    @Published var message: String?
    @Published var exportURLs: [URL] = []
    @Published var torchOn = false
    @Published var corners: [SIMD3<Float>] = []        // older scans only; Mark wall replaced them
    @Published private(set) var wallPoints: [WallPoint] = []
    @Published private(set) var gapDepths: [GapDepth] = []
    @Published private(set) var structure: CapturedStructure?
    @Published private(set) var measurements: [UUID: WallMeasurement] = [:]
    @Published private(set) var savedScans: [String] = []   // timestamps, newest first
    @Published private(set) var loadedFromFile = false
    // Outside walk: points on the siding, grouped one list per exterior wall,
    // in the order taken; a fixed spot by the door marked going out and coming
    // back in measures the tracking drift.
    @Published var exteriorWalls: [[SIMD3<Float>]] = []
    @Published var anchorStart: SIMD3<Float>?
    @Published var anchorEnd: SIMD3<Float>?
    @Published var isOutside = false
    // Resuming a saved scan on site: the phone relocalizes against the saved
    // AR world map, after which new rooms and outside points line up with it.
    @Published private(set) var canResume = false
    @Published private(set) var isRelocalizing = false
    @Published private(set) var resumed = false

    static var isSupported: Bool { RoomCaptureSession.isSupported }

    // Our own AR session, so a saved world map can be loaded into it.
    let arSession = ARSession()
    let captureView: RoomCaptureView
    private var discardNext = false
    private var stamp = ""
    private var savedRooms: [CapturedRoom] = []
    private var previousWalls: [CapturedRoom.Surface] = []
    private var relocalizeStarted = Date.distantPast

    override init() {
        captureView = RoomCaptureView(frame: .zero, arSession: arSession)
        super.init()
        captureView.delegate = self
        refreshSaved()
    }

    // RoomCaptureViewDelegate inherits NSCoding; nothing here needs archiving.
    required init?(coder: NSCoder) { nil }
    func encode(with coder: NSCoder) {}

    func startRoom() {
        // A reopened plan's AR session is gone, so new rooms could not line up with it.
        if loadedFromFile { newScan() }
        discardNext = false
        exportURLs = []
        if let s = structure { previousWalls = s.walls }
        structure = nil
        isScanning = true
        captureView.captureSession.run(configuration: RoomCaptureSession.Configuration())
    }

    func finishRoom() {
        isBusy = true
        setTorch(false)
        // Keep the AR session alive so the next room lines up with this one.
        captureView.captureSession.stop(pauseARSession: false)
    }

    func cancelRoom() {
        discardNext = true
        setTorch(false)
        captureView.captureSession.stop(pauseARSession: false)
        isScanning = false
    }

    func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool {
        !discardNext
    }

    func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
        isBusy = false
        isScanning = false
        if let error {
            message = "Scan failed: \(error.localizedDescription)"
            return
        }
        rooms.append(processedResult)
        message = "Room \(rooms.count) added"
    }

    func removeLastRoom() {
        if !rooms.isEmpty { rooms.removeLast() }
        exportURLs = []
        structure = nil
    }

    // The camera keeps tracking with the torch on, which is what dark
    // closets need; RoomPlan's own lighting warnings still apply.
    func setTorch(_ on: Bool) {
        guard let device = AVCaptureDevice.default(for: .video), device.hasTorch else {
            if on { message = "This device has no flashlight" }
            return
        }
        do {
            try device.lockForConfiguration()
            device.torchMode = on ? .on : .off
            device.unlockForConfiguration()
            torchOn = on
        } catch {
            message = "Flashlight unavailable: \(error.localizedDescription)"
        }
    }

    enum MarkResult { case marked(feet: Double), notWall, noSurface }

    // Records the wall under the crosshair: where it is and which way it
    // faces. Only upright surfaces count, so a stray tap at the floor or a
    // shelf is refused rather than saved.
    func markWallPoint() -> MarkResult {
        guard let frame = arSession.currentFrame else { return .noSurface }
        let query = frame.raycastQuery(from: CGPoint(x: 0.5, y: 0.5),
                                       allowing: .estimatedPlane, alignment: .vertical)
        guard let hit = arSession.raycast(query).first else {
            return aimedPoint() == nil ? .noSurface : .notWall
        }
        // The hit's y axis is the surface normal; keep its level part.
        let t = hit.worldTransform
        let n = SIMD3(t.columns.1.x, 0, t.columns.1.z)
        guard simd_length(n) > 0.7 else { return .notWall }
        let p = SIMD3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        wallPoints.append(WallPoint(point: p, normal: simd_normalize(n)))
        writeFiles()
        let cam = frame.camera.transform.columns.3
        return .marked(feet: Double(simd_distance(p, SIMD3(cam.x, cam.y, cam.z))) * 3.28084)
    }

    func undoWallPoint() {
        if !wallPoints.isEmpty { wallPoints.removeLast() }
        writeFiles()
    }

    // Sets or clears the laser depth across a gap.
    func setGapDepth(_ depth: GapDepth?, for gap: PlanGap) {
        let middle = (gap.worldA + gap.worldB) / 2
        gapDepths.removeAll { simd_distance($0.middle, middle) < 0.5 }
        if let depth { gapDepths.append(depth) }
        writeFiles()
    }

    // The surface point under the screen centre, from the LiDAR mesh.
    func aimedPoint() -> SIMD3<Float>? {
        guard let frame = arSession.currentFrame else { return nil }
        let query = frame.raycastQuery(from: CGPoint(x: 0.5, y: 0.5),
                                       allowing: .estimatedPlane, alignment: .any)
        guard let hit = arSession.raycast(query).first else { return nil }
        let p = hit.worldTransform.columns.3
        return SIMD3(p.x, p.y, p.z)
    }

    // MARK: Outside walk

    @discardableResult
    func markAnchor() -> Bool {
        guard let p = aimedPoint() else { return false }
        if anchorStart == nil { anchorStart = p } else { anchorEnd = p }
        writeFiles()
        return true
    }

    @discardableResult
    func markExteriorPoint() -> Bool {
        guard let p = aimedPoint() else { return false }
        if exteriorWalls.isEmpty { exteriorWalls.append([]) }
        exteriorWalls[exteriorWalls.count - 1].append(p)
        writeFiles()
        return true
    }

    func nextExteriorWall() {
        if let last = exteriorWalls.last, !last.isEmpty { exteriorWalls.append([]) }
    }

    // Where the current wall's points turn a corner, i.e. Next wall was
    // missed: the indexes at which each further wall starts. Empty when
    // the points lie within 6″ of one line.
    var cornerSplits: [Int] {
        guard let wall = exteriorWalls.last else { return [] }
        return Self.splits(wall.map { SIMD2(Double($0.x), Double($0.z)) }, offset: 0)
    }

    // Splits where the two lines fit best overall (least total squared
    // error, so a two-point stub is not favoured), then checks each part.
    private static func splits(_ pts: [SIMD2<Double>], offset: Int) -> [Int] {
        let tolerance = 6 / 39.37
        guard pts.count >= 4, lineFit(pts).worst > tolerance else { return [] }
        let cost = (2...(pts.count - 2)).map {
            (k: $0, squares: lineFit(Array(pts[..<$0])).squares + lineFit(Array(pts[$0...])).squares)
        }
        let k = cost.min { $0.squares < $1.squares }!.k
        return splits(Array(pts[..<k]), offset: offset) + [offset + k]
            + splits(Array(pts[k...]), offset: offset + k)
    }

    // Distances of the points from their best-fit line: the largest, and the sum of squares.
    private static func lineFit(_ pts: [SIMD2<Double>]) -> (worst: Double, squares: Double) {
        let m = pts.reduce(SIMD2<Double>.zero, +) / Double(pts.count)
        var sxx = 0.0, sxy = 0.0, syy = 0.0
        for p in pts {
            let q = p - m
            sxx += q.x * q.x; sxy += q.x * q.y; syy += q.y * q.y
        }
        let angle = 0.5 * atan2(2 * sxy, sxx - syy)
        let distances = pts.map { abs(-($0.x - m.x) * sin(angle) + ($0.y - m.y) * cos(angle)) }
        return (distances.max() ?? 0, distances.reduce(0) { $0 + $1 * $1 })
    }

    func splitLastExteriorWall(at indexes: [Int]) {
        guard let wall = exteriorWalls.popLast() else { return }
        let bounds = [0] + indexes + [wall.count]
        for (s, e) in zip(bounds, bounds.dropFirst()) { exteriorWalls.append(Array(wall[s..<e])) }
        writeFiles()
    }

    func undoExteriorPoint() {
        if exteriorWalls.last?.isEmpty == true { exteriorWalls.removeLast() }
        if !exteriorWalls.isEmpty { exteriorWalls[exteriorWalls.count - 1].removeLast() }
        writeFiles()
    }

    // How far the start spot appears to have moved by the time we're back:
    // the tracking error accumulated over the walk.
    var drift: SIMD3<Float>? {
        guard let s = anchorStart, let e = anchorEnd else { return nil }
        return e - s
    }

    // Each wall's points, corrected for drift in proportion to how far
    // through the walk they were taken, fitted with a straight line (metres,
    // plan x/z) spanning the points.
    struct XY { var x: Double; var y: Double }
    var exteriorPlanLines: [(a: XY, b: XY)] {
        let total = max(exteriorWalls.reduce(0) { $0 + $1.count }, 1)
        var index = 0
        var lines: [(a: XY, b: XY)] = []
        for wall in exteriorWalls {
            let pts: [XY] = wall.map { p in
                index += 1
                let f = Float(index) / Float(total + 1)
                let q = p - (drift ?? .zero) * f
                return XY(x: Double(q.x), y: Double(q.z))
            }
            guard pts.count >= 2 else { continue }
            let mx = pts.map(\.x).reduce(0, +) / Double(pts.count)
            let my = pts.map(\.y).reduce(0, +) / Double(pts.count)
            var sxx = 0.0, sxy = 0.0, syy = 0.0
            for p in pts {
                sxx += (p.x - mx) * (p.x - mx)
                sxy += (p.x - mx) * (p.y - my)
                syy += (p.y - my) * (p.y - my)
            }
            let angle = 0.5 * atan2(2 * sxy, sxx - syy)
            let d = XY(x: cos(angle), y: sin(angle))
            let ts = pts.map { ($0.x - mx) * d.x + ($0.y - my) * d.y }
            lines.append((XY(x: mx + d.x * ts.min()!, y: my + d.y * ts.min()!),
                          XY(x: mx + d.x * ts.max()!, y: my + d.y * ts.max()!)))
        }
        return lines
    }

    func export() async {
        guard !rooms.isEmpty else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let built = try await StructureBuilder(options: [.beautifyObjects])
                .capturedStructure(from: rooms)
            measurements = remap(measurements, from: previousWalls, to: built.walls)
            structure = built
            // A resumed scan keeps its name; a new one is named by the time.
            // File names carry only a timestamp: never an address or job number.
            if !resumed || stamp.isEmpty { stamp = Self.stampFormatter.string(from: Date()) }
            writeFiles()
            saveWorldMap()
        } catch {
            message = "Export failed: \(error.localizedDescription)"
        }
    }

    // A rebuild can give walls new identifiers. Readings follow their wall
    // to the new wall in the same place: same floor, parallel, middles within
    // about a foot. Readings whose wall has gone are dropped.
    private func remap(_ readings: [UUID: WallMeasurement], from old: [CapturedRoom.Surface],
                       to new: [CapturedRoom.Surface]) -> [UUID: WallMeasurement] {
        let newIDs = Set(new.map(\.identifier))
        func mid(_ s: CapturedRoom.Surface) -> SIMD2<Float> { SIMD2(s.transform.columns.3.x, s.transform.columns.3.z) }
        func dir(_ s: CapturedRoom.Surface) -> SIMD2<Float> { SIMD2(s.transform.columns.0.x, s.transform.columns.0.z) }
        func map(_ id: UUID) -> UUID? {
            if newIDs.contains(id) { return id }
            guard let o = old.first(where: { $0.identifier == id }) else { return nil }
            return new.filter { $0.story == o.story && abs(simd_dot(dir($0), dir(o))) > 0.98 }
                .min { simd_distance(mid($0), mid(o)) < simd_distance(mid($1), mid(o)) }
                .flatMap { simd_distance(mid($0), mid(o)) < 0.3 ? $0.identifier : nil }
        }
        var out: [UUID: WallMeasurement] = [:]
        for (id, m) in readings {
            guard let key = map(id) else { continue }
            var moved = m
            moved.walls = m.walls.compactMap(map)
            moved.moving = m.moving.compactMap(map)
            out[key] = moved
        }
        return out
    }

    // MARK: Save and resume on site

    private var worldMapURL: URL { Self.docs.appendingPathComponent("scan-\(stamp).worldmap") }

    func saveWorldMap() {
        guard !stamp.isEmpty, !loadedFromFile else { return }
        let url = worldMapURL
        arSession.getCurrentWorldMap { map, _ in
            guard let map,
                  let data = try? NSKeyedArchiver.archivedData(withRootObject: map, requiringSecureCoding: true)
            else { return }
            try? data.write(to: url)
        }
    }

    func startResume() {
        guard let data = try? Data(contentsOf: worldMapURL),
              let map = try? NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data) else {
            message = "This scan has no saved session to resume."
            return
        }
        let config = ARWorldTrackingConfiguration()
        config.initialWorldMap = map
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
        }
        arSession.run(config, options: [.resetTracking, .removeExistingAnchors])
        relocalizeStarted = Date()
        isRelocalizing = true
    }

    // Polled while the resume screen is up. ARKit reports limited tracking
    // until it recognises the saved space, then normal.
    func checkRelocalized() -> Bool {
        guard isRelocalizing, Date().timeIntervalSince(relocalizeStarted) > 1.5,
              case .normal = arSession.currentFrame?.camera.trackingState else { return false }
        isRelocalizing = false
        resumed = true
        loadedFromFile = false
        rooms = savedRooms
        if let s = structure { previousWalls = s.walls }
        // Fold an earlier walk's drift correction into its points, so a new
        // walk can measure its own drift from a fresh start spot.
        if let d = drift {
            let total = max(exteriorWalls.reduce(0) { $0 + $1.count }, 1)
            var index = 0
            exteriorWalls = exteriorWalls.map { wall in
                wall.map { p in
                    index += 1
                    return p - d * (Float(index) / Float(total + 1))
                }
            }
        }
        // New outside points start a new wall, not the last one walked before.
        if exteriorWalls.last?.isEmpty == false { exteriorWalls.append([]) }
        anchorStart = nil
        anchorEnd = nil
        message = "Located. Scan more rooms or go outside, then Build floor plan."
        return true
    }

    func cancelResume() {
        isRelocalizing = false
        arSession.pause()
    }

    func setMeasurement(_ m: WallMeasurement?, for wall: UUID) {
        measurements[wall] = m
        writeFiles()
    }

    private func writeFiles() {
        guard let structure else { return }
        do {
            let dir = Self.docs
            let planURL = dir.appendingPathComponent("scan-\(stamp).cvalrscan.json")
            let rawURL = dir.appendingPathComponent("scan-\(stamp).capturedstructure.json")
            try PlanExport.data(for: structure, corners: corners, wallPoints: wallPoints, gapDepths: gapDepths,
                                measurements: measurements,
                                exterior: exteriorWalls, anchorStart: anchorStart, anchorEnd: anchorEnd)
                .write(to: planURL)
            try JSONEncoder().encode(structure).write(to: rawURL)
            exportURLs = [planURL, rawURL]
            message = "Saved and ready to share"
            refreshSaved()
        } catch {
            message = "Export failed: \(error.localizedDescription)"
        }
    }

    // MARK: Saved scans (the app's Documents folder, also visible in Files)

    static let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

    func refreshSaved() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: Self.docs.path)) ?? []
        savedScans = names
            .filter { $0.hasPrefix("scan-") && $0.hasSuffix(".capturedstructure.json") }
            .map { String($0.dropFirst(5).dropLast(".capturedstructure.json".count)) }
            .sorted(by: >)
    }

    static func title(for stamp: String) -> String {
        guard let date = stampFormatter.date(from: stamp) else { return stamp }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    func newScan() {
        rooms = []
        corners = []
        wallPoints = []
        gapDepths = []
        measurements = [:]
        exteriorWalls = []
        anchorStart = nil
        anchorEnd = nil
        structure = nil
        exportURLs = []
        loadedFromFile = false
        resumed = false
        canResume = false
        savedRooms = []
        previousWalls = []
        stamp = ""
        message = nil
    }

    func load(stamp: String) {
        let rawURL = Self.docs.appendingPathComponent("scan-\(stamp).capturedstructure.json")
        let planURL = Self.docs.appendingPathComponent("scan-\(stamp).cvalrscan.json")
        do {
            let loaded = try JSONDecoder().decode(CapturedStructure.self, from: Data(contentsOf: rawURL))
            let saved = (try? JSONDecoder().decode(SavedPlan.self, from: Data(contentsOf: planURL)))
            rooms = []
            corners = (saved?.corners ?? []).map {
                SIMD3(Float($0.point[0]), Float($0.elevation), Float($0.point[1]))
            }
            var m: [UUID: WallMeasurement] = [:]
            for r in saved?.measurements ?? [] {
                guard let id = UUID(uuidString: r.wall) else { continue }
                m[id] = WallMeasurement(
                    inches: r.inches, face: WallMeasurement.Face(rawValue: r.face) ?? .inside,
                    sideSign: r.side ?? 1, room: r.room ?? "",
                    walls: (r.walls ?? [r.wall]).compactMap(UUID.init(uuidString:)),
                    move: WallMeasurement.Move(rawValue: r.move ?? "auto") ?? .auto,
                    moving: (r.moving ?? []).compactMap(UUID.init(uuidString:)))
            }
            measurements = m
            wallPoints = (saved?.wallPoints ?? []).map {
                WallPoint(point: SIMD3(Float($0.point[0]), Float($0.elevation), Float($0.point[1])),
                          normal: SIMD3(Float($0.normal[0]), 0, Float($0.normal[1])))
            }
            gapDepths = (saved?.gapDepths ?? []).compactMap { d in
                guard d.gap.count == 2, let from = UUID(uuidString: d.from) else { return nil }
                return GapDepth(gapA: SIMD2(d.gap[0][0], d.gap[0][1]), gapB: SIMD2(d.gap[1][0], d.gap[1][1]),
                                from: from, inches: d.inches)
            }
            func world(_ p: SavedPlan.Point) -> SIMD3<Float> {
                SIMD3(Float(p.point[0]), Float(p.elevation), Float(p.point[1]))
            }
            exteriorWalls = (saved?.exterior?.walls ?? []).map { $0.map(world) }
            anchorStart = saved?.exterior?.anchorStart.map(world)
            anchorEnd = saved?.exterior?.anchorEnd.map(world)
            structure = loaded
            savedRooms = loaded.rooms
            self.stamp = stamp
            loadedFromFile = true
            resumed = false
            canResume = FileManager.default.fileExists(atPath: worldMapURL.path)
            exportURLs = FileManager.default.fileExists(atPath: planURL.path) ? [planURL, rawURL] : [rawURL]
            writeFiles()
            message = "Opened scan from \(Self.title(for: stamp))"
        } catch {
            message = "Couldn't open that scan: \(error.localizedDescription)"
        }
    }

    // Copies a scan picked in Files into the app, then opens it. Either file
    // of a pair can be picked; its partner is copied too when it sits beside it.
    func importScan(from url: URL) {
        let name = url.lastPathComponent
        guard name.hasPrefix("scan-"),
              let stamp = [".capturedstructure.json", ".cvalrscan.json"]
                .first(where: { name.hasSuffix($0) })
                .map({ String(name.dropFirst(5).dropLast($0.count)) }) else {
            message = "Pick a scan-….capturedstructure.json file"
            return
        }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let folder = url.deletingLastPathComponent()
        for suffix in [".capturedstructure.json", ".cvalrscan.json", ".worldmap"] {
            let src = folder.appendingPathComponent("scan-\(stamp)\(suffix)")
            let dst = Self.docs.appendingPathComponent(src.lastPathComponent)
            guard src != dst, FileManager.default.fileExists(atPath: src.path) else { continue }
            try? FileManager.default.removeItem(at: dst)
            try? FileManager.default.copyItem(at: src, to: dst)
        }
        refreshSaved()
        load(stamp: stamp)
    }

    func deleteSaved(_ stamp: String) {
        for suffix in [".capturedstructure.json", ".cvalrscan.json", ".worldmap"] {
            try? FileManager.default.removeItem(at: Self.docs.appendingPathComponent("scan-\(stamp)\(suffix)"))
        }
        if loadedFromFile && self.stamp == stamp { newScan() }
        refreshSaved()
    }

    private struct SavedPlan: Decodable {
        struct Point: Decodable { let point: [Double]; let elevation: Double }
        struct Reading: Decodable {
            let wall: String; let inches: Int; let face: String
            let side: Int?; let room: String?; let walls: [String]?; let move: String?; let moving: [String]?
        }
        struct Exterior: Decodable { let walls: [[Point]]; let anchorStart: Point?; let anchorEnd: Point? }
        struct WallPointIn: Decodable { let point: [Double]; let elevation: Double; let normal: [Double] }
        struct GapDepthIn: Decodable { let gap: [[Double]]; let from: String; let inches: Int }
        let corners: [Point]?
        let wallPoints: [WallPointIn]?
        let gapDepths: [GapDepthIn]?
        let measurements: [Reading]?
        let exterior: Exterior?
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmm"
        return f
    }()
}
