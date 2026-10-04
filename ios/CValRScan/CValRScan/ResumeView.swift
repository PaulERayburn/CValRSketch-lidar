import SwiftUI
import UIKit

// Shown while the phone matches what the camera sees against the saved scan.
struct ResumeView: View {
    @ObservedObject var scan: ScanController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            SessionView(session: scan.arSession).ignoresSafeArea()
            VStack {
                Text("Stand in a room you scanned before and slowly look around its walls and corners until the phone recognises it.")
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .padding(10)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .padding()
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Locating…")
                }
                .padding(8)
                .background(.thinMaterial, in: Capsule())
                Spacer()
                Button("Cancel", role: .cancel) {
                    scan.cancelResume()
                    dismiss()
                }
                .buttonStyle(.bordered)
                .padding()
            }
        }
        .task {
            scan.startResume()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                if scan.checkRelocalized() {
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    dismiss()
                    return
                }
            }
        }
    }
}
