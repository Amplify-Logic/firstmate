import AppKit
import SwiftUI

let env = ProcessInfo.processInfo.environment
let outDir = env["NM_OUT"]!
let sandbox = env["NM_SANDBOX"]!
var logLines: [String] = []
func log(_ s: String) { print(s); fflush(stdout); logLines.append(s) }

func sleepS(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }

func axWalk(_ obj: Any, _ out: inout [(String, NSRect)]) {
    var label: String? = nil, frame = NSRect.zero, kids: [Any] = []
    if let v = obj as? NSView { label = v.accessibilityLabel(); frame = v.accessibilityFrame(); kids = v.accessibilityChildren() ?? [] }
    else if let e = obj as? NSAccessibilityElement { label = e.accessibilityLabel(); frame = e.accessibilityFrame(); kids = e.accessibilityChildren() ?? [] }
    else { return }
    if let label, !label.isEmpty { out.append((label, frame)) }
    for c in kids { axWalk(c, &out) }
}

@MainActor func elements(_ panel: NSWindow) -> [(String, NSRect)] {
    var out: [(String, NSRect)] = []
    if let v = panel.contentView { axWalk(v, &out) }
    return out
}

var closedHeight: CGFloat = 0
// Points come from FloaterView's fixed layout (6 pt padding, 12 pt arrow, 20 pt controls,
// 4 pt spacing); every click is verified by its observable effect, not assumed.
@MainActor func point(_ panel: NSWindow, _ target: String, model: FloaterModel) -> NSPoint? {
    let w = panel.frame.width, h = panel.frame.height
    switch target {
    case "arrow": return NSPoint(x: w - 12, y: h - 28)
    case "repeat": return NSPoint(x: w - 6 - 12 - 6 - 10, y: h - 6 - 10)
    case "mute": return NSPoint(x: w - 6 - 12 - 6 - 10 - 24, y: h - 6 - 34)
    default:
        guard target.hasPrefix("row:"), let id = Int(target.dropFirst(4)),
              let k = model.recent.firstIndex(where: { $0.id == id }) else { return nil }
        let n = CGFloat(model.recent.count)
        let listH = h - closedHeight - 4
        let rowH = (listH - 2 * (n - 1)) / n
        return NSPoint(x: w - 6 - 115, y: 6 + (n - 1 - CGFloat(k)) * (rowH + 2) + rowH / 2)
    }
}

@MainActor func click(_ panel: NSWindow, _ target: String, model: FloaterModel) async -> Bool {
    guard let p = point(panel, target, model: model) else { log("!! no point for \(target)"); return false }
    log("click \(target) at window point (\(Int(p.x)), \(Int(p.y)))")
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        panel.sendEvent(e)
        await sleepS(0.08)
    }
    return true
}

@MainActor func snapshot(_ panel: NSWindow, _ name: String, _ caption: String) {
    let v = panel.contentView!
    let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
    v.cacheDisplay(in: v.bounds, to: rep)
    let win = NSImage(size: v.bounds.size); win.addRepresentation(rep)
    let screen = (panel.screen ?? NSScreen.main)!
    let vis = screen.visibleFrame, full = screen.frame
    // Canvas: the right-hand strip of the screen, scaled 2x, with the off-screen area to the right shaded.
    let stripMinX = vis.maxX - 330, stripMaxX = vis.maxX + 70
    let stripTop = panel.frame.maxY + 40, stripBottom = stripTop - 320
    let scale: CGFloat = 2
    let size = NSSize(width: (stripMaxX - stripMinX) * scale, height: (stripTop - stripBottom) * scale + 40)
    let img = NSImage(size: size)
    img.lockFocus()
    NSColor(calibratedRed: 0.24, green: 0.28, blue: 0.35, alpha: 1).setFill(); NSRect(origin: .zero, size: size).fill()
    NSColor(calibratedRed: 0.9, green: 0.64, blue: 0.64, alpha: 1).setFill()
    NSRect(x: (full.maxX - stripMinX) * scale, y: 0, width: size.width, height: size.height).fill()
    NSColor.red.setFill(); NSRect(x: (full.maxX - stripMinX) * scale - 2, y: 0, width: 3, height: size.height).fill()
    let f = panel.frame
    win.draw(in: NSRect(x: (f.minX - stripMinX) * scale, y: (f.minY - stripBottom) * scale, width: f.width * scale, height: f.height * scale))
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 18, weight: .semibold), .foregroundColor: NSColor.white]
    (caption as NSString).draw(at: NSPoint(x: 12, y: size.height - 30), withAttributes: attrs)
    ("screen edge x=\(Int(full.maxX))" as NSString).draw(at: NSPoint(x: (full.maxX - stripMinX) * scale + 8, y: size.height - 60),
        withAttributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.black])
    img.unlockFocus()
    let data = NSBitmapImageRep(data: img.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
    log("snap \(name): frame=\(f) topRight=(\(f.maxX), \(f.maxY)) visibleMaxX=\(vis.maxX)")
}

func playerLog() -> String { (try? String(contentsOfFile: "\(sandbox)/player.log", encoding: .utf8)) ?? "" }
func synthCount() -> Int { ((try? String(contentsOfFile: "\(sandbox)/synth.log", encoding: .utf8)) ?? "").split(separator: "\n").count }
func resetLogs() { for f in ["player.log", "synth.log"] { FileManager.default.createFile(atPath: "\(sandbox)/\(f)", contents: Data()) } }

var failures: [String] = []
func check(_ ok: Bool, _ what: String) { log((ok ? "PASS " : "FAIL ") + what); if !ok { failures.append(what) } }

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
MainActor.assumeIsolated {
    let model = FloaterModel(repoRoot: env["FM_DESK_FLOATER_ROOT"]!, fmHome: env["FM_HOME"]!)
    let panel = FloaterPanel(model: model)
    panel.orderFrontRegardless()
    model.refreshMute()
    NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: panel, queue: .main) { _ in
        MainActor.assumeIsolated { log("  didResize -> frame=\(panel.frame)") }
    }
    Task { @MainActor in
        await sleepS(1.5)
        let vis = (panel.screen ?? NSScreen.main)!.visibleFrame
        let closed = panel.frame
        closedHeight = closed.height
        snapshot(panel, "r2-1-floater-closed", "closed at launch position")
        check(closed.maxX <= vis.maxX, "closed floater is on-screen")

        // S: open the list
        _ = await click(panel, "arrow", model: model)
        await sleepS(2.0)
        let open = panel.frame
        snapshot(panel, "r2-2-recent-list-open", "list open: top-right corner kept, list drops down-left")
        log("rows: \(model.recent.map { "\($0.id): \($0.text)" })")
        check(model.showingRecent, "list is showing")
        check(open.maxX == closed.maxX && open.maxY == closed.maxY, "top-right corner unchanged when the list opens (\(closed.maxX),\(closed.maxY)) -> (\(open.maxX),\(open.maxY))")
        check(open.maxX <= vis.maxX && open.minX >= vis.minX && open.minY >= vis.minY, "open floater fully inside the visible screen")
        check(open.width > closed.width && open.height > closed.height, "window grew to fit the list")
        check(model.recent.count == 5 && model.recent.first?.id == 5, "list shows the 5 kept replies newest first")
        guard model.recent.count >= 3 else { log("FAILURES: \(failures)"); try? logLines.joined(separator: "\n").write(toFile: "\(outDir)/r2-floater-harness-log.txt", atomically: true, encoding: .utf8); exit(1) }

        // S: pick the third one back
        resetLogs()
        let target = model.recent[2]
        let t0 = Date()
        _ = await click(panel, "row:\(target.id)", model: model)
        var started: Date? = nil
        for _ in 0..<60 { if playerLog().contains("play-start") { started = Date(); break }; await sleepS(0.05) }
        log("status=\(model.status)")
        snapshot(panel, "r2-3-after-clicking-third-reply", "clicked the 3rd reply: \(model.status)")
        await sleepS(1.5)
        log("player log:\n" + playerLog())
        check(playerLog().contains("MP3 audio of: \(target.text)"), "the chosen reply (#\(target.id)) was played")
        check(playerLog().components(separatedBy: "play-start").count == 2, "only the chosen reply was played")
        check(synthCount() == 0, "no new synthesis for the replay (synth calls: \(synthCount()))")
        if let s = started { log(String(format: "audio started %.2fs after the click", s.timeIntervalSince(t0))) }
        check(panel.frame == open, "floater did not move while replaying")

        // S: Repeat button uses kept audio
        await sleepS(2.2)
        resetLogs()
        let r0 = Date()
        _ = await click(panel, "repeat", model: model)
        var rs: Date? = nil
        for _ in 0..<80 { if playerLog().contains("play-start") { rs = Date(); break }; await sleepS(0.05) }
        await sleepS(1.3)
        log("repeat player log:\n" + playerLog())
        check(playerLog().contains("MP3 audio of: \(model.recent[0].text)"), "Repeat played the newest reply")
        check(synthCount() == 0, "Repeat did not synthesize again")
        if let s = rs { log(String(format: "Repeat audio started %.2fs after the click", s.timeIntervalSince(r0))); check(s.timeIntervalSince(r0) < 1.0, "Repeat audio starts well under the 1.5 s synthesis wait") }

        // S: a new reply arriving while the list is open shows up
        let p = Process(); p.executableURL = URL(fileURLWithPath: env["FM_DESK_FLOATER_ROOT"]! + "/bin/fm-speak.sh")
        p.arguments = ["The release branch is cut."]; try? p.run(); p.waitUntilExit()
        await sleepS(11)
        log("rows after new reply: \(model.recent.map { "\($0.id): \($0.text)" })")
        check(model.recent.first?.text == "The release branch is cut.", "a reply that arrives while the list is open appears at the top within the refresh")
        check(panel.frame.maxX == closed.maxX && panel.frame.maxY == closed.maxY, "top-right still fixed after the list grew")
        snapshot(panel, "r2-4-new-reply-appears", "new reply arrived while list open")

        // Adversarial: a reply pruned after the list was read
        await sleepS(2.5)
        let gone = model.recent.last!
        try? FileManager.default.removeItem(atPath: env["FM_HOME"]! + "/state/speak-history/\(gone.id)")
        resetLogs()
        _ = await click(panel, "row:\(gone.id)", model: model)
        await sleepS(1.0)
        log("status after clicking pruned reply: \(model.status)")
        check(model.status == "No longer kept", "a pruned reply reports 'No longer kept'")
        check(!playerLog().contains("play-start"), "nothing plays for a pruned reply")

        // Adversarial: muted
        await sleepS(2.5)
        _ = await click(panel, "mute", model: model)
        await sleepS(2.6)
        check(model.muted, "mute button muted the voice")
        resetLogs()
        _ = await click(panel, "row:\(model.recent[0].id)", model: model)
        await sleepS(0.3)
        log("status after clicking while muted: \(model.status)")
        check(model.status == "Voice muted", "muted: clicking a reply says 'Voice muted'")
        check(!playerLog().contains("play-start"), "muted: nothing plays")
        await sleepS(1.5)
        _ = await click(panel, "mute", model: model)
        await sleepS(2.6)
        check(!model.muted, "mute button unmuted again")

        // S: close the list
        _ = await click(panel, "arrow", model: model)
        await sleepS(1.0)
        snapshot(panel, "r2-5-list-closed-again", "list closed: back to original frame")
        check(panel.frame == closed, "closing the list restores the original frame \(closed) (now \(panel.frame))")
        check(!model.showingRecent, "list is hidden")

        // Adversarial: empty history
        try? FileManager.default.removeItem(atPath: env["FM_HOME"]! + "/state/speak-history")
        _ = await click(panel, "arrow", model: model)
        await sleepS(1.5)
        snapshot(panel, "r2-6-empty-history", "empty history")
        check(model.recent.isEmpty, "empty history shows no rows")
        check(panel.frame.maxX == closed.maxX && panel.frame.maxY == closed.maxY, "empty list keeps the top-right corner")
        check(panel.frame.maxX <= vis.maxX, "empty list on-screen")
        _ = await click(panel, "arrow", model: model)
        await sleepS(0.8)

        log(failures.isEmpty ? "ALL CHECKS PASSED" : "FAILURES: \(failures)")
        try? logLines.joined(separator: "\n").write(toFile: "\(outDir)/r2-floater-harness-log.txt", atomically: true, encoding: .utf8)
        exit(failures.isEmpty ? 0 : 1)
    }
}
app.run()
