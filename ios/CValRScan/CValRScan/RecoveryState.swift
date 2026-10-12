import Foundation
import simd

// What an unbuilt scan needs to carry on after the app is killed: everything
// in memory before Build floor plan writes the scan files, except the rooms
// (CapturedRoom JSON, in their own file, written only when they change) and
// the AR world map (its own file, ~100 MB). Plain values only, so this file
// builds on a Mac too, for testing.
struct RecoveryState: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version = RecoveryState.currentVersion
    var scanId: String
    var savedAt: Date
    var appVersion: String
    // The saved scan this continues (a resumed scan, or a scan built before
    // more rooms were added); "" when Build floor plan never ran.
    var stamp: String
    var resumed: Bool
    var name: String
    var roomCount: Int
    var photoFolder: String
    var photos: [Photo]
    var wallPoints: [WallPt]
    var corners: [SIMD3<Float>]
    var exterior: [[Exterior]]
    var anchorStart: SIMD3<Float>?
    var anchorEnd: SIMD3<Float>?

    struct Photo: Codable, Equatable, Sendable {
        var id: String
        var point: SIMD3<Float>
        var facing: SIMD2<Float>
        var takenAt: Date
        var outside: Bool
        var fullRes: Bool
    }

    struct WallPt: Codable, Equatable, Sendable {
        var point: SIMD3<Float>
        var normal: SIMD3<Float>
    }

    struct Exterior: Codable, Equatable, Sendable {
        var point: SIMD3<Float>
        var kind: String?
        var method: String?
        var distance: Double?
        var angle: Double?
        var rms: Double?
        var n: Int?
        var camera: SIMD2<Double>?
        var dir: SIMD2<Double>?
        var span: [SIMD2<Double>]?
        var dirs: [SIMD2<Double>]?
    }

    var outsideWallCount: Int { exterior.filter { !$0.isEmpty }.count }

    // Worth offering: something was scanned, marked or photographed.
    var hasWork: Bool {
        roomCount > 0 || !photos.isEmpty || !wallPoints.isEmpty || outsideWallCount > 0 || anchorStart != nil
    }

    // A stray NaN from a fit must not stop the whole state being saved.
    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return e
    }

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return d
    }
}

// Where an unbuilt scan's recovery bundle lives: Documents/inprogress-<id>/,
// which the saved-scans list (scan-*.capturedstructure.json) never matches.
enum RecoveryFiles {
    static let prefix = "inprogress-"
    static let stateFile = "state.json"
    static let roomsFile = "rooms.json"
    static let mapFile = "session.worldmap"

    static func newId() -> String { String(UUID().uuidString.prefix(8)).lowercased() }

    static func folderName(_ id: String) -> String { prefix + id }

    static func scanId(fromFolder name: String) -> String? {
        guard name.hasPrefix(prefix) else { return nil }
        let id = String(name.dropFirst(prefix.count))
        let ok = !id.isEmpty && id.count <= 64
            && id.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" }
        return ok ? id : nil
    }

    // The one to offer on the home screen: the newest with something in it,
    // other than the scan already open.
    static func pick(_ found: [RecoveryState], excluding current: String?) -> RecoveryState? {
        found.filter { $0.scanId != current && $0.hasWork }.max { $0.savedAt < $1.savedAt }
    }

    // "6 rooms, 8 photos, 11:15 AM"
    static func summary(_ s: RecoveryState, when: String) -> String {
        var parts = [count(s.roomCount, "room")]
        if !s.photos.isEmpty { parts.append(count(s.photos.count, "photo")) }
        if s.outsideWallCount > 0 { parts.append(count(s.outsideWallCount, "outside wall")) }
        if !s.wallPoints.isEmpty { parts.append(count(s.wallPoints.count, "hidden-wall point")) }
        parts.append(when)
        return parts.joined(separator: ", ")
    }

    // The time alone today, else the date too.
    static func when(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        calendar.isDate(date, inSameDayAs: now)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(date: .abbreviated, time: .shortened)
    }

    // A discarded scan's photos are kept under a name that says what they
    // are, never deleted: "Recovered photos 2026-10-12 11-15", then " 2", " 3"…
    static func recoveredPhotosName(_ date: Date, existing: Set<String>, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd HH-mm"
        let base = "Recovered photos \(f.string(from: date))"
        if !existing.contains(base) { return base }
        var k = 2
        while existing.contains("\(base) \(k)") { k += 1 }
        return "\(base) \(k)"
    }

    private static func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }
}
