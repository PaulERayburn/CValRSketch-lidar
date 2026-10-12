import AVFoundation
import Combine
import Speech
import SwiftUI
import UIKit
import WebKit

// CValRSketch's mobile app (m/index.html, bundled by the "Bundle CValRSketch"
// build phase) for drawing a plan from scratch with the laser: each reading
// fills the sketch's entry, and a direction tapped or said straight after it
// adds the wall. The page itself is unchanged; this side supplies what an
// in-app web view lacks: the laser, speech recognition and the share sheet.
struct SketchView: View {
    var body: some View {
        SketchWebView()
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle("Sketch")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { LaserButton() } }
    }
}

// The laser's state in a toolbar: tap to connect or disconnect.
struct LaserButton: View {
    @ObservedObject private var laser = Laser.shared

    var body: some View {
        switch laser.status {
        case .connected:
            Button("Laser", systemImage: "dot.radiowaves.left.and.right") { laser.disconnect() }
                .labelStyle(.titleAndIcon).tint(.green)
        case .searching:
            Button { laser.disconnect() } label: { HStack(spacing: 6) { ProgressView(); Text("Laser") } }
        case .off:
            Button("Connect laser", systemImage: "dot.radiowaves.left.and.right") { laser.connect() }
                .labelStyle(.titleAndIcon)
        case .bluetoothOff, .unauthorized:
            Label("No Bluetooth", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        }
    }
}

private struct SketchWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { SketchHost.shared.web }
    func updateUIView(_ view: WKWebView, context: Context) {}
}

// One page for the app's lifetime, so leaving the Sketch screen and coming
// back keeps the sketch in progress.
@MainActor
final class SketchHost: NSObject, WKScriptMessageHandler, WKUIDelegate {
    static let shared = SketchHost()
    static let scheme = "cvalrsketch"

    let web: WKWebView
    private let speech = SketchSpeech()
    private var laserReadings: AnyCancellable?

    private override init() {
        let config = WKWebViewConfiguration()
        // A custom scheme rather than file:// gives the page a real origin, so its
        // settings and recent projects (localStorage) are kept.
        config.setURLSchemeHandler(BundleScheme(), forURLScheme: Self.scheme)
        config.userContentController.addUserScript(WKUserScript(source: Self.bridge, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        web = WKWebView(frame: .zero, configuration: config)
        // Without a UI delegate a web view answers alert() silently and confirm()
        // and prompt() with no, so Delete shape, Split and the rest did nothing.
        #if DEBUG
        web.isInspectable = true
        #endif
        super.init()
        web.uiDelegate = self
        for name in ["speech", "share"] { config.userContentController.add(self, name: name) }
        speech.send = { [weak self] js in self?.web.evaluateJavaScript(js) }
        web.load(URLRequest(url: URL(string: "\(Self.scheme)://app/m/index.html")!))
        laserReadings = Laser.shared.$reading.dropFirst().compactMap { $0 }.sink { [weak self] r in
            let entry = "\(r.inches / 12)'\(r.inches % 12)"
            self?.web.evaluateJavaScript("window.CValRLaser && CValRLaser.enter(\(Self.jsString(entry)))")
        }
    }

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        switch message.name {
        case "speech":
            if body["cmd"] as? String == "start" { speech.start() } else { speech.stop() }
        case "share":
            share(body["files"] as? [[String: String]] ?? [])
        default: break
        }
    }

    private func share(_ files: [[String: String]]) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SketchShare", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let urls: [URL] = files.compactMap { f in
            guard let name = f["name"], let b64 = f["data"], let data = Data(base64Encoded: b64) else { return nil }
            let url = dir.appendingPathComponent((name as NSString).lastPathComponent)
            return (try? data.write(to: url)) != nil ? url : nil
        }
        guard !urls.isEmpty, let top = Self.topController() else {
            web.evaluateJavaScript("window.__cvalrShareDone && __cvalrShareDone(false)")
            return
        }
        let sheet = UIActivityViewController(activityItems: urls, applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = web
        sheet.popoverPresentationController?.sourceRect = CGRect(x: web.bounds.midX, y: web.bounds.midY, width: 1, height: 1)
        sheet.completionWithItemsHandler = { [weak self] _, done, _, _ in
            self?.web.evaluateJavaScript("window.__cvalrShareDone && __cvalrShareDone(\(done))")
        }
        top.present(sheet, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        present(message) { a in a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() }) }
            ?? completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        present(message) { a in
            a.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
            a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        } ?? completionHandler(false)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        present(prompt) { a in
            a.addTextField { $0.text = defaultText; $0.clearButtonMode = .whileEditing }
            a.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(nil) })
            a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(a.textFields?.first?.text ?? "") })
        } ?? completionHandler(nil)
    }

    // Shows an alert built by `build`; nil when there's nothing to show it on.
    private func present(_ message: String, _ build: (UIAlertController) -> Void) -> Void? {
        guard let top = Self.topController() else { return nil }
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        build(alert)
        top.present(alert, animated: true)
        return ()
    }

    private static func topController() -> UIViewController? {
        var top = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?.rootViewController
        while let next = top?.presentedViewController { top = next }
        return top
    }

    static func jsString(_ s: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [s])
        return data.flatMap { String(data: $0, encoding: .utf8) }.map { String($0.dropFirst().dropLast()) } ?? "\"\""
    }

    // Injected before the page's own scripts.
    //  - CValRLaser.enter: a reading becomes the entry (or the next piece after a
    //    trailing + or −). `pending` stays set until the entry is used or edited, and a
    //    direction tapped while it is set adds the wall at once; dictation.js does
    //    the same for a spoken direction.
    //  - webkitSpeechRecognition, standing in for the browser's (not available in
    //    an app's web view) with iOS speech recognition, one final result per
    //    utterance, as dictation.js expects.
    //  - navigator.share for files, through the iOS share sheet (Save to Files,
    //    AirDrop, Mail), which the page's Save and Export already use.
    private static let bridge = #"""
    (function () {
      window.CValRLaser = {
        pending: false,
        enter(text) {
          const a = window.SketchEntryAdapter;
          if (!a) return;
          const cur = (a.getEntry() || '').trim();
          a.setEntry(/([+−]|\bplus|\bminus)$/i.test(cur) ? cur + ' ' + text : text);
          this.pending = true;
        }
      };
      document.addEventListener('click', (e) => {
        const b = e.target.closest && e.target.closest('[data-k]');
        const L = window.CValRLaser;
        if (!b || !L.pending) return;
        const k = b.dataset.k;
        if (k === 'l' || k === 'r' || k === 'u' || k === 'd') {
          L.pending = false;
          setTimeout(() => window.SketchEntryAdapter && SketchEntryAdapter.commit(), 0);
        } else if (k !== '+' && k !== '-') {
          L.pending = false;
        }
      }, true);

      const post = (name, msg) => window.webkit.messageHandlers[name].postMessage(msg);

      class NativeSpeech {
        constructor() { this.continuous = false; this.interimResults = false; this.lang = 'en-US'; }
        start() { window.__cvalrSpeechTarget = this; post('speech', { cmd: 'start' }); }
        stop() { post('speech', { cmd: 'stop' }); }
        abort() { this.stop(); }
      }
      window.SpeechRecognition = undefined;
      window.webkitSpeechRecognition = NativeSpeech;
      window.__cvalrSpeech = {
        started() { const r = window.__cvalrSpeechTarget; r && r.onstart && r.onstart(); },
        result(t) {
          const r = window.__cvalrSpeechTarget;
          if (!r || !r.onresult) return;
          const res = [{ transcript: t, confidence: 1 }];
          res.isFinal = true;
          r.onresult({ resultIndex: 0, results: [res] });
        },
        error(code) { const r = window.__cvalrSpeechTarget; r && r.onerror && r.onerror({ error: code }); },
        ended() { const r = window.__cvalrSpeechTarget; r && r.onend && r.onend(); }
      };

      const read = (f) => new Promise((res, rej) => {
        const r = new FileReader();
        r.onload = () => res({ name: f.name, data: String(r.result).split(',')[1] || '' });
        r.onerror = rej;
        r.readAsDataURL(f);
      });
      Object.defineProperty(navigator, 'canShare', { configurable: true, value: (d) => !!(d && d.files && d.files.length) });
      Object.defineProperty(navigator, 'share', { configurable: true, value: async (d) => {
        const files = await Promise.all(((d && d.files) || []).map(read));
        await new Promise((resolve, reject) => {
          window.__cvalrShareDone = (ok) => ok ? resolve() : reject(new DOMException('Share cancelled', 'AbortError'));
          post('share', { files });
        });
      }});
    })();
    """#
}

// Serves the bundled sketch app: cvalrsketch://app/<path> is Sketch/<path> in
// the app bundle. Query strings (the page's ?v= cache busters) are ignored.
private final class BundleScheme: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url,
              let root = Bundle.main.resourceURL?.appendingPathComponent("Sketch", isDirectory: true) else { return }
        let file = root.appendingPathComponent(String(url.path.drop(while: { $0 == "/" }))).standardizedFileURL
        guard file.path.hasPrefix(root.standardizedFileURL.path), let data = try? Data(contentsOf: file) else {
            task.didReceive(HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!)
            task.didFinish()
            return
        }
        let types = ["html": "text/html", "js": "text/javascript", "mjs": "text/javascript", "css": "text/css",
                     "svg": "image/svg+xml", "png": "image/png", "json": "application/json",
                     "webmanifest": "application/manifest+json"]
        let type = types[file.pathExtension.lowercased()] ?? "application/octet-stream"
        task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                        headerFields: ["Content-Type": type, "Content-Length": "\(data.count)"])!)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

// iOS speech recognition behaving like the browser's continuous mode: it
// listens until stopped and hands over each utterance once there is a pause.
// On-device where the phone supports it, so it works without signal.
@MainActor
final class SketchSpeech {
    var send: (String) -> Void = { _ in }

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    // Read on the audio thread: the tap appends to whichever request is current.
    nonisolated(unsafe) private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var generation = 0
    private var heard = ""
    private var pause: Timer?
    private var failures: [Date] = []
    private var running = false

    func start() {
        SFSpeechRecognizer.requestAuthorization { status in
            AVAudioApplication.requestRecordPermission { mic in
                Task { @MainActor in
                    guard status == .authorized, mic else { self.fail("not-allowed"); return }
                    self.begin()
                }
            }
        }
    }

    func stop() {
        guard running else { send("__cvalrSpeech.ended()"); return }
        running = false
        finishUtterance(restart: false)
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        send("__cvalrSpeech.ended()")
    }

    private func begin() {
        guard !running else { return }
        guard let recognizer, recognizer.isAvailable else { fail("network"); return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            let input = engine.inputNode
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { [weak self] buffer, _ in
                self?.request?.append(buffer)
            }
            engine.prepare()
            try engine.start()
        } catch {
            fail("audio-capture")
            return
        }
        running = true
        newUtterance()
        send("__cvalrSpeech.started()")
    }

    private func newUtterance() {
        guard running, let recognizer else { return }
        generation += 1
        let mine = generation
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        req.addsPunctuation = false
        request = req
        heard = ""
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            Task { @MainActor in
                guard let self, mine == self.generation else { return }
                if let result {
                    self.heard = result.bestTranscription.formattedString
                    self.pause?.invalidate()
                    if result.isFinal { self.finishUtterance(restart: true); return }
                    self.pause = Timer.scheduledTimer(withTimeInterval: 0.9, repeats: false) { _ in
                        Task { @MainActor in if mine == self.generation { self.finishUtterance(restart: true) } }
                    }
                } else if error != nil {
                    // A recognition task gives up after a long silence; start another,
                    // unless it keeps failing.
                    let now = Date()
                    self.failures = self.failures.filter { now.timeIntervalSince($0) < 10 } + [now]
                    if self.failures.count > 5 { self.fail("network"); self.stop() } else { self.newUtterance() }
                }
            }
        }
    }

    private func finishUtterance(restart: Bool) {
        pause?.invalidate()
        generation += 1
        task?.cancel()
        task = nil
        request = nil
        let said = heard.trimmingCharacters(in: .whitespaces)
        heard = ""
        if !said.isEmpty { send("__cvalrSpeech.result(\(SketchHost.jsString(said)))") }
        if restart { newUtterance() }
    }

    private func fail(_ code: String) {
        send("__cvalrSpeech.error('\(code)')")
        if !running { send("__cvalrSpeech.ended()") }
    }
}
