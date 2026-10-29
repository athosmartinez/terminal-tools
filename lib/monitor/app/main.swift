// app/main.swift — MonitorBar, a menu bar toggle for the external display.
// Agent app (LSUIElement): no Dock icon, no Cmd-Tab entry, only the status item.
// Built into ~/Applications/MonitorBar.app by `monitor app`.

import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()

    func applicationDidFinishLaunching(_ notification: Notification) {
        menu.delegate = self
        statusItem.menu = menu
        refreshIcon()
        registerLoginOnFirstLaunch()

        // Event-driven instead of polling: macOS calls back on every display
        // change (our own toggle, the CLI, or the cable being unplugged).
        CGDisplayRegisterReconfigurationCallback({ _, flags, context in
            guard !flags.contains(.beginConfigurationFlag), let context else { return }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { delegate.refreshIcon() }
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    private func refreshIcon() {
        let state = DisplayToggle.state()
        let image = NSImage(systemSymbolName: state == .on ? "display" : "tv.slash",
                            accessibilityDescription: "External display")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.appearsDisabled = state == .absent
    }

    // Rebuilt on every open so the labels always match the current state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let state = DisplayToggle.state()

        let header: String
        switch state {
        case .on: header = "External display: on"
        case .off: header = "External display: off"
        case .absent: header = "No external display"
        }
        menu.addItem(withTitle: header, action: nil, keyEquivalent: "").isEnabled = false

        if state != .absent {
            let title = state == .on ? "Turn Off Display" : "Turn On Display"
            menu.addItem(withTitle: title, action: #selector(toggleDisplay), keyEquivalent: "").target = self
        }

        menu.addItem(.separator())
        let login = menu.addItem(withTitle: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(withTitle: "Quit MonitorBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc private func toggleDisplay() {
        do {
            if DisplayToggle.state() == .on { try DisplayToggle.turnOff() } else { try DisplayToggle.turnOn() }
        } catch {
            showError(error)
        }
        refreshIcon()
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            showError(error)
        }
    }

    // Starting at login is the point of a 24/7 toggle, so it is on by default;
    // done once, so turning it off in the menu sticks.
    private func registerLoginOnFirstLaunch() {
        let key = "didAutoRegisterLogin"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        try? SMAppService.mainApp.register()
    }

    private func showError(_ error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "MonitorBar"
        alert.informativeText = "\(error)"
        alert.runModal()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
