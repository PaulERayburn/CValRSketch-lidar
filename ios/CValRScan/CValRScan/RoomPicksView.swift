import SwiftUI

// The picks for the room being scanned. Held by ScanningView without
// observing it, so a tap re-renders only the panel, never RoomPlan's view.
@MainActor
final class RoomPicksBox: ObservableObject {
    @Published var picks = RoomPicks()
}

// While RoomPlan scans a room: a bar at the bottom with what's picked so
// far; open, one row of chips per field (lists in RoomPicks.swift). One tap
// picks, a second clears. The picks go with the room at Done with room.
struct RoomPicksPanel: View {
    @ObservedObject var box: RoomPicksBox
    @Binding var open: Bool
    // Names so far, for numbering bedrooms; asked only when Bedroom is tapped.
    let existing: @MainActor () -> [String]
    @State private var typing = false
    @State private var typed = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { open.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "tag")
                    Text(box.picks.isEmpty ? "Name this room, pick finishes" : box.picks.summary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    Image(systemName: open ? "chevron.down" : "chevron.up")
                }
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity, minHeight: 40)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(open ? "Hides the picks" : "Shows room name, finish and condition picks")
            if open {
                ChipRow(title: "Room", options: RoomChoices.names + [RoomChoices.other],
                        selected: RoomChoices.chip(for: box.picks.name),
                        label: { chip in
                            chip == RoomChoices.chip(for: box.picks.name) ? (box.picks.name ?? chip) : chip
                        }) { chip in
                    if RoomChoices.chip(for: box.picks.name) == chip {
                        box.picks.name = nil
                    } else if chip == RoomChoices.other {
                        typed = ""
                        typing = true
                    } else {
                        box.picks.name = RoomChoices.number(chip, existing: existing())
                    }
                }
                FinishChipRows(finishes: $box.picks.finishes)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal)
        .alert("Room name", isPresented: $typing) {
            TextField("e.g. Sunroom", text: $typed)
                .textInputAutocapitalization(.words)
            Button("Cancel", role: .cancel) {}
            Button("OK") {
                let n = RoomNames.canonical(typed)
                guard !n.isEmpty else { return }
                RoomNames.addOwn(n)
                box.picks.name = n
            }
        }
    }
}

// Floor, walls, ceiling and condition: one row of chips each. Used while
// scanning and in the plan's room sheet.
struct FinishChipRows: View {
    @Binding var finishes: RoomFinishes

    var body: some View {
        ChipRow(title: "Floor", options: RoomChoices.floor, selected: finishes.floor) { finishes.floor = finishes.floor == $0 ? nil : $0 }
        ChipRow(title: "Walls", options: RoomChoices.walls, selected: finishes.walls) { finishes.walls = finishes.walls == $0 ? nil : $0 }
        ChipRow(title: "Ceiling", options: RoomChoices.ceiling, selected: finishes.ceiling) { finishes.ceiling = finishes.ceiling == $0 ? nil : $0 }
        ChipRow(title: "Condition", options: RoomChoices.condition, selected: finishes.condition) {
            finishes.condition = finishes.condition == $0 ? nil : $0
        }
    }
}

// A field's name and its choices, scrolling sideways; the picked one filled in.
struct ChipRow: View {
    let title: String
    let options: [String]
    let selected: String?
    var label: (String) -> String = { $0 }
    let tap: (String) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(options, id: \.self) { o in
                        let on = o == selected
                        Button { tap(o) } label: {
                            Text(label(o))
                                .font(.subheadline.weight(on ? .semibold : .regular))
                                .padding(.horizontal, 12)
                                .frame(minHeight: 40)
                                .foregroundStyle(on ? Color.white : Color.primary)
                                .background(on ? Color.accentColor : Color(.secondarySystemFill), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(title): \(label(o))")
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
            }
        }
    }
}
