import ARKit
import CoreImage
import SwiftUI
import UIKit
import simd

// Photos taken mid-scan: each kept as a JPEG beside the scan, with where the
// phone stood and which way it faced, so it shows on the plan as a pin and
// can go into a report. They stay on the phone unless the scan is shared.

struct ScanPhoto: Equatable, Identifiable {
    var id: String              // file name in the scan's photo folder
    var point: SIMD3<Float>     // the phone, world metres
    var facing: SIMD2<Float>    // level direction it faced (x, z)
    var takenAt: Date
    var outside: Bool
    var fullRes: Bool           // a full camera still, not a video frame
}

extension PlanExport {
    struct PhotoOut: Codable {
        let file: String
        let point: [Double]     // x, z
        let elevation: Double
        let facing: [Double]
        let takenAt: String
        let outside: Bool
        let fullRes: Bool
    }

    static func photoOut(_ p: ScanPhoto) -> PhotoOut {
        func r(_ v: Float) -> Double { (Double(v) * 1000).rounded() / 1000 }
        return PhotoOut(file: p.id, point: [r(p.point.x), r(p.point.z)], elevation: r(p.point.y),
                        facing: [r(p.facing.x), r(p.facing.y)],
                        takenAt: ISO8601DateFormatter().string(from: p.takenAt), outside: p.outside, fullRes: p.fullRes)
    }

    static func photoIn(_ o: PhotoOut) -> ScanPhoto? {
        guard o.point.count == 2, o.facing.count == 2 else { return nil }
        return ScanPhoto(id: o.file, point: SIMD3(Float(o.point[0]), Float(o.elevation), Float(o.point[1])),
                         facing: SIMD2(Float(o.facing[0]), Float(o.facing[1])),
                         takenAt: ISO8601DateFormatter().date(from: o.takenAt) ?? Date(),
                         outside: o.outside, fullRes: o.fullRes)
    }
}

extension ScanController {
    enum PhotoResult { case saved(fullRes: Bool), failed }

    var photoDirectory: URL? {
        photoFolder.isEmpty ? nil : Self.docs.appendingPathComponent(photoFolder, isDirectory: true)
    }

    func photoURL(_ p: ScanPhoto) -> URL? { photoDirectory?.appendingPathComponent(p.id) }

    // A full-resolution still when the session allows one, else the current
    // camera frame. The frame is let go as soon as its pixels are taken, and
    // the JPEG is made off the main thread: holding frames starves tracking.
    func takePhoto(outside: Bool) async -> PhotoResult {
        var buffer: CVPixelBuffer?
        var camera: simd_float4x4?
        var full = false
        if let hr = try? await arSession.captureHighResolutionFrame() {
            buffer = hr.capturedImage; camera = hr.camera.transform; full = true
        } else if let f = arSession.currentFrame {
            buffer = f.capturedImage; camera = f.camera.transform
        }
        guard let buffer, let camera else { return .failed }
        if photoFolder.isEmpty { photoFolder = "photos-\(UUID().uuidString.prefix(8))" }
        guard let dir = photoDirectory else { return .failed }
        let name = "photo-\(photos.count + 1)-\(Int(Date().timeIntervalSince1970)).jpg"
        let url = dir.appendingPathComponent(name)
        let ok = await Task.detached(priority: .userInitiated) { () -> Bool in
            let image = CIImage(cvPixelBuffer: buffer).oriented(.right)
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let data = CIContext().jpegRepresentation(of: image, colorSpace: space,
                      options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.8])
            else { return false }
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return (try? data.write(to: url)) != nil
        }.value
        guard ok else { return .failed }
        // The camera looks down its -z axis; keep the level part.
        let f = SIMD2(-camera.columns.2.x, -camera.columns.2.z)
        photos.append(ScanPhoto(id: name, point: SIMD3(camera.columns.3.x, camera.columns.3.y, camera.columns.3.z),
                                facing: simd_length(f) > 0.01 ? simd_normalize(f) : SIMD2(0, -1),
                                takenAt: Date(), outside: outside, fullRes: full))
        photoZip = nil
        writeFiles()
        return .saved(fullRes: full)
    }

    func deletePhoto(_ p: ScanPhoto) {
        if let url = photoURL(p) { try? FileManager.default.removeItem(at: url) }
        photos.removeAll { $0.id == p.id }
        photoZip = nil
        writeFiles()
    }

    // The photo folder as one zip for sharing, made when first wanted after a
    // change (zipping on every edit would be slow).
    func zippedPhotos(named base: String) -> URL? {
        if let z = photoZip, FileManager.default.fileExists(atPath: z.path) { return z }
        guard !photos.isEmpty, let dir = photoDirectory else { return nil }
        var out: URL?
        var err: NSError?
        NSFileCoordinator().coordinate(readingItemAt: dir, options: .forUploading, error: &err) { zip in
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent("\(base) photos.zip")
            try? FileManager.default.removeItem(at: dest)
            if (try? FileManager.default.copyItem(at: zip, to: dest)) != nil { out = dest }
        }
        photoZip = out
        return out
    }
}

// Tapped a photo pin on the plan.
struct PhotoSheet: View {
    let photo: ScanPhoto
    let url: URL?
    let onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                if let url, let image = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: image).resizable().scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    ContentUnavailableView("Photo missing", systemImage: "photo")
                }
                Text("\(photo.outside ? "Outside" : "Inside") · \(photo.takenAt.formatted(date: .omitted, time: .shortened)) · \(photo.fullRes ? "full camera still" : "video frame")")
                    .font(.footnote).foregroundStyle(.secondary)
                HStack {
                    if let url { ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") } }
                    Spacer()
                    Button("Delete photo", role: .destructive) { onDelete(); dismiss() }
                }
            }
            .padding()
            .navigationTitle("Photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

// The shutter used on the scanning and outside screens.
struct PhotoButton: View {
    @ObservedObject var scan: ScanController
    let outside: Bool
    let show: (String) -> Void
    @State private var busy = false

    var body: some View {
        Button {
            busy = true
            Task {
                switch await scan.takePhoto(outside: outside) {
                case .saved(let full):
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    show("Photo \(scan.photos.count) saved\(full ? "" : " (video frame)")")
                case .failed:
                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                    show("Couldn't take a photo. Try again.")
                }
                busy = false
            }
        } label: {
            Image(systemName: "camera.fill").font(.title2).padding(12)
        }
        .buttonStyle(.borderedProminent)
        .tint(.indigo)
        .disabled(busy)
    }
}
