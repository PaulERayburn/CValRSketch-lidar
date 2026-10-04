import SwiftUI
import RoomPlan
import UIKit
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var scan = ScanController()
    @State private var picking = false
    @State private var resuming = false

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
                        Task { await scan.export() }
                    }
                    .disabled(scan.rooms.isEmpty || scan.isBusy)
                    if scan.structure != nil {
                        NavigationLink {
                            PlanView(scan: scan)
                        } label: {
                            Label(scan.measurements.isEmpty
                                  ? "Measure walls"
                                  : "Measure walls (\(scan.measurements.count) entered)",
                                  systemImage: "ruler")
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
                    Section("Saved scans") {
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
                    }
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
            // Crosshair for Mark corner: the LiDAR point under it is recorded.
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
                HStack {
                    Button("Cancel", role: .cancel) { scan.cancelRoom() }
                        .buttonStyle(.bordered)
                    Spacer()
                    Button {
                        let ok = scan.markCorner()
                        UINotificationFeedbackGenerator().notificationOccurred(ok ? .success : .error)
                        show(ok ? "Corner \(scan.corners.count) marked" : "No surface under the crosshair")
                    } label: {
                        Label("Mark corner", systemImage: "scope")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .contextMenu {
                        Button("Undo last corner", role: .destructive) { scan.undoCorner() }
                    }
                    Spacer()
                    Button(scan.isBusy ? "Processing…" : "Done with room") { scan.finishRoom() }
                        .buttonStyle(.borderedProminent)
                        .disabled(scan.isBusy)
                }
                .padding()
            }
        }
    }

    private func show(_ text: String) {
        flash = text
        Task {
            try? await Task.sleep(for: .seconds(1.5))
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
