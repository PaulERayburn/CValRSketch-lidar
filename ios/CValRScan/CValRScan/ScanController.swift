import ARKit
import AVFoundation
import Foundation
import RoomPlan
import UIKit

// Drives RoomPlan: scans rooms one after another in the same AR session so
// they share one coordinate system, then merges them into one structure.
// Marked corners and meter readings live in that same coordinate system.
@MainActor
final class ScanController: NSObject, ObservableObject, @preconcurrency RoomCaptureViewDelegate {
    @Published var rooms: [CapturedRoom] = [] { didSet { roomsChanged = true } }
    @Published var isScanning = false
    private var wideAfterRoom = false
    @Published var isBusy = false
    @Published var message: String?
    @Published var exportURLs: [URL] = [] { didSet { shareURLs = namedCopies(of: exportURLs) } }
    // The same files, named by the scan's name and date for sharing.
    @Published private(set) var shareURLs: [URL] = []
    // The user's name for this scan, usually the address.
    @Published private(set) var scanName = ""
    @Published private(set) var savedNames: [String: String] = [:]   // stamp: name
    // Photos taken mid-scan (Photos.swift), kept in their own folder.
    @Published var photos: [ScanPhoto] = []
    var photoFolder = ""
    var photoZip: URL?
    @Published var torchOn = false
    @Published var corners: [SIMD3<Float>] = []        // older scans only; Mark wall replaced them
    @Published private(set) var wallPoints: [WallPoint] = []
    @Published private(set) var gapDepths: [GapDepth] = []
    @Published private(set) var spans: [SpanReading] = []
    @Published private(set) var wallEdits: [UUID: WallEdit] = [:]
    @Published private(set) var roomLabels: [RoomLabel] = []
    // Names and finishes picked while each room scanned (RoomPicks.swift),
    // until Build floor plan puts them on the plan's rooms.
    @Published private(set) var scannedPicks: [ScannedRoomPicks] = []
    // Picks for the room being scanned, from Done with room until RoomPlan hands it over.
    private var picksForRoom: RoomPicks?
    @Published private(set) var addedOpenings: [AddedOpening] = []
    @Published private(set) var hiddenOpenings: Set<UUID> = []      // the scan's doors and openings removed or replaced
    private var editHistory: [EditSnapshot] = []
    var canUndoEdit: Bool { !editHistory.isEmpty }
    var hasEdits: Bool { !wallEdits.isEmpty || !roomLabels.isEmpty || !addedOpenings.isEmpty || !hiddenOpenings.isEmpty || !addedWalls.isEmpty || !stairEdits.isEmpty || !addedStairs.isEmpty }
    @Published private(set) var addedWalls: [AddedWall] = []
    // Walls drawn or moved in Edit extend the floor outline the import uses.
    @Published private(set) var wallsShapeFloor = true
    func setWallsShapeFloor(_ on: Bool) { wallsShapeFloor = on; writeFiles() }
    private struct EditSnapshot {
        var walls: [UUID: WallEdit]; var rooms: [RoomLabel]; var openings: [AddedOpening]; var hidden: Set<UUID>
        var added: [AddedWall] = []
        var stairs: [UUID: StairEdit] = [:]
        var addedStairs: [StairChain] = []
        var fills: [AreaFill] = []
    }
    // Unscanned areas the user filled in from the floor above.
    @Published private(set) var areaFills: [AreaFill] = []
    func fillFromAbove(_ a: UnscannedArea) {
        commit { $0.fills.append(AreaFill(story: a.story, centre: a.centre, cell: 0.1524, cells: a.cells)) }
        refreshChecks()
    }
    // Space nobody scanned (Unscanned.swift), and what the user said about it.
    @Published private(set) var unscannedDoors: [UnscannedDoor] = []
    @Published private(set) var unscannedAreas: [UnscannedArea] = []
    @Published private(set) var outsideDoors: Set<UUID> = []
    @Published private(set) var ignoredAreas: [SIMD2<Double>] = []
    // Missing-wall edges the user says are open to outside (a porch or recessed entry).
    @Published private(set) var outsideEdges: [SIMD2<Double>] = []
    // The user's names for the floors (story: name), e.g. Main floor, Basement 2.
    @Published private(set) var floorNames: [Int: String] = [:]
    func setFloorName(_ story: Int, _ name: String?) {
        let n = name?.trimmingCharacters(in: .whitespaces) ?? ""
        floorNames[story] = n.isEmpty ? nil : n
        writeFiles()
    }
    func floorName(_ story: Int) -> String { floorNames[story] ?? "Floor \(story + 1)" }
    func markEdgeOutside(_ g: PlanGap) { outsideEdges.append((g.worldA + g.worldB) / 2); writeFiles() }

    func refreshChecks() {
        if let s = structure {
            let filled = Dictionary(grouping: areaFills, by: \.story).mapValues { $0.flatMap(\.cells) }
            unscannedDoors = Unscanned.doors(floors: s.floors, doors: s.doors + s.openings, skip: hiddenOpenings.union(outsideDoors),
                                             extra: filled)
            unscannedAreas = Unscanned.areas(floors: s.floors, ignored: ignoredAreas + areaFills.map(\.centre), angle: planGeometry.angle)
        } else {
            unscannedDoors = Unscanned.doors(floors: rooms.flatMap(\.floors), doors: rooms.flatMap { $0.doors + $0.openings }, skip: outsideDoors)
            unscannedAreas = Unscanned.areas(floors: rooms.flatMap(\.floors), ignored: ignoredAreas)
        }
    }
    // Doors the user has answered for (outside, or leading to a closet,
    // storage or unfinished space) are no longer flagged.
    func markOutsideDoor(_ id: UUID) { outsideDoors.insert(id); writeFiles(); refreshChecks() }
    // A false opening at the mouth of a bump-out or alcove: it goes, and the
    // walls round the bump-out are marked as the user's, so the import closes
    // their floor into the room ("Drawn walls extend the floor").
    func openToRoom(_ d: UnscannedDoor) {
        guard let structure else { return }
        let u = simd_normalize(d.b - d.a), n = SIMD2(-u.y, u.x)
        let side = simd_dot(d.beyond - d.at, n) >= 0 ? 1.0 : -1.0
        let reach = simd_distance(d.a, d.b) / 2 + 1.5
        var walls: [UUID] = []
        for w in structure.walls where w.story == d.story {
            guard let s = edited(PlanExport.segment(w)) else { continue }
            let a = SIMD2(s.a[0], s.a[1]), b = SIMD2(s.b[0], s.b[1]), m = (a + b) / 2
            if simd_dot(m - d.at, n) * side > 0.05, min(simd_distance(a, d.at), simd_distance(b, d.at)) < reach { walls.append(w.identifier) }
        }
        commit { s in
            s.hidden.insert(d.id)
            for id in walls where s.walls[id] == nil { s.walls[id] = WallEdit() }
        }
        refreshChecks()
    }
    func markDoorLeadsTo(_ d: UnscannedDoor, name: String) {
        outsideDoors.insert(d.id)
        setRoomName(name, source: .new, at: d.beyond, story: d.story)
    }
    func ignoreArea(_ a: UnscannedArea) { ignoredAreas.append(a.centre); writeFiles(); refreshChecks() }

    // Stairs the user drew (Stairs.swift).
    @Published private(set) var addedStairs: [StairChain] = []

    func addStairChain(_ c: StairChain) { commit { $0.addedStairs.append(c) } }
    func changeStairChain(_ id: UUID, _ change: @escaping (inout StairChain) -> Void) {
        commit { if let i = $0.addedStairs.firstIndex(where: { $0.id == id }) { change(&$0.addedStairs[i]) } }
    }
    // Removes a piece and everything after it; the whole stair once none are left.
    func removeStairPieces(_ id: UUID, from index: Int) {
        commit {
            guard let i = $0.addedStairs.firstIndex(where: { $0.id == id }) else { return }
            if index <= 0 { $0.addedStairs.remove(at: i) } else { $0.addedStairs[i].pieces = Array($0.addedStairs[i].pieces.prefix(index)) }
        }
    }
    @Published private(set) var stairEdits: [UUID: StairEdit] = [:]

    func flipStairs(_ id: UUID) { commit { $0.stairs[id, default: StairEdit()].flip.toggle() } }
    func hideStairs(_ id: UUID) { commit { $0.stairs[id, default: StairEdit()].hidden = true } }
    func turnStairs(_ id: UUID) { commit { $0.stairs[id, default: StairEdit()].turn.toggle() } }
    func setStairRun(_ id: UUID, inches: Int) { commit { $0.stairs[id, default: StairEdit()].run = Double(inches) * 0.0254 } }
    var hasReadings: Bool { !measurements.isEmpty || !spans.isEmpty }
    @Published private(set) var structure: CapturedStructure?
    @Published private(set) var measurements: [UUID: WallMeasurement] = [:]
    @Published private(set) var savedScans: [String] = []   // timestamps, newest first
    @Published private(set) var loadedFromFile = false
    // Outside walk: points on the siding, grouped one list per exterior wall,
    // in the order taken; a fixed spot by the door marked going out and coming
    // back in measures the tracking drift.
    @Published var exteriorWalls: [[ExteriorPoint]] = []
    @Published var anchorStart: SIMD3<Float>?
    @Published var anchorEnd: SIMD3<Float>?
    @Published var isOutside = false
    // Resuming a saved scan on site: the phone relocalizes against the saved
    // AR world map, after which new rooms and outside points line up with it.
    @Published private(set) var canResume = false
    @Published private(set) var isRelocalizing = false
    @Published private(set) var resumed = false
    // Crash-safe progress (Recovery.swift): an unbuilt scan found on disk at
    // launch, and whether the scan open now came back that way and still
    // has to be located on site before it can be added to.
    @Published private(set) var recoveryOffer: RecoveryOffer?
    @Published private(set) var recoveredNeedsResume = false
    private let recoveryIO = RecoveryIO(root: ScanController.docs)
    private var recoveryId: String?
    private var roomsChanged = true
    private var roomsSavedFor: String?
    private var recoveryMap: URL?
    private var mapSaving = false
    private var mapWanted = false
    private var lastMapSave = Date.distantPast
    private var mapBackgroundTask = UIBackgroundTaskIdentifier.invalid

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
    lazy var outsideDepth = OutsideDepth(session: arSession)
    // The 0.5× camera, run while the AR session is paused (WidePhoto.swift).
    lazy var widePhoto = WidePhoto(scan: self)
    // True from pausing the AR session for the wide camera until it runs
    // again: a world map can't be taken from a paused session.
    var arPausedForWidePhoto = false
    var isSavingMap: Bool { mapSaving }
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
        refreshRecovery()
    }

    // RoomCaptureViewDelegate inherits NSCoding; nothing here needs archiving.
    required init?(coder: NSCoder) { nil }
    func encode(with coder: NSCoder) {}

    func startRoom() {
        // A reopened plan's AR session is gone, so new rooms could not line up with it.
        if loadedFromFile { newScan() }
        discardNext = false
        picksForRoom = nil
        exportURLs = []
        if let s = structure { previous = s }
        structure = nil
        isScanning = true
        captureView.captureSession.run(configuration: RoomCaptureSession.Configuration())
    }

    // `picks`: what the user tapped in the panel while the room scanned.
    // `thenWide`: open the wide camera as soon as the room is processed.
    func finishRoom(picks: RoomPicks = RoomPicks(), thenWide: Bool = false) {
        wideAfterRoom = thenWide
        picksForRoom = picks.isEmpty ? nil : picks
        isBusy = true
        setTorch(false)
        // Keep the AR session alive so the next room lines up with this one.
        captureView.captureSession.stop(pauseARSession: false)
    }

    func cancelRoom() {
        wideAfterRoom = false
        discardNext = true
        picksForRoom = nil
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
        let picks = picksForRoom
        picksForRoom = nil
        let wide = wideAfterRoom
        wideAfterRoom = false
        if let error {
            message = "Scan failed: \(error.localizedDescription)"
            return
        }
        rooms.append(processedResult)
        if let picks {
            let m = Self.middle(of: processedResult)
            scannedPicks.append(ScannedRoomPicks(room: processedResult.identifier, picks: picks, center: m.center, elevation: m.elevation))
            // "Bedroom 2" counts as a use of Bedroom, as the room sheet's list counts names.
            if let n = picks.name, let chip = RoomChoices.chip(for: n) { RoomNames.recordUse(chip == RoomChoices.other ? n : chip) }
        }
        message = "Room \(rooms.count) added"
        refreshChecks()
        saveProgress(worldMap: true)
        // Wide photo waits for this room's map save itself, so it can start now.
        if wide { widePhoto.begin(outside: false) { [weak self] in self?.message = $0 } }
    }

    func removeLastRoom() {
        if let gone = rooms.popLast() { scannedPicks.removeAll { $0.room == gone.identifier } }
        exportURLs = []
        structure = nil
        refreshChecks()
        saveProgress()
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
        var s = EditSnapshot(walls: wallEdits, rooms: roomLabels, openings: addedOpenings, hidden: hiddenOpenings, added: addedWalls, stairs: stairEdits, addedStairs: addedStairs, fills: areaFills)
        editHistory.append(s)
        change(&s)
        wallEdits = s.walls
        roomLabels = s.rooms
        addedOpenings = s.openings
        hiddenOpenings = s.hidden
        addedWalls = s.added
        stairEdits = s.stairs
        addedStairs = s.addedStairs
        areaFills = s.fills
        writeFiles()
    }

    // Names a room: a new name at a spot, or renaming or removing (nil) a
    // scanned name or one given before. `finishes` nil keeps a label's own.
    func setRoomName(_ name: String?, finishes: RoomFinishes? = nil, source: RoomSource, at point: SIMD2<Double>, story: Int) {
        commit { s in
            switch source {
            case .new:
                if let name, !name.isEmpty {
                    s.rooms.append(RoomLabel(story: story, point: point, name: name, replaces: nil, finishes: finishes ?? RoomFinishes()))
                }
            case .label(let i):
                guard s.rooms.indices.contains(i) else { return }
                if let name, !name.isEmpty {
                    s.rooms[i].name = name
                    if let finishes { s.rooms[i].finishes = finishes }
                }
                else if s.rooms[i].replaces != nil { s.rooms[i].name = ""; s.rooms[i].finishes = RoomFinishes() }
                else { s.rooms.remove(at: i) }
            case .scanned(let i):
                s.rooms.removeAll { $0.replaces == i }
                s.rooms.append(RoomLabel(story: story, point: point, name: name ?? "", replaces: i,
                                         finishes: name == nil ? RoomFinishes() : finishes ?? RoomFinishes()))
            }
        }
    }

    // A room's finishes as they stand (the scan's own rooms have none).
    func finishes(for source: RoomSource) -> RoomFinishes {
        if case .label(let i) = source, roomLabels.indices.contains(i) { return roomLabels[i].finishes }
        return RoomFinishes()
    }

    // Every room name so far, for numbering bedrooms while scanning: picks
    // of rooms not yet built, and the plan's rooms of a scan being added to.
    func existingRoomNames() -> [String] {
        let built = (structure ?? previous).map { resolvedRooms($0).map(\.name) } ?? []
        return built + scannedPicks.compactMap(\.picks.name)
    }

    // The middle of a scanned room's floor (world x, z) and the floor's height.
    static func middle(of room: CapturedRoom) -> (center: SIMD2<Double>, elevation: Double) {
        if let f = room.floors.max(by: { $0.dimensions.x * $0.dimensions.y < $1.dimensions.x * $1.dimensions.y }) {
            let t = f.transform.columns.3
            return (SIMD2(Double(t.x), Double(t.z)), Double(t.y))
        }
        let ws = room.walls
        guard !ws.isEmpty else { return (.zero, 0) }
        let c = ws.reduce(SIMD2<Double>.zero) { $0 + SIMD2(Double($1.transform.columns.3.x), Double($1.transform.columns.3.z)) } / Double(ws.count)
        let bottom = ws.map { Double($0.transform.columns.3.y - $0.dimensions.y / 2) }.min() ?? 0
        return (c, bottom)
    }

    // A scanned room's extent across the floor (world x, z), from its wall ends.
    nonisolated static func footprint(_ room: CapturedRoom) -> (lo: SIMD2<Float>, hi: SIMD2<Float>)? {
        var lo = SIMD2<Float>(.infinity, .infinity), hi = SIMD2<Float>(-.infinity, -.infinity)
        for w in room.walls {
            let c = SIMD2(w.transform.columns.3.x, w.transform.columns.3.z)
            let u = SIMD2(w.transform.columns.0.x, w.transform.columns.0.z) * (w.dimensions.x / 2)
            for e in [c - u, c + u] { lo = simd_min(lo, e); hi = simd_max(hi, e) }
        }
        return lo.x.isFinite && hi.x.isFinite ? (lo, hi) : nil
    }

    // Build floor plan: the picks made while each room scanned go on the
    // plan's room there: the scan's own name for it (renamed, if a name was
    // picked), else a new name at the room's middle. Not an Undo step.
    private func applyScannedPicks(_ s: CapturedStructure) {
        guard !scannedPicks.isEmpty else { return }
        var labels = roomLabels
        var used: Set<Int> = []
        for p in scannedPicks {
            let story = Self.story(at: p.center, elevation: p.elevation, in: s)
            func dist(_ i: Int) -> Double {
                let c = s.sections[i].center
                return simd_distance(SIMD2(Double(c.x), Double(c.z)), p.center)
            }
            let picked = (p.picks.name ?? "").isEmpty ? nil : p.picks.name
            // The scan's own name for this room is one whose centre lies inside
            // the room scanned (a big living room's can sit well off its
            // middle), else one within 1.5 m. Of those, one already called what
            // was picked, then the nearest.
            let box = rooms.first { $0.identifier == p.room }.flatMap(Self.footprint)
            func inside(_ i: Int) -> Bool {
                guard let box else { return false }
                let c = s.sections[i].center
                return c.x >= box.lo.x - 0.3 && c.x <= box.hi.x + 0.3 && c.z >= box.lo.y - 0.3 && c.z <= box.hi.y + 0.3
            }
            func sameName(_ i: Int) -> Bool {
                guard let picked else { return false }
                return Self.roomName(String(describing: s.sections[i].label)).lowercased() == picked.lowercased()
            }
            let near = s.sections.indices
                .filter { s.sections[$0].story == story && !used.contains($0) && (inside($0) || dist($0) < 1.5) }
                .min { (sameName($0) ? 0 : 1, dist($0)) < (sameName($1) ? 0 : 1, dist($1)) }
            guard let i = near else {
                labels.append(RoomLabel(story: story, point: p.center, name: picked ?? "Room", replaces: nil, finishes: p.picks.finishes))
                continue
            }
            used.insert(i)
            let scanned = Self.roomName(String(describing: s.sections[i].label))
            let c = s.sections[i].center
            var label = labels.first { $0.replaces == i }
                ?? RoomLabel(story: story, point: SIMD2(Double(c.x), Double(c.z)), name: scanned, replaces: i)
            if let picked { label.name = picked }
            if label.name.isEmpty { label.name = scanned.isEmpty ? "Room" : scanned }
            let f = p.picks.finishes
            label.finishes = RoomFinishes(floor: f.floor ?? label.finishes.floor, walls: f.walls ?? label.finishes.walls,
                                          ceiling: f.ceiling ?? label.finishes.ceiling, condition: f.condition ?? label.finishes.condition)
            labels.removeAll { $0.replaces == i }
            labels.append(label)
        }
        roomLabels = labels
        scannedPicks = []
    }

    // The floor (story) of the built plan under a point at a height: one
    // whose outline holds it, the nearest in height.
    private static func story(at c: SIMD2<Double>, elevation: Double, in s: CapturedStructure) -> Int {
        let p = CGPoint(x: c.x, y: c.y)
        let ranked = s.floors.map { f -> (story: Int, cost: Double) in
            let poly = PlanExport.floor(f).polygon.compactMap { $0.count == 2 ? CGPoint(x: $0[0], y: $0[1]) : nil }
            return (f.story, abs(Double(f.transform.columns.3.y) - elevation) + (inside(p, poly) ? 0 : 100))
        }
        return ranked.min { $0.cost < $1.cost }?.story ?? 0
    }

    // The typical height of the walls of the scanned room at a point on a
    // floor of the plan: the middle wall height, leaving out half walls.
    // Metres to the centimetre; nil where no scanned room holds the point.
    static func ceilingHeight(story: Int, at c: SIMD2<Double>, in s: CapturedStructure) -> Double? {
        let p = CGPoint(x: c.x, y: c.y)
        func poly(_ f: CapturedRoom.Surface) -> [CGPoint] {
            PlanExport.floor(f).polygon.compactMap { $0.count == 2 ? CGPoint(x: $0[0], y: $0[1]) : nil }
        }
        let level = s.floors.filter { $0.story == story && inside(p, poly($0)) }.map { Double($0.transform.columns.3.y) }.first
        let room = s.rooms.first { r in
            r.floors.contains { f in
                inside(p, poly(f)) && level.map { abs(Double(f.transform.columns.3.y) - $0) < 0.5 } ?? true
            }
        }
        let heights = (room?.walls ?? []).map { Double($0.dimensions.y) }.filter { $0 > 1.5 && $0.isFinite }.sorted()
        guard !heights.isEmpty else { return nil }
        return (heights[heights.count / 2] * 100).rounded() / 100
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
        let drawn = addedWalls.map { w -> AddedWall in
            var w = w
            if simd_distance(w.a, from) < 0.1 { w.a = to }
            if simd_distance(w.b, from) < 0.1 { w.b = to }
            return w
        }
        commit { $0.walls = e; $0.added = drawn }
    }

    func deleteWalls(_ ids: Set<UUID>) {
        var e = wallEdits
        let drawn = Set(addedWalls.map(\.id))
        for id in ids where !drawn.contains(id) { e[id, default: WallEdit()].hidden = true }
        commit { $0.walls = e; $0.added.removeAll { ids.contains($0.id) } }
    }

    // Slides one wall sideways by `v` (world). Walls joined at its ends that
    // run across it stretch to follow; walls running on in line with it stay
    // put, and a short wall joins each to the moved end. One Undo step.
    func slideWall(_ id: UUID, by v: SIMD2<Double>) {
        guard let structure else { return }
        var segs: [(id: UUID, a: SIMD2<Double>, b: SIMD2<Double>, scanned: Bool)] =
            structure.walls.compactMap { w in edited(PlanExport.segment(w)).map { (w.identifier, SIMD2($0.a[0], $0.a[1]), SIMD2($0.b[0], $0.b[1]), true) } }
        segs += addedWalls.map { ($0.id, $0.a, $0.b, false) }
        guard let me = segs.first(where: { $0.id == id }) else { return }
        let dir = simd_normalize(me.b - me.a)
        var e = wallEdits, drawn = addedWalls, links: [AddedWall] = []
        for end in [me.a, me.b] {
            let to = end + v
            for s in segs {
                let atA = simd_distance(s.a, end) < 0.1, atB = simd_distance(s.b, end) < 0.1
                guard atA || atB else { continue }
                let inLine = s.id != id && abs(simd_dot(simd_normalize(s.b - s.a), dir)) > 0.9
                if inLine { continue }
                if s.scanned {
                    if atA { e[s.id, default: WallEdit()].a = to }
                    if atB { e[s.id, default: WallEdit()].b = to }
                } else if let i = drawn.firstIndex(where: { $0.id == s.id }) {
                    if atA { drawn[i].a = to }
                    if atB { drawn[i].b = to }
                }
            }
            if segs.contains(where: { $0.id != id && abs(simd_dot(simd_normalize($0.b - $0.a), dir)) > 0.9
                && (simd_distance($0.a, end) < 0.1 || simd_distance($0.b, end) < 0.1) }) {
                links.append(AddedWall(story: structure.walls.first { $0.identifier == id }?.story ?? addedWalls.first { $0.id == id }?.story ?? 0,
                                       a: end, b: to))
            }
        }
        commit { $0.walls = e; $0.added = drawn + links }
    }

    // Moves one end of one wall only, leaving walls joined there where they are.
    func moveOneEnd(_ id: UUID, from: SIMD2<Double>, to: SIMD2<Double>) {
        if let i = addedWalls.firstIndex(where: { $0.id == id }) {
            var w = addedWalls[i]
            if simd_distance(w.a, from) <= simd_distance(w.b, from) { w.a = to } else { w.b = to }
            commit { $0.added[i] = w }
            return
        }
        guard let structure, let wall = structure.walls.first(where: { $0.identifier == id }),
              let s = edited(PlanExport.segment(wall)) else { return }
        let a = SIMD2(s.a[0], s.a[1]), b = SIMD2(s.b[0], s.b[1])
        var e = wallEdits
        if simd_distance(a, from) <= simd_distance(b, from) { e[id, default: WallEdit()].a = to } else { e[id, default: WallEdit()].b = to }
        commitEdits(e)
    }

    // A wall drawn where the scan saw none (world x, z).
    func addWall(story: Int, a: SIMD2<Double>, b: SIMD2<Double>) {
        commit { $0.added.append(AddedWall(story: story, a: a, b: b)) }
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
        let drawn = addedWalls.map { w -> AddedWall in
            var w = w
            if let m = moves.first(where: { simd_distance(w.a, $0.from) < 0.1 }) { w.a = m.to }
            if let m = moves.first(where: { simd_distance(w.b, $0.from) < 0.1 }) { w.b = m.to }
            return w
        }
        commit { $0.walls = e; $0.added = drawn }
    }

    func undoEdit() {
        guard let last = editHistory.popLast() else { return }
        wallEdits = last.walls
        roomLabels = last.rooms
        addedOpenings = last.openings
        hiddenOpenings = last.hidden
        addedWalls = last.added
        stairEdits = last.stairs
        addedStairs = last.addedStairs
        areaFills = last.fills
        writeFiles()
    }

    func restoreScan() {
        guard hasEdits else { return }
        commit { $0 = EditSnapshot(walls: [:], rooms: [], openings: [], hidden: [], added: []) }
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

    // The surface point under the screen centre, from an estimated plane:
    // ARKit's guess from camera features, not the LiDAR depth, so weak on
    // plain surfaces, at a slant and at a distance.
    func aimedPoint() -> SIMD3<Float>? { aimedHit()?.point }

    private func aimedHit() -> (point: SIMD3<Float>, normal: SIMD3<Float>, camera: SIMD3<Float>)? {
        guard let frame = arSession.currentFrame else { return nil }
        let query = frame.raycastQuery(from: CGPoint(x: 0.5, y: 0.5),
                                       allowing: .estimatedPlane, alignment: .any)
        guard let hit = arSession.raycast(query).first else { return nil }
        let t = hit.worldTransform, c = frame.camera.transform.columns.3
        return (SIMD3(t.columns.3.x, t.columns.3.y, t.columns.3.z), SIMD3(t.columns.1.x, t.columns.1.y, t.columns.1.z),
                SIMD3(c.x, c.y, c.z))
    }

    // MARK: Outside walk

    // Outside, the siding is marked from LiDAR depth. RoomPlan runs the AR
    // session its own way while scanning, so depth is switched on here, on
    // the session as it runs: no reset, so the world origin and everything
    // already scanned stay where they are. Scan a room hands the session back
    // to RoomPlan, which sets it up again for itself, as after a resume.
    func startOutsideWalk() {
        guard OutsideDepth.isSupported else { return }
        if let c = arSession.configuration as? ARWorldTrackingConfiguration, c.frameSemantics.contains(.sceneDepth) {
            outsideDepth.start()
            return
        }
        // The default video format, which every LiDAR device gives depth with.
        let config = ARWorldTrackingConfiguration()
        if let c = arSession.configuration as? ARWorldTrackingConfiguration { config.worldAlignment = c.worldAlignment }
        Self.addDepth(to: config)
        arSession.run(config)
        outsideDepth.start()
    }

    func stopOutsideWalk() { outsideDepth.stop() }

    private static func addDepth(to config: ARWorldTrackingConfiguration) {
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) { config.sceneReconstruction = .mesh }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) { config.frameSemantics.insert(.sceneDepth) }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) { config.frameSemantics.insert(.smoothedSceneDepth) }
    }

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

    enum ExteriorMark { case marked(ExteriorPoint), refused(String) }

    // With LiDAR, the siding across the screen is fitted as one upright
    // plane, and the point is where the crosshair meets it; without, the
    // estimated-plane hit under the crosshair.
    func markExteriorPoint() -> ExteriorMark {
        let mark: ExteriorPoint
        if outsideDepth.running {
            switch outsideDepth.strip() {
            case .failure(let f):
                switch f {
                case .tooFar: return .refused(CrosshairReading.tooFar)
                case .notUpright: return .refused("That's not upright. Aim at the siding, not the ground or the eaves.")
                case .offWall: return .refused("Hold steady on one wall")
                case .tooFewSamples, .noWall: return .refused(CrosshairReading.noReading)
                }
            case .success(let s):
                let reading = CrosshairReading(point: s.point, distance: s.distance, angle: s.angle)
                if let why = reading.refusal { return .refused(why) }
                mark = ExteriorPoint(point: SIMD3(Float(s.point.x), Float(s.point.y), Float(s.point.z)), method: "lidar",
                                     distance: s.distance, angle: s.angle, rms: s.rms, n: s.count,
                                     camera: outsideDepth.cameraPlan, dir: s.dir, span: [s.span.0, s.span.1])
            }
        } else {
            guard let hit = aimedHit() else { return .refused("No surface under the crosshair") }
            let ray = hit.point - hit.camera
            mark = ExteriorPoint(point: hit.point, method: "plane", distance: Double(simd_length(ray)),
                                 angle: DepthMath.incidence(direction: SIMD3<Double>(ray), normal: SIMD3<Double>(hit.normal)),
                                 camera: SIMD2(Double(hit.camera.x), Double(hit.camera.z)))
        }
        if exteriorWalls.isEmpty { exteriorWalls.append([]) }
        exteriorWalls[exteriorWalls.count - 1].append(mark)
        writeFiles()
        return .marked(mark)
    }

    // Two faces of siding meeting under the crosshair. The corner ends the
    // current wall; Next wall (which ExteriorView calls after checking the
    // wall for a missed corner) starts the next one from it.
    func markExteriorCorner() -> ExteriorMark {
        guard outsideDepth.running else { return .refused(CrosshairReading.noReading) }
        let c: DepthMath.Corner
        switch outsideDepth.cornerFit() {
        case .success(let k): c = k
        case .failure(let f):
            switch f {
            case .tooFar: return .refused(CrosshairReading.tooFar)
            case .notUpright: return .refused("That's not upright. Aim at the siding, not the ground or the eaves.")
            case .oneWall: return .refused("Only one wall in view — aim at the corner")
            case .notCorner: return .refused("Faces don't meet at a corner")
            case .tooFewSamples, .noWall: return .refused(CrosshairReading.noReading)
            }
        }
        let mark = ExteriorPoint(point: SIMD3(Float(c.point.x), Float(c.point.y), Float(c.point.z)), kind: "corner",
                                 method: "lidar-corner", distance: c.distance, angle: c.angle, rms: c.rms, n: c.count,
                                 camera: outsideDepth.cameraPlan, dirs: orderFaces(c))
        if exteriorWalls.isEmpty { exteriorWalls.append([]) }
        exteriorWalls[exteriorWalls.count - 1].append(mark)
        writeFiles()
        return .marked(mark)
    }

    // The face the current wall's points lie along is the wall just walked,
    // so it goes first. With nothing marked on this wall yet, the face on the
    // screen's left is taken as walked: the importer doesn't rely on the order.
    private func orderFaces(_ c: DepthMath.Corner) -> [SIMD2<Double>] {
        let c2 = SIMD2(c.point.x, c.point.z)
        let walked = (exteriorWalls.last ?? []).map { SIMD2(Double($0.point.x), Double($0.point.z)) }
            .filter { simd_distance($0, c2) > 0.15 }
        func off(_ d: SIMD2<Double>) -> Double { walked.reduce(0) { $0 + abs(d.x * ($1.y - c2.y) - d.y * ($1.x - c2.x)) } }
        if !walked.isEmpty { return off(c.dirs[0]) <= off(c.dirs[1]) ? c.dirs : c.dirs.reversed() }
        guard let f = outsideDepth.forwardPlan else { return c.dirs }
        let right = SIMD2(-f.y, f.x)
        return simd_dot(c.dirs[0], right) <= simd_dot(c.dirs[1], right) ? c.dirs : c.dirs.reversed()
    }

    // A wall holding only the corner that started it: nothing walked on it yet.
    private static func onlyCorner(_ wall: [ExteriorPoint]) -> Bool { wall.count == 1 && wall[0].isCorner }

    func nextExteriorWall() {
        guard let last = exteriorWalls.last, !last.isEmpty, !Self.onlyCorner(last) else { return }
        // After a corner, the next wall starts at it.
        if let c = last.last, c.isCorner {
            exteriorWalls.append([c])
        } else {
            exteriorWalls.append([])
        }
        writeFiles()
    }

    // How far through the walk each point was taken, for spreading the drift:
    // a corner starting a wall is the one that ended the wall before, one point.
    private var walkSteps: (each: [[Int]], total: Int) {
        var k = 0
        let each = exteriorWalls.enumerated().map { i, wall in
            wall.enumerated().map { j, p -> Int in
                if j == 0, p.isCorner, i > 0, exteriorWalls[i - 1].last == p { return k }
                k += 1
                return k
            }
        }
        return (each, k)
    }

    // Where the current wall's points turn a corner, i.e. Next wall was
    // missed: the indexes at which each further wall starts. Empty when
    // the points lie within 6″ of one line.
    var cornerSplits: [Int] {
        guard let wall = exteriorWalls.last else { return [] }
        return Self.splits(wall.map { SIMD2(Double($0.point.x), Double($0.point.z)) }, offset: 0)
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
        // A corner belongs to both walls it joins: Undo takes it off both.
        if let last = exteriorWalls.last, Self.onlyCorner(last), exteriorWalls.count >= 2,
           exteriorWalls[exteriorWalls.count - 2].last == last[0] { exteriorWalls.removeLast() }
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
        let steps = walkSteps
        let total = max(steps.total, 1)
        var lines: [(a: XY, b: XY)] = []
        for (wall, ks) in zip(exteriorWalls, steps.each) {
            let pts: [XY] = zip(wall, ks).map { p, k in
                let f = Float(k) / Float(total + 1)
                let q = p.point - (drift ?? .zero) * f
                return XY(x: Double(q.x), y: Double(q.z))
            }
            // One LiDAR point: the strip it was fitted to.
            if wall.count == 1, let span = wall[0].span, span.count == 2, let k = ks.first {
                let d = drift.map { SIMD2(Double($0.x), Double($0.z)) * (Double(k) / Double(total + 1)) } ?? .zero
                lines.append((XY(x: span[0].x - d.x, y: span[0].y - d.y), XY(x: span[1].x - d.x, y: span[1].y - d.y)))
                continue
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
            applyScannedPicks(built)
            // A resumed scan keeps its name; a new one is named by the time.
            // Stored files are named by the time only; the scan's name (often
            // the address) goes into the plan and into the copies that are shared.
            if !resumed || stamp.isEmpty { stamp = Self.stampFormatter.string(from: Date()) }
            // A recovered scan not yet located on site: this session is not
            // in the scan's space, so its map would be wrong; the map saved
            // with the recovery goes to the scan instead.
            let recovered = recoveredNeedsResume
            let wrote = writeFiles()
            if wrote { finishRecovery(moveMapTo: recovered ? worldMapURL : nil) }
            saveWorldMap()
            write3DModel(replace: true)
            if recovered && wrote { becomeSavedScan() }
            if lost > 0 {
                message = "\(lost == 1 ? "1 edit" : "\(lost) edits") couldn't find \(lost == 1 ? "its wall" : "their walls") in the rebuilt plan. Check them in Measure & edit plan."
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
        guard !stamp.isEmpty, !loadedFromFile, !recoveredNeedsResume else { return }
        recoveryIO.saveWorldMap(from: arSession, to: worldMapURL, onlyFor: nil) { _ in }
    }

    // False when there is no readable map, so the resume screen closes.
    @discardableResult
    func startResume() -> Bool {
        // A recovered scan resumes from the map saved with it, else its saved scan's.
        let urls = (recoveredNeedsResume ? [recoveryMap].compactMap { $0 } : []) + (stamp.isEmpty ? [] : [worldMapURL])
        guard let map = urls.lazy.compactMap({ url in
            (try? Data(contentsOf: url)).flatMap { try? NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: $0) }
        }).first else {
            if recoveredNeedsResume {
                canResume = false
                message = "The saved AR session couldn't be read, so this scan can't be resumed on site. Build floor plan still works."
            } else {
                message = "This scan has no saved session to resume."
            }
            return false
        }
        let config = ARWorldTrackingConfiguration()
        config.initialWorldMap = map
        // Depth too, for marking outside walls once located.
        Self.addDepth(to: config)
        arSession.run(config, options: [.resetTracking, .removeExistingAnchors])
        relocalizeStarted = Date()
        isRelocalizing = true
        return true
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
            let steps = walkSteps
            let total = max(steps.total, 1)
            exteriorWalls = zip(exteriorWalls, steps.each).map { wall, ks in
                zip(wall, ks).map { p, k in p.shifted(by: -d * (Float(k) / Float(total + 1))) }
            }
        }
        // New outside points start a new wall, not the last one walked before.
        if exteriorWalls.last?.isEmpty == false { exteriorWalls.append([]) }
        anchorStart = nil
        anchorEnd = nil
        recoveredNeedsResume = false
        recoveryMap = nil
        message = "Located. Scan more rooms or go outside, then Build floor plan."
        saveProgress()
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

    // Before Build floor plan there are no scan files: the recovery bundle
    // is written instead. True when the scan files were written.
    @discardableResult
    func writeFiles() -> Bool {
        guard let structure else {
            saveProgress()
            return false
        }
        do {
            let dir = Self.docs
            let planURL = dir.appendingPathComponent("scan-\(stamp).cvalrscan.json")
            let rawURL = dir.appendingPathComponent("scan-\(stamp).capturedstructure.json")
            try PlanExport.data(for: structure, corners: corners, wallPoints: wallPoints, gapDepths: gapDepths,
                                measurements: measurements, spans: spans, wallEdits: wallEdits,
                                roomLabels: roomLabels, addedOpenings: addedOpenings,
                                rooms: resolvedRooms(structure).map { r in
                                    var r = r
                                    r.ceilingHeight = Self.ceilingHeight(story: r.story, at: r.center, in: structure)
                                    return r
                                }, hiddenOpenings: hiddenOpenings,
                                exterior: exteriorWalls, anchorStart: anchorStart, anchorEnd: anchorEnd,
                                name: scanName, photos: photos, photoFolder: photoFolder, addedWalls: addedWalls,
                                wallsShapeFloor: wallsShapeFloor, stairEdits: stairEdits,
                                stairChains: addedStairs, outsideDoors: outsideDoors, ignoredAreas: ignoredAreas, outsideEdges: outsideEdges, floorNames: floorNames,
                                areaFills: areaFills)
                .write(to: planURL)
            try JSONEncoder().encode(structure).write(to: rawURL)
            exportURLs = [planURL, rawURL] + (FileManager.default.fileExists(atPath: modelURL.path) ? [modelURL] : [])
            message = "Saved and ready to share"
            refreshChecks()
            refreshSaved()
            return true
        } catch {
            message = "Export failed: \(error.localizedDescription)"
            return false
        }
    }

    // MARK: Crash-safe progress (Recovery.swift)

    // Scanned, marked or photographed, and not yet saved by Build floor plan.
    var unbuiltScanInProgress: Bool {
        !loadedFromFile && structure == nil
            && (!rooms.isEmpty || !photos.isEmpty || !wallPoints.isEmpty || exteriorWalls.contains { !$0.isEmpty } || anchorStart != nil)
    }

    var photosBelongToSavedScan: Bool { belongsToSavedScan(stamp) }

    // Scan a room would start a scan from nothing (rather than add to this one).
    var scanRoomStartsNewScan: Bool { loadedFromFile || (structure == nil && !unbuiltScanInProgress) }

    // Called after every change while the scan is unbuilt (writeFiles does,
    // when there is no plan yet). The small state goes every time, the rooms
    // when they changed; the world map after a room, else every 5 minutes.
    func saveProgress(worldMap: Bool = false) {
        guard unbuiltScanInProgress else {
            // Everything taken off again (Remove last room down to none): nothing to recover.
            // A recovered scan whose rooms couldn't be read keeps its bundle.
            if let id = recoveryId, !loadedFromFile, structure == nil, !recoveredNeedsResume {
                recoveryId = nil
                roomsSavedFor = nil
                recoveryIO.finish(id, moveMapTo: nil) {}
            }
            return
        }
        let id: String
        if let r = recoveryId { id = r } else {
            id = RecoveryFiles.newId()
            recoveryId = id
            recoveryIO.allow(id)
        }
        let state = RecoveryState(scanId: id, savedAt: Date(), appVersion: Self.appVersion, stamp: stamp, resumed: resumed,
                                  name: scanName, roomCount: rooms.count, photoFolder: photoFolder,
                                  photos: photos.map(RecoveryState.Photo.init), wallPoints: wallPoints.map(RecoveryState.WallPt.init),
                                  corners: corners, exterior: exteriorWalls.map { $0.map(RecoveryState.Exterior.init) },
                                  anchorStart: anchorStart, anchorEnd: anchorEnd,
                                  roomPicks: scannedPicks.isEmpty ? nil : scannedPicks)
        let sendRooms = roomsChanged || roomsSavedFor != id
        recoveryIO.save(state, rooms: sendRooms ? rooms : nil)
        roomsChanged = false
        roomsSavedFor = id
        if worldMap || (!isScanning && Date().timeIntervalSince(lastMapSave) > 300) { saveRecoveryMap(id) }
    }

    // One world map at a time; one asked for meanwhile follows when it's done.
    private func saveRecoveryMap(_ id: String) {
        // Until a recovered scan is located, this session isn't in its space.
        guard !recoveredNeedsResume, !isRelocalizing else { return }
        // Left for the next save (lastMapSave unchanged, so it comes soon).
        if arPausedForWidePhoto { return }
        if mapSaving { mapWanted = true; return }
        mapSaving = true
        mapWanted = false
        lastMapSave = Date()
        // A little time to finish writing if the user leaves the app meanwhile.
        // Out of time, the write is abandoned; the previous map stays whole.
        mapBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Save AR session") { self.endMapBackgroundTask() }
        recoveryIO.saveWorldMap(from: arSession, to: recoveryIO.mapURL(id), onlyFor: id) { _ in
            Task { @MainActor in
                self.mapSaving = false
                self.endMapBackgroundTask()
                if self.mapWanted, let id = self.recoveryId, self.unbuiltScanInProgress { self.saveRecoveryMap(id) }
            }
        }
    }

    private func endMapBackgroundTask() {
        guard mapBackgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(mapBackgroundTask)
        mapBackgroundTask = .invalid
    }

    // Build floor plan wrote the scan files: the bundle isn't needed.
    private func finishRecovery(moveMapTo: URL?) {
        guard let id = recoveryId else { return }
        recoveryId = nil
        roomsSavedFor = nil
        mapWanted = false
        recoveryIO.finish(id, moveMapTo: moveMapTo) {}
    }

    // A recovered scan built before it was located: it now stands as a saved
    // scan does when opened, and resumes on site the same way.
    private func becomeSavedScan() {
        recoveredNeedsResume = false
        let hadMap = recoveryMap != nil
        recoveryMap = nil
        savedRooms = rooms
        rooms = []
        loadedFromFile = true
        resumed = false
        canResume = hadMap || FileManager.default.fileExists(atPath: worldMapURL.path)
    }

    func refreshRecovery() {
        recoveryOffer = RecoveryFiles.pick(recoveryIO.list(), excluding: recoveryId).map { s in
            RecoveryOffer(state: s, photosBelongToSavedScan: belongsToSavedScan(s.stamp),
                          hasWorldMap: FileManager.default.fileExists(atPath: recoveryIO.mapURL(s.scanId).path))
        }
    }

    private func belongsToSavedScan(_ stamp: String) -> Bool {
        !stamp.isEmpty && FileManager.default.fileExists(atPath: Self.docs.appendingPathComponent("scan-\(stamp).cvalrscan.json").path)
    }

    // Puts an unbuilt scan back as it was: rooms, marks, the outside walk,
    // photos and name; and a scan it continues, with its edits and readings.
    // New rooms and outside points wait for Resume on site, so they line up.
    func recover(_ offer: RecoveryOffer) async {
        let s = offer.state
        isBusy = true
        let restored = await recoveryIO.loadRooms(s.scanId)
        isBusy = false
        newScan()
        let rawURL = Self.docs.appendingPathComponent("scan-\(s.stamp).capturedstructure.json")
        if !s.stamp.isEmpty, FileManager.default.fileExists(atPath: rawURL.path) { load(stamp: s.stamp) }
        if let st = structure { previous = st }
        structure = nil
        exportURLs = []
        recoveryId = s.scanId
        recoveryIO.allow(s.scanId)
        rooms = restored ?? []
        savedRooms = rooms
        // Unreadable rooms stay on disk as they are until a new room replaces them.
        roomsChanged = false
        roomsSavedFor = s.scanId
        stamp = s.stamp
        resumed = s.resumed
        scanName = s.name
        photoFolder = s.photoFolder
        photos = s.photos.map(\.scanPhoto)
        photoZip = nil
        wallPoints = s.wallPoints.map(\.wallPoint)
        corners = s.corners
        exteriorWalls = s.exterior.map { $0.map(\.exteriorPoint) }
        anchorStart = s.anchorStart
        anchorEnd = s.anchorEnd
        // Picks whose room couldn't be read have nowhere to go.
        scannedPicks = (s.roomPicks ?? []).filter { p in rooms.contains { $0.identifier == p.room } }
        loadedFromFile = false
        recoveredNeedsResume = true
        let map = recoveryIO.mapURL(s.scanId)
        recoveryMap = FileManager.default.fileExists(atPath: map.path) ? map : nil
        canResume = recoveryMap != nil || (!s.stamp.isEmpty && FileManager.default.fileExists(atPath: worldMapURL.path))
        lastMapSave = Date()
        refreshChecks()
        recoveryOffer = nil
        refreshRecovery()
        var said = "Recovered \(RecoveryFiles.summary(s, when: "from \(RecoveryFiles.when(s.savedAt))"))."
        if restored == nil && s.roomCount > 0 { said += " Its rooms couldn't be read." }
        if !canResume { said += " Its AR session wasn't saved, so it can't be resumed on site; Build floor plan still works." }
        message = said
    }

    // Throws away an unbuilt scan's rooms; its photos are kept (Recovery.swift).
    func discardRecovery(_ offer: RecoveryOffer) {
        let s = offer.state
        discardBundle(s.scanId, photoFolder: offer.photosBelongToSavedScan || s.photos.isEmpty ? nil : s.photoFolder, savedAt: s.savedAt)
    }

    // New while this scan is unbuilt: keep it to recover later, or discard it.
    func leaveCurrentScan(discard: Bool) {
        if !discard {
            saveProgress()
        } else if let id = recoveryId {
            discardBundle(id, photoFolder: belongsToSavedScan(stamp) || photos.isEmpty ? nil : photoFolder, savedAt: Date())
            recoveryId = nil
        }
        newScan()
    }

    private func discardBundle(_ id: String, photoFolder: String?, savedAt: Date) {
        recoveryIO.discard(id, photoFolder: photoFolder, savedAt: savedAt) { kept in
            Task { @MainActor in
                self.refreshRecovery()
                if let kept { self.message = "Unfinished scan discarded. Its photos are in Files › On My iPhone › CValRScan › \(kept)." }
                else { self.message = "Unfinished scan discarded." }
            }
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
        photoZip = nil
        writeFiles()
        shareURLs = namedCopies(of: exportURLs)
    }

    // Copies of the scan files named like "123 Main St 2026-10-08_21-07.cvalrscan.json",
    // so a shared or saved file says which job it is. The originals keep
    // their timestamp names, which the app finds them by. Characters that
    // file systems refuse (/ \ : * ? " < > |) are left out.
    private func namedCopies(of urls: [URL]) -> [URL] {
        let name = scanName.components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|")).joined()
            .trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !stamp.isEmpty, !urls.isEmpty else {
            return urls + [zippedPhotos(named: stamp.isEmpty ? "scan" : "scan-\(stamp)")].compactMap { $0 }
        }
        let date = Self.stampFormatter.date(from: stamp).map(Self.fileDateFormatter.string(from:)) ?? stamp
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("share-\(stamp)")
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return urls.map { url in
            let suffix = url.lastPathComponent.replacingOccurrences(of: "scan-\(stamp)", with: "")
            let copy = dir.appendingPathComponent("\(name) \(date)\(suffix)")
            return (try? FileManager.default.copyItem(at: url, to: copy)) != nil ? copy : url
        } + [zippedPhotos(named: "\(name) \(date)")].compactMap { $0 }
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
        scannedPicks = []
        picksForRoom = nil
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
        photos = []
        addedWalls = []
        wallsShapeFloor = true
        stairEdits = [:]
        addedStairs = []
        outsideDoors = []
        ignoredAreas = []
        outsideEdges = []
        floorNames = [:]
        areaFills = []
        unscannedDoors = []
        unscannedAreas = []
        photoFolder = ""
        photoZip = nil
        message = nil
        // An unbuilt scan left behind keeps its bundle, and is offered again.
        recoveryId = nil
        roomsSavedFor = nil
        recoveredNeedsResume = false
        recoveryMap = nil
        mapWanted = false
        recoveryIO.afterPending { Task { @MainActor in self.refreshRecovery() } }
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
                r.point.count == 2 ? RoomLabel(story: r.story, point: SIMD2(r.point[0], r.point[1]), name: r.name, replaces: r.replaces,
                                               finishes: RoomFinishes(floor: r.finishes?.floor, walls: r.finishes?.walls,
                                                                      ceiling: r.finishes?.ceiling, condition: r.condition)) : nil
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
            wallsShapeFloor = saved?.wallsShapeFloor ?? true
            addedStairs = (saved?.stairChains ?? []).compactMap(PlanExport.chainIn) + (saved?.addedStairs ?? []).compactMap { s in
                guard s.a.count == 2, s.b.count == 2 else { return nil }
                let a = SIMD2(s.a[0], s.a[1]), b = SIMD2(s.b[0], s.b[1]), len = simd_distance(a, b)
                guard len > 0.05 else { return nil }
                return StairChain(id: UUID(uuidString: s.id) ?? UUID(), story: s.story, start: a, dir: (b - a) / len, width: s.width,
                                  pieces: [.init(kind: .flight, length: len, steps: StairChain.defaultSteps(metres: len))])
            }
            stairEdits = Dictionary(uniqueKeysWithValues: (saved?.stairEdits ?? []).compactMap { e in
                UUID(uuidString: e.id).map { ($0, StairEdit(flip: e.flip, hidden: e.hidden, turn: e.turn ?? false, run: e.run)) }
            })
            addedWalls = (saved?.addedWalls ?? []).compactMap { w in
                guard w.a.count == 2, w.b.count == 2 else { return nil }
                return AddedWall(id: UUID(uuidString: w.id) ?? UUID(), story: w.story, a: SIMD2(w.a[0], w.a[1]), b: SIMD2(w.b[0], w.b[1]))
            }
            outsideDoors = Set((saved?.outsideDoors ?? []).compactMap(UUID.init(uuidString:)))
            ignoredAreas = (saved?.ignoredAreas ?? []).filter { $0.count == 2 }.map { SIMD2($0[0], $0[1]) }
            outsideEdges = (saved?.outsideEdges ?? []).filter { $0.count == 2 }.map { SIMD2($0[0], $0[1]) }
            floorNames = Dictionary((saved?.floorNames ?? []).map { ($0.story, $0.name) }, uniquingKeysWith: { a, _ in a })
            areaFills = (saved?.fillsFromAbove ?? []).filter { $0.centre.count == 2 }.map {
                AreaFill(story: $0.story, centre: SIMD2($0.centre[0], $0.centre[1]), cell: $0.cell,
                         cells: $0.cells.map { $0.filter { $0.count == 2 }.map { SIMD2($0[0], $0[1]) } }.filter { $0.count == 4 })
            }
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
            func xy(_ v: [Double]?) -> SIMD2<Double>? { v.flatMap { $0.count == 2 ? SIMD2($0[0], $0[1]) : nil } }
            exteriorWalls = (saved?.exterior?.walls ?? []).map { $0.map { p in
                ExteriorPoint(point: SIMD3(Float(p.point[0]), Float(p.elevation), Float(p.point[1])), kind: p.kind, method: p.method,
                              distance: p.distance, angle: p.angle, rms: p.rms, n: p.n, camera: xy(p.camera), dir: xy(p.dir),
                              span: p.span.map { $0.compactMap(xy) }.flatMap { $0.count == 2 ? $0 : nil },
                              dirs: p.dirs.map { $0.compactMap(xy) }.flatMap { $0.count == 2 ? $0 : nil })
            } }
            anchorStart = saved?.exterior?.anchorStart.map(world)
            anchorEnd = saved?.exterior?.anchorEnd.map(world)
            structure = loaded
            savedRooms = loaded.rooms
            self.stamp = stamp
            scanName = saved?.name ?? ""
            photoFolder = saved?.photoFolder ?? ""
            photos = (saved?.photos ?? []).compactMap(PlanExport.photoIn)
            photoZip = nil
            loadedFromFile = true
            resumed = false
            canResume = FileManager.default.fileExists(atPath: worldMapURL.path)
            write3DModel(replace: false)
            refreshChecks()
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
        struct FolderOnly: Decodable { let photoFolder: String? }
        let plan = Self.docs.appendingPathComponent("scan-\(stamp).cvalrscan.json")
        if let folder = (try? JSONDecoder().decode(FolderOnly.self, from: Data(contentsOf: plan)))?.photoFolder, !folder.isEmpty {
            try? FileManager.default.removeItem(at: Self.docs.appendingPathComponent(folder, isDirectory: true))
        }
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
        struct ExteriorPointIn: Decodable {
            let point: [Double]; let elevation: Double
            let method: String?; let distance: Double?; let angle: Double?; let rms: Double?; let n: Int?
            let camera: [Double]?; let dir: [Double]?; let span: [[Double]]?
            let kind: String?; let dirs: [[Double]]?
        }
        struct Exterior: Decodable { let walls: [[ExteriorPointIn]]; let anchorStart: Point?; let anchorEnd: Point? }
        struct WallPointIn: Decodable { let point: [Double]; let elevation: Double; let normal: [Double] }
        struct GapDepthIn: Decodable { let gap: [[Double]]; let from: String; let inches: Int }
        // finishes and condition from 0.28.0; absent in older scans.
        struct RoomLabelIn: Decodable { let story: Int; let point: [Double]; let name: String; let replaces: Int?
            let finishes: PlanExport.FinishesOut?; let condition: String? }
        struct OpeningIn: Decodable { let story: Int; let wall: String?; let a: [Double]; let b: [Double]
            let kind: String?; let door: Bool?; let hingeAtB: Bool?; let side: Int?; let style: String? }
        struct WallEditIn: Decodable { let wall: String; let hidden: Bool; let a: [Double]?; let b: [Double]? }
        struct SpanIn: Decodable {
            let a: [Double]; let b: [Double]; let story: Int; let inches: Int; let face: String; let entered: String?
        }
        let name: String?
        let photoFolder: String?
        let photos: [PlanExport.PhotoOut]?
        let addedWalls: [PlanExport.AddedWallOut]?
        let wallsShapeFloor: Bool?
        struct StairEditIn: Decodable { let id: String; let flip: Bool; let hidden: Bool; let turn: Bool?; let run: Double? }
        let stairEdits: [StairEditIn]?
        struct OldStairIn: Decodable { let id: String; let story: Int; let a: [Double]; let b: [Double]; let width: Double }
        let addedStairs: [OldStairIn]?                 // 0.15.0: single flights
        let stairChains: [PlanExport.StairChainOut]?
        let outsideDoors: [String]?
        let ignoredAreas: [[Double]]?
        let outsideEdges: [[Double]]?
        struct FloorNameIn: Decodable { let story: Int; let name: String }
        let floorNames: [FloorNameIn]?
        struct FillIn: Decodable { let story: Int; let centre: [Double]; let cell: Double; let cells: [[[Double]]] }
        let fillsFromAbove: [FillIn]?
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
