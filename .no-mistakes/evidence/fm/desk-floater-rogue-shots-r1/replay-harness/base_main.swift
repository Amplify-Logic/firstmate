import AppKit
var key = TapKey.rightShift
let name = CommandLine.arguments[1]
play(name) { e in
    if e.type != .flagsChanged { key.chord(); return }
    if key.update(e, allowed: [], limit: 0.5) { shots.append(Date().timeIntervalSince(t0)) }
}
