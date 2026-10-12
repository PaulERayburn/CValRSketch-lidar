import AVFoundation
import AudioToolbox
import MediaPlayer
import SwiftUI
import UIKit

// A Bluetooth selfie-stick remote presses volume up, so a press of either
// volume button calls `onPress` while this is on screen. iOS has no API for
// the buttons themselves: the system volume is watched instead, an
// invisible volume view keeps the volume bar from showing, and the volume is
// put back after each press so the next one registers too (at full volume a
// volume-up press would change nothing and go unseen).
struct VolumeButtonCatcher: UIViewRepresentable {
    let onPress: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MPVolumeView {
        // Present and not hidden, or iOS shows its own volume bar; just too faint to see.
        let view = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        view.alpha = 0.01
        view.isUserInteractionEnabled = false
        context.coordinator.onPress = onPress
        context.coordinator.start(view)
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) { context.coordinator.onPress = onPress }

    static func dismantleUIView(_ uiView: MPVolumeView, coordinator: Coordinator) { coordinator.stop() }

    @MainActor
    final class Coordinator {
        var onPress: (() -> Void)?
        private weak var view: MPVolumeView?
        private var observation: NSKeyValueObservation?
        private var level: Float = 0.5
        private var original: Float?
        private var lastPress = Date.distantPast

        func start(_ view: MPVolumeView) {
            self.view = view
            let audio = AVAudioSession.sharedInstance()
            // Ambient and mixed, so music or a call playing isn't interrupted;
            // the session has to be active for volume changes to be reported.
            try? audio.setCategory(.ambient, options: [.mixWithOthers])
            try? audio.setActive(true)
            let now = audio.outputVolume
            original = now
            level = min(max(now, 1 / 16), 15 / 16)
            if level != now { setVolume(level) }
            observation = audio.observe(\.outputVolume, options: [.new]) { [weak self] _, change in
                guard let v = change.newValue else { return }
                Task { @MainActor in self?.changed(to: v) }
            }
        }

        func stop() {
            observation?.invalidate()
            observation = nil
            if let original, original != level { setVolume(original) }
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }

        private func changed(to v: Float) {
            // Our own reset, not a press.
            guard abs(v - level) > 0.001 else { return }
            setVolume(level)
            // Holding a button repeats; one mark per press.
            guard Date().timeIntervalSince(lastPress) > 0.4 else { return }
            lastPress = Date()
            onPress?()
        }

        private func setVolume(_ v: Float) {
            // The slider only takes a new value once the volume change is done.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak view = self.view] in
                view?.subviews.compactMap { $0 as? UISlider }.first?.value = v
            }
        }
    }
}
