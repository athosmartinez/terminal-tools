// app/main.swift — VoxBar, the menu bar item for Voxtype.
// The icon shows the daemon state (ready, recording, transcribing, stuck, not
// running). The menu restarts the daemon, opens its log, and lists the last
// transcriptions; a click on one copies its full text. The entries come from
// the file that `vox record` (the Voxtype post-process hook) writes.
// Agent app (LSUIElement): no Dock icon, only the status item.
// Built into ~/Applications/VoxBar.app by `vox app`.

import AppKit
import ServiceManagement

private let env = ProcessInfo.processInfo.environment
private let home = FileManager.default.homeDirectoryForCurrentUser

// Same default as the vox script. A GUI app gets no XDG_DATA_HOME, so the
// environment counts only when the app is started from a shell.
private let historyURL: URL = {
    if let path = env["VOX_HISTORY_FILE"] { return URL(fileURLWithPath: path) }
    let base = env["XDG_DATA_HOME"].map { URL(fileURLWithPath: $0) }
        ?? home.appendingPathComponent(".local/share")
    return base.appendingPathComponent("terminal-tools/vox-history")
}()

// The daemon writes these on macOS (`state_file = "auto"` in its config).
private let stateFile = "/tmp/voxtype/state"
private let pidFile = "/tmp/voxtype/pid"
private let logFile = home.appendingPathComponent("Library/Logs/voxtype/stdout.log").path
private let daemonLabel = "io.voxtype.daemon"
// max_duration_secs is 60, and large-v3-turbo on the M2 transcribes 60 s of
// audio in about 25 s, so 90 s in "transcribing" is a hang, not a slow run.
private let stuckAfter: TimeInterval = 90

enum Status: Equatable {
    case notRunning, ready, recording, transcribing, stuck

    var symbol: String {
        switch self {
        case .notRunning: return "mic.slash"
        case .ready: return "mic"
        case .recording: return "mic.fill"
        case .transcribing: return "hourglass"
        case .stuck: return "exclamationmark.triangle"
        }
    }

    var tint: NSColor? {
        switch self {
        case .recording: return .systemRed
        case .stuck: return .systemOrange
        default: return nil   // follow the menu bar's light/dark tint
        }
    }

    func label(seconds: Int) -> String {
        switch self {
        case .notRunning: return "Voxtype: not running"
        case .ready: return "Voxtype: ready"
        case .recording: return "Voxtype: recording (\(seconds) s)"
        case .transcribing: return "Voxtype: transcribing (\(seconds) s)"
        case .stuck: return "Voxtype: transcription stuck for \(seconds) s"
        }
    }
}

// A dead pid means the daemon crashed or was stopped; its state file stays.
func readStatus() -> (Status, Int) {
    let pidText = (try? String(contentsOfFile: pidFile, encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let pid = pidText.flatMap({ pid_t($0) }), pid > 0,
          kill(pid, 0) == 0 || errno == EPERM else { return (.notRunning, 0) }

    let state = (try? String(contentsOfFile: stateFile, encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let changed = (try? FileManager.default.attributesOfItem(atPath: stateFile)[.modificationDate]) as? Date
    let age = max(0, Int(Date().timeIntervalSince(changed ?? Date())))
    switch state {
    case "recording": return (.recording, age)
    case "transcribing": return (TimeInterval(age) >= stuckAfter ? .stuck : .transcribing, age)
    default: return (.ready, age)
    }
}

struct Entry {
    let date: Date
    let text: String
}

// Records "<epoch>\t<text>" joined by U+001E, oldest first.
func loadEntries() -> [Entry] {
    guard let data = try? Data(contentsOf: historyURL),
          let raw = String(data: data, encoding: .utf8) else { return [] }
    return raw.split(separator: "\u{1e}").compactMap { record in
        guard let tab = record.firstIndex(of: "\t"),
              let epoch = TimeInterval(record[..<tab]) else { return nil }
        return Entry(date: Date(timeIntervalSince1970: epoch),
                     text: String(record[record.index(after: tab)...]))
    }.reversed()
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private var shown: Status?
    private weak var headerItem: NSMenuItem?
    private let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd/MM HH:mm"
        return f
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        menu.delegate = self
        statusItem.menu = menu
        refresh()
        registerLoginOnFirstLaunch()

        // Polled, not watched: the daemon gives no event when it dies, and the
        // state file is rewritten in place. Two tiny reads a second cost
        // nothing. The .common mode keeps the header live while the menu is open.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        timer.tolerance = 0.25
        RunLoop.main.add(timer, forMode: .common)
    }

    private func refresh() {
        let (status, seconds) = readStatus()
        headerItem?.title = status.label(seconds: seconds)
        guard status != shown else { return }
        shown = status
        let image = NSImage(systemSymbolName: status.symbol, accessibilityDescription: status.label(seconds: 0))
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.contentTintColor = status.tint
    }

    // Rebuilt on every open, so a new transcription shows with no refresh.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let (status, seconds) = readStatus()

        let header = menu.addItem(withTitle: status.label(seconds: seconds), action: nil, keyEquivalent: "")
        header.isEnabled = false
        headerItem = header
        let restart = status == .notRunning ? "Start Voxtype" : "Restart Voxtype"
        menu.addItem(withTitle: restart, action: #selector(restartDaemon), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Open Log", action: #selector(openLog), keyEquivalent: "").target = self

        menu.addItem(.separator())
        let entries = loadEntries()
        if entries.isEmpty {
            menu.addItem(withTitle: "No transcriptions yet", action: nil, keyEquivalent: "").isEnabled = false
            menu.addItem(withTitle: "Run `vox hook` to save them", action: nil, keyEquivalent: "").isEnabled = false
        } else {
            menu.addItem(withTitle: "Recent transcriptions — click to copy", action: nil, keyEquivalent: "").isEnabled = false
            for entry in entries {
                let item = menu.addItem(withTitle: "\(timeFormat.string(from: entry.date))   \(preview(entry.text))",
                                        action: #selector(copyEntry(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = entry.text
                item.toolTip = entry.text
            }
            menu.addItem(withTitle: "Clear History…", action: #selector(clearHistory), keyEquivalent: "").target = self
        }

        menu.addItem(.separator())
        let login = menu.addItem(withTitle: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(withTitle: "Quit VoxBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    func menuDidClose(_ menu: NSMenu) { headerItem = nil }

    // One line per entry, short enough for a menu; the tooltip shows it all.
    private func preview(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ⏎ ")
        return line.count > 70 ? String(line.prefix(70)) + "…" : line
    }

    @objc private func copyEntry(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // kickstart -k kills a running (or hung) daemon and starts it again;
    // launchd keeps it alive, so this is also the way to start it.
    @objc private func restartDaemon() {
        run("/bin/launchctl", ["kickstart", "-k", "gui/\(getuid())/\(daemonLabel)"])
    }

    @objc private func openLog() {
        run("/usr/bin/open", ["-a", "Console", logFile])
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

    @objc private func clearHistory() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Clear the Voxtype history?"
        alert.informativeText = "This deletes \(historyURL.path)."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try FileManager.default.removeItem(at: historyURL)
        } catch CocoaError.fileNoSuchFile {
        } catch {
            showMessage("\(error)")
        }
    }

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

    // Dictation runs all day, so the item starts at login by default; done
    // once, so turning it off in the menu sticks.
    private func registerLoginOnFirstLaunch() {
        let key = "didAutoRegisterLogin"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        try? SMAppService.mainApp.register()
    }

    private func showMessage(_ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "VoxBar"
        alert.informativeText = text
        alert.runModal()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
