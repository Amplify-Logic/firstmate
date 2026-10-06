import AppKit
// Mirrors HotkeyMonitor.handle + shotTapped (secure input is off in this replay).
var key = TapKey.rightShift
let name = CommandLine.arguments[1]
play(name) { e in
    let at = TapKey.time(of: e)
    if e.type != .flagsChanged { if e.type == .keyDown { key.keyPressed(at: at) } else { key.chord() }; return }
    if key.update(keyCode: e.keyCode, flags: e.modifierFlags, at: at, allowed: [], limit: 0.5) {
        Timer.scheduledTimer(withTimeInterval: key.settle, repeats: false) { _ in
            if key.takeSettled(tap: at) { shots.append(Date().timeIntervalSince(t0)) }
        }
    }
}
