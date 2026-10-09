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
    @Published var exportURLs: [URL] = [] { didSet { shareURLs = namedCopies(of: exportURLs) } }
    // The same files, named by the scan's name and date for sharing.
    @Published private(set) var shareURLs: [URL] = []
    // The user's name for this scan, usually the address.
    @Published private(set) var scanName = ""
    @Published private(set) var savedNames: [String: String] = [:]   // stamp: name
    @Published var torchOn = false
    @Published var corners: [SIMD3<Float>] = []        // older scans only; Mark wall replaced them
    @Published private(set) var wallPoints: [WallPoint] = []
    @Published private(set) var gapDepths: [GapDepth] = []
    @Published private(set) var spans: [SpanReading] = []
    @Published private(set) var wallEdits: [UUID: WallEdit] = [:]
    @Published private(set) var roomLabels: [RoomLabel] = []
    @Published private(set) var addedOpenings: [AddedOpening] = []
    @Published private(set) var hiddenOpenings: Set<UUID> = []      // the scan's doors and openings removed or replaced
    private var editHistory: [EditSnapshot] = []
    var canUndoEdit: Bool { !editHistory.isEmpty }
    var hasEdits: Bool { !wallEdits.isEmpty || !roomLabels.isEmpty || !addedOpenings.isEmpty || !hiddenOpenings.isEmpty }
    private struct EditSnapshot {
        var walls: [UUID: WallEdit]; var rooms: [RoomLabel]; var openings: [AddedOpening]; var hidden: Set<UUID>
    }
    var hasReadings: Bool { !measurements.isEmpty || !spans.isEmpty }
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

    // "0.6.0 (1)": the app version shown on the home screen and written into each scan.
    nonisolated static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }

    // Our own AR session, so a saved world map can be loaded into it.
    let arSession = ARSession()
    let captureView: RoomCaptureView
    private var discardNext = false
    private var stamp = ""
    private var savedRooms: [CapturedRoom] = []
    private var previous: CapturedStructure?   // the plan before a rebuild, for edits to follow
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
        if let s = structure { previous = s }
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

    // MARK: Cleaning up the scan

    func edited(_ s: PlanExport.Segment) -> PlanExport.Segment? { WallEdit.apply(wallEdits, to: s) }

    private func commitEdits(_ new: [UUID: WallEdit]) {
        commit { $0.walls = new }
    }

    private func commit(_ change: (inout EditSnapshot) -> Void) {
        var s = EditSnapshot(walls: wallEdits, rooms: roomLabels, openings: addedOpenings, hidden: hiddenOpenings)
        editHistory.append(s)
        change(&s)
        wallEdits = s.walls
        roomLabels = s.rooms
        addedOpenings = s.openings
        hiddenOpenings = s.hidden
        writeFiles()
    }

    // Names a room: a new name at a spot, or renaming or removing (nil) a
    // scanned name or one given before.
    func setRoomName(_ name: String?, source: RoomSource, at point: SIMD2<Double>, story: Int) {
        commit { s in
            switch source {
            case .new:
                if let name, !name.isEmpty { s.rooms.append(RoomLabel(story: story, point: point, name: name, replaces: nil)) }
            case .label(let i):
                guard s.rooms.indices.contains(i) else { return }
                if let name, !name.isEmpty { s.rooms[i].name = name }
                else if s.rooms[i].replaces != nil { s.rooms[i].name = "" }
                else { s.rooms.remove(at: i) }
            case .scanned(let i):
                s.rooms.removeAll { $0.replaces == i }
                s.rooms.append(RoomLabel(story: story, point: point, name: name ?? "", replaces: i))
            }
        }
    }

    // Adds a door or opening, or replaces one: one added before, or one the
    // scan found (which is then left out). nil removes it.
    func setOpening(_ o: AddedOpening?, replacing ref: OpeningRef) {
        commit { s in
            switch ref {
            case .new: break
            case .added(let i): if s.openings.indices.contains(i) { s.openings.remove(at: i) }
            case .scanned(let id): s.hidden.insert(id)
            }
            if let o { s.openings.append(o) }
        }
    }

    func deleteWall(_ id: UUID) {
        var e = wallEdits
        e[id, default: WallEdit()].hidden = true
        commitEdits(e)
    }

    // Moves every wall end at `from` (world x, z, within 10 cm) to `to`, so
    // walls meeting there stay joined.
    func moveWallEnds(from: SIMD2<Double>, to: SIMD2<Double>) {
        guard let structure else { return }
        var e = wallEdits
        for w in structure.walls {
            guard let s = edited(PlanExport.segment(w)) else { continue }
            if simd_distance(SIMD2(s.a[0], s.a[1]), from) < 0.1 { e[w.identifier, default: WallEdit()].a = to }
            if simd_distance(SIMD2(s.b[0], s.b[1]), from) < 0.1 { e[w.identifier, default: WallEdit()].b = to }
        }
        commitEdits(e)
    }

    func deleteWalls(_ ids: Set<UUID>) {
        var e = wallEdits
        for id in ids { e[id, default: WallEdit()].hidden = true }
        commitEdits(e)
    }

    // Moves several wall ends at once (world x, z), each from where it is now;
    // walls joined at a moved end follow it. One step in the edit history.
    func moveWallEnds(_ moves: [(from: SIMD2<Double>, to: SIMD2<Double>)]) {
        guard let structure, !moves.isEmpty else { return }
        var e = wallEdits
        for w in structure.walls {
            guard let s = edited(PlanExport.segment(w)) else { continue }
            let a = SIMD2(s.a[0], s.a[1]), b = SIMD2(s.b[0], s.b[1])
            if let m = moves.first(where: { simd_distance(a, $0.from) < 0.1 }) { e[w.identifier, default: WallEdit()].a = m.to }
            if let m = moves.first(where: { simd_distance(b, $0.from) < 0.1 }) { e[w.identifier, default: WallEdit()].b = m.to }
        }
        commitEdits(e)
    }

    func undoEdit() {
        guard let last = editHistory.popLast() else { return }
        wallEdits = last.walls
        roomLabels = last.rooms
        addedOpenings = last.openings
        hiddenOpenings = last.hidden
        writeFiles()
    }

    func restoreScan() {
        guard hasEdits else { return }
        commit { $0 = EditSnapshot(walls: [:], rooms: [], openings: [], hidden: []) }
    }

    func removeWallPoint(at index: Int) {
        guard wallPoints.indices.contains(index) else { return }
        wallPoints.remove(at: index)
        writeFiles()
    }

    func removeGapDepth(_ depth: GapDepth) {
        gapDepths.removeAll { $0 == depth }
        writeFiles()
    }

    // Sets or clears the reading between two corners (either order).
    func setSpan(_ span: SpanReading?, a: SIMD2<Double>, b: SIMD2<Double>) {
        func same(_ s: SpanReading) -> Bool {
            (simd_distance(s.a, a) < 0.15 && simd_distance(s.b, b) < 0.15)
                || (simd_distance(s.a, b) < 0.15 && simd_distance(s.b, a) < 0.15)
        }
        spans.removeAll(where: same)
        if let span { spans.append(span) }
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

    enum AnchorCheck { case none, checked, far(SIMD3<Float>, feet: Double) }

    // Coming back in: the spot under the crosshair should be the start spot,
    // give or take the walk's drift (inches). Further than 2 ft and it was
    // probably aimed at something else, so it is handed back to ask about
    // rather than saved as a drift of several feet.
    func checkAnchor() -> AnchorCheck {
        guard let p = aimedPoint() else { return .none }
        if let s = anchorStart {
            let feet = Double(simd_length(SIMD2(p.x - s.x, p.z - s.z))) * 3.28084
            if feet > 2 { return .far(p, feet: feet) }
        }
        anchorEnd = p
        writeFiles()
        return .checked
    }

    func acceptAnchorEnd(_ p: SIMD3<Float>) {
        anchorEnd = p
        writeFiles()
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
            // Readings and edits follow their walls and doors into the new plan.
            var lost = 0
            if let old = structure ?? previous {
                measurements = remap(measurements, from: old.walls, to: built.walls)
                lost = carryEdits(from: old, to: built)
            }
            previous = nil
            structure = built
            // A resumed scan keeps its name; a new one is named by the time.
            // Stored files are named by the time only; the scan's name (often
            // the address) goes into the plan and into the copies that are shared.
            if !resumed || stamp.isEmpty { stamp = Self.stampFormatter.string(from: Date()) }
            writeFiles()
            saveWorldMap()
            write3DModel(replace: true)
            if lost > 0 {
                message = "\(lost == 1 ? "1 edit" : "\(lost) edits") couldn't find \(lost == 1 ? "its wall" : "their walls") in the rebuilt plan. Check them in Measure walls, Edit."
            }
        } catch {
            message = "Export failed: \(error.localizedDescription)"
        }
    }

    // A rebuild can give walls new identifiers. Readings follow their wall
    // to the new wall in the same place: same floor, parallel, middles within
    // about a foot. Readings whose wall has gone are dropped.
    private func remap(_ readings: [UUID: WallMeasurement], from old: [CapturedRoom.Surface],
                       to new: [CapturedRoom.Surface]) -> [UUID: WallMeasurement] {
        let map = Self.matcher(old, new, sameLength: false)
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

    // The surface of a new build in the same place as one of an earlier
    // build: same floor, parallel, middles within about a foot and, for
    // edits, lengths within about a foot (so a deleted piece of wall doesn't
    // hide the whole wall it was rebuilt into).
    private nonisolated static func matcher(_ old: [CapturedRoom.Surface], _ new: [CapturedRoom.Surface],
                                            sameLength: Bool) -> (UUID) -> UUID? {
        let newIDs = Set(new.map(\.identifier))
        func mid(_ s: CapturedRoom.Surface) -> SIMD2<Float> { SIMD2(s.transform.columns.3.x, s.transform.columns.3.z) }
        func dir(_ s: CapturedRoom.Surface) -> SIMD2<Float> { SIMD2(s.transform.columns.0.x, s.transform.columns.0.z) }
        return { id in
            if newIDs.contains(id) { return id }
            guard let o = old.first(where: { $0.identifier == id }) else { return nil }
            return new.filter { $0.story == o.story && abs(simd_dot(dir($0), dir(o))) > 0.98
                                && (!sameLength || abs($0.dimensions.x - o.dimensions.x) < 0.3) }
                .min { simd_distance(mid($0), mid(o)) < simd_distance(mid($1), mid(o)) }
                .flatMap { simd_distance(mid($0), mid(o)) < 0.3 ? $0.identifier : nil }
        }
    }

    // Moves the clean-up edits onto a rebuilt plan's walls, doors and rooms.
    // Returns how many could not be placed; those are dropped.
    private func carryEdits(from old: CapturedStructure, to new: CapturedStructure) -> Int {
        let wall = Self.matcher(old.walls, new.walls, sameLength: true)
        let wallNear = Self.matcher(old.walls, new.walls, sameLength: false)
        let opening = Self.matcher(old.doors + old.windows + old.openings,
                                   new.doors + new.windows + new.openings, sameLength: true)
        var lost = 0
        var edits: [UUID: WallEdit] = [:]
        for (id, e) in wallEdits {
            if let n = wall(id), edits[n] == nil { edits[n] = e } else { lost += 1 }
        }
        var hidden: Set<UUID> = []
        for id in hiddenOpenings {
            if let n = opening(id) { hidden.insert(n) } else { lost += 1 }
        }
        // Added doors keep their place; only the wall they sit in is renamed.
        let added = addedOpenings.map { o -> AddedOpening in
            var o = o
            o.wall = o.wall.flatMap(wallNear)
            return o
        }
        var depths: [GapDepth] = []
        for d in gapDepths {
            if let n = wallNear(d.from) { var d = d; d.from = n; depths.append(d) } else { lost += 1 }
        }
        // A name that replaced a scanned room follows that room: same floor,
        // middle within a metre.
        let labels = roomLabels.map { l -> RoomLabel in
            var l = l
            if let i = l.replaces, i < old.sections.count {
                let o = old.sections[i]
                l.replaces = new.sections.indices
                    .filter { new.sections[$0].story == o.story }
                    .min { simd_distance(new.sections[$0].center, o.center) < simd_distance(new.sections[$1].center, o.center) }
                    .flatMap { simd_distance(new.sections[$0].center, o.center) < 1 ? $0 : nil }
            }
            return l
        }
        wallEdits = edits
        hiddenOpenings = hidden
        addedOpenings = added
        gapDepths = depths
        roomLabels = labels
        // Undo steps name the old walls; Restore scan still undoes everything.
        editHistory = []
        return lost
    }

    // MARK: Save and resume on site

    var modelURL: URL { Self.docs.appendingPathComponent("scan-\(stamp).usdz") }

    // A 3-D model of the scan (walls, doors, windows, furniture boxes) that
    // Files, Quick Look and AR on any iPhone or Mac open directly. Written
    // when a plan is built, and for older scans the first time they're opened.
    func write3DModel(replace: Bool) {
        guard let structure, !stamp.isEmpty else { return }
        let url = modelURL
        if !replace && FileManager.default.fileExists(atPath: url.path) { return }
        try? FileManager.default.removeItem(at: url)
        do {
            try structure.export(to: url, exportOptions: .model)
        } catch {
            try? structure.export(to: url, exportOptions: .parametric)
        }
    }

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
        if let s = structure { previous = s }
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
                                measurements: measurements, spans: spans, wallEdits: wallEdits,
                                roomLabels: roomLabels, addedOpenings: addedOpenings,
                                rooms: resolvedRooms(structure), hiddenOpenings: hiddenOpenings,
                                exterior: exteriorWalls, anchorStart: anchorStart, anchorEnd: anchorEnd,
                                name: scanName)
                .write(to: planURL)
            try JSONEncoder().encode(structure).write(to: rawURL)
            exportURLs = [planURL, rawURL] + (FileManager.default.fileExists(atPath: modelURL.path) ? [modelURL] : [])
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
        struct NameOnly: Decodable { let name: String? }
        var found: [String: String] = [:]
        for stamp in savedScans {
            let url = Self.docs.appendingPathComponent("scan-\(stamp).cvalrscan.json")
            if let n = (try? JSONDecoder().decode(NameOnly.self, from: Data(contentsOf: url)))?.name { found[stamp] = n }
        }
        savedNames = found
    }

    static func title(for stamp: String) -> String {
        guard let date = stampFormatter.date(from: stamp) else { return stamp }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    // A saved scan's name and date, or just the date.
    func savedTitle(for stamp: String) -> String {
        let date = Self.title(for: stamp)
        guard let name = savedNames[stamp], !name.isEmpty else { return date }
        return "\(name) · \(date)"
    }

    func setName(_ name: String) {
        scanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if structure != nil { writeFiles() }
        shareURLs = namedCopies(of: exportURLs)
    }

    // Copies of the scan files named like "2603 36 Ave 2026-10-08_21-07.cvalrscan.json",
    // so a shared or saved file says which job it is. The originals keep
    // their timestamp names, which the app finds them by. Characters that
    // file systems refuse (/ \ : * ? " < > |) are left out.
    private func namedCopies(of urls: [URL]) -> [URL] {
        let name = scanName.components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|")).joined()
            .trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !stamp.isEmpty, !urls.isEmpty else { return urls }
        let date = Self.stampFormatter.date(from: stamp).map(Self.fileDateFormatter.string(from:)) ?? stamp
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("share-\(stamp)")
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return urls.map { url in
            let suffix = url.lastPathComponent.replacingOccurrences(of: "scan-\(stamp)", with: "")
            let copy = dir.appendingPathComponent("\(name) \(date)\(suffix)")
            return (try? FileManager.default.copyItem(at: url, to: copy)) != nil ? copy : url
        }
    }

    private static let fileDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm"
        return f
    }()

    func newScan() {
        rooms = []
        corners = []
        wallPoints = []
        gapDepths = []
        spans = []
        wallEdits = [:]
        roomLabels = []
        addedOpenings = []
        hiddenOpenings = []
        editHistory = []
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
        previous = nil
        stamp = ""
        scanName = ""
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
                    moving: (r.moving ?? []).compactMap(UUID.init(uuidString:)),
                    entered: r.entered ?? "")
            }
            measurements = m
            wallPoints = (saved?.wallPoints ?? []).map {
                WallPoint(point: SIMD3(Float($0.point[0]), Float($0.elevation), Float($0.point[1])),
                          normal: SIMD3(Float($0.normal[0]), 0, Float($0.normal[1])))
            }
            wallEdits = Dictionary(uniqueKeysWithValues: (saved?.wallEdits ?? []).compactMap { e in
                UUID(uuidString: e.wall).map { ($0, WallEdit(hidden: e.hidden,
                    a: e.a.flatMap { $0.count == 2 ? SIMD2($0[0], $0[1]) : nil },
                    b: e.b.flatMap { $0.count == 2 ? SIMD2($0[0], $0[1]) : nil })) }
            })
            roomLabels = (saved?.roomLabels ?? []).compactMap { r in
                r.point.count == 2 ? RoomLabel(story: r.story, point: SIMD2(r.point[0], r.point[1]), name: r.name, replaces: r.replaces) : nil
            }
            addedOpenings = (saved?.addedOpenings ?? []).compactMap { o in
                guard o.a.count == 2, o.b.count == 2 else { return nil }
                return AddedOpening(story: o.story, wall: o.wall.flatMap(UUID.init(uuidString:)),
                                    a: SIMD2(o.a[0], o.a[1]), b: SIMD2(o.b[0], o.b[1]),
                                    kind: OpeningKind(rawValue: o.kind ?? "") ?? (o.door == false ? .opening : .interior),
                                    hingeAtB: o.hingeAtB ?? false, side: o.side ?? 1,
                                    style: DoorStyle(rawValue: o.style ?? "") ?? .swing)
            }
            hiddenOpenings = Set((saved?.hiddenOpenings ?? []).compactMap(UUID.init(uuidString:)))
            editHistory = []
            spans = (saved?.spans ?? []).compactMap { r in
                guard r.a.count == 2, r.b.count == 2 else { return nil }
                return SpanReading(a: SIMD2(r.a[0], r.a[1]), b: SIMD2(r.b[0], r.b[1]), story: r.story,
                                   inches: r.inches, face: WallMeasurement.Face(rawValue: r.face) ?? .outside,
                                   entered: r.entered ?? "")
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
            scanName = saved?.name ?? ""
            loadedFromFile = true
            resumed = false
            canResume = FileManager.default.fileExists(atPath: worldMapURL.path)
            write3DModel(replace: false)
            exportURLs = (FileManager.default.fileExists(atPath: planURL.path) ? [planURL, rawURL] : [rawURL])
                + (FileManager.default.fileExists(atPath: modelURL.path) ? [modelURL] : [])
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
        for suffix in [".capturedstructure.json", ".cvalrscan.json", ".worldmap", ".usdz"] {
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
        for suffix in [".capturedstructure.json", ".cvalrscan.json", ".worldmap", ".usdz"] {
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
            let entered: String?
        }
        struct Exterior: Decodable { let walls: [[Point]]; let anchorStart: Point?; let anchorEnd: Point? }
        struct WallPointIn: Decodable { let point: [Double]; let elevation: Double; let normal: [Double] }
        struct GapDepthIn: Decodable { let gap: [[Double]]; let from: String; let inches: Int }
        struct RoomLabelIn: Decodable { let story: Int; let point: [Double]; let name: String; let replaces: Int? }
        struct OpeningIn: Decodable { let story: Int; let wall: String?; let a: [Double]; let b: [Double]
            let kind: String?; let door: Bool?; let hingeAtB: Bool?; let side: Int?; let style: String? }
        struct WallEditIn: Decodable { let wall: String; let hidden: Bool; let a: [Double]?; let b: [Double]? }
        struct SpanIn: Decodable {
            let a: [Double]; let b: [Double]; let story: Int; let inches: Int; let face: String; let entered: String?
        }
        let name: String?
        let corners: [Point]?
        let wallPoints: [WallPointIn]?
        let gapDepths: [GapDepthIn]?
        let spans: [SpanIn]?
        let wallEdits: [WallEditIn]?
        let roomLabels: [RoomLabelIn]?
        let addedOpenings: [OpeningIn]?
        let hiddenOpenings: [String]?
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
