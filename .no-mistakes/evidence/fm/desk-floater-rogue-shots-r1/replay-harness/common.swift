import AppKit
// One step of a recorded timeline: at `t` seconds, a key (keyDown) or a
// Right Shift flagsChanged (down/up).
enum Step { case key(Character), shiftDown, shiftUp }
let rightShiftDown = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.shift.rawValue | 0x04)
func makeEvent(_ s: Step) -> NSEvent {
    let ts = ProcessInfo.processInfo.systemUptime
    switch s {
    case .key(let c):
        return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ts, windowNumber: 0,
                                context: nil, characters: String(c), charactersIgnoringModifiers: String(c), isARepeat: false, keyCode: 0)!
    case .shiftDown:
        return NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: rightShiftDown, timestamp: ts, windowNumber: 0,
                                context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 60)!
    case .shiftUp:
        return NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: [], timestamp: ts, windowNumber: 0,
                                context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 60)!
    }
}
func timeline(_ name: String) -> [(Double, Step)] {
    var out: [(Double, Step)] = []
    switch name {
    case "incident":
        // "How could this shape" typed at 150 ms a key, Right Shift brushed
        // twice 140 ms apart, then "?" and Return (6 Oct 2026, 17:51:04-05).
        let text = Array("How could this shape")
        for (i, c) in text.enumerated() { out.append((Double(i) * 0.15, .key(c))) }
        let last = Double(text.count - 1) * 0.15
        out += [(last + 0.30, .shiftDown), (last + 0.36, .shiftUp),
                (last + 0.44, .shiftDown), (last + 0.50, .shiftUp),
                (last + 0.62, .key("?")), (last + 0.80, .key("\r"))]
    case "pause-then-brush":
        // Typing, a 3 s pause (past the quiet window), a brush, then "?" right after.
        out += [(0, .key("a")), (0.15, .key("b")), (3.15, .shiftDown), (3.20, .shiftUp), (3.35, .key("?"))]
    case "deliberate":
        // Typing, then 3 s later a deliberate lone tap with nothing after it.
        out += [(0, .key("x")), (3.0, .shiftDown), (3.12, .shiftUp)]
    case "double-deliberate":
        // Away from typing, two quick taps.
        out += [(0, .shiftDown), (0.08, .shiftUp), (0.25, .shiftDown), (0.32, .shiftUp)]
    default: fatalError(name)
    }
    return out
}
var shots: [Double] = []
let t0 = Date()
func play(_ name: String, feed: @escaping (NSEvent) -> Void) {
    let steps = timeline(name)
    for (t, s) in steps {
        let wait = t - Date().timeIntervalSince(t0)
        if wait > 0 { RunLoop.main.run(until: Date().addingTimeInterval(wait)) }
        feed(makeEvent(s))
    }
    RunLoop.main.run(until: Date().addingTimeInterval(1.0))
    let shown = shots.map { String(format: "%.2fs", $0) }.joined(separator: ", ")
    print("\(name): \(shots.count) screenshot(s) taken\(shots.isEmpty ? "" : " at " + shown)")
}
