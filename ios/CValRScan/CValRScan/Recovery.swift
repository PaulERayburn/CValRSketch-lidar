import ARKit
import Foundation
import RoomPlan

// Crash-safe progress. Until Build floor plan the scan lives only in memory,
// so after every change ScanController hands a snapshot here and it goes to
// Documents/inprogress-<id>/ (RecoveryState.swift) on a background queue.
// Each file is written to a temporary file and then swapped in, so a crash
// mid-write leaves the previous good copy.

// An unbuilt scan found on disk, as the home screen offers it.
struct RecoveryOffer: Identifiable, Equatable {
    let state: RecoveryState
    // A resumed scan's photo folder is also the saved scan's, so discarding
    // the unbuilt rooms leaves the photos where they are.
    let photosBelongToSavedScan: Bool
    let hasWorldMap: Bool
    var id: String { state.scanId }
    var summary: String { RecoveryFiles.summary(state, when: RecoveryFiles.when(state.savedAt)) }
}

// All recovery file work, on one serial queue so writes, the world map and
// deleting a finished bundle happen in the order asked for. Only ids that
// are `allow`ed may be written: a world map that arrives after Build floor
// plan has deleted the bundle is dropped rather than bringing it back.
final class RecoveryIO: @unchecked Sendable {
    let root: URL
    private let queue = DispatchQueue(label: "CValRScan.recovery", qos: .utility)
    private let lock = NSLock()
    private var allowed: Set<String> = []
    private var pending: [String: (state: RecoveryState, rooms: [CapturedRoom]?)] = [:]
    private var scheduled: Set<String> = []

    init(root: URL) { self.root = root }

    func folder(_ id: String) -> URL { root.appendingPathComponent(RecoveryFiles.folderName(id), isDirectory: true) }
    func mapURL(_ id: String) -> URL { folder(id).appendingPathComponent(RecoveryFiles.mapFile) }

    func allow(_ id: String) { lock.withLock { _ = allowed.insert(id) } }

    private func isAllowed(_ id: String) -> Bool { lock.withLock { allowed.contains(id) } }

    // Latest wins: saves that come faster than the disk are folded into one.
    // Rooms are passed only when they changed, and kept until written.
    func save(_ state: RecoveryState, rooms: [CapturedRoom]?) {
        let id = state.scanId
        let schedule: Bool = lock.withLock {
            pending[id] = (state, rooms ?? pending[id]?.rooms)
            return scheduled.insert(id).inserted
        }
        if schedule { queue.async { self.flush(id) } }
    }

    private func flush(_ id: String) {
        let job: (state: RecoveryState, rooms: [CapturedRoom]?)? = lock.withLock {
            scheduled.remove(id)
            return pending.removeValue(forKey: id)
        }
        guard let job, isAllowed(id) else { return }
        let dir = folder(id)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // Rooms before the state, so the state never counts rooms that aren't on disk.
            if let rooms = job.rooms {
                try JSONEncoder().encode(rooms).write(to: dir.appendingPathComponent(RecoveryFiles.roomsFile), options: .atomic)
            }
            try RecoveryState.encoder().encode(job.state).write(to: dir.appendingPathComponent(RecoveryFiles.stateFile), options: .atomic)
        } catch {
            // Disk full or the like: what wasn't written goes out with the next save.
            lock.withLock {
                if let newer = pending[id] { pending[id] = (newer.state, newer.rooms ?? job.rooms) } else { pending[id] = job }
            }
        }
    }

    // Asks ARKit for the session's world map and writes it to `url`, archive
    // and write both on the queue (the map is ~100 MB). `onlyFor` skips the
    // write once that recovery bundle is finished or discarded. `done` runs
    // off the main thread.
    func saveWorldMap(from session: ARSession, to url: URL, onlyFor id: String?, done: @escaping @Sendable (Bool) -> Void) {
        session.getCurrentWorldMap { @Sendable [self] map, _ in
            guard let map else { done(false); return }
            let box = MapBox(map: map)
            self.queue.async {
                if let id, !self.isAllowed(id) { done(false); return }
                do {
                    let data = try NSKeyedArchiver.archivedData(withRootObject: box.map, requiringSecureCoding: true)
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: url, options: .atomic)
                    done(true)
                } catch {
                    done(false)
                }
            }
        }
    }

    // ARWorldMap isn't marked Sendable; it is handed over once and only read after.
    private struct MapBox: @unchecked Sendable { let map: ARWorldMap }

    // The unbuilt scans on disk (their small state files only).
    func list() -> [RecoveryState] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.compactMap { name -> RecoveryState? in
            guard let id = RecoveryFiles.scanId(fromFolder: name),
                  let data = try? Data(contentsOf: folder(id).appendingPathComponent(RecoveryFiles.stateFile)),
                  let s = try? RecoveryState.decoder().decode(RecoveryState.self, from: data),
                  s.scanId == id else { return nil }
            return s
        }
    }

    // The rooms, read after any write still queued. nil when the file is missing or unreadable.
    func loadRooms(_ id: String) async -> [CapturedRoom]? {
        await withCheckedContinuation { (c: CheckedContinuation<[CapturedRoom]?, Never>) in
            queue.async {
                let url = self.folder(id).appendingPathComponent(RecoveryFiles.roomsFile)
                let rooms = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([CapturedRoom].self, from: $0) }
                c.resume(returning: rooms)
            }
        }
    }

    // Build floor plan saved the scan: the bundle goes, its world map first
    // moved to `mapTo` when the scan files need it.
    func finish(_ id: String, moveMapTo mapTo: URL?, done: @escaping @Sendable () -> Void) {
        lock.withLock { _ = allowed.remove(id); pending[id] = nil }
        queue.async {
            let fm = FileManager.default
            if let mapTo, fm.fileExists(atPath: self.mapURL(id).path) {
                try? fm.removeItem(at: mapTo)
                try? fm.moveItem(at: self.mapURL(id), to: mapTo)
            }
            try? fm.removeItem(at: self.folder(id))
            done()
        }
    }

    // The user threw an unbuilt scan away. Its photo folder, if given, is
    // renamed "Recovered photos …" rather than deleted. Hands back that name.
    func discard(_ id: String, photoFolder: String?, savedAt: Date, done: @escaping @Sendable (String?) -> Void) {
        lock.withLock { _ = allowed.remove(id); pending[id] = nil }
        queue.async {
            let fm = FileManager.default
            var kept: String?
            if let photoFolder, !photoFolder.isEmpty {
                let src = self.root.appendingPathComponent(photoFolder, isDirectory: true)
                if fm.fileExists(atPath: src.path) {
                    let existing = Set((try? fm.contentsOfDirectory(atPath: self.root.path)) ?? [])
                    let name = RecoveryFiles.recoveredPhotosName(savedAt, existing: existing)
                    if (try? fm.moveItem(at: src, to: self.root.appendingPathComponent(name, isDirectory: true))) != nil { kept = name }
                }
            }
            try? fm.removeItem(at: self.folder(id))
            done(kept)
        }
    }

    // Runs `then` once everything queued so far is on disk.
    func afterPending(_ then: @escaping @Sendable () -> Void) { queue.async(execute: then) }
}

// The scan's in-memory values to and from their saved form.
extension RecoveryState.Photo {
    init(_ p: ScanPhoto) {
        self.init(id: p.id, point: p.point, facing: p.facing, takenAt: p.takenAt, outside: p.outside, fullRes: p.fullRes,
                  wide: p.wide ? true : nil)
    }
    var scanPhoto: ScanPhoto {
        ScanPhoto(id: id, point: point, facing: facing, takenAt: takenAt, outside: outside, fullRes: fullRes, wide: wide ?? false)
    }
}

extension RecoveryState.WallPt {
    init(_ w: WallPoint) { self.init(point: w.point, normal: w.normal) }
    var wallPoint: WallPoint { WallPoint(point: point, normal: normal) }
}

extension RecoveryState.Exterior {
    init(_ p: ExteriorPoint) {
        self.init(point: p.point, kind: p.kind, method: p.method, distance: p.distance, angle: p.angle, rms: p.rms, n: p.n,
                  camera: p.camera, dir: p.dir, span: p.span, dirs: p.dirs)
    }
    var exteriorPoint: ExteriorPoint {
        ExteriorPoint(point: point, kind: kind, method: method, distance: distance, angle: angle, rms: rms, n: n,
                      camera: camera, dir: dir, span: span, dirs: dirs)
    }
}
