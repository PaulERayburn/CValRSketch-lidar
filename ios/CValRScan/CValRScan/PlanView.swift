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
    @State private var panBase: CGSize?
    @State private var deleting: EditTarget?
    @State private var tool = EditTool.walls
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
                            if let o = geo.addedOpenings.filter({ $0.story == shown })
                                .first(where: { view.distance(tap.location, $0.a, $0.b) < 20 }),
                               let w = wallUnder(o.a, o.b, scan.addedOpenings[o.index].wall) {
                                doorDraft = DoorDraft(wall: w, at: CGPoint(x: (o.a.x + o.b.x) / 2, y: (o.a.y + o.b.y) / 2),
                                                      ref: .added(o.index), kind: scan.addedOpenings[o.index].kind, inches: inches(o.a, o.b))
                                return
                            }
                            if let f = geo.features.filter({ $0.story == shown && $0.id != nil && $0.kind != .window })
                                .first(where: { view.distance(tap.location, $0.a, $0.b) < 20 }),
                               let id = f.id, let w = wallUnder(f.a, f.b, f.wall) {
                                doorDraft = DoorDraft(wall: w, at: CGPoint(x: (f.a.x + f.b.x) / 2, y: (f.a.y + f.b.y) / 2),
                                                      ref: .scanned(id), kind: f.kind == .opening ? .opening : .interior,
                                                      inches: inches(f.a, f.b))
                                return
                            }
                            if let w = view.nearest(to: tap.location, in: walls) {
                                doorDraft = DoorDraft(wall: w, at: view.unmap(tap.location), ref: .new, kind: .interior, inches: 32)
                            }
                            return
                        }
                        if editMode {
                            let walls = geo.walls.filter { $0.story == shown }
                            let wall = view.nearest(to: tap.location, in: walls)
                            let hidden = geo.hiddenLines.filter { $0.story == shown }
                                .min { view.distance(tap.location, $0.a, $0.b) < view.distance(tap.location, $1.a, $1.b) }
                            if let h = hidden, view.distance(tap.location, h.a, h.b) < 24,
                               wall.map({ view.distance(tap.location, $0.a, $0.b) > view.distance(tap.location, h.a, h.b) }) ?? true {
                                deleting = .hidden(h)
                            } else if let wall {
                                deleting = .wall(wall)
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
                    Button(editMode ? "Done" : "Edit") { editMode.toggle(); tool = .walls }
                }
                Button("Fit") { withAnimation { zoom = 1; pan = .zero } }
            }
            if editMode {
                ToolbarItemGroup(placement: .bottomBar) {
                    Button("Undo", systemImage: "arrow.uturn.backward") { scan.undoEdit() }
                        .disabled(!scan.canUndoEdit)
                    Spacer()
                    Button("Restore scan") { scan.restoreScan() }
                        .disabled(!scan.hasEdits)
                }
            }
        }
        .sheet(item: $roomDraft) { d in
            RoomSheet(draft: d) { name in scan.setRoomName(name, source: d.source, at: d.point, story: d.story) }
                .presentationDetents([.medium, .large])
        }
        .sheet(item: $doorDraft) { d in
            DoorSheet(draft: d) { choice in
                guard let (kind, inches) = choice else { scan.setOpening(nil, replacing: d.ref); return }
                scan.setOpening(opening(on: d.wall, at: d.at, inches: inches, kind: kind, geo: geo), replacing: d.ref)
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

    // The middle of the screen always stays over the plan's central area (its
    // bounds less 15% each side), so it can't be panned or zoomed out of sight.
    private func clamp(_ p: CGSize, geo: PlanGeometry, story: Int, size: CGSize, zoom: CGFloat) -> CGSize {
        let r = Viewport(geo: geo, story: story, size: size, zoom: zoom, pan: .zero).bounds
        let inner = r.insetBy(dx: r.width * 0.15, dy: r.height * 0.15)
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
                    endDrag = (d.from, snap(view.unmap(v.location), from: d.from, geo: geo, story: story, view: view))
                } else if let b = panBase {
                    pan = clamp(CGSize(width: b.width + v.translation.width, height: b.height + v.translation.height),
                                geo: geo, story: story, size: size, zoom: zoom)
                }
            }
            .onEnded { _ in
                if let d = endDrag, hypot(d.to.x - d.from.x, d.to.y - d.from.y) > 0.02 {
                    scan.moveWallEnds(from: geo.world(d.from), to: geo.world(d.to))
                }
                endDrag = nil
                panBase = nil
            }
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
        let editMode = self.editMode, endDrag = self.endDrag
        return Canvas { ctx, _ in
            for f in geo.floors where f.story == story {
                var p = Path()
                p.addLines(f.points.map(view.map))
                p.closeSubpath()
                ctx.fill(p, with: .color(.gray.opacity(0.22)))
            }
            for s in geo.sections where s.story == story && !s.label.isEmpty {
                ctx.draw(Text(s.label).font(.caption.bold()).foregroundStyle(.secondary), at: view.map(s.center))
            }
            for w in walls {
                var p = Path()
                p.move(to: view.map(w.a))
                p.addLine(to: view.map(w.b))
                let colour: Color = preview.moving.contains(w.id) ? .orange
                    : (preview.run.contains(w.id) || w.id == selectedID || w.id == reference) ? .blue
                    : measured.contains(w.id) ? .green
                    : w.id == suggested ? .purple
                    : (w.exterior ? .primary : .gray)
                let width: CGFloat = preview.run.contains(w.id) || preview.moving.contains(w.id)
                    || w.id == selectedID || w.id == suggested
                    ? 6 : (w.exterior ? 4.5 : 2.5)
                ctx.stroke(p, with: .color(colour), style: StrokeStyle(lineWidth: width, lineCap: .round))
            }
            for f in geo.features where f.story == story {
                var p = Path()
                p.move(to: view.map(f.a))
                p.addLine(to: view.map(f.b))
                let colour: Color = f.kind == .door ? .orange : f.kind == .entrance ? .red : (f.kind == .window ? .cyan : .gray)
                ctx.stroke(p, with: .color(colour.opacity(0.85)), lineWidth: f.kind == .entrance ? 7 : 5)
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
                    for w in walls {
                        let far: CGPoint? = hypot(w.a.x - d.from.x, w.a.y - d.from.y) < 0.3 ? w.b
                            : hypot(w.b.x - d.from.x, w.b.y - d.from.y) < 0.3 ? w.a : nil
                        guard let o = far else { continue }
                        var p = Path()
                        p.move(to: view.map(o))
                        p.addLine(to: view.map(d.to))
                        ctx.stroke(p, with: .color(.teal), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    }
                    let t = view.map(d.to)
                    ctx.fill(Path(ellipseIn: CGRect(x: t.x - 7, y: t.y - 7, width: 14, height: 14)), with: .color(.teal))
                }
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
        let run = geo.run(from: wall, sign: place.sign, outside: place.outside)
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
                } header: {
                    Text("Where were you standing?")
                } footer: {
                    Text(run.walls.count > 1
                         ? "This face spans \(run.walls.count) scanned pieces, shown in blue. Laser from one end of the blue stretch to the other."
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
        case .walls: return "Tap a wall to delete it, drag a wall's end (square) to move it."
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
}

// A door or opening: its type, then a common width or any typed one.
struct DoorSheet: View {
    let draft: DoorDraft
    let onSave: ((OpeningKind, Int)?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var kind = OpeningKind.interior
    @State private var inches = 32
    @State private var custom = ""
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
                if draft.ref != .new {
                    Button("Remove", role: .destructive) { onSave(nil); dismiss() }
                }
            }
            .navigationTitle(draft.ref == .new ? "Add on this wall" : "This door or opening")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave((kind, typed ?? inches)); dismiss() }
                        .disabled(!custom.isEmpty && typed == nil)
                }
            }
            .onAppear { kind = draft.kind; inches = draft.inches }
        }
    }
}

// Naming a room: the usual appraisal names, or anything typed.
struct RoomSheet: View {
    let draft: RoomDraft
    let onSave: (String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    static let names = ["Bedroom", "Primary bedroom", "Bath", "2-pc bath", "3-pc bath", "4-pc bath", "Kitchen", "Living",
                        "Dining", "Family", "Laundry", "Closet", "Entry", "Hall", "Mudroom", "Office", "Utility", "Storage"]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("Room name", text: $text)
                            .textInputAutocapitalization(.sentences)
                        Button("Save") { onSave(text.trimmingCharacters(in: .whitespaces)); dismiss() }
                            .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                Section("Common") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 8) {
                        ForEach(Self.names, id: \.self) { n in
                            Button(n) { onSave(n); dismiss() }
                                .buttonStyle(.bordered)
                        }
                    }
                }
                if draft.name != nil {
                    Button("Remove name", role: .destructive) { onSave(nil); dismiss() }
                }
            }
            .navigationTitle(draft.name == nil ? "Name this room" : "Rename \(draft.name!)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onAppear { text = draft.name ?? "" }
        }
    }
}
