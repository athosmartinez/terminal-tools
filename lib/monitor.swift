// monitor.swift — turn external displays off/on without unplugging the cable.
// macOS stops driving the display, but the USB-C link stays up, so a monitor
// with USB-C Power Delivery keeps charging the Mac.
//
// Built and run by the `monitor` wrapper; see `monitor -h`.

import CoreGraphics
import Foundation

// CGSConfigureDisplayEnabled is private (no public header). Resolved with dlsym
// so a macOS release that removes it fails with a clear message instead of a
// link error.
typealias ConfigureEnabledFn = @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> CGError

// A disabled display drops out of the active list, so its id is remembered here
// for `on`. The online list is checked too, as a fallback.
let stateFile = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".config/terminal-tools/monitor-disabled")

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(1)
}

func loadConfigureEnabled() -> ConfigureEnabledFn {
    guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW),
          let sym = dlsym(handle, "CGSConfigureDisplayEnabled") else {
        fail("monitor: CGSConfigureDisplayEnabled is not available on this macOS version")
    }
    return unsafeBitCast(sym, to: ConfigureEnabledFn.self)
}

func displays(online: Bool) -> [CGDirectDisplayID] {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    var count: UInt32 = 0
    let err = online
        ? CGGetOnlineDisplayList(16, &ids, &count)
        : CGGetActiveDisplayList(16, &ids, &count)
    guard err == .success else { fail("monitor: cannot list displays (CGError \(err.rawValue))") }
    return Array(ids.prefix(Int(count)))
}

func isBuiltin(_ id: CGDirectDisplayID) -> Bool { CGDisplayIsBuiltin(id) != 0 }

func setEnabled(_ id: CGDirectDisplayID, _ enabled: Bool) {
    let configure = loadConfigureEnabled()
    var config: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&config) == .success else {
        fail("monitor: cannot begin display configuration")
    }
    let err = configure(config, id, enabled)
    guard err == .success else {
        CGCancelDisplayConfiguration(config)
        fail("monitor: cannot change display \(id) (CGError \(err.rawValue))")
    }
    guard CGCompleteDisplayConfiguration(config, .permanently) == .success else {
        fail("monitor: cannot apply display configuration")
    }
}

func saveDisabled(_ ids: [CGDirectDisplayID]) {
    try? FileManager.default.createDirectory(at: stateFile.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
    try? ids.map(String.init).joined(separator: "\n")
        .write(to: stateFile, atomically: true, encoding: .utf8)
}

func loadDisabled() -> [CGDirectDisplayID] {
    guard let text = try? String(contentsOf: stateFile, encoding: .utf8) else { return [] }
    return text.split(separator: "\n").compactMap { CGDirectDisplayID($0) }
}

let active = displays(online: false)
let externals = active.filter { !isBuiltin($0) }

switch CommandLine.arguments.dropFirst().first {
case "off":
    // With the lid closed the built-in panel is inactive; disabling the
    // external one too would leave the Mac with no screen at all.
    guard active.contains(where: isBuiltin) else {
        fail("monitor: built-in display is inactive (lid closed?) — refusing to leave no screen")
    }
    guard !externals.isEmpty else { fail("monitor: no active external display") }
    saveDisabled(externals)
    externals.forEach { setEnabled($0, false) }
    print("external display off — USB-C charging continues; run 'monitor on' to restore")

case "on":
    let online = displays(online: true)
    let candidates = Set(loadDisabled() + online.filter { !isBuiltin($0) && !active.contains($0) })
    guard !candidates.isEmpty else { fail("monitor: no disabled external display to restore") }
    candidates.forEach { setEnabled($0, true) }
    saveDisabled([])
    print("external display on")

case "status", nil:
    print(externals.isEmpty ? "external display: off (or not connected)" : "external display: on")

default:
    fail("usage: monitor [on|off|status]")
}
