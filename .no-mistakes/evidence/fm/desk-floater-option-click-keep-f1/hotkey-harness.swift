import AppKit
import ApplicationServices
import XCTest
@testable import DeskFloater

// Scratch live-validation harness (not committed): drives the real HotkeyMonitor
// through AppKit's local event monitor with synthesized NSEvents posted to this
// process only, and records which push-to-talk callbacks fire.
@MainActor
final class ZZHotkeyHarnessTests: XCTestCase {
    private var log: [String] = []
    private var monitor: HotkeyMonitor!
    private var base: TimeInterval = 0

    override func setUp() async throws {
        try XCTSkipUnless(AXIsProcessTrusted(), "needs Accessibility trust")
        _ = NSApplication.shared
        NSApp.finishLaunching()
        log = []
        monitor = HotkeyMonitor()
        monitor.onTalkDown = { [unowned self] in log.append("talkDown") }
        monitor.onTalkUp = { [unowned self] in log.append("talkUp(deliver)") }
        monitor.onTalkChord = { [unowned self] in log.append("talkChord(cancel)") }
        monitor.onDictateTap = { [unowned self] in log.append("dictate") }
        monitor.onShotTap = { [unowned self] in log.append("shot") }
        monitor.start()
        pump()
        base = ProcessInfo.processInfo.systemUptime
    }

    override func tearDown() async throws {
        monitor = nil
    }

    private func pump() {
        while let e = NSApp.nextEvent(matching: .any, until: Date(timeIntervalSinceNow: 0.05),
                                      inMode: .default, dequeue: true) {
            NSApp.sendEvent(e)
        }
    }

    private func flags(_ down: Bool, at t: TimeInterval) -> NSEvent {
        let f: NSEvent.ModifierFlags = down ? [.option, NSEvent.ModifierFlags(rawValue: 0x40)] : []
        return NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: f,
                                timestamp: base + t, windowNumber: 0, context: nil,
                                characters: "", charactersIgnoringModifiers: "",
                                isARepeat: false, keyCode: 61)!
    }

    private func key(_ chars: String, code: UInt16, at t: TimeInterval) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.option],
                         timestamp: base + t, windowNumber: 0, context: nil,
                         characters: chars, charactersIgnoringModifiers: chars,
                         isARepeat: false, keyCode: code)!
    }

    private func click(_ type: NSEvent.EventType, at t: TimeInterval) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: NSPoint(x: 10, y: 10), modifierFlags: [.option],
                           timestamp: base + t, windowNumber: 0, context: nil,
                           eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    private func drive(_ name: String, _ events: [NSEvent]) -> [String] {
        log = []
        for e in events { NSApp.postEvent(e, atStart: false) }
        pump()
        print("HARNESS \(name): \(log)")
        return log
    }

    func testA_ClickThatOpensMenuMidHoldKeepsRecordingAndReleaseDelivers() {
        let got = drive("left click at 4s, right click at 6s, Escape at 8s, release at 30s", [
            flags(true, at: 0), click(.leftMouseDown, at: 4), click(.rightMouseDown, at: 6),
            key("\u{1b}", code: 53, at: 8), flags(false, at: 30)
        ])
        XCTAssertEqual(got, ["talkDown", "talkUp(deliver)"])
    }

    func testB_QuickOptionLetterCancelsWithoutDelivering() {
        let got = drive("Option-e at 0.1s, release at 0.2s", [
            flags(true, at: 0), key("´", code: 14, at: 0.1), flags(false, at: 0.2)
        ])
        XCTAssertEqual(got, ["talkDown", "talkChord(cancel)"])
    }

    func testC_QuickOptionClickCancelsWithoutDelivering() {
        let got = drive("Option-click at 0.29s, second click 0.4s, release at 1s", [
            flags(true, at: 0), click(.leftMouseDown, at: 0.29), click(.leftMouseDown, at: 0.4),
            flags(false, at: 1)
        ])
        XCTAssertEqual(got, ["talkDown", "talkChord(cancel)"])
    }

    func testD_ClickJustPastWindowKeeps() {
        let got = drive("click at 0.31s, release at 2s", [
            flags(true, at: 0), click(.leftMouseDown, at: 0.31), flags(false, at: 2)
        ])
        XCTAssertEqual(got, ["talkDown", "talkUp(deliver)"])
    }

    func testE_NextHoldGetsFreshWindow() {
        let got = drive("hold 0-5s with click at 3s, new hold at 10s with Option-letter at 10.1s, release 10.2s", [
            flags(true, at: 0), click(.leftMouseDown, at: 3), flags(false, at: 5),
            flags(true, at: 10), key("å", code: 0, at: 10.1), flags(false, at: 10.2)
        ])
        XCTAssertEqual(got, ["talkDown", "talkUp(deliver)", "talkDown", "talkChord(cancel)"])
    }
}
