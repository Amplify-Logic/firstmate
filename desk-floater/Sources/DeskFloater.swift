import AppKit
import AVFoundation
import SwiftUI

@main
struct DeskFloaterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: FloaterPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let root = ProcessInfo.processInfo.environment["FM_DESK_FLOATER_ROOT"]
            ?? FileManager.default.currentDirectoryPath
        let home = ProcessInfo.processInfo.environment["FM_HOME"]
            ?? root
        let model = FloaterModel(repoRoot: root, fmHome: home)
        let panel = FloaterPanel(model: model)
        panel.orderFrontRegardless()
        self.panel = panel
    }
}

final class FloaterPanel: NSPanel {
    init(model: FloaterModel) {
        let view = FloaterView(model: model)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 72, height: 72)
        super.init(
            contentRect: hosting.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.contentView = hosting
        self.isFloatingPanel = true
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.isMovableByWindowBackground = true
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = true
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            self.setFrameOrigin(NSPoint(x: f.maxX - 100, y: f.midY))
        }
    }

    override var canBecomeKey: Bool { true }
}

@MainActor
final class FloaterModel: ObservableObject {
    enum Mode {
        case idle
        case recording
        case busy
    }

    @Published var mode: Mode = .idle
    @Published var status: String = "Hold to talk"

    let repoRoot: String
    let fmHome: String
    private var recorder: AVAudioRecorder?
    private var recordURL: URL?

    init(repoRoot: String, fmHome: String) {
        self.repoRoot = repoRoot
        self.fmHome = fmHome
    }

    func toggle() {
        switch mode {
        case .idle:
            startRecording()
        case .recording:
            stopAndDeliver()
        case .busy:
            break
        }
    }

    func pressBegan() {
        guard mode == .idle else { return }
        startRecording()
    }

    func pressEnded() {
        guard mode == .recording else { return }
        stopAndDeliver()
    }

    private func startRecording() {
        Task {
            let ok = await requestMic()
            guard ok else {
                status = "Mic denied"
                return
            }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("fm-desk-\(UUID().uuidString).wav")
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatLinearPCM),
                AVSampleRateKey: 16000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false
            ]
            do {
                let rec = try AVAudioRecorder(url: url, settings: settings)
                rec.prepareToRecord()
                guard rec.record() else {
                    status = "Record failed"
                    return
                }
                recorder = rec
                recordURL = url
                mode = .recording
                status = "Listening…"
            } catch {
                status = "Record error"
            }
        }
    }

    private func stopAndDeliver() {
        recorder?.stop()
        recorder = nil
        guard let url = recordURL else {
            mode = .idle
            status = "Hold to talk"
            return
        }
        recordURL = nil
        mode = .busy
        status = "Transcribing…"
        Task.detached(priority: .userInitiated) { [repoRoot, fmHome] in
            let transcript = Self.transcribe(repoRoot: repoRoot, fmHome: fmHome, audio: url)
            try? FileManager.default.removeItem(at: url)
            await MainActor.run {
                guard let text = transcript?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty else {
                    self.mode = .idle
                    self.status = "No speech"
                    return
                }
                self.status = "Delivering…"
            }
            let delivered = Self.deliver(repoRoot: repoRoot, fmHome: fmHome, text: transcript ?? "")
            await MainActor.run {
                self.mode = .idle
                self.status = delivered ? "Sent" : "Deliver failed"
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    if self.mode == .idle {
                        self.status = "Hold to talk"
                    }
                }
            }
        }
    }

    private func requestMic() async -> Bool {
        await withCheckedContinuation { cont in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                cont.resume(returning: granted)
            }
        }
    }

    nonisolated private static func transcribe(repoRoot: String, fmHome: String, audio: URL) -> String? {
        let bin = (repoRoot as NSString).appendingPathComponent("bin/fm-deepgram-stt.sh")
        return run(bin: bin, args: [audio.path], env: ["FM_HOME": fmHome])
    }

    nonisolated private static func deliver(repoRoot: String, fmHome: String, text: String) -> Bool {
        let bin = (repoRoot as NSString).appendingPathComponent("bin/fm-desk-voice.sh")
        return run(bin: bin, args: ["deliver", "--source", "desk-floater", text], env: ["FM_HOME": fmHome]) != nil
    }

    nonisolated private static func run(bin: String, args: [String], env: [String: String]) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bin)
        proc.arguments = args
        var environment = ProcessInfo.processInfo.environment
        for (k, v) in env { environment[k] = v }
        proc.environment = environment
        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return nil
        }
        guard proc.terminationStatus == 0 else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }
}

struct FloaterView: View {
    @ObservedObject var model: FloaterModel

    var body: some View {
        ZStack {
            Circle()
                .fill(color)
                .shadow(radius: 6)
            Image(systemName: icon)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: 72, height: 72)
        .overlay(alignment: .bottom) {
            Text(model.status)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.black.opacity(0.45), in: Capsule())
                .offset(y: 28)
        }
        .padding(24)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in model.pressBegan() }
                .onEnded { _ in model.pressEnded() }
        )
        .onTapGesture(count: 2) {
            model.toggle()
        }
        .accessibilityLabel("Desk push to talk")
    }

    private var color: Color {
        switch model.mode {
        case .idle: return Color(red: 0.12, green: 0.45, blue: 0.85)
        case .recording: return Color(red: 0.85, green: 0.20, blue: 0.20)
        case .busy: return Color(red: 0.35, green: 0.35, blue: 0.40)
        }
    }

    private var icon: String {
        switch model.mode {
        case .idle: return "mic.fill"
        case .recording: return "waveform"
        case .busy: return "hourglass"
        }
    }
}
