import Foundation
import simd

// The quick picks for a room: its name, finishes and condition, tapped
// while RoomPlan scans it (ContentView's RoomPicksPanel) or later in the
// plan's room sheet. Edit the lists here. Room names are names from
// RoomNames.catalogue (PlanView.swift), so both places name rooms alike.
// Plain values only, so this file builds on a Mac too, for testing.
enum RoomChoices {
    static let names = ["Living", "Kitchen", "Dining", "Family", "Bedroom", "Primary bedroom", "Bath", "Ensuite",
                        "2-pc bath", "Laundry", "Entry", "Hall", "Office", "Closet", "Mudroom", "Rec room",
                        "Utility", "Garage"]
    static let other = "Other"
    static let floor = ["Hardwood", "Laminate", "Vinyl plank", "Carpet", "Tile", "Concrete", "Linoleum"]
    static let walls = ["Drywall", "Plaster", "Panelling", "Wood", "Brick", "Unfinished"]
    static let ceiling = ["Drywall", "Stipple/popcorn", "T-bar", "Wood", "Open joists", "Vaulted"]
    static let condition = ["Updated", "Average", "Dated", "Needs work"]

    // Bedrooms are numbered: "Bedroom 3" when two bedrooms exist already
    // (or the highest number in use plus one, if that's more).
    static let numbered: Set<String> = ["Bedroom"]

    static func number(_ base: String, existing: [String]) -> String {
        guard numbered.contains(base) else { return base }
        var count = 0, highest = 0
        for n in existing {
            if n == base { count += 1; continue }
            guard n.hasPrefix(base + " "), let k = Int(n.dropFirst(base.count + 1)) else { continue }
            count += 1
            highest = max(highest, k)
        }
        return "\(base) \(max(count, highest) + 1)"
    }

    // The chip a name belongs to: "Bedroom" for "Bedroom 2", Other for a typed name.
    static func chip(for name: String?) -> String? {
        guard let name, !name.isEmpty else { return nil }
        if names.contains(name) { return name }
        for base in numbered where name.hasPrefix(base + " ") && Int(name.dropFirst(base.count + 1)) != nil { return base }
        return other
    }
}

struct RoomFinishes: Codable, Equatable, Sendable {
    var floor: String?
    var walls: String?
    var ceiling: String?
    var condition: String?

    var isEmpty: Bool { floor == nil && walls == nil && ceiling == nil && condition == nil }
    // "Tile · Drywall · Drywall · Updated"
    var summary: String { [floor, walls, ceiling, condition].compactMap { $0 }.joined(separator: " · ") }
}

struct RoomPicks: Codable, Equatable, Sendable {
    var name: String?
    var finishes = RoomFinishes()

    var isEmpty: Bool { (name ?? "").isEmpty && finishes.isEmpty }
    // "Kitchen · Tile · Drywall · Drywall · Updated"
    var summary: String { ([name].compactMap { $0 } + [finishes.summary]).filter { !$0.isEmpty }.joined(separator: " · ") }
}

// Picks made while one room was scanned, kept with that room until Build
// floor plan turns them into a room name on the plan (ScanController).
// `room` is the CapturedRoom's identifier; `center` its floor's middle
// (world x, z) and `elevation` the floor's world height.
struct ScannedRoomPicks: Codable, Equatable, Sendable {
    var room: UUID
    var picks: RoomPicks
    var center: SIMD2<Double>
    var elevation: Double
}
