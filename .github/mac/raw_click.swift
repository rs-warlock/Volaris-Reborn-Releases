// raw_click.swift <x> <y> : a real left click at a screen point (CGEvent mouse move, down, up), as a player's mouse makes.
// System Events' "click at" presses the accessibility element at that point instead: the launcher v2 window paints its
// own buttons, so that press reached nothing and the window saw no mouse event at all (2026-10-29).
import CoreGraphics
import Foundation

let args = CommandLine.arguments
guard args.count >= 3, let x = Double(args[1]), let y = Double(args[2]) else {
    print("usage: raw_click.swift <x> <y>")
    exit(2)
}
let point = CGPoint(x: x, y: y)
let source = CGEventSource(stateID: .hidSystemState)
CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
usleep(250_000)
CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
usleep(90_000)
CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
print("raw-click \(x),\(y)")
