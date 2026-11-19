// DisplayToggle.swift — turn external displays off/on without unplugging the cable.
// macOS stops driving the display, but the USB-C link stays up, so a monitor
// with USB-C Power Delivery keeps charging the Mac.
//
// Shared by the `monitor` CLI (cli/main.swift) and the menu bar app
// (app/main.swift); both read and write the same state file.

import CoreGraphics
import Foundation

enum DisplayState { case on, off, absent }

/// What the rules below need to know about one display. A plain value, so the
/// tests run the rules on fake displays.
struct DisplayInfo: Equatable {
    let id: CGDirectDisplayID
    let builtin: Bool
    let vendor: UInt32
    let product: UInt32

    var isVirtual: Bool { vendor == VirtualDisplay.vendorID && product == VirtualDisplay.productID }

    // "External" means a monitor on a cable. MonitorBar's virtual display is
    // not built in either, but it has no cable to restore and no picture to
    // stop, so on, off and status must not count it.
    var isExternal: Bool { !builtin && !isVirtual }
}

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
        // The online list only matters for a monitor that is off.
        guard let online = try? displays(online: true) else {
            return active.contains(where: \.isExternal) ? .on : .absent
        }
        return state(active: active, online: online, remembered: loadDisabled())
    }

    static func state(active: [DisplayInfo], online: [DisplayInfo], remembered: [CGDirectDisplayID]) -> DisplayState {
        if active.contains(where: \.isExternal) { return .on }
        return disabledCandidates(active: active, online: online, remembered: remembered).isEmpty ? .absent : .off
    }

    static func turnOff() throws {
        let externals = try externalsSafeToDisable(active: displays(online: false))
        saveDisabled(externals)
        for id in externals { try setEnabled(id, false) }
    }

    // Disabling the picture does not drop the link, so the monitor's own
    // auto source switch never fires; asking for the HDMI input over DDC
    // does the handoff explicitly. Safety is checked before the DDC write so
    // a closed lid never ends with the only visible screen on another device.
    static func switchToHDMIAndTurnOff() throws {
        let externals = try externalsSafeToDisable(active: displays(online: false))
        try DDC.setInput(hdmiInput())
        saveDisabled(externals)
        for id in externals { try setEnabled(id, false) }
    }

    static func hdmiInput() -> UInt16 { MonitorConfig.load().hdmiInput }

    static func externalsSafeToDisable(active: [DisplayInfo]) throws -> [CGDirectDisplayID] {
        // With the lid closed the built-in panel is inactive; disabling the
        // external one too would leave the Mac with no screen at all.
        guard active.contains(where: \.builtin) else {
            throw DisplayToggleError(description: "built-in display is inactive (lid closed?) — refusing to leave no screen")
        }
        let externals = active.filter(\.isExternal).map(\.id)
        guard !externals.isEmpty else { throw DisplayToggleError(description: "no active external display") }
        return externals
    }

    static func turnOn() throws {
        let candidates = try disabledCandidates(active: displays(online: false), online: displays(online: true),
                                                remembered: loadDisabled())
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

    // True for a short time after any off or on, from the app or the CLI: both
    // write the state file. An HDMI handoff can bounce the link, and that
    // bounce looks exactly like a cable being plugged in.
    static func changedRecently(within seconds: TimeInterval) -> Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: stateFile.path)
        guard let modified = attributes?[.modificationDate] as? Date else { return false }
        return Date().timeIntervalSince(modified) < seconds
    }

    static func summary() -> String {
        let active = (try? displays(online: false)) ?? []
        let online = (try? displays(online: true)) ?? []
        return "active=\(active.map(\.id)) online=\(online.map(\.id)) remembered=\(loadDisabled())"
    }

    static func disabledCandidates(active: [DisplayInfo], online: [DisplayInfo],
                                   remembered: [CGDirectDisplayID]) -> Set<CGDirectDisplayID> {
        Set(remembered + online.filter(\.isExternal).map(\.id)).subtracting(active.map(\.id))
    }

    static func displays(online: Bool) throws -> [DisplayInfo] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        let err = online
            ? CGGetOnlineDisplayList(16, &ids, &count)
            : CGGetActiveDisplayList(16, &ids, &count)
        guard err == .success else { throw DisplayToggleError(description: "cannot list displays (CGError \(err.rawValue))") }
        return ids.prefix(Int(count)).map {
            DisplayInfo(id: $0, builtin: CGDisplayIsBuiltin($0) != 0,
                        vendor: CGDisplayVendorNumber($0), product: CGDisplayModelNumber($0))
        }
    }

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

/// ~/.config/terminal-tools/monitor.conf, one `key=value` per line. A missing
/// key or a value that does not parse keeps the default.
struct MonitorConfig: Equatable {
    enum Side: String { case left, right }

    /// DDC input values are vendor-specific: MCCS says HDMI-1 = 17, Samsung uses 5.
    var hdmiInput: UInt16 = 17
    var virtualWidth = 1920
    var virtualHeight = 1080
    /// The side of the anchor display that the virtual display sits on.
    var virtualSide = Side.right
    /// Points below the top edge of the anchor display; negative is above.
    var virtualY = 0
    /// The Moonlight host has no default: it names a machine.
    var moonlightHost = ""
    /// "Desktop" is the app that Sunshine defines out of the box.
    var moonlightApp = "Desktop"

    static let file = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/terminal-tools/monitor.conf")

    static func load() -> MonitorConfig {
        parse((try? String(contentsOf: file, encoding: .utf8)) ?? "")
    }

    static func parse(_ text: String) -> MonitorConfig {
        var config = MonitorConfig()
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[1].isEmpty else { continue }
            let value = parts[1]
            switch parts[0] {
            case "hdmi_input":
                if let n = UInt16(value) { config.hdmiInput = n }
            case "virtual_size":
                // The upper limit is far above any stream size; it only keeps a
                // typing error from asking WindowServer for a huge framebuffer.
                let size = value.lowercased().split(separator: "x").map { Int($0) }
                if size.count == 2, let width = size[0], let height = size[1],
                   (320...7680).contains(width), (200...4320).contains(height) {
                    config.virtualWidth = width
                    config.virtualHeight = height
                }
            case "virtual_side":
                if let side = Side(rawValue: value.lowercased()) { config.virtualSide = side }
            case "virtual_y":
                if let y = Int(value), (-10_000...10_000).contains(y) { config.virtualY = y }
            case "moonlight_host":
                config.moonlightHost = value
            case "moonlight_app":
                config.moonlightApp = value
            default:
                break
            }
        }
        return config
    }
}
