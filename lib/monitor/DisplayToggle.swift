// DisplayToggle.swift — turn external displays off/on without unplugging the cable.
// macOS stops driving the display, but the USB-C link stays up, so a monitor
// with USB-C Power Delivery keeps charging the Mac.
//
// Shared by the `monitor` CLI (cli/main.swift) and the menu bar app
// (app/main.swift); both read and write the same state file.

import CoreGraphics
import Foundation

enum DisplayState { case on, off, absent }

struct DisplayToggleError: Error, CustomStringConvertible {
    let description: String
}

enum DisplayToggle {
    // CGSConfigureDisplayEnabled is private (no public header). Resolved with
    // dlsym so a macOS release that removes it fails with a clear message
    // instead of a link error.
    private typealias ConfigureEnabledFn = @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> CGError

    // A disabled display drops out of the active list, so its id is remembered
    // here for `on`. The online list is checked too, as a fallback.
    private static let stateFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/terminal-tools/monitor-disabled")

    static func state() -> DisplayState {
        guard let active = try? displays(online: false) else { return .absent }
        if active.contains(where: { !isBuiltin($0) }) { return .on }
        return (try? disabledCandidates(active: active))?.isEmpty == false ? .off : .absent
    }

    static func turnOff() throws {
        let externals = try externalsSafeToDisable()
        saveDisabled(externals)
        for id in externals { try setEnabled(id, false) }
    }

    // Disabling the picture does not drop the link, so the monitor's own
    // auto source switch never fires; asking for the HDMI input over DDC
    // does the handoff explicitly. Safety is checked before the DDC write so
    // a closed lid never ends with the only visible screen on another device.
    static func switchToHDMIAndTurnOff() throws {
        let externals = try externalsSafeToDisable()
        try DDC.setInput(hdmiInput())
        saveDisabled(externals)
        for id in externals { try setEnabled(id, false) }
    }

    // `hdmi_input=<n>` in monitor.conf; DDC input values are vendor-specific
    // (MCCS HDMI-1 = 17, which is the default; Samsung uses 5).
    static func hdmiInput() -> UInt16 {
        let text = (try? String(contentsOf: configFile, encoding: .utf8)) ?? ""
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, parts[0] == "hdmi_input", let value = UInt16(parts[1]) { return value }
        }
        return 17
    }

    private static let configFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/terminal-tools/monitor.conf")

    private static func externalsSafeToDisable() throws -> [CGDirectDisplayID] {
        let active = try displays(online: false)
        // With the lid closed the built-in panel is inactive; disabling the
        // external one too would leave the Mac with no screen at all.
        guard active.contains(where: isBuiltin) else {
            throw DisplayToggleError(description: "built-in display is inactive (lid closed?) — refusing to leave no screen")
        }
        let externals = active.filter { !isBuiltin($0) }
        guard !externals.isEmpty else { throw DisplayToggleError(description: "no active external display") }
        return externals
    }

    static func turnOn() throws {
        let candidates = try disabledCandidates(active: displays(online: false))
        guard !candidates.isEmpty else { throw DisplayToggleError(description: "no disabled external display to restore") }
        // A remembered id can be stale (cable unplugged while off); only fail
        // when no display at all came back.
        var lastError: Error?
        var restored = 0
        for id in candidates {
            do { try setEnabled(id, true); restored += 1 } catch { lastError = error }
        }
        saveDisabled([])
        if restored == 0, let lastError { throw lastError }
    }

    private static func disabledCandidates(active: [CGDirectDisplayID]) throws -> Set<CGDirectDisplayID> {
        let online = try displays(online: true)
        return Set(loadDisabled() + online.filter { !isBuiltin($0) && !active.contains($0) })
            .subtracting(active)
    }

    private static func displays(online: Bool) throws -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        let err = online
            ? CGGetOnlineDisplayList(16, &ids, &count)
            : CGGetActiveDisplayList(16, &ids, &count)
        guard err == .success else { throw DisplayToggleError(description: "cannot list displays (CGError \(err.rawValue))") }
        return Array(ids.prefix(Int(count)))
    }

    private static func isBuiltin(_ id: CGDirectDisplayID) -> Bool { CGDisplayIsBuiltin(id) != 0 }

    private static func loadConfigureEnabled() throws -> ConfigureEnabledFn {
        guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW),
              let sym = dlsym(handle, "CGSConfigureDisplayEnabled") else {
            throw DisplayToggleError(description: "CGSConfigureDisplayEnabled is not available on this macOS version")
        }
        return unsafeBitCast(sym, to: ConfigureEnabledFn.self)
    }

    private static func setEnabled(_ id: CGDirectDisplayID, _ enabled: Bool) throws {
        let configure = try loadConfigureEnabled()
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else {
            throw DisplayToggleError(description: "cannot begin display configuration")
        }
        let err = configure(config, id, enabled)
        guard err == .success else {
            CGCancelDisplayConfiguration(config)
            throw DisplayToggleError(description: "cannot change display \(id) (CGError \(err.rawValue))")
        }
        guard CGCompleteDisplayConfiguration(config, .permanently) == .success else {
            throw DisplayToggleError(description: "cannot apply display configuration")
        }
    }

    private static func saveDisabled(_ ids: [CGDirectDisplayID]) {
        try? FileManager.default.createDirectory(at: stateFile.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? ids.map(String.init).joined(separator: "\n")
            .write(to: stateFile, atomically: true, encoding: .utf8)
    }

    private static func loadDisabled() -> [CGDirectDisplayID] {
        guard let text = try? String(contentsOf: stateFile, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { CGDirectDisplayID($0) }
    }
}
