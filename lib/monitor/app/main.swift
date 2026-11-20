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
    // Where each Moonlight window was before it went to the virtual display,
    // and if it was in full screen there.
    private var moonlightHome: [pid_t: (frame: CGRect, fullScreen: Bool)] = [:]
    // True from Turn On to Turn Off. The app can lose the display without the
    // user: with no real display active it turns the display off, and it
    // turns it on again when a real display comes back.
    private var virtualWanted = false
    // The Moonlight processes that the user sent to the virtual display, and
    // whether one of their windows is not there now.
    private var moonlightOnVirtual: Set<pid_t> = []
    private var moonlightLeft = false
    // Tracked windows that cannot be checked: no Accessibility grant (it is
    // dropped silently after every rebuild, and Open Moonlight needs none).
    private var moonlightUnchecked = false
    private var pendingMoonlightCheck: DispatchWorkItem?
    // The app recreates a display that WindowServer dropped once per chain of
    // failed placements; a display that is never listed must not cycle.
    private var recreatedVirtual = false
    // The rescue of other apps' windows from the virtual display (WindowRescue).
    private var rescueTimer: Timer?
    // Automatic attempts per window number, kept while the window exists.
    private var rescueTried: [CGWindowID: Int] = [:]
    // Windows that are on the virtual display at the last look, and whether
    // the grant to move them is missing.
    private var strandedWindows = 0
    private var rescueUnchecked = false
    private var rescueRunning = false
    // A pass asked for while one runs: nil for none, else whether it is manual.
    private var rescueAgain: Bool?
    // A pass that ends after a Turn Off must not touch the new state.
    private var rescueGeneration = 0
    private let rescueQueue = DispatchQueue(label: "com.athosmartinez.terminal-tools.monitorbar.rescue")

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
        workspace.addObserver(self, selector: #selector(noteQuit(_:)),
                              name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        // An app that comes to the front can open or restore a window.
        workspace.addObserver(self, selector: #selector(noteActivate),
                              name: NSWorkspace.didActivateApplicationNotification, object: nil)
    }

    @objc private func noteActivate() { rescueWindows() }

    // The virtual display lives in this process, so it must go with it.
    func applicationWillTerminate(_ notification: Notification) { virtual.turnOff() }

    // The arrangement can change over a sleep with no display added or removed.
    @objc private func noteWake() {
        lastWake = Date()
        // A wake is a system event, never the app's own, so a new recreate
        // cannot start a cycle.
        recreatedVirtual = false
        schedulePlacement()
    }

    // A tracked Moonlight that quits must not keep the warning.
    @objc private func noteQuit(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == Moonlight.bundleID else { return }
        // The list of running apps can still hold it now, and a pid with no
        // window counts as left.
        moonlightOnVirtual.remove(app.processIdentifier)
        moonlightHome[app.processIdentifier] = nil
        checkMoonlight()
    }

    // The anchor of the virtual display can appear or go (cable, `monitor
    // off`, lid). Moving the display raises only "moved" flags, so a placement
    // cannot schedule the next one.
    // A display event also gives every window new rescue attempts: macOS
    // moves windows then. Never on "moved" flags, which `place` raises.
    private func displaysChanged(_ flags: CGDisplayChangeSummaryFlags) {
        refreshIcon()
        if !flags.isDisjoint(with: [.addFlag, .removeFlag, .enabledFlag, .disabledFlag]) {
            rescueTried.removeAll()
            schedulePlacement()
        }
    }

    // One attempt after the last event: a change of displays arrives as a
    // burst of callbacks, and WindowServer lists a new display a moment late.
    private func schedulePlacement(attempt: Int = 1) {
        guard virtualWanted else { return }
        pendingPlacement?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.placeVirtual(attempt: attempt) }
        pendingPlacement = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    // A plug or unplug takes some seconds to settle, and the virtual display
    // can be out of the list for all of them.
    private static let placementAttempts = 8

    // Silent like the cable restore: it also runs with nobody at the menu.
    private func placeVirtual(attempt: Int) {
        let config = MonitorConfig.load()
        do {
            guard virtual.displayID != nil else {
                // Off since no real display was active (lid closed, sleep).
                guard VirtualDisplay.anchor(try DisplayToggle.displays(online: false)) != nil else { return }
                try virtual.turnOn(config)
                log.notice("virtual display: on again \(DisplayToggle.summary(), privacy: .public)")
                schedulePlacement()
                return
            }
            if try virtual.place(config) {
                recreatedVirtual = false
                scheduleMoonlightCheck()
                rescueWindows()
            } else if attempt < Self.placementAttempts {
                schedulePlacement(attempt: attempt + 1)
            } else if !recreatedVirtual {
                // WindowServer can drop the display and leave the object, and
                // its return sends no event: a new object comes back listed.
                log.notice("virtual display: not active after \(attempt, privacy: .public) attempts, made again \(DisplayToggle.summary(), privacy: .public)")
                recreatedVirtual = true
                virtual.turnOff()
                schedulePlacement()
            } else {
                log.error("virtual display: not active after \(attempt, privacy: .public) attempts \(DisplayToggle.summary(), privacy: .public)")
            }
        } catch {
            log.error("virtual display: \(String(describing: error), privacy: .public)")
            // WindowServer can refuse a configuration while it settles. With
            // no real display, `place` released the object: nothing to retry.
            if virtual.displayID != nil, attempt < Self.placementAttempts {
                schedulePlacement(attempt: attempt + 1)
            }
        }
        refreshIcon()
    }

    // The window moves with the display, but its AX frame and a new window
    // arrive a moment later; a read at once can be stale.
    private func scheduleMoonlightCheck(after delay: TimeInterval = 2) {
        pendingMoonlightCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.checkMoonlight() }
        pendingMoonlightCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // Only a warning: the user moves the window with the menu, so a window
    // never jumps to a display that nobody sees while the user works in it.
    private func checkMoonlight() {
        let running = Set(moonlightPIDs)
        moonlightOnVirtual.formIntersection(running)
        var left = false
        var unchecked = false
        if !moonlightOnVirtual.isEmpty, let id = virtual.displayID, virtual.isOn {
            if AXIsProcessTrusted() {
                let bounds = CGDisplayBounds(id)
                left = moonlightOnVirtual.contains {
                    Moonlight.leftVirtual(window: try? AppWindow.frame(pid: $0, timeout: AppWindow.checkTimeout), virtual: bounds)
                }
            } else {
                unchecked = true
            }
        }
        if left != moonlightLeft {
            log.notice("moonlight: \(left ? "left" : "back on", privacy: .public) the virtual display")
        }
        moonlightLeft = left
        moonlightUnchecked = unchecked
        refreshIcon()
    }

    // MARK: windows of other apps on the virtual display

    // No event tells that a window opened or moved, short of an observer in
    // every app, so a timer looks while the virtual display is wanted. A tick
    // is one window list, and nothing more while no window is on the display.
    // The default run loop mode: no tick while the menu is open.
    private func startRescue() {
        rescueTimer?.invalidate()
        rescueTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.rescueWindows()
        }
    }

    private func stopRescue() {
        rescueTimer?.invalidate()
        rescueTimer = nil
        rescueTried.removeAll()
        strandedWindows = 0
        rescueUnchecked = false
        rescueRunning = false
        rescueAgain = nil
        rescueGeneration += 1
    }

    // The windows on the virtual display now, and the whole list; nil when
    // the display is off. It sets the count for the badge and the menu.
    @discardableResult
    private func lookForStranded() -> (bounds: CGRect, listed: [ListedWindow], stranded: [ListedWindow])? {
        guard virtual.isOn, let id = virtual.displayID else {
            strandedWindows = 0
            rescueUnchecked = false
            return nil
        }
        let bounds = CGDisplayBounds(id)
        let listed = WindowRescue.onScreen()
        let stranded = WindowRescue.stranded(listed, virtual: bounds, moonlight: Set(moonlightPIDs), own: getpid())
        strandedWindows = stranded.count
        // Silent: AXIsProcessTrustedWithOptions with the prompt would show
        // the system request at every tick.
        rescueUnchecked = !stranded.isEmpty && !AXIsProcessTrusted()
        return (bounds, listed, stranded)
    }

    // The usable area of the display that the windows go to.
    private func rescueTarget() -> CGRect? {
        guard let active = try? DisplayToggle.displays(online: false),
              let id = WindowRescue.target(main: CGMainDisplayID(), active: active) else { return nil }
        return visibleFrame(of: id)
    }

    // One pass: the windows that have attempts left move to the main display.
    // `manual` is the menu item: it shows the request for the grant and an
    // error, and it does not wait for the end of a drag.
    private func rescueWindows(manual: Bool = false) {
        guard virtualWanted else { return }
        if rescueRunning {
            rescueAgain = (rescueAgain ?? false) || manual
            return
        }
        // A window that the user drags is in the user's hand.
        guard manual || NSEvent.pressedMouseButtons == 0 else { return }
        guard let look = lookForStranded() else {
            refreshIcon()
            return
        }
        rescueTried = WindowRescue.pruned(rescueTried, listed: look.listed)
        let due = WindowRescue.due(look.stranded, tried: rescueTried)
        guard !due.isEmpty, !rescueUnchecked else {
            refreshIcon()
            return
        }
        guard let visible = rescueTarget() else {
            if manual { showError(DisplayToggleError(description: "no real display is active")) }
            refreshIcon()
            return
        }
        // Every attempt counts, also one that moves the window: an app can
        // put the window back, and a count that a success clears is a loop.
        for window in due { rescueTried[window.number, default: 0] += 1 }
        rescueRunning = true
        let generation = rescueGeneration
        let bounds = look.bounds
        rescueQueue.async { [weak self] in
            let failures = AppDelegate.move(due, virtual: bounds, visible: visible)
            DispatchQueue.main.async {
                guard let self, generation == self.rescueGeneration else { return }
                self.rescueRunning = false
                if manual, let last = failures.last {
                    self.showError(DisplayToggleError(description: due.count == 1
                        ? "\(last)" : "\(failures.count) of \(due.count) windows did not move: \(last)"))
                }
                if let again = self.rescueAgain {
                    self.rescueAgain = nil
                    self.rescueWindows(manual: again)
                } else {
                    self.lookForStranded()
                    self.refreshIcon()
                }
            }
        }
    }

    // Off the main thread: a move takes some tenths of a second, seconds for
    // a full screen window, and the menu bar must not freeze. Each
    // Accessibility call waits at most AppWindow.checkTimeout, so an app that
    // does not answer holds the queue for some seconds, not minutes; a full
    // screen exit that answers late costs one attempt.
    private static func move(_ windows: [ListedWindow], virtual: CGRect, visible: CGRect) -> [Error] {
        var failures: [Error] = []
        for listed in windows {
            let name = "window \(listed.number) of pid \(listed.pid)"
            do {
                let window = try AppWindow.window(pid: listed.pid, bounds: listed.bounds, timeout: AppWindow.checkTimeout)
                // A full screen window comes back as a plain window: nobody
                // saw it in full screen, and a window is easier to reach.
                let result = try AppWindow.setFrame(window, fullScreen: false, trace: { step in
                    log.notice("rescue \(name, privacy: .public): \(step, privacy: .public)")
                }) { WindowRescue.frame(window: $0, virtual: virtual, visible: visible) }
                guard !virtual.contains(CGPoint(x: result.midX, y: result.midY)) else {
                    throw DisplayToggleError(description: "the app kept its window on the virtual display")
                }
            } catch {
                log.error("rescue \(name, privacy: .public): \(String(describing: error), privacy: .public)")
                failures.append(error)
            }
        }
        return failures
    }

    // The menu item: every window gets its attempts again.
    @objc private func rescueWindowsNow() {
        do { try AppWindow.requireAccess() } catch { showError(error); return }
        rescueTried.removeAll()
        rescueWindows(manual: true)
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
        let warning = moonlightLeft || moonlightUnchecked || strandedWindows > 0
        let image = warning
            ? NSImage(systemSymbolName: "display.trianglebadge.exclamationmark",
                      accessibilityDescription: "The virtual display needs attention")
            : NSImage(systemSymbolName: state == .on ? "display" : "tv.slash",
                      accessibilityDescription: "External display")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.appearsDisabled = state == .absent && !warning
    }

    // Rebuilt on every open so the labels always match the current state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        checkMoonlight()
        // A count only: a move here would hold the menu.
        lookForStranded()
        refreshIcon()
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
        if strandedWindows > 0 {
            let count = strandedWindows == 1 ? "1 window" : "\(strandedWindows) windows"
            menu.addItem(withTitle: "\(count) on the virtual display", action: nil, keyEquivalent: "").isEnabled = false
            menu.addItem(withTitle: "Move Other Windows to Main Display", action: #selector(rescueWindowsNow), keyEquivalent: "").target = self
        }
        if moonlightUnchecked || rescueUnchecked {
            menu.addItem(withTitle: "Allow Accessibility for Window Checks", action: #selector(askAccessibility), keyEquivalent: "").target = self
        }
        // A Moonlight that runs keeps its stream, and its window moves. With
        // no Moonlight, the item starts a stream on the display.
        if moonlightPIDs.isEmpty {
            menu.addItem(withTitle: "Open Moonlight on Virtual Display", action: #selector(openMoonlight), keyEquivalent: "").target = self
        } else {
            if moonlightLeft {
                menu.addItem(withTitle: "Moonlight left the virtual display", action: nil, keyEquivalent: "").isEnabled = false
            }
            menu.addItem(withTitle: "Move Moonlight to Virtual Display", action: #selector(moveMoonlightToVirtual), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Move Moonlight to Main Display", action: #selector(moveMoonlightToMain), keyEquivalent: "").target = self
        }
    }

    // macOS shows its own request; the error text says what to do when the
    // list has a stale entry from an earlier build.
    @objc private func askAccessibility() {
        do { try AppWindow.requireAccess() } catch { showError(error) }
    }

    @objc private func toggleVirtual() {
        if virtual.isOn {
            virtual.turnOff()
            virtualWanted = false
            pendingPlacement?.cancel()
            pendingMoonlightCheck?.cancel()
            // macOS moves the windows back by itself, to places of its choice.
            moonlightHome.removeAll()
            moonlightOnVirtual.removeAll()
            moonlightLeft = false
            moonlightUnchecked = false
            stopRescue()
            refreshIcon()
            return
        }
        do {
            try virtual.turnOn(MonitorConfig.load())
            virtualWanted = true
            recreatedVirtual = false
            rescueTried.removeAll()
            startRescue()
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
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] app, error in
                DispatchQueue.main.async {
                    if let error { self?.showError(error) }
                    // A Turn Off can come before the launch ends.
                    guard let self, let pid = app?.processIdentifier, self.virtualWanted else { return }
                    self.moonlightOnVirtual.insert(pid)
                    // The stream window opens some seconds after the launch.
                    self.scheduleMoonlightCheck(after: 5)
                }
            }
        } catch {
            showError(error)
        }
    }

    private var moonlightPIDs: [pid_t] {
        NSRunningApplication.runningApplications(withBundleIdentifier: Moonlight.bundleID).map(\.processIdentifier)
    }

    // The area of a display that the menu bar and the Dock leave, in global
    // coordinates. NSScreen has it; a display with no NSScreen yet gives its bounds.
    private func visibleFrame(of id: CGDirectDisplayID) -> CGRect {
        let number = NSDeviceDescriptionKey("NSScreenNumber")
        guard let primary = NSScreen.screens.first,
              let screen = NSScreen.screens.first(where: { ($0.deviceDescription[number] as? NSNumber)?.uint32Value == id }) else {
            return CGDisplayBounds(id)
        }
        return Moonlight.global(cocoa: screen.visibleFrame, primaryHeight: primary.frame.height)
    }

    // Moves the main window of every Moonlight that runs. `target` gets the
    // current frame and gives the new one, with the full screen state at the
    // end (nil keeps it). `moved` runs after the window took the frame.
    // `arrived` says if the frame that the window has afterwards is on the
    // wanted display: Moonlight can refuse the move with no error. A window
    // that did not move is an error, also when another did.
    private func moveMoonlight(_ target: (pid_t, CGRect) throws -> (frame: CGRect, fullScreen: Bool?),
                               arrived: (CGRect) -> Bool, moved: (pid_t) -> Void = { _ in }) throws {
        try AppWindow.requireAccess()
        let pids = moonlightPIDs
        guard !pids.isEmpty else { throw DisplayToggleError(description: "Moonlight is not running") }
        var failures: [Error] = []
        for pid in pids {
            do {
                let goal = try target(pid, AppWindow.frame(pid: pid))
                let result = try AppWindow.setFrame(pid: pid, goal.frame, fullScreen: goal.fullScreen) { step in
                    log.notice("moonlight \(pid, privacy: .public): \(step, privacy: .public)")
                }
                guard arrived(result) else {
                    throw DisplayToggleError(description: "Moonlight kept its window at \(Int(result.minX)), \(Int(result.minY))")
                }
                moved(pid)
            } catch {
                log.error("moonlight \(pid, privacy: .public): \(String(describing: error), privacy: .public)")
                failures.append(error)
            }
        }
        guard let last = failures.last else { return }
        throw DisplayToggleError(description: pids.count == 1
            ? "\(last)" : "\(failures.count) of \(pids.count) Moonlight windows did not move: \(last)")
    }

    @objc private func moveMoonlightToVirtual() {
        do {
            guard virtual.isOn, let id = virtual.displayID else {
                throw DisplayToggleError(description: "the virtual display is off")
            }
            let bounds = CGDisplayBounds(id)
            let visible = visibleFrame(of: id)
            let displays = try DisplayToggle.displays(online: false).map { CGDisplayBounds($0.id) }
            try moveMoonlight({ pid, frame in
                let middle = CGPoint(x: frame.midX, y: frame.midY)
                // The way back. A window that is on the virtual display
                // already keeps the place that it came from.
                if !bounds.contains(middle) {
                    moonlightHome[pid] = (frame, try AppWindow.isFullScreen(pid: pid))
                }
                // Full screen on a display that nobody sees costs nothing, and
                // only then the video covers the display, so the pointer maps
                // to the remote screen with no dead border.
                return (Moonlight.frame(onVirtual: bounds, visible: visible, window: frame,
                                        current: displays.first { $0.contains(middle) }), true)
            }, arrived: { bounds.contains(CGPoint(x: $0.midX, y: $0.midY)) },
               moved: { moonlightOnVirtual.insert($0) })
        } catch {
            showError(error)
        }
        checkMoonlight()
    }

    @objc private func moveMoonlightToMain() {
        do {
            let active = try DisplayToggle.displays(online: false)
            guard let anchor = VirtualDisplay.anchor(active) else {
                throw DisplayToggleError(description: "no real display is active")
            }
            let real = active.filter { !$0.isVirtual }.map { CGDisplayBounds($0.id) }
            let visible = visibleFrame(of: anchor)
            // The remembered frame goes only after the window took it: a
            // move that fails must keep the way back.
            // A window with no remembered place keeps its full screen state,
            // and so does a window that is on a real display already.
            try moveMoonlight({ pid, frame in
                let home = moonlightHome[pid]
                let goal = Moonlight.frame(onReal: real, visible: visible, remembered: home?.frame, window: frame)
                return (goal, goal == frame ? nil : home?.fullScreen)
            }, arrived: { frame in
                real.contains { $0.contains(CGPoint(x: frame.midX, y: frame.midY)) }
            }, moved: {
                moonlightHome[$0] = nil
                moonlightOnVirtual.remove($0)
            })
        } catch {
            showError(error)
        }
        checkMoonlight()
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
