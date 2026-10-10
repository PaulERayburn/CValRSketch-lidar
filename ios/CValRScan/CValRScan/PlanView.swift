import simd
import SwiftUI
import UIKit

// What the reading sheet is proposing, drawn live on the plan above it.
struct ReadingPreview: Equatable {
    var run: [UUID] = []
    var moving: [UUID] = []
}

struct PlanView: View {
    @ObservedObject var scan: ScanController
    @State private var story: Int?
    @State private var selected: PlanWall?
    @State private var selectedGap: PlanGap?
    // Corner to corner: on while picking, the first corner once tapped, and
    // the pair waiting for its reading.
    @State private var cornerMode = false
    @State private var spanStart: CGPoint?
    @State private var spanDraft: SpanDraft?
    // Cleaning up the scan: on while editing, the wall end being dragged (plan
    // feet, from → to), where a pan started, and what a tap asked to delete.
    @State private var editMode = false
    @State private var endDrag: (from: CGPoint, to: CGPoint)?
    @State private var dragMoves: [(from: CGPoint, to: CGPoint)] = []
    @State private var dragEnded = Date.distantPast
    @State private var shownPhoto: ScanPhoto?   // a tap right after a drag is the drag's end
    @State private var panBase: CGSize?
    @State private var deleting: EditTarget?
    @State private var tool = EditTool.walls
    @State private var selectedWalls: Set<UUID> = []
    @State private var roomDraft: RoomDraft?
    @State private var doorDraft: DoorDraft?
    @State private var preview = ReadingPreview()
    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @GestureState private var pinch: CGFloat = 1
    // Zoom and pan when a pinch began, so it zooms about the fingers.
    @State private var pinchStart: (zoom: CGFloat, pan: CGSize)?
    @GestureState private var drag: CGSize = .zero

    var body: some View {
        let geo = scan.planGeometry
        let shown = story ?? geo.stories.first ?? 0
        VStack(spacing: 6) {
            if geo.stories.count > 1 {
                Picker("Floor", selection: Binding(get: { shown }, set: { story = $0 })) {
                    ForEach(geo.stories, id: \.self) { Text("Floor \($0 + 1)").tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
            }
            if editMode {
                Picker("Tool", selection: $tool) {
                    ForEach(EditTool.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                Text(tool.hint)
                    .font(.footnote.bold())
                    .foregroundStyle(.teal)
                    .padding(.horizontal)
            } else if cornerMode {
                Text(spanStart == nil ? "Tap the corner where your reading starts." : "Now tap the corner where it ends.")
                    .font(.footnote.bold())
                    .foregroundStyle(.blue)
            } else if !scan.hasReadings {
                Text("Start with the longest outside wall, in purple: tap it and enter its laser reading. Or tap Corners to measure between any two corners.")
                    .font(.footnote)
                    .foregroundStyle(.purple)
            } else {
                Text("Pinch to zoom, drag to move, Fit to re-centre. Tap a wall to enter a reading.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            GeometryReader { box in
                let view = Viewport(geo: geo, story: shown, size: box.size, zoom: zoom * pinch,
                                    pan: CGSize(width: pan.width + drag.width, height: pan.height + drag.height))
                canvas(geo: geo, story: shown, view: view)
                    .contentShape(Rectangle())
                    .gesture(editMode && tool == .walls ? AnyGesture(editDrag(geo: geo, story: shown, view: view, size: box.size).map { _ in () })
                                      : AnyGesture(panDrag(geo: geo, story: shown, size: box.size).map { _ in () }))
                    .simultaneousGesture(anchoredZoom(geo: geo, story: shown, size: box.size))
                    .simultaneousGesture(SpatialTapGesture().onEnded { tap in
                        if editMode && tool == .rooms {
                            let near = geo.rooms.filter { $0.story == shown }
                                .min { hypot(view.map($0.center).x - tap.location.x, view.map($0.center).y - tap.location.y)
                                     < hypot(view.map($1.center).x - tap.location.x, view.map($1.center).y - tap.location.y) }
                            if let r = near, hypot(view.map(r.center).x - tap.location.x, view.map(r.center).y - tap.location.y) < 34 {
                                roomDraft = RoomDraft(source: r.source, point: geo.world(r.center), story: shown, name: r.name)
                            } else {
                                roomDraft = RoomDraft(source: .new, point: geo.world(view.unmap(tap.location)), story: shown, name: nil)
                            }
                            return
                        }
                        if editMode && tool == .doors {
                            let walls = geo.walls.filter { $0.story == shown }
                            func wallUnder(_ a: CGPoint, _ b: CGPoint, _ id: UUID?) -> PlanWall? {
                                id.flatMap { geo.wall($0) }
                                    ?? view.nearest(to: view.map(CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)), in: walls)
                            }
                            func inches(_ a: CGPoint, _ b: CGPoint) -> Int { Int((hypot(b.x - a.x, b.y - a.y) * 12).rounded()) }
                            // A door's swing as drawn (a→b) restated along its wall's a→b, which
                            // is how the saved opening runs.
                            func swing(_ a: CGPoint, _ b: CGPoint, on w: PlanWall, hingeAtB: Bool, side: Int) -> (Bool, Int) {
                                let same = (b.x - a.x) * w.direction.dx + (b.y - a.y) * w.direction.dy >= 0
                                return same ? (hingeAtB, side) : (!hingeAtB, -side)
                            }
                            if let o = geo.addedOpenings.filter({ $0.story == shown })
                                .first(where: { view.distance(tap.location, $0.a, $0.b) < 20 }),
                               let w = wallUnder(o.a, o.b, scan.addedOpenings[o.index].wall) {
                                let src = scan.addedOpenings[o.index]
                                let (h, s) = swing(o.a, o.b, on: w, hingeAtB: src.hingeAtB, side: src.side)
                                doorDraft = DoorDraft(wall: w, at: CGPoint(x: (o.a.x + o.b.x) / 2, y: (o.a.y + o.b.y) / 2),
                                                      ref: .added(o.index), kind: src.kind, inches: inches(o.a, o.b),
                                                      hingeAtB: h, side: s, style: src.style)
                                return
                            }
                            if let f = geo.features.filter({ $0.story == shown && $0.id != nil && $0.kind != .window })
                                .first(where: { view.distance(tap.location, $0.a, $0.b) < 20 }),
                               let id = f.id, let w = wallUnder(f.a, f.b, f.wall) {
                                let (h, s) = swing(f.a, f.b, on: w, hingeAtB: f.hingeAtB, side: f.side)
                                doorDraft = DoorDraft(wall: w, at: CGPoint(x: (f.a.x + f.b.x) / 2, y: (f.a.y + f.b.y) / 2),
                                                      ref: .scanned(id), kind: f.kind == .opening ? .opening : .interior,
                                                      inches: inches(f.a, f.b), hingeAtB: h, side: s)
                                return
                            }
                            if let w = view.nearest(to: tap.location, in: walls) {
                                // A new door opens into the floor by default.
                                let at = view.unmap(tap.location), n = w.normal
                                let into = geo.floors.filter { $0.story == shown }
                                    .contains { ScanController.inside(CGPoint(x: at.x + n.dx, y: at.y + n.dy), $0.points) }
                                doorDraft = DoorDraft(wall: w, at: at, ref: .new, kind: .interior, inches: 32, side: into ? 1 : -1)
                            }
                            return
                        }
                        if editMode {
                            if endDrag != nil || Date().timeIntervalSince(dragEnded) < 0.5 { return }
                            let walls = geo.walls.filter { $0.story == shown }
                            let wall = view.nearest(to: tap.location, in: walls)
                            let hidden = geo.hiddenLines.filter { $0.story == shown }
                                .min { view.distance(tap.location, $0.a, $0.b) < view.distance(tap.location, $1.a, $1.b) }
                            if let h = hidden, view.distance(tap.location, h.a, h.b) < 24,
                               wall.map({ view.distance(tap.location, $0.a, $0.b) > view.distance(tap.location, h.a, h.b) }) ?? true {
                                deleting = .hidden(h)
                            } else if let wall {
                                if selectedWalls.contains(wall.id) { selectedWalls.remove(wall.id) } else { selectedWalls.insert(wall.id) }
                                UISelectionFeedbackGenerator().selectionChanged()
                            }
                            return
                        }
                        if cornerMode {
                            let corners = geo.corners(story: shown)
                            guard let c = corners.min(by: { hypot(view.map($0).x - tap.location.x, view.map($0).y - tap.location.y)
                                    < hypot(view.map($1).x - tap.location.x, view.map($1).y - tap.location.y) }),
                                  hypot(view.map(c).x - tap.location.x, view.map(c).y - tap.location.y) < 30 else { return }
                            UISelectionFeedbackGenerator().selectionChanged()
                            if let start = spanStart {
                                guard hypot(c.x - start.x, c.y - start.y) > 0.3 else { return }
                                let existing = geo.spans.first {
                                    (hypot($0.a.x - start.x, $0.a.y - start.y) < 0.5 && hypot($0.b.x - c.x, $0.b.y - c.y) < 0.5)
                                        || (hypot($0.a.x - c.x, $0.a.y - c.y) < 0.5 && hypot($0.b.x - start.x, $0.b.y - start.y) < 0.5)
                                }?.reading
                                spanDraft = SpanDraft(a: start, b: c, story: shown, existing: existing)
                                spanStart = nil
                                cornerMode = false
                            } else {
                                spanStart = c
                            }
                            return
                        }
                        // A photo pin wins when the tap is right on it.
                        if let pin = geo.photos.filter({ $0.story == shown })
                            .min(by: { hypot(view.map($0.at).x - tap.location.x, view.map($0.at).y - tap.location.y)
                                     < hypot(view.map($1.at).x - tap.location.x, view.map($1.at).y - tap.location.y) }),
                           hypot(view.map(pin.at).x - tap.location.x, view.map(pin.at).y - tap.location.y) < 18,
                           let photo = scan.photos.first(where: { $0.id == pin.id }) {
                            shownPhoto = photo
                            return
                        }
                        let wall = view.nearest(to: tap.location, in: geo.walls.filter { $0.story == shown })
                        // A gap wins when it's nearer than any wall.
                        let gaps = geo.gaps.filter { $0.story == shown }
                        if let gap = gaps.min(by: { view.distance(tap.location, $0.a, $0.b) < view.distance(tap.location, $1.a, $1.b) }),
                           view.distance(tap.location, gap.a, gap.b) < 24,
                           wall.map({ view.distance(tap.location, $0.a, $0.b) > view.distance(tap.location, gap.a, gap.b) }) ?? true {
                            focus(on: gap.middle, geo: geo, story: shown, size: box.size)
                            selectedGap = gap
                            return
                        }
                        guard let wall else { return }
                        focus(on: wall, geo: geo, story: shown, size: box.size)
                        selected = wall
                    })
                    .sheet(item: $spanDraft) { draft in
                        SpanSheet(draft: draft, geo: geo) { reading in
                            scan.setSpan(reading.map {
                                var r = $0
                                r.a = geo.world(draft.a); r.b = geo.world(draft.b)
                                return r
                            }, a: geo.world(draft.a), b: geo.world(draft.b))
                        }
                        .presentationDetents([.fraction(0.55), .large])
                        .presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.55)))
                    }
                    .sheet(item: $selectedGap) { gap in
                        GapSheet(gap: gap, geo: geo) { scan.setGapDepth($0, for: gap) }
                            .presentationDetents([.fraction(0.55), .large])
                            .presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.55)))
                    }
            }
            .clipped()
            legend
        }
        .navigationTitle("Measure walls")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if !editMode {
                    Button(cornerMode ? "Cancel" : "Corners") {
                        cornerMode.toggle()
                        spanStart = nil
                    }
                }
                if !cornerMode {
                    Button(editMode ? "Done" : "Edit") {
                        editMode.toggle(); tool = .walls; selectedWalls = []
                        selected = nil; selectedGap = nil   // a reading sheet would hide Undo
                    }
                }
                Button("Fit") { withAnimation { zoom = 1; pan = .zero } }
            }
            if editMode {
                ToolbarItemGroup(placement: .bottomBar) {
                    Button("Undo", systemImage: "arrow.uturn.backward") { scan.undoEdit() }
                        .disabled(!scan.canUndoEdit)
                    Spacer()
                    if !selectedWalls.isEmpty && tool == .walls {
                        Button("Align \(selectedWalls.count)") {
                            align(selectedWalls, geo: geo)
                            selectedWalls = []
                        }
                        Spacer()
                        Button("Delete \(selectedWalls.count)", role: .destructive) {
                            scan.deleteWalls(selectedWalls)
                            selectedWalls = []
                        }
                        Spacer()
                        Button("Clear") { selectedWalls = [] }
                    } else {
                        Button("Restore scan") { scan.restoreScan() }
                            .disabled(!scan.hasEdits)
                    }
                }
            }
        }
        .sheet(item: $shownPhoto) { p in
            PhotoSheet(photo: p, url: scan.photoURL(p)) { scan.deletePhoto(p) }
                .presentationDetents([.large])
        }
        .sheet(item: $roomDraft) { d in
            RoomSheet(draft: d) { name in scan.setRoomName(name, source: d.source, at: d.point, story: d.story) }
                .presentationDetents([.medium, .large])
        }
        .sheet(item: $doorDraft) { d in
            DoorSheet(draft: d) { choice in
                guard let c = choice else { scan.setOpening(nil, replacing: d.ref); return }
                var o = opening(on: d.wall, at: d.at, inches: c.inches, kind: c.kind, geo: geo)
                // The new opening runs along the wall a→b; swing sides are kept
                // relative to the door as it was drawn in the sheet.
                o.hingeAtB = c.hingeAtB
                o.side = c.side
                o.style = c.style
                scan.setOpening(o, replacing: d.ref)
            }
            .presentationDetents([.medium, .large])
        }
        .confirmationDialog(deleting?.title ?? "", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { target in
            Button("Delete", role: .destructive) {
                switch target {
                case .wall(let w): scan.deleteWall(w.id)
                case .hidden(let h):
                    if let i = h.wallPoint { scan.removeWallPoint(at: i) }
                    if let d = h.depth { scan.removeGapDepth(d) }
                }
            }
        } message: { target in
            Text(target.message)
        }
        .sheet(item: $selected, onDismiss: { preview = ReadingPreview() }) { wall in
            MeasureSheet(wall: wall, geo: geo, measured: measuredIDs(excluding: wall.id),
                         existing: scan.measurements[wall.id], preview: $preview) { m in
                scan.setMeasurement(m, for: wall.id)
            }
            .presentationDetents([.fraction(0.55), .large])
            .presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.55)))
        }
    }

    // Lines the selected walls up on one straight line: the length-weighted
    // average of their directions (squared to the house within 10°), through
    // their length-weighted middle. Every end moves square onto it; walls
    // joined at those ends follow.
    private func align(_ ids: Set<UUID>, geo: PlanGeometry) {
        let ws = geo.walls.filter { ids.contains($0.id) }
        guard !ws.isEmpty else { return }
        var sx = 0.0, sy = 0.0, cx = 0.0, cy = 0.0, total = 0.0
        for w in ws {
            let L = Double(w.length), t = 2 * atan2(Double(w.b.y - w.a.y), Double(w.b.x - w.a.x))
            sx += L * cos(t); sy += L * sin(t)
            cx += L * Double(w.a.x + w.b.x) / 2; cy += L * Double(w.a.y + w.b.y) / 2; total += L
        }
        guard total > 0 else { return }
        var ang = atan2(sy, sx) / 2
        for axis in [0.0, .pi / 2, .pi, -.pi / 2] where abs(remainder(ang - axis, 2 * .pi)) < 10 * .pi / 180 { ang = axis }
        let ux = cos(ang), uy = sin(ang), mx = cx / total, my = cy / total
        func onLine(_ p: CGPoint) -> CGPoint {
            let t = (Double(p.x) - mx) * ux + (Double(p.y) - my) * uy
            return CGPoint(x: mx + ux * t, y: my + uy * t)
        }
        var moves: [(from: SIMD2<Double>, to: SIMD2<Double>)] = []
        for w in ws {
            for e in [w.a, w.b] where !moves.contains(where: { simd_distance($0.from, geo.world(e)) < 0.01 }) {
                moves.append((geo.world(e), geo.world(onLine(e))))
            }
        }
        scan.moveWallEnds(moves)
    }

    // An added door or opening, centred where the wall was tapped and kept
    // inside the wall.
    private func opening(on w: PlanWall, at p: CGPoint, inches: Int, kind: OpeningKind, geo: PlanGeometry) -> AddedOpening {
        let L = w.length, half = min(CGFloat(inches) / 24, L / 2)
        let d = w.direction
        let t = min(max((p.x - w.a.x) * d.dx + (p.y - w.a.y) * d.dy, half), L - half)
        let a = CGPoint(x: w.a.x + d.dx * (t - half), y: w.a.y + d.dy * (t - half))
        let b = CGPoint(x: w.a.x + d.dx * (t + half), y: w.a.y + d.dy * (t + half))
        return AddedOpening(story: w.story, wall: w.id, a: geo.world(a), b: geo.world(b), kind: kind)
    }

    private func panDrag(geo: PlanGeometry, story: Int, size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .updating($drag) { v, s, _ in s = v.translation }
            .onEnded { v in
                pan = clamp(CGSize(width: pan.width + v.translation.width, height: pan.height + v.translation.height),
                            geo: geo, story: story, size: size, zoom: zoom)
            }
    }

    // Zooms about the point between the fingers, so what is under them stays
    // put, rather than about the middle of the screen.
    private func anchoredZoom(geo: PlanGeometry, story: Int, size: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { v in
                if pinchStart == nil { pinchStart = (zoom, pan) }
                guard let s = pinchStart else { return }
                let z = min(max(s.zoom * v.magnification, 1), 15), k = z / s.zoom
                let ax = v.startLocation.x - size.width / 2, ay = v.startLocation.y - size.height / 2
                zoom = z
                pan = clamp(CGSize(width: ax * (1 - k) + s.pan.width * k, height: ay * (1 - k) + s.pan.height * k),
                            geo: geo, story: story, size: size, zoom: z)
            }
            .onEnded { _ in pinchStart = nil }
    }

    // The middle of the screen stays within the plan's bounds plus a quarter of
    // the view, so every edge can be brought to the middle at any zoom while the
    // plan can never be panned out of sight.
    private func clamp(_ p: CGSize, geo: PlanGeometry, story: Int, size: CGSize, zoom: CGFloat) -> CGSize {
        let r = Viewport(geo: geo, story: story, size: size, zoom: zoom, pan: .zero).bounds
        let inner = r.insetBy(dx: -size.width * 0.25, dy: -size.height * 0.25)
        let cx = size.width / 2, cy = size.height / 2
        return CGSize(width: min(max(p.width, cx - inner.maxX), cx - inner.minX),
                      height: min(max(p.height, cy - inner.maxY), cy - inner.minY))
    }

    // Editing: a drag that starts on a wall end moves that end (and every wall
    // end joined to it), snapping to other corners and to square; any other
    // drag pans as usual.
    private func editDrag(geo: PlanGeometry, story: Int, view: Viewport, size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { v in
                if endDrag == nil && panBase == nil {
                    let ends = geo.walls.filter { $0.story == story }.flatMap { [$0.a, $0.b] }
                    if let e = ends.min(by: { hypot(view.map($0).x - v.startLocation.x, view.map($0).y - v.startLocation.y)
                            < hypot(view.map($1).x - v.startLocation.x, view.map($1).y - v.startLocation.y) }),
                       hypot(view.map(e).x - v.startLocation.x, view.map(e).y - v.startLocation.y) < 22 {
                        endDrag = (e, e)
                        UISelectionFeedbackGenerator().selectionChanged()
                    } else {
                        panBase = pan
                    }
                }
                if let d = endDrag {
                    let to = squareDrag(view.unmap(v.location), from: d.from, geo: geo, story: story, view: view)
                    endDrag = (d.from, to)
                    dragMoves = squareMoves(from: d.from, to: to, geo: geo, story: story)
                } else if let b = panBase {
                    pan = clamp(CGSize(width: b.width + v.translation.width, height: b.height + v.translation.height),
                                geo: geo, story: story, size: size, zoom: zoom)
                }
            }
            .onEnded { _ in
                if let d = endDrag, hypot(d.to.x - d.from.x, d.to.y - d.from.y) > 0.02 {
                    scan.moveWallEnds(dragMoves.map { (geo.world($0.from), geo.world($0.to)) })
                }
                if endDrag != nil { dragEnded = Date() }
                endDrag = nil
                dragMoves = []
                panBase = nil
            }
    }

    // A dragged end moves straight across or straight along the house, never
    // at a slant: whichever way the finger has gone further. It still snaps to
    // a corner or square with a far end on that line.
    private func squareDrag(_ p: CGPoint, from: CGPoint, geo: PlanGeometry, story: Int, view: Viewport) -> CGPoint {
        // Right on another corner, it goes there whatever the angle (to put a
        // stray end back where it belongs).
        if let c = geo.corners(story: story).filter({ hypot($0.x - from.x, $0.y - from.y) > 0.3 })
            .min(by: { hypot(view.map($0).x - view.map(p).x, view.map($0).y - view.map(p).y)
                     < hypot(view.map($1).x - view.map(p).x, view.map($1).y - view.map(p).y) }),
           hypot(view.map(c).x - view.map(p).x, view.map(c).y - view.map(p).y) < 14 { return c }
        let across = abs(p.x - from.x) >= abs(p.y - from.y)
        var q = snap(across ? CGPoint(x: p.x, y: from.y) : CGPoint(x: from.x, y: p.y), from: from, geo: geo, story: story, view: view)
        if across { q.y = from.y } else { q.x = from.x }
        return q
    }

    // The ends a drag moves. Walls joined at the dragged end that run the way
    // it moves get longer or shorter; walls that run across it slide over
    // whole, so every wall stays square. (Walls joined at a slid wall's far
    // end follow that end as usual.)
    private func squareMoves(from: CGPoint, to: CGPoint, geo: PlanGeometry, story: Int) -> [(from: CGPoint, to: CGPoint)] {
        let dx = to.x - from.x, dy = to.y - from.y, len = hypot(dx, dy)
        guard len > 0.001 else { return [] }
        var moves = [(from: from, to: to)]
        for w in geo.walls where w.story == story {
            let far: CGPoint? = hypot(w.a.x - from.x, w.a.y - from.y) < 0.1 ? w.b
                : hypot(w.b.x - from.x, w.b.y - from.y) < 0.1 ? w.a : nil
            guard let o = far, w.length > 0.01 else { continue }
            let along = abs(((o.x - from.x) * dx + (o.y - from.y) * dy) / (w.length * len))
            if along < 0.35, !moves.contains(where: { hypot($0.from.x - o.x, $0.from.y - o.y) < 0.1 }) {
                moves.append((o, CGPoint(x: o.x + dx, y: o.y + dy)))
            }
        }
        return moves
    }

    // A dragged end lands on a corner near it, or lines up square with the
    // far end of a wall it belongs to.
    private func snap(_ p: CGPoint, from: CGPoint, geo: PlanGeometry, story: Int, view: Viewport) -> CGPoint {
        let others = geo.corners(story: story).filter { hypot($0.x - from.x, $0.y - from.y) > 0.3 }
        if let c = others.min(by: { hypot(view.map($0).x - view.map(p).x, view.map($0).y - view.map(p).y)
                < hypot(view.map($1).x - view.map(p).x, view.map($1).y - view.map(p).y) }),
           hypot(view.map(c).x - view.map(p).x, view.map(c).y - view.map(p).y) < 14 { return c }
        // Lining up square catches within 10 points on screen, so zoomed in it
        // catches only a fraction of an inch.
        let catchFt = 10 / (view.scale * view.zoom)
        var q = p
        for w in geo.walls where w.story == story {
            let far: CGPoint? = hypot(w.a.x - from.x, w.a.y - from.y) < 0.3 ? w.b
                : hypot(w.b.x - from.x, w.b.y - from.y) < 0.3 ? w.a : nil
            guard let o = far else { continue }
            if abs(q.x - o.x) < catchFt { q.x = o.x }
            if abs(q.y - o.y) < catchFt { q.y = o.y }
        }
        return q
    }

    // Wraps onto a second line rather than squeezing words.
    private var legend: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 6, alignment: .leading)],
                  alignment: .leading, spacing: 4) {
            Label("outside wall", systemImage: "line.diagonal").foregroundStyle(.primary)
            Label("≈ interior", systemImage: "line.diagonal").foregroundStyle(.gray)
            Label("reading", systemImage: "checkmark").foregroundStyle(.green)
            if !scan.exteriorWalls.isEmpty {
                Label("outside walk", systemImage: "line.diagonal").foregroundStyle(.orange)
            }
            if !scan.planGeometry.openGaps.isEmpty {
                Label("missing", systemImage: "line.diagonal").foregroundStyle(.red)
            }
            if !scan.planGeometry.hiddenLines.isEmpty {
                Label("hidden", systemImage: "line.diagonal").foregroundStyle(.brown)
            }
        }
        .font(.caption2)
        .lineLimit(1)
        .padding(.horizontal)
        .padding(.bottom, 4)
    }

    private func measuredIDs(excluding id: UUID? = nil) -> Set<UUID> {
        var ids = Set<UUID>()
        for (key, m) in scan.measurements where key != id {
            ids.formUnion(m.walls.isEmpty ? [key] : m.walls)
        }
        return ids
    }

    // Zooms in on the tapped wall and moves it into the top of the screen,
    // above the reading sheet.
    private func focus(on wall: PlanWall, geo: PlanGeometry, story: Int, size: CGSize) {
        focus(on: CGPoint(x: (wall.a.x + wall.b.x) / 2, y: (wall.a.y + wall.b.y) / 2), geo: geo, story: story, size: size)
    }

    private func focus(on point: CGPoint, geo: PlanGeometry, story: Int, size: CGSize) {
        let newZoom = max(zoom, 2.5)
        let probe = Viewport(geo: geo, story: story, size: size, zoom: newZoom, pan: pan)
        let mid = probe.map(point)
        withAnimation {
            zoom = newZoom
            pan.width += size.width / 2 - mid.x
            pan.height += size.height * 0.22 - mid.y
        }
    }

    // How wide a room name can be, in screen points: twice the distance to
    // the nearer wall across from it, less a margin, never under 50.
    static func labelWidth(at c: CGPoint, walls: [(CGPoint, CGPoint)]) -> CGFloat {
        var left = CGFloat.infinity, right = CGFloat.infinity
        for (a, b) in walls where (a.y - c.y) * (b.y - c.y) <= 0 && abs(b.y - a.y) > 0.5 {
            let x = a.x + (b.x - a.x) * (c.y - a.y) / (b.y - a.y)
            if x < c.x { left = min(left, c.x - x) } else { right = min(right, x - c.x) }
        }
        let half = min(left, right, 120)
        return max(2 * half - 8, 50)
    }

    private func canvas(geo: PlanGeometry, story: Int, view: Viewport) -> some View {
        let walls = geo.walls.filter { $0.story == story }
        let measurements = scan.measurements
        let measured = measuredIDs()
        let selectedID = selected?.id
        let preview = self.preview
        // Until there is a reading, suggest the longest outside wall: the
        // reading that checks the most of the plan.
        let suggested = !scan.hasReadings
            ? walls.filter(\.exterior).max { $0.length < $1.length }?.id : nil
        // While a gap's sheet is open, the wall its laser depth starts from.
        let reference = selectedGap.flatMap { geo.referenceWall(for: $0)?.wall.id }
        let cornerMode = self.cornerMode, spanStart = self.spanStart, draft = self.spanDraft
        let editMode = self.editMode, endDrag = self.endDrag, picked = self.selectedWalls, moves = self.dragMoves
        return Canvas { ctx, _ in
            for f in geo.floors where f.story == story {
                var p = Path()
                p.addLines(f.points.map(view.map))
                p.closeSubpath()
                ctx.fill(p, with: .color(.gray.opacity(0.22)))
            }
            // Room names wrap to fit between the walls either side of them.
            let wallLines = walls.map { (view.map($0.a), view.map($0.b)) }
            for s in geo.sections where s.story == story && !s.label.isEmpty {
                let c = view.map(s.center)
                let room = Self.labelWidth(at: c, walls: wallLines)
                func line(_ t: String) -> GraphicsContext.ResolvedText {
                    ctx.resolve(Text(t).font(.caption.bold()).foregroundStyle(.secondary))
                }
                // Word by word, a new line whenever the next word won't fit.
                var lines: [String] = []
                for word in s.label.split(separator: " ").map(String.init) {
                    if let last = lines.last,
                       line(last + " " + word).measure(in: CGSize(width: 1000, height: 100)).width <= room {
                        lines[lines.count - 1] = last + " " + word
                    } else {
                        lines.append(word)
                    }
                }
                let height = line("Ag").measure(in: CGSize(width: 1000, height: 100)).height
                for (i, l) in lines.enumerated() {
                    let y = c.y + (CGFloat(i) - CGFloat(lines.count - 1) / 2) * height
                    ctx.draw(line(l), at: CGPoint(x: c.x, y: y))
                }
            }
            for w in walls {
                var p = Path()
                p.move(to: view.map(w.a))
                p.addLine(to: view.map(w.b))
                let colour: Color = picked.contains(w.id) ? .teal
                    : preview.moving.contains(w.id) ? .orange
                    : (preview.run.contains(w.id) || w.id == selectedID || w.id == reference) ? .blue
                    : measured.contains(w.id) ? .green
                    : w.id == suggested ? .purple
                    : (w.exterior ? .primary : .gray)
                let width: CGFloat = preview.run.contains(w.id) || preview.moving.contains(w.id)
                    || w.id == selectedID || w.id == suggested || picked.contains(w.id)
                    ? 6 : (w.exterior ? 4.5 : 2.5)
                ctx.stroke(p, with: .color(colour), style: StrokeStyle(lineWidth: width, lineCap: .round))
            }
            for f in geo.features where f.story == story {
                var p = Path()
                p.move(to: view.map(f.a))
                p.addLine(to: view.map(f.b))
                let colour: Color = f.kind == .door ? .orange : f.kind == .entrance ? .red : (f.kind == .window ? .cyan : .purple)
                ctx.stroke(p, with: .color(colour.opacity(0.85)),
                           style: StrokeStyle(lineWidth: f.kind == .entrance ? 7 : 5, lineCap: .butt,
                                              dash: f.kind == .opening ? [6, 4] : []))
                if f.kind == .door || f.kind == .entrance {
                    let sym = Self.doorSymbol(a: view.map(f.a), b: view.map(f.b), hingeAtB: f.hingeAtB, side: f.side, style: f.style)
                    ctx.stroke(sym.path, with: .color(colour.opacity(0.75)),
                               style: StrokeStyle(lineWidth: 1.4, dash: sym.dashed ? [4, 3] : []))
                }
            }
            for gap in geo.gaps where gap.story == story {
                var p = Path()
                p.move(to: view.map(gap.a))
                p.addLine(to: view.map(gap.b))
                ctx.stroke(p, with: .color(gap.filled ? .gray.opacity(0.5) : .red),
                           style: StrokeStyle(lineWidth: gap.filled ? 2 : 5, lineCap: .round, dash: [5, 4]))
            }
            for l in geo.hiddenLines where l.story == story {
                var p = Path()
                p.move(to: view.map(l.a))
                p.addLine(to: view.map(l.b))
                ctx.stroke(p, with: .color(.brown), style: StrokeStyle(lineWidth: 4, lineCap: .round))
            }
            for w in geo.wallPoints where w.story == story {
                let c = view.map(w.point)
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)), with: .color(.brown))
            }
            for l in geo.exteriorLines {
                var p = Path()
                p.move(to: view.map(l.a))
                p.addLine(to: view.map(l.b))
                ctx.stroke(p, with: .color(.orange), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            }
            // Where each wall stops, so two walls in line read as two.
            for w in walls {
                for e in [view.map(w.a), view.map(w.b)] {
                    ctx.fill(Path(ellipseIn: CGRect(x: e.x - 2.5, y: e.y - 2.5, width: 5, height: 5)), with: .color(.gray))
                }
            }

            // Editing: a handle on every wall end, and the walls being dragged.
            if editMode {
                for w in walls {
                    for e in [w.a, w.b] {
                        let p = view.map(e)
                        ctx.stroke(Path(CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)), with: .color(.teal), lineWidth: 1.5)
                    }
                }
                if let d = endDrag {
                    func moved(_ e: CGPoint) -> CGPoint? { moves.first { hypot($0.from.x - e.x, $0.from.y - e.y) < 0.1 }?.to }
                    for w in walls {
                        let a = moved(w.a), b = moved(w.b)
                        guard a != nil || b != nil else { continue }
                        var p = Path()
                        p.move(to: view.map(a ?? w.a))
                        p.addLine(to: view.map(b ?? w.b))
                        ctx.stroke(p, with: .color(.teal), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    }
                    let t = view.map(d.to)
                    ctx.fill(Path(ellipseIn: CGRect(x: t.x - 7, y: t.y - 7, width: 14, height: 14)), with: .color(.teal))
                }
            }
            // Photo pins: a camera dot with a pointer the way it faced.
            for pin in geo.photos where pin.story == story {
                let p = view.map(pin.at)
                var ray = Path()
                ray.move(to: p)
                ray.addLine(to: CGPoint(x: p.x + pin.dir.dx * 20, y: p.y + pin.dir.dy * 20))
                ctx.stroke(ray, with: .color(.indigo), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 9, y: p.y - 9, width: 18, height: 18)), with: .color(.indigo))
                ctx.draw(Text(Image(systemName: "camera.fill")).font(.system(size: 9)).foregroundStyle(.white), at: p)
            }
            // Corners to pick from, the one picked, and the pair being entered.
            if cornerMode {
                for c in geo.corners(story: story) {
                    let p = view.map(c)
                    ctx.stroke(Path(ellipseIn: CGRect(x: p.x - 7, y: p.y - 7, width: 14, height: 14)),
                               with: .color(.blue), lineWidth: 2)
                }
            }
            for c in [spanStart, draft?.a, draft?.b].compactMap({ $0 }) {
                let p = view.map(c)
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 8, y: p.y - 8, width: 16, height: 16)), with: .color(.blue))
            }

            // Labels: readings first, drawn on the side they were taken and
            // across the whole stretch they cover, then the scan's estimates.
            var placed: [CGRect] = []
            for span in geo.spans where span.reading.story == story {
                let (a, end, side) = Self.spanLine(span.a, span.b)
                drawDimension(ctx, view: view, a: a, b: end, side: side,
                              text: "\(Feet.text(span.reading.inches)) \(span.reading.face == .outside ? "out" : "in") ✓",
                              colour: .green, force: true, placed: &placed)
            }
            var labelled = Set<UUID>()
            for (key, m) in measurements {
                guard let w = geo.wall(key), w.story == story else { continue }
                let run = geo.run(from: w, sign: m.sideSign, outside: m.face == .outside)
                labelled.formUnion(run.walls.map(\.id))
                drawDimension(ctx, view: view, a: run.start, b: run.end, side: w.sideVector(m.sideSign),
                              text: "\(Feet.text(m.inches)) ✓", colour: .green, force: true, placed: &placed)
            }
            let order = walls.filter { !labelled.contains($0.id) }.sorted {
                ($0.id == selectedID ? 1_000_000 : 0) + $0.scanInches > ($1.id == selectedID ? 1_000_000 : 0) + $1.scanInches
            }
            for w in order {
                let inches = geo.labelInches(w)
                let colour: Color = w.id == selectedID ? .blue : (w.exterior ? .red : .gray)
                drawDimension(ctx, view: view, a: w.a, b: w.b, side: w.sideVector(w.labelSign),
                              text: (w.exterior ? "" : "≈") + Feet.text(inches), colour: colour,
                              force: w.id == selectedID, placed: &placed)
            }
        }
    }

    // A door's plan symbol for its style. Pocket: the leaf drawn dashed inside
    // the wall beyond the hinge end, where it slides away. Bifold: leaves
    // folded out to the door's side, a pair from each jamb. Sliding: two
    // overlapping panels, one each side of the wall line.
    static func doorSymbol(a: CGPoint, b: CGPoint, hingeAtB: Bool, side: Int, style: DoorStyle) -> (path: Path, dashed: Bool) {
        let L = hypot(b.x - a.x, b.y - a.y)
        guard L > 1 else { return (Path(), false) }
        let ux = (b.x - a.x) / L, uy = (b.y - a.y) / L
        let nx = -uy * CGFloat(side), ny = ux * CGFloat(side)
        func at(_ t: CGFloat, _ o: CGFloat) -> CGPoint { CGPoint(x: a.x + ux * t + nx * o, y: a.y + uy * t + ny * o) }
        var p = Path()
        switch style {
        case .swing:
            return (swingPath(a: a, b: b, hingeAtB: hingeAtB, side: side), false)
        case .pocket:
            let off: CGFloat = 2.5
            if hingeAtB { p.move(to: at(L * 0.15, off)); p.addLine(to: at(L * 2, off)) }
            else { p.move(to: at(-L, off)); p.addLine(to: at(L * 0.85, off)) }
            return (p, true)
        case .bifold:
            let d = L * 0.18
            p.move(to: at(0, 0)); p.addLine(to: at(L * 0.125, d)); p.addLine(to: at(L * 0.25, 0))
            p.move(to: at(L, 0)); p.addLine(to: at(L * 0.875, d)); p.addLine(to: at(L * 0.75, 0))
            return (p, false)
        case .sliding:
            let off: CGFloat = 3
            p.move(to: at(0, off)); p.addLine(to: at(L * 0.55, off))
            p.move(to: at(L * 0.45, -off)); p.addLine(to: at(L, -off))
            return (p, false)
        }
    }

    // A door's swing: the open leaf square to the wall at the hinge, and the
    // quarter circle its free edge sweeps. Screen points; side as in the data.
    static func swingPath(a: CGPoint, b: CGPoint, hingeAtB: Bool, side: Int) -> Path {
        let h = hingeAtB ? b : a, e = hingeAtB ? a : b
        let vx = e.x - h.x, vy = e.y - h.y, w = hypot(vx, vy)
        var p = Path()
        guard w > 1 else { return p }
        // The side's normal, (−dy, dx) of a→b, in screen points.
        let L = hypot(b.x - a.x, b.y - a.y)
        let nx = -(b.y - a.y) / L * CGFloat(side), ny = (b.x - a.x) / L * CGFloat(side)
        let leaf = CGPoint(x: h.x + nx * w, y: h.y + ny * w)
        p.move(to: h)
        p.addLine(to: leaf)
        // Turn from the closed position (along the wall) to the open leaf.
        let turn: CGFloat = (vx * ny - vy * nx) > 0 ? 1 : -1
        let start = atan2(vy, vx)
        p.move(to: e)
        for k in 1...16 {
            let t = start + turn * (.pi / 2) * CGFloat(k) / 16
            p.addLine(to: CGPoint(x: h.x + cos(t) * w, y: h.y + sin(t) * w))
        }
        return p
    }

    // A corner-to-corner reading drawn along the house's main direction,
    // offset up or left, with the second end lined up with the first.
    static func spanLine(_ a: CGPoint, _ b: CGPoint) -> (CGPoint, CGPoint, CGVector) {
        if abs(b.x - a.x) >= abs(b.y - a.y) { return (a, CGPoint(x: b.x, y: a.y), CGVector(dx: 0, dy: -1)) }
        return (a, CGPoint(x: a.x, y: b.y), CGVector(dx: -1, dy: 0))
    }

    // A dimension line with end ticks beside the wall, on the given side,
    // with its label. Skipped when it would overlap one already drawn.
    private func drawDimension(_ ctx: GraphicsContext, view: Viewport, a pa: CGPoint, b pb: CGPoint,
                               side: CGVector, text: String, colour: Color, force: Bool, placed: inout [CGRect]) {
        let a = view.map(pa), b = view.map(pb)
        let resolved = ctx.resolve(Text(text).font(.caption.weight(.semibold)).foregroundStyle(colour))
        let size = resolved.measure(in: CGSize(width: 400, height: 100))
        guard force || hypot(b.x - a.x, b.y - a.y) > size.width * 0.8 else { return }
        var angle = atan2(b.y - a.y, b.x - a.x)
        if angle > .pi / 2 { angle -= .pi } else if angle <= -.pi / 2 { angle += .pi }
        let off = size.height / 2 + 10
        let centre = CGPoint(x: (a.x + b.x) / 2 + side.dx * off, y: (a.y + b.y) / 2 + side.dy * off)
        let box = CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height)
            .applying(CGAffineTransform(rotationAngle: angle))
            .offsetBy(dx: centre.x, dy: centre.y)
            .insetBy(dx: -2, dy: -2)
        if !force, placed.contains(where: { $0.intersects(box) }) { return }
        placed.append(box)
        let gap: CGFloat = 4, tick: CGFloat = 4
        var dim = Path()
        dim.move(to: CGPoint(x: a.x + side.dx * gap, y: a.y + side.dy * gap))
        dim.addLine(to: CGPoint(x: b.x + side.dx * gap, y: b.y + side.dy * gap))
        for e in [a, b] {
            dim.move(to: CGPoint(x: e.x + side.dx * (gap - tick), y: e.y + side.dy * (gap - tick)))
            dim.addLine(to: CGPoint(x: e.x + side.dx * (gap + tick), y: e.y + side.dy * (gap + tick)))
        }
        ctx.stroke(dim, with: .color(colour.opacity(0.8)), lineWidth: 1)
        ctx.drawLayer { layer in
            layer.translateBy(x: centre.x, y: centre.y)
            layer.rotate(by: .radians(angle))
            layer.draw(resolved, at: .zero)
        }
    }
}

// Maps plan feet onto the screen: fit to the view, then the reader's zoom and pan.
private struct Viewport {
    let scale: CGFloat, ox: CGFloat, oy: CGFloat, minX: CGFloat, minY: CGFloat
    let centre: CGPoint, zoom: CGFloat, pan: CGSize

    init(geo: PlanGeometry, story: Int, size: CGSize, zoom: CGFloat, pan: CGSize) {
        let pts = geo.walls.filter { $0.story == story }.flatMap { [$0.a, $0.b] }
            + geo.exteriorLines.flatMap { [$0.a, $0.b] }
        minX = pts.map(\.x).min() ?? 0
        minY = pts.map(\.y).min() ?? 0
        let w = max((pts.map(\.x).max() ?? 1) - minX, 1)
        let h = max((pts.map(\.y).max() ?? 1) - minY, 1)
        let pad: CGFloat = 36
        scale = min((size.width - 2 * pad) / w, (size.height - 2 * pad) / h)
        ox = (size.width - w * scale) / 2
        oy = (size.height - h * scale) / 2
        centre = CGPoint(x: size.width / 2, y: size.height / 2)
        self.zoom = zoom
        self.pan = pan
    }

    func map(_ p: CGPoint) -> CGPoint {
        let q = CGPoint(x: (p.x - minX) * scale + ox, y: (p.y - minY) * scale + oy)
        return CGPoint(x: centre.x + (q.x - centre.x) * zoom + pan.width,
                       y: centre.y + (q.y - centre.y) * zoom + pan.height)
    }

    // Where the plan sits on screen.
    var bounds: CGRect {
        let a = map(CGPoint(x: minX, y: minY))
        let b = map(CGPoint(x: minX + (centre.x * 2 - ox * 2) / scale, y: minY + (centre.y * 2 - oy * 2) / scale))
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    // Screen point back to plan feet.
    func unmap(_ s: CGPoint) -> CGPoint {
        let qx = centre.x + (s.x - pan.width - centre.x) / zoom, qy = centre.y + (s.y - pan.height - centre.y) / zoom
        return CGPoint(x: (qx - ox) / scale + minX, y: (qy - oy) / scale + minY)
    }

    // Screen distance from a tap to a plan segment.
    func distance(_ tap: CGPoint, _ pa: CGPoint, _ pb: CGPoint) -> CGFloat {
        let a = map(pa), b = map(pb)
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = max(dx * dx + dy * dy, 0.0001)
        let t = min(max(((tap.x - a.x) * dx + (tap.y - a.y) * dy) / len2, 0), 1)
        return hypot(tap.x - (a.x + t * dx), tap.y - (a.y + t * dy))
    }

    func nearest(to tap: CGPoint, in walls: [PlanWall]) -> PlanWall? {
        func dist(_ w: PlanWall) -> CGFloat {
            let a = map(w.a), b = map(w.b)
            let dx = b.x - a.x, dy = b.y - a.y
            let len2 = max(dx * dx + dy * dy, 0.0001)
            let t = min(max(((tap.x - a.x) * dx + (tap.y - a.y) * dy) / len2, 0), 1)
            return hypot(tap.x - (a.x + t * dx), tap.y - (a.y + t * dy))
        }
        guard let best = walls.min(by: { dist($0) < dist($1) }), dist(best) < 24 else { return nil }
        return best
    }
}

struct MeasureSheet: View {
    let wall: PlanWall
    let geo: PlanGeometry
    let measured: Set<UUID>
    let existing: WallMeasurement?
    @Binding var preview: ReadingPreview
    let onSave: (WallMeasurement?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var choice = 0
    @State private var move = WallMeasurement.Move.auto
    @State private var onlyThis = false

    // Where the reading was taken: a room on one side, or outside.
    private struct Place { let sign: Int; let outside: Bool; let title: String; let room: String }
    private var places: [Place] {
        let here = wall.roomName(wall.labelSign), there = wall.roomName(-wall.labelSign)
        if wall.exterior {
            return [Place(sign: wall.labelSign, outside: false, title: "Inside, \(here)", room: here),
                    Place(sign: -wall.labelSign, outside: true, title: "Outside", room: "outside")]
        }
        return [Place(sign: wall.labelSign, outside: false, title: "In \(here)", room: here),
                Place(sign: -wall.labelSign, outside: false, title: "In \(there)", room: there)]
    }

    var body: some View {
        let place = places[min(choice, places.count - 1)]
        let joined = geo.run(from: wall, sign: place.sign, outside: place.outside)
        let run = onlyThis ? WallRun(walls: [wall], start: wall.a, end: wall.b, startWall: nil, endWall: nil,
                                     sign: place.sign, outside: place.outside) : joined
        let estimate = geo.estimateInches(run)
        let parsed = LengthParser.inches(from: text)
        let sum = LengthParser.reading(from: text).flatMap { LengthParser.describe($0.parts) }
        let moving = resolveMoving(run)
        NavigationStack {
            Form {
                Section {
                    Picker("Measured from", selection: $choice) {
                        ForEach(places.indices, id: \.self) { Text(places[$0].title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    LabeledContent("Scan estimate, face to face", value: Feet.text(estimate))
                    if joined.walls.count > 1 || onlyThis {
                        Toggle("Only the piece I tapped", isOn: $onlyThis)
                    }
                } header: {
                    Text("Where were you standing?")
                } footer: {
                    Text(run.walls.count > 1
                         ? "This face spans \(run.walls.count) scanned pieces in a line, shown in blue. Laser from one end of the blue stretch to the other, or turn on Only the piece I tapped."
                         : onlyThis ? "Laser the blue piece only, end to end."
                         : "Laser along the blue wall, face to face, from one end to the other.")
                }
                Section("Your reading") {
                    HStack {
                        TextField("e.g. 10 9  or  6 5 + 6 2", text: $text)
                            .keyboardType(.numbersAndPunctuation)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        Button("Paste") { text = UIPasteboard.general.string ?? text }
                            .buttonStyle(.bordered)
                    }
                    if let parsed {
                        let diff = parsed - estimate
                        HStack {
                            Text("= \(Feet.text(parsed))").font(.title2.bold())
                            Spacer()
                            Text(diff == 0 ? "matches scan" : "\(diff > 0 ? "+" : "−")\(abs(diff))″ vs scan")
                                .foregroundStyle(abs(diff) > 2 ? .orange : .secondary)
                        }
                        if let sum {
                            Text(sum).font(.footnote).foregroundStyle(.secondary)
                        }
                        if abs(diff) > 2 {
                            Text("More than 2″ off. Check it's the blue stretch and the right room.")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        }
                    } else if !text.isEmpty {
                        Text("Not understood. Try feet then inches, like 10 9.").foregroundStyle(.red)
                    }
                }
                Section {
                    Picker("To fit the reading, move", selection: $move) {
                        Text("Auto").tag(WallMeasurement.Move.auto)
                        if run.startWall != nil { Text(geo.endName(run, start: true)).tag(WallMeasurement.Move.start) }
                        if run.endWall != nil { Text(geo.endName(run, start: false)).tag(WallMeasurement.Move.end) }
                        if run.startWall != nil && run.endWall != nil { Text("Both").tag(WallMeasurement.Move.both) }
                    }
                } footer: {
                    Text(moveDescription(run, moving: moving) + " Shown in orange.")
                }
                if existing != nil {
                    Button("Remove reading", role: .destructive) {
                        onSave(nil)
                        dismiss()
                    }
                }
            }
            .navigationTitle("Wall reading")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let parsed {
                            onSave(WallMeasurement(inches: parsed, face: place.outside ? .outside : .inside,
                                                   sideSign: place.sign, room: place.room,
                                                   walls: run.walls.map(\.id), move: move, moving: moving,
                                                   entered: text.trimmingCharacters(in: .whitespaces)))
                        }
                        dismiss()
                    }
                    .disabled(parsed == nil)
                }
            }
            .onAppear {
                if let existing {
                    text = existing.entered.isEmpty ? "\(existing.inches / 12) \(existing.inches % 12)" : existing.entered
                    choice = places.firstIndex { $0.sign == existing.sideSign && $0.outside == (existing.face == .outside) } ?? 0
                    move = existing.move
                    onlyThis = existing.walls == [wall.id] && geo.run(from: wall, sign: existing.sideSign, outside: existing.face == .outside).walls.count > 1
                }
            }
            .onChange(of: ReadingPreview(run: run.walls.map(\.id), moving: moving), initial: true) { _, new in
                preview = new
            }
        }
    }

    private func resolveMoving(_ run: WallRun) -> [UUID] {
        switch move {
        case .auto: return geo.autoMoving(run, measured: measured)
        case .start: return [run.startWall?.id].compactMap { $0 }
        case .end: return [run.endWall?.id].compactMap { $0 }
        case .both: return Array(Set([run.startWall?.id, run.endWall?.id].compactMap { $0 }))
        }
    }

    private func moveDescription(_ run: WallRun, moving: [UUID]) -> String {
        func kind(_ w: PlanWall?) -> String {
            guard let w else { return "wall" }
            return measured.contains(w.id) ? "measured wall" : (w.exterior ? "outside wall" : "partition")
        }
        if moving.count == 2 { return "Both end walls share the change." }
        if moving.first == run.startWall?.id {
            return "The \(kind(run.startWall)) at the \(geo.endName(run, start: true)) moves; the other end stays."
        }
        if moving.first == run.endWall?.id {
            return "The \(kind(run.endWall)) at the \(geo.endName(run, start: false)) moves; the other end stays."
        }
        return "Nothing closes this stretch, so nothing moves."
    }
}

// The two corners picked for a reading, waiting for the number.
struct SpanDraft: Identifiable {
    let id = UUID()
    let a: CGPoint
    let b: CGPoint
    let story: Int
    let existing: SpanReading?
}

// A reading between two corners. Outside it runs siding corner to siding
// corner; inside, face to face. Lengths can be added and subtracted, the way a
// long wall is lasered in pieces.
struct SpanSheet: View {
    let draft: SpanDraft
    let geo: PlanGeometry
    let onSave: (SpanReading?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var face = WallMeasurement.Face.outside

    var body: some View {
        let estimate = geo.spanEstimate(draft.a, draft.b, story: draft.story, outside: face == .outside)
        let reading = LengthParser.reading(from: text)
        NavigationStack {
            Form {
                Section {
                    Picker("Measured", selection: $face) {
                        Text("Outside").tag(WallMeasurement.Face.outside)
                        Text("Inside").tag(WallMeasurement.Face.inside)
                    }
                    .pickerStyle(.segmented)
                    LabeledContent("Scan estimate", value: Feet.text(estimate))
                } header: {
                    Text("Between the two blue corners")
                } footer: {
                    Text(face == .outside
                         ? "Outside: siding corner to siding corner, along the wall. The estimate adds a \(Int(Assume.exteriorInches))″ wall at each outside corner; an inside corner (the step in an L) adds nothing."
                         : "Inside: face to face, along the wall.")
                }
                Section {
                    HStack {
                        TextField("e.g. 24 6  or  11 11 + 6 5 + 6 2", text: $text)
                            .keyboardType(.numbersAndPunctuation)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        Button("Paste") { text = UIPasteboard.general.string ?? text }
                            .buttonStyle(.bordered)
                    }
                    if let reading {
                        let diff = reading.total - estimate
                        HStack {
                            Text("= \(Feet.text(reading.total))").font(.title2.bold())
                            Spacer()
                            Text(diff == 0 ? "matches scan" : "\(diff > 0 ? "+" : "−")\(abs(diff))″ vs scan")
                                .foregroundStyle(abs(diff) > 6 ? .orange : .secondary)
                        }
                        if let sum = LengthParser.describe(reading.parts) {
                            Text(sum).font(.footnote).foregroundStyle(.secondary)
                        }
                    } else if !text.isEmpty {
                        Text("Not understood. Try feet then inches, like 24 6, or pieces like 11 11 + 6 5 + 6 2.")
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("Your reading")
                } footer: {
                    Text("Add pieces with +, or take one off with − (spaces round it), e.g. to the fence and back: 30 0 − 5 6.")
                }
                if draft.existing != nil {
                    Button("Remove reading", role: .destructive) {
                        onSave(nil)
                        dismiss()
                    }
                }
            }
            .navigationTitle("Corner to corner")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let reading {
                            onSave(SpanReading(a: .zero, b: .zero, story: draft.story, inches: reading.total, face: face,
                                               entered: text.trimmingCharacters(in: .whitespaces)))
                        }
                        dismiss()
                    }
                    .disabled(reading == nil)
                }
            }
            .onAppear {
                if let e = draft.existing {
                    face = e.face
                    text = e.entered.isEmpty ? "\(e.inches / 12) \(e.inches % 12)" : e.entered
                }
            }
        }
    }
}

// What a tap in Edit mode asked to delete.
enum EditTarget {
    case wall(PlanWall)
    case hidden(HiddenLine)

    var title: String {
        switch self {
        case .wall(let w): return "Delete this \(Feet.text(w.scanInches)) wall?"
        case .hidden: return "Delete this hidden wall?"
        }
    }
    var message: String {
        switch self {
        case .wall: return "For stray bits the scan made. The wall is left out of the plan, the import and the detailed plan; Undo or Restore scan brings it back."
        case .hidden(let h): return h.depth != nil ? "Removes the laser depth that placed it." : "Removes the Mark wall point that placed it."
        }
    }
}

enum EditTool: String, CaseIterable {
    case walls = "Walls", rooms = "Rooms", doors = "Doors"
    var hint: String {
        switch self {
        case .walls: return "Tap walls to select them, then Align or Delete. Drag a wall's end (square) along the wall to lengthen it, or across to slide the wall."
        case .rooms: return "Tap a room to name it, or tap a name to change or remove it."
        case .doors: return "Tap a wall to add a door or opening; tap any door or opening to change its type or width, or remove it."
        }
    }
}

struct RoomDraft: Identifiable {
    let id = UUID()
    let source: RoomSource
    let point: SIMD2<Double>
    let story: Int
    let name: String?
}

struct DoorDraft: Identifiable {
    let id = UUID()
    let wall: PlanWall
    let at: CGPoint
    let ref: OpeningRef
    let kind: OpeningKind
    let inches: Int
    var hingeAtB = false
    var side = 1
    var style = DoorStyle.swing
}

// A door or opening: its type, then a common width or any typed one.
struct DoorSheet: View {
    let draft: DoorDraft
    let onSave: ((kind: OpeningKind, inches: Int, hingeAtB: Bool, side: Int, style: DoorStyle)?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var kind = OpeningKind.interior
    @State private var inches = 32
    @State private var custom = ""
    @State private var hingeAtB = false
    @State private var side = 1
    @State private var style = DoorStyle.swing
    static let widths: [OpeningKind: [Int]] = [
        .entrance: [32, 34, 36, 42, 60, 72], .interior: [24, 28, 30, 32, 34, 36], .opening: [30, 36, 48, 60, 72, 96],
    ]

    var body: some View {
        let typed = LengthParser.inches(from: custom)
        NavigationStack {
            Form {
                Picker("Type", selection: $kind) {
                    Text("Entrance").tag(OpeningKind.entrance)
                    Text("Interior").tag(OpeningKind.interior)
                    Text("Opening").tag(OpeningKind.opening)
                }
                .pickerStyle(.segmented)
                Section("Width") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), spacing: 8)], spacing: 8) {
                        ForEach(Self.widths[kind] ?? [], id: \.self) { w in
                            Button(Feet.text(w)) { inches = w; custom = "" }
                                .buttonStyle(.bordered)
                                .tint(inches == w && custom.isEmpty ? .accentColor : .gray)
                        }
                    }
                    HStack {
                        TextField("Other, e.g. 40 in or 3 4", text: $custom)
                            .keyboardType(.numbersAndPunctuation)
                            .autocorrectionDisabled()
                        if let typed { Text("= \(Feet.text(typed))").bold() }
                    }
                }
                if kind != .opening {
                    Picker("Style", selection: $style) {
                        Text("Swing").tag(DoorStyle.swing)
                        Text("Pocket").tag(DoorStyle.pocket)
                        Text("Bifold").tag(DoorStyle.bifold)
                        Text("Sliding").tag(DoorStyle.sliding)
                    }
                    .pickerStyle(.segmented)
                    Section(style == .swing ? "Swing" : "Which way") {
                        HStack(spacing: 16) {
                            Canvas { ctx, size in
                                // Turned to lie like the wall on the plan, so the buttons read the same way.
                                ctx.translateBy(x: size.width / 2, y: size.height / 2)
                                ctx.rotate(by: .radians(atan2(draft.wall.direction.dy, draft.wall.direction.dx)))
                                ctx.translateBy(x: -size.width / 2, y: -size.height / 2)
                                let a = CGPoint(x: 12, y: size.height / 2), b = CGPoint(x: size.width - 12, y: size.height / 2)
                                var wall = Path()
                                wall.move(to: CGPoint(x: 0, y: a.y)); wall.addLine(to: CGPoint(x: size.width, y: a.y))
                                ctx.stroke(wall, with: .color(.gray), lineWidth: 3)
                                var d = Path(); d.move(to: a); d.addLine(to: b)
                                ctx.stroke(d, with: .color(kind == .entrance ? .red : .orange), lineWidth: 4)
                                // Shrink the leaf to fit the preview box.
                                let s = min(1, (size.height / 2 - 4) / (b.x - a.x))
                                let mid = CGPoint(x: (a.x + b.x) / 2, y: a.y)
                                let sa = CGPoint(x: mid.x - (mid.x - a.x) * s, y: a.y), sb = CGPoint(x: mid.x + (b.x - mid.x) * s, y: a.y)
                                let sym = style == .swing ? (sa, sb) : (a, b)
                                let symbol = PlanView.doorSymbol(a: sym.0, b: sym.1, hingeAtB: hingeAtB, side: side, style: style)
                                ctx.stroke(symbol.path, with: .color(.primary), style: StrokeStyle(lineWidth: 1.5, dash: symbol.dashed ? [4, 3] : []))
                            }
                            .frame(width: 110, height: 110)
                            .id("\(hingeAtB)-\(side)-\(kind)-\(style)")   // redraw when the swing changes
                            // Borderless, so a tap in this form row only fires the button under it.
                            VStack(alignment: .leading, spacing: 14) {
                                if style == .swing || style == .pocket {
                                    Button(style == .pocket ? "Pocket at other end" : "Hinge at other end",
                                           systemImage: "arrow.left.and.right") { hingeAtB.toggle() }
                                        .buttonStyle(.borderless)
                                }
                                if style != .pocket {
                                    Button(style == .swing ? "Swing other way" : "Other side", systemImage: "arrow.up.and.down") { side = -side }
                                        .buttonStyle(.borderless)
                                }
                            }
                        }
                    }
                }
                if draft.ref != .new {
                    Button("Remove", role: .destructive) { onSave(nil); dismiss() }
                }
            }
            .navigationTitle(draft.ref == .new ? "Add on this wall" : "This door or opening")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave((kind, typed ?? inches, hingeAtB, side, style)); dismiss() }
                        .disabled(!custom.isEmpty && typed == nil)
                }
            }
            .onAppear { kind = draft.kind; inches = draft.inches; hingeAtB = draft.hingeAtB; side = draft.side; style = draft.style }
        }
    }
}

// Naming a room: type a few letters and pick from the list. Matches allow
// for typos and other names for the same room (master, powder room, den),
// and the names used most rise to the top. Anything else typed is kept.
struct RoomSheet: View {
    let draft: RoomDraft
    let onSave: (String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var typing: Bool
    @State private var own = RoomNames.own

    private var query: String { text.trimmingCharacters(in: .whitespaces) }
    private var matches: [RoomNames.Match] { RoomNames.search(query) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("Type to search, e.g. bed, master, powder", text: $text)
                            .textInputAutocapitalization(.words)
                            .autocorrectionDisabled()
                            .focused($typing)
                            .submitLabel(.done)
                            .onSubmit { if !query.isEmpty { save(matches.first?.name ?? query) } }
                        if !text.isEmpty {
                            Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                                .buttonStyle(.borderless)
                        }
                    }
                }
                if query.isEmpty {
                    let used = RoomNames.mostUsed()
                    if !used.isEmpty {
                        Section("Used most") {
                            ForEach(used, id: \.self) { n in row(n, note: nil) }
                        }
                    }
                    let mine = RoomNames.byUse(own)
                    if !mine.isEmpty {
                        Section {
                            ForEach(mine, id: \.self) { n in row(n, note: nil) }
                                .onDelete { offsets in
                                    for i in offsets { RoomNames.removeOwn(mine[i]) }
                                    own = RoomNames.own
                                }
                        } header: {
                            Text("Your rooms")
                        } footer: {
                            Text("Swipe left on one of your rooms to take it off the list.")
                        }
                    }
                    Section("All rooms") {
                        ForEach(RoomNames.catalogue.map(\.name).filter { !used.contains($0) }, id: \.self) { n in row(n, note: nil) }
                    }
                } else {
                    Section {
                        ForEach(matches, id: \.name) { m in row(m.name, note: m.note) }
                        if !matches.contains(where: { $0.name.caseInsensitiveCompare(query) == .orderedSame }) {
                            Button { save(query) } label: {
                                Label("Add \u{201C}\(RoomNames.canonical(query))\u{201D} to the list", systemImage: "plus")
                            }
                        }
                    } header: {
                        Text(matches.isEmpty ? "No match" : "Matches")
                    }
                }
                if query.isEmpty {
                    Section {
                        Button("Add a room name", systemImage: "plus") { typing = true }
                    } footer: {
                        Text("Type a name that isn't listed, then tap Add. It's kept on this phone for every scan.")
                    }
                }
                if draft.name != nil {
                    Button("Remove name", role: .destructive) { onSave(nil); dismiss() }
                }
            }
            .navigationTitle(draft.name == nil ? "Name this room" : "Rename \(draft.name!)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onAppear { typing = draft.name == nil }
        }
    }

    private func row(_ name: String, note: String?) -> some View {
        Button { save(name) } label: {
            HStack {
                Text(name).foregroundStyle(.primary)
                if let note { Text(note).font(.footnote).foregroundStyle(.secondary) }
                Spacer()
                if name == draft.name { Image(systemName: "checkmark") }
            }
        }
    }

    private func save(_ name: String) {
        let n = RoomNames.canonical(name)
        RoomNames.addOwn(n)
        RoomNames.recordUse(n)
        onSave(n)
        dismiss()
    }
}

// Room names an appraiser uses, each with the other words people use for it.
enum RoomNames {
    struct Entry { let name: String; let aliases: [String] }
    struct Match { let name: String; let note: String? }

    static let catalogue: [Entry] = [
        Entry(name: "Bedroom", aliases: ["bed", "br", "bdrm", "bdr", "guest room", "spare room", "kids room", "nursery"]),
        Entry(name: "Primary bedroom", aliases: ["master", "master bedroom", "main bedroom", "mbr", "owner's suite", "owners suite", "principal bedroom"]),
        Entry(name: "Bath", aliases: ["bathroom", "washroom"]),
        Entry(name: "2-pc bath", aliases: ["2pc", "2 piece", "two piece", "half bath", "powder room", "powder", "wc", "toilet", "lav", "lavatory"]),
        Entry(name: "3-pc bath", aliases: ["3pc", "3 piece", "three piece", "shower room", "3/4 bath", "three quarter bath"]),
        Entry(name: "4-pc bath", aliases: ["4pc", "4 piece", "four piece", "full bath", "main bath", "tub"]),
        Entry(name: "5-pc bath", aliases: ["5pc", "5 piece", "five piece"]),
        Entry(name: "Ensuite", aliases: ["en suite", "en-suite", "primary bath", "master bath", "master ensuite"]),
        Entry(name: "Kitchen", aliases: ["kit", "kitchenette", "galley"]),
        Entry(name: "Living", aliases: ["living room", "lounge", "front room", "sitting room", "parlour", "parlor", "lr"]),
        Entry(name: "Dining", aliases: ["dining room", "dinette", "dr"]),
        Entry(name: "Nook", aliases: ["breakfast nook", "eating area", "breakfast"]),
        Entry(name: "Family", aliases: ["family room", "fr"]),
        Entry(name: "Great room", aliases: ["great"]),
        Entry(name: "Den", aliases: ["tv room"]),
        Entry(name: "Rec room", aliases: ["recreation room", "rec", "games room", "rumpus room", "basement"]),
        Entry(name: "Media room", aliases: ["theatre", "theater", "home theatre", "home theater"]),
        Entry(name: "Office", aliases: ["study", "library", "home office", "work room"]),
        Entry(name: "Laundry", aliases: ["laundry room", "washer", "dryer", "wash room"]),
        Entry(name: "Closet", aliases: ["cl", "clo", "cupboard", "wardrobe", "coat closet", "linen", "linen closet"]),
        Entry(name: "Walk-in closet", aliases: ["wic", "walk in", "walkin", "walk-in", "dressing room"]),
        Entry(name: "Pantry", aliases: ["larder"]),
        Entry(name: "Entry", aliases: ["foyer", "vestibule", "front entry", "entrance", "porch"]),
        Entry(name: "Hall", aliases: ["hallway", "corridor", "passage", "landing"]),
        Entry(name: "Stairs", aliases: ["stairway", "staircase", "stairwell"]),
        Entry(name: "Mudroom", aliases: ["mud room", "boot room", "back entry", "rear entry"]),
        Entry(name: "Utility", aliases: ["utility room", "mechanical", "furnace room", "boiler room", "mech"]),
        Entry(name: "Storage", aliases: ["store room", "storeroom", "cold room", "cold cellar", "root cellar"]),
        Entry(name: "Sunroom", aliases: ["sun room", "solarium", "3 season", "three season", "florida room", "conservatory"]),
        Entry(name: "Bonus room", aliases: ["bonus", "flex room", "flex"]),
        Entry(name: "Loft", aliases: ["attic room"]),
        Entry(name: "Gym", aliases: ["exercise room", "fitness"]),
        Entry(name: "Workshop", aliases: ["shop", "hobby room", "craft room"]),
        Entry(name: "Garage", aliases: ["carport", "gar"]),
    ]

    // A name in the catalogue's own spelling when typed in any case.
    static func canonical(_ name: String) -> String {
        let n = name.trimmingCharacters(in: .whitespaces)
        if let e = catalogue.first(where: { $0.name.caseInsensitiveCompare(n) == .orderedSame }) { return e.name }
        if let u = own.first(where: { $0.caseInsensitiveCompare(n) == .orderedSame }) { return u }
        return n.prefix(1).uppercased() + n.dropFirst()
    }

    // MARK: How often each name is used, kept on this phone

    private static let usageKey = "roomNameUsage"
    private static var usage: [String: Int] { UserDefaults.standard.dictionary(forKey: usageKey) as? [String: Int] ?? [:] }

    static func recordUse(_ name: String) {
        var u = usage
        u[name, default: 0] += 1
        UserDefaults.standard.set(u, forKey: usageKey)
    }

    // Names added by the user: anything typed that isn't in the catalogue.
    private static let ownKey = "roomNamesOwn"
    static var own: [String] { UserDefaults.standard.stringArray(forKey: ownKey) ?? [] }

    static func addOwn(_ name: String) {
        guard !name.isEmpty, !catalogue.contains(where: { $0.name == name }), !own.contains(name) else { return }
        UserDefaults.standard.set((own + [name]).sorted(), forKey: ownKey)
    }

    static func removeOwn(_ name: String) {
        UserDefaults.standard.set(own.filter { $0 != name }, forKey: ownKey)
        var u = usage
        u[name] = nil
        UserDefaults.standard.set(u, forKey: usageKey)
    }

    // The user's own names, most used first.
    static func byUse(_ names: [String]) -> [String] {
        let u = usage
        return names.sorted { (u[$0] ?? 0) != (u[$1] ?? 0) ? (u[$0] ?? 0) > (u[$1] ?? 0) : $0 < $1 }
    }

    // The catalogue names used most; the user's own names have their own list.
    static func mostUsed(_ limit: Int = 6) -> [String] {
        let known = Set(catalogue.map(\.name))
        return usage.filter { known.contains($0.key) }.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(limit).map(\.key)
    }

    // MARK: Search

    // Lower case, letters and digits only, words separated by single spaces.
    private static func plain(_ s: String) -> String {
        String(s.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " })
            .split(separator: " ").joined(separator: " ")
    }

    // How well a query fits one term: 0 best; nil for no fit.
    private static func score(_ q: String, _ term: String) -> Int? {
        let t = plain(term)
        if t == q { return 0 }
        if t.hasPrefix(q) { return 1 }
        if t.split(separator: " ").contains(where: { $0.hasPrefix(q) }) { return 2 }
        if q.count >= 3 && t.contains(q) { return 3 }
        // Typos: allow one slip in short words, two in longer ones.
        guard q.count >= 3 else { return nil }
        let allowed = q.count >= 6 ? 2 : 1
        var best = typoDistance(q, t)
        if t.count > q.count { best = min(best, typoDistance(q, String(t.prefix(q.count)))) }
        for w in t.split(separator: " ") where w.count >= 3 {
            best = min(best, typoDistance(q, String(w)))
            if w.count > q.count { best = min(best, typoDistance(q, String(w.prefix(q.count)))) }
        }
        return best <= allowed ? 4 + best : nil
    }

    static func search(_ query: String) -> [Match] {
        let q = plain(query)
        guard !q.isEmpty else { return [] }
        let used = usage
        var found: [(match: Match, score: Int, used: Int, order: Int)] = []
        for (i, e) in catalogue.enumerated() {
            var best: (Int, String?)?
            if let s = score(q, e.name) { best = (s, nil) }
            for a in e.aliases {
                if let s = score(q, a), s < (best?.0 ?? .max) { best = (s, a) }
            }
            if let (s, alias) = best {
                found.append((Match(name: e.name, note: alias), s, used[e.name] ?? 0, i))
            }
        }
        // Names the user added.
        for name in own {
            if let s = score(q, name) { found.append((Match(name: name, note: nil), s, used[name] ?? 0, catalogue.count)) }
        }
        return found.sorted {
            if $0.score != $1.score { return $0.score < $1.score }
            if $0.used != $1.used { return $0.used > $1.used }
            return $0.order < $1.order
        }.prefix(8).map(\.match)
    }

    // Edits (insert, delete, change, swap two letters) to turn a into b.
    private static func typoDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var d = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { d[i][0] = i }
        for j in 0...b.count { d[0][j] = j }
        for i in 1...a.count {
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1)
                }
            }
        }
        return d[a.count][b.count]
    }
}
