import SwiftUI
import RoomPlan
import UIKit
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var scan = ScanController()
    @State private var picking = false
    @State private var resuming = false
    @State private var measuring = false
    @State private var askReading = false

    // After Build floor plan: what still needs doing before leaving the site.
    private var buildAdvice: String {
        var lines: [String] = []
        if !scan.hasReadings {
            lines.append("Laser the longest outside wall from inside, face to face, and enter it. Without one, nothing checks the scan's size.")
        }
        let gaps = scan.planGeometry.openGaps.count
        if gaps > 0 {
            lines.append("\(gaps == 1 ? "1 wall" : "\(gaps) walls") the scan couldn't see, often a closet back, \(gaps == 1 ? "is" : "are") shown in red. Fix them while you're here.")
        }
        return lines.joined(separator: "\n\n")
    }

    var body: some View {
        NavigationStack {
            List {
                if !ScanController.isSupported {
                    Text("This device has no LiDAR scanner. Use an iPhone or iPad Pro with LiDAR.")
                        .foregroundStyle(.red)
                }
                Section(scan.loadedFromFile ? "Opened scan" : "Rooms scanned") {
                    if scan.loadedFromFile {
                        if scan.canResume {
                            Button("Resume on site", systemImage: "location.viewfinder") { resuming = true }
                                .font(.headline)
                            Text("Back at the property? Resume to add rooms or walk outside; everything lines up with this scan.")
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Viewing a saved plan. It was saved before resuming was added, so it can be measured and shared but not extended.")
                                .foregroundStyle(.secondary)
                        }
                    } else if scan.rooms.isEmpty {
                        Text("None yet. Scan each room, walking slowly along the walls.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(scan.rooms.enumerated()), id: \.offset) { i, room in
                        Text("Room \(i + 1): \(count(room.walls.count, "wall")), \(count(room.doors.count, "door")), \(count(room.windows.count, "window"))")
                    }
                    if !scan.corners.isEmpty {
                        Text("\(count(scan.corners.count, "corner")) marked")
                            .foregroundStyle(.secondary)
                    }
                    if !scan.wallPoints.isEmpty {
                        Text("\(count(scan.wallPoints.count, "hidden-wall point")) marked")
                            .foregroundStyle(.secondary)
                    }
                    let outsideWalls = scan.exteriorWalls.filter { $0.count >= 2 }.count
                    if outsideWalls > 0 {
                        Text("Outside: \(count(outsideWalls, "wall")) marked" + (scan.anchorEnd != nil ? ", loop closed" : ""))
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    Button("Scan a room", systemImage: "camera.viewfinder") { scan.startRoom() }
                        .disabled(!ScanController.isSupported || scan.isBusy)
                    Button("Remove last room", systemImage: "arrow.uturn.backward", role: .destructive) {
                        scan.removeLastRoom()
                    }
                    .disabled(scan.rooms.isEmpty || scan.isBusy)
                    Button("Go outside", systemImage: "house") { scan.isOutside = true }
                        .disabled(scan.rooms.isEmpty || scan.isBusy || scan.loadedFromFile || scan.anchorEnd != nil)
                    Button("Build floor plan", systemImage: "square.split.bottomrightquarter") {
                        Task {
                            await scan.export()
                            // The importer needs a tape reading to check the scan against.
                            if scan.structure != nil && (!scan.hasReadings || !scan.planGeometry.openGaps.isEmpty) {
                                askReading = true
                            }
                        }
                    }
                    .disabled(scan.rooms.isEmpty || scan.isBusy)
                    if scan.structure != nil {
                        Button {
                            measuring = true
                        } label: {
                            Label(!scan.hasReadings
                                  ? "Measure walls"
                                  : "Measure walls (\(scan.measurements.count + scan.spans.count) entered)",
                                  systemImage: "ruler")
                        }
                        if !scan.hasReadings {
                            Text("No laser reading yet. Enter at least one so the plan can be checked.")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        }
                        let gaps = scan.planGeometry.openGaps.count
                        if gaps > 0 {
                            Text("\(gaps == 1 ? "1 wall is" : "\(gaps) walls are") missing, shown in red on Measure walls. Tap one to see how to fill it.")
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                    }
                    if !scan.exportURLs.isEmpty {
                        ShareLink(items: scan.exportURLs) {
                            Label("Share scan files", systemImage: "square.and.arrow.up")
                        }
                    }
                }
                if let message = scan.message {
                    Text(message).foregroundStyle(.secondary)
                }
                if !scan.savedScans.isEmpty {
                    Section {
                        ForEach(scan.savedScans, id: \.self) { stamp in
                            Button {
                                scan.load(stamp: stamp)
                            } label: {
                                Label(ScanController.title(for: stamp), systemImage: "doc.text")
                            }
                            .disabled(scan.isBusy)
                        }
                        .onDelete { offsets in
                            for i in offsets { scan.deleteSaved(scan.savedScans[i]) }
                        }
                    } header: {
                        Text("Saved scans")
                    }
                }
                Section {
                } footer: {
                    Text("CValRScan \(ScanController.appVersion) · scan format \(PlanExport.Plan.formatVersion)")
                        .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("CValRScan")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("New") { scan.newScan() }
                        .disabled(scan.isBusy || (scan.rooms.isEmpty && !scan.loadedFromFile))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Open…") { picking = true }
                }
            }
            .fileImporter(isPresented: $picking, allowedContentTypes: [.json]) { result in
                if case .success(let url) = result { scan.importScan(from: url) }
            }
            .navigationDestination(isPresented: $measuring) {
                PlanView(scan: scan)
            }
            .alert(!scan.hasReadings ? "Enter a laser reading" : "Walls missing", isPresented: $askReading) {
                Button("Measure now") { measuring = true }
                Button("Later", role: .cancel) {}
            } message: {
                Text(buildAdvice)
            }
            .fullScreenCover(isPresented: $scan.isOutside) {
                ExteriorView(scan: scan)
            }
            .fullScreenCover(isPresented: $resuming) {
                ResumeView(scan: scan)
            }
            .overlay { if scan.isBusy && !scan.isScanning { ProgressView() } }
        }
        .fullScreenCover(isPresented: $scan.isScanning) {
            ScanningView(scan: scan)
        }
    }
}

struct ScanningView: View {
    @ObservedObject var scan: ScanController
    @State private var flash: String?

    var body: some View {
        ZStack {
            CaptureViewContainer(view: scan.captureView).ignoresSafeArea()
            MarkedPointsOverlay(session: scan.arSession, points: scan.wallPoints.map(\.point), colour: .brown)
                .ignoresSafeArea()
            // Crosshair for Mark wall: the wall under it is recorded.
            Image(systemName: "plus")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.white)
                .shadow(color: .black, radius: 2)
                .allowsHitTesting(false)
            VStack {
                HStack {
                    Spacer()
                    Button {
                        scan.setTorch(!scan.torchOn)
                    } label: {
                        Image(systemName: scan.torchOn ? "flashlight.on.fill" : "flashlight.off.fill")
                            .font(.title2)
                            .padding(12)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(scan.torchOn ? .yellow : .gray)
                }
                .padding()
                if let flash {
                    Text(flash)
                        .padding(8)
                        .background(.thinMaterial, in: Capsule())
                }
                Spacer()
                Text("Wall hidden by coats or shelves? Aim at any bare spot on it and tap Mark wall. One point per hidden wall.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .padding(8)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal)
                HStack {
                    Button("Cancel", role: .cancel) { scan.cancelRoom() }
                        .buttonStyle(.bordered)
                    Spacer()
                    Button {
                        switch scan.markWallPoint() {
                        case .marked(let feet):
                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                            show(String(format: "Wall point %d marked, %.1f ft away", scan.wallPoints.count, feet), seconds: 3)
                        case .notWall:
                            UINotificationFeedbackGenerator().notificationOccurred(.error)
                            show("That's not a wall. Aim at the wall itself, not the floor, ceiling or a shelf.", seconds: 3)
                        case .noSurface:
                            UINotificationFeedbackGenerator().notificationOccurred(.error)
                            show("Nothing under the crosshair. Move closer.", seconds: 3)
                        }
                    } label: {
                        Label(scan.wallPoints.isEmpty ? "Mark wall" : "Mark wall (\(scan.wallPoints.count))",
                              systemImage: "scope")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.brown)
                    Spacer()
                    Button(scan.isBusy ? "Processing…" : "Done with room") { scan.finishRoom() }
                        .buttonStyle(.borderedProminent)
                        .disabled(scan.isBusy)
                }
                .padding(.horizontal)
                .padding(.top, 4)
                if !scan.wallPoints.isEmpty {
                    Button("Undo last wall point", systemImage: "arrow.uturn.backward") {
                        scan.undoWallPoint()
                        show("Wall point removed")
                    }
                    .font(.footnote)
                    .buttonStyle(.bordered)
                }
                Color.clear.frame(height: 8)
            }
        }
    }

    private func show(_ text: String, seconds: Double = 1.5) {
        flash = text
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            if flash == text { flash = nil }
        }
    }
}

private func count(_ n: Int, _ noun: String) -> String {
    "\(n) \(noun)\(n == 1 ? "" : "s")"
}

struct CaptureViewContainer: UIViewRepresentable {
    let view: RoomCaptureView
    func makeUIView(context: Context) -> RoomCaptureView { view }
    func updateUIView(_ uiView: RoomCaptureView, context: Context) {}
}
