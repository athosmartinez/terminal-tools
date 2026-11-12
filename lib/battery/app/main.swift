// app/main.swift — BatteryBar, the battery of the connected Bluetooth devices
// in the menu bar: "KB 100%  MS 85%", a ⚠ in orange at or below `low=`, and
// a battery icon alone when no device reports its battery.
// Agent app (LSUIElement): no Dock icon, only the status item.
// Built into ~/Applications/BatteryBar.app by `battery app`.

import AppKit
import IOKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let source: BatterySource = BLEBatterySource()
    private var config = BatteryConfig.load()
    private var pollTimer: Timer?
    private var hidPort: IONotificationPortRef?
    private var pendingRescan: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        source.onChange = { [weak self] in self?.render() }
        source.start()
        render()
        registerLoginOnFirstLaunch()
        schedulePoll()
        watchBluetoothHID()
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
    }

    // MARK: - Title

    private func render() {
        guard let button = statusItem.button else { return }
        let parts = source.state == .ready ? titleParts(source.devices, config) : []
        if parts.isEmpty {
            let working = source.state == .ready || source.state == .starting
            let image = NSImage(systemSymbolName: working ? "battery.100percent" : "battery.0percent",
                                accessibilityDescription: "Bluetooth battery")
            image?.isTemplate = true
            button.image = image
            button.attributedTitle = NSAttributedString()
            button.toolTip = stateMessage ?? "No connected device reports its battery"
            return
        }
        button.image = nil
        button.toolTip = nil
        // Monospaced digits, so the title does not change width with the values.
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let title = NSMutableAttributedString()
        for (index, part) in parts.enumerated() {
            if index > 0 { title.append(NSAttributedString(string: "  ", attributes: [.font: font])) }
            var attributes: [NSAttributedString.Key: Any] = [.font: font]
            if part.low { attributes[.foregroundColor] = NSColor.systemOrange }
            title.append(NSAttributedString(string: part.text, attributes: attributes))
        }
        button.attributedTitle = title
    }

    /// Why no device can show, or nil when Bluetooth works.
    private var stateMessage: String? {
        switch source.state {
        case .ready: return nil
        case .starting: return "Waiting for Bluetooth…"
        case .poweredOff: return "Bluetooth is off"
        case .unauthorized: return "No Bluetooth permission"
        case .unsupported: return "This Mac has no Bluetooth Low Energy"
        }
    }

    // MARK: - Menu

    // Rebuilt on every open, so it shows the latest values and config.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        reloadConfig()

        if let message = stateMessage {
            menu.addItem(withTitle: message, action: nil, keyEquivalent: "").isEnabled = false
            if source.state == .unauthorized {
                menu.addItem(withTitle: "Open Bluetooth Privacy Settings…", action: #selector(openPrivacy),
                             keyEquivalent: "").target = self
            }
        } else {
            let devices = config.visible(source.devices)
            if devices.isEmpty {
                menu.addItem(withTitle: "No connected device reports its battery", action: nil,
                             keyEquivalent: "").isEnabled = false
            }
            for device in devices {
                let mark = config.isLow(device.percent) ? "⚠\u{FE0E} " : ""
                // Enabled with no action: plain text, not grayed out.
                let item = menu.addItem(withTitle: "\(mark)\(device.name)   \(percentText(device.percent))",
                                        action: nil, keyEquivalent: "")
                item.toolTip = "Label: \(config.label(for: device.name))"
            }
            let hidden = source.devices.count - devices.count
            if hidden > 0 {
                menu.addItem(withTitle: "\(hidden) hidden by show=", action: nil, keyEquivalent: "").isEnabled = false
            }
        }

        menu.addItem(.separator())
        menu.addItem(withTitle: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r").target = self
        menu.addItem(withTitle: "Open Config…", action: #selector(openConfig), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        let login = menu.addItem(withTitle: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(withTitle: "Quit BatteryBar", action: #selector(NSApplication.terminate(_:)),
                     keyEquivalent: "q")
    }

    @objc private func refreshNow() {
        reloadConfig()
        source.refresh()
    }

    // The config has no file watch: it is read again when the menu opens, on
    // Refresh Now and on every timer tick.
    private func reloadConfig() {
        let fresh = BatteryConfig.load()
        guard fresh != config else { return }
        let intervalChanged = fresh.interval != config.interval
        config = fresh
        if intervalChanged { schedulePoll() }
        render()
    }

    // `open` fails on a missing file, so a commented template is written first.
    @objc private func openConfig() {
        let url = BatteryConfig.defaultURL
        let files = FileManager.default
        if !files.fileExists(atPath: url.path) {
            do {
                try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try BatteryConfig.template.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                return showMessage("Cannot create \(url.path): \(error.localizedDescription)")
            }
        }
        // -t: the default text editor, because no app owns the .conf extension.
        run("/usr/bin/open", ["-t", url.path])
    }

    @objc private func openPrivacy() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Refresh triggers

    // Values with notifications arrive by themselves; the timer reads the
    // others again and looks for devices that the HID watch cannot see.
    private func schedulePoll() {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: config.interval, repeats: true) { [weak self] _ in
            self?.reloadConfig()
            self?.source.poll()
        }
        timer.tolerance = min(30, config.interval / 10)
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    // CoreBluetooth on macOS has no event for "a device connected to the
    // system" (registerForConnectionEvents is iOS only). A BLE keyboard or
    // mouse also appears as an IOHIDDevice with Transport "Bluetooth Low
    // Energy", so an IOKit match on it is the connect event, and its end the
    // disconnect event. No device is opened, so no Input Monitoring permission.
    private func watchBluetoothHID() {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        hidPort = port
        IONotificationPortSetDispatchQueue(port, .main)
        let context = Unmanaged.passUnretained(self).toOpaque()
        for type in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            let matching = IOServiceMatching("IOHIDDevice") as NSMutableDictionary
            matching["IOPropertyMatch"] = ["Transport": "Bluetooth Low Energy"]
            var iterator: io_iterator_t = 0
            let result = IOServiceAddMatchingNotification(port, type, matching as CFDictionary, { context, iterator in
                guard let context else { return }
                AppDelegate.drain(iterator)
                Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue().scheduleRescan(after: 2)
            }, context, &iterator)
            // The first drain arms the notification. The devices that are
            // connected already are found by the first rescan.
            if result == KERN_SUCCESS { AppDelegate.drain(iterator) }
        }
    }

    private static func drain(_ iterator: io_iterator_t) {
        var service = IOIteratorNext(iterator)
        while service != 0 {
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
    }

    // The HID device appears before its GATT services answer, and a wake
    // reconnects every device, so the rescan waits a moment. Several events
    // in a row make one rescan.
    private func scheduleRescan(after seconds: TimeInterval) {
        pendingRescan?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.source.refresh() }
        pendingRescan = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    @objc private func didWake() { scheduleRescan(after: 5) }

    // MARK: - Login, process, messages

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            showMessage("\(error)")
        }
    }

    // On by default; done once, so turning it off in the menu sticks.
    private func registerLoginOnFirstLaunch() {
        let key = "didAutoRegisterLogin"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        try? SMAppService.mainApp.register()
    }

    private func run(_ tool: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.terminationHandler = { [weak self] done in
            guard done.terminationStatus != 0 else { return }
            let command = ([tool] + arguments).joined(separator: " ")
            DispatchQueue.main.async { self?.showMessage("\(command) failed (exit \(done.terminationStatus))") }
        }
        do { try process.run() } catch { showMessage("\(error)") }
    }

    private func showMessage(_ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "BatteryBar"
        alert.informativeText = text
        alert.runModal()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
