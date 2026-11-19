// app/main.swift — MonitorBar, a menu bar toggle for the external display and
// the owner of the virtual display.
// Agent app (LSUIElement): no Dock icon, no Cmd-Tab entry, only the status item.
// Built into ~/Applications/MonitorBar.app by `monitor app`.

import AppKit
import IOKit
import ServiceManagement
import os

private let log = Logger(subsystem: "com.athosmartinez.terminal-tools.monitorbar", category: "connect")

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private var cablePort: IONotificationPortRef?
    private var pendingRestore: DispatchWorkItem?
    private var lastWake: Date?
    private let virtual = VirtualDisplay()
    private var pendingPlacement: DispatchWorkItem?

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
            DispatchQueue.main.async { delegate.displaysChanged(flags) }
        }, Unmanaged.passUnretained(self).toOpaque())

        watchCable()

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            workspace.addObserver(self, selector: #selector(noteWake), name: name, object: nil)
        }
    }

    // The virtual display lives in this process, so it must go with it.
    func applicationWillTerminate(_ notification: Notification) { virtual.turnOff() }

    // The arrangement can change over a sleep with no display added or removed.
    @objc private func noteWake() {
        lastWake = Date()
        schedulePlacement()
    }

    // The anchor of the virtual display can appear or go (cable, `monitor
    // off`, lid). Moving the display raises only "moved" flags, so a placement
    // cannot schedule the next one.
    private func displaysChanged(_ flags: CGDisplayChangeSummaryFlags) {
        refreshIcon()
        if !flags.isDisjoint(with: [.addFlag, .removeFlag, .enabledFlag, .disabledFlag]) { schedulePlacement() }
    }

    // One attempt after the last event: a change of displays arrives as a
    // burst of callbacks, and WindowServer lists a new display a moment late.
    private func schedulePlacement() {
        guard virtual.displayID != nil else { return }
        pendingPlacement?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.placeVirtual() }
        pendingPlacement = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    // Silent like the cable restore: it also runs with nobody at the menu.
    private func placeVirtual() {
        do {
            try virtual.place(MonitorConfig.load())
        } catch {
            log.error("virtual display: \(String(describing: error), privacy: .public)")
        }
    }

    // macOS creates this service when a USB-C port enters DisplayPort mode, so
    // a plain charger never fires it. The display callback cannot replace it: a
    // disabled display sends no add event when its cable is plugged back in.
    // Matches that exist already are drained without acting: a display left
    // off stays off across a relaunch or login.
    private func watchCable() {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        cablePort = port
        IONotificationPortSetDispatchQueue(port, .main)
        var iterator: io_iterator_t = 0
        let result = IOServiceAddMatchingNotification(
            port, kIOFirstMatchNotification, IOServiceMatching("IOPortTransportStateDisplayPort"),
            { context, iterator in
                guard let context else { return }
                let delegate = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
                let count = AppDelegate.drain(iterator)
                log.notice("cable: \(count, privacy: .public) DisplayPort transport(s) appeared \(DisplayToggle.summary(), privacy: .public)")
                delegate.scheduleRestore()
            },
            Unmanaged.passUnretained(self).toOpaque(), &iterator)
        guard result == KERN_SUCCESS else {
            log.error("cannot watch the USB-C ports (kern_return \(result, privacy: .public))")
            return
        }
        log.notice("watching USB-C ports, \(AppDelegate.drain(iterator), privacy: .public) already connected")
    }

    // The iterator must be emptied, or IOKit stops sending notifications.
    private static func drain(_ iterator: io_iterator_t) -> Int {
        var count = 0
        while case let service = IOIteratorNext(iterator), service != 0 {
            IOObjectRelease(service)
            count += 1
        }
        return count
    }

    // WindowServer needs time to settle after a plug, and a flaky connector can
    // fire more than once, so only the last event leads to an attempt.
    private func scheduleRestore() {
        pendingRestore?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.restoreAfterConnect() }
        pendingRestore = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    // Silent on purpose: nobody clicked anything, so an alert would be noise.
    private func restoreAfterConnect() {
        guard DisplayToggle.state() == .off, !DisplayToggle.changedRecently(within: 10) else { return }
        // Displays are detected again at wake, which looks like a plug. Without
        // this, a display left off overnight would come back on every morning.
        if let lastWake, Date().timeIntervalSince(lastWake) < 15 {
            log.notice("restore skipped: the Mac just woke")
            return
        }
        do {
            try DisplayToggle.turnOn()
            log.notice("display restored \(DisplayToggle.summary(), privacy: .public)")
        } catch {
            log.error("restore failed: \(String(describing: error), privacy: .public)")
        }
        refreshIcon()
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
        if state == .on {
            menu.addItem(withTitle: "Turn Off & Switch to HDMI", action: #selector(switchToHDMI), keyEquivalent: "").target = self
        }

        menu.addItem(.separator())
        addVirtualItems(to: menu)

        menu.addItem(.separator())
        let login = menu.addItem(withTitle: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(withTitle: "Quit MonitorBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    private func addVirtualItems(to menu: NSMenu) {
        guard VirtualDisplay.isAvailable else {
            menu.addItem(withTitle: "Virtual display: not available on this macOS", action: nil, keyEquivalent: "").isEnabled = false
            return
        }
        guard virtual.isOn, let id = virtual.displayID else {
            menu.addItem(withTitle: "Virtual display: off", action: nil, keyEquivalent: "").isEnabled = false
            menu.addItem(withTitle: "Turn On Virtual Display", action: #selector(toggleVirtual), keyEquivalent: "").target = self
            return
        }
        // Nothing shows this display, so the menu says where it is.
        let bounds = CGDisplayBounds(id)
        let header = "Virtual display: \(Int(bounds.width))x\(Int(bounds.height)) at \(Int(bounds.minX)), \(Int(bounds.minY))"
        menu.addItem(withTitle: header, action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(withTitle: "Turn Off Virtual Display", action: #selector(toggleVirtual), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Open Moonlight on Virtual Display", action: #selector(openMoonlight), keyEquivalent: "").target = self
    }

    @objc private func toggleVirtual() {
        if virtual.isOn {
            virtual.turnOff()
            return
        }
        do {
            try virtual.turnOn(MonitorConfig.load())
            schedulePlacement()
        } catch {
            showError(error)
        }
    }

    // Through LaunchServices, not as a child process: a child would use
    // MonitorBar's privacy permissions (local network, input) in place of
    // Moonlight's own. A new instance, because a Moonlight that already runs
    // would only come to the front and drop the arguments.
    @objc private func openMoonlight() {
        do {
            guard virtual.isOn, let id = virtual.displayID else {
                throw DisplayToggleError(description: "the virtual display is off")
            }
            let arguments = try Moonlight.arguments(MonitorConfig.load(), display: CGDisplayBounds(id))
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Moonlight.bundleID) else {
                throw DisplayToggleError(description: "Moonlight is not installed")
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.arguments = arguments
            configuration.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] _, error in
                guard let error else { return }
                DispatchQueue.main.async { self?.showError(error) }
            }
        } catch {
            showError(error)
        }
    }

    @objc private func toggleDisplay() {
        do {
            if DisplayToggle.state() == .on { try DisplayToggle.turnOff() } else { try DisplayToggle.turnOn() }
        } catch {
            showError(error)
        }
        refreshIcon()
    }

    @objc private func switchToHDMI() {
        do { try DisplayToggle.switchToHDMIAndTurnOff() } catch { showError(error) }
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
