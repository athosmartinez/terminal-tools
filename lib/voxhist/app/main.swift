// app/main.swift — VoxHistBar, a menu bar list of the last Voxtype transcriptions.
// A click on an entry copies its full text. The entries come from the file that
// `voxhist record` (the Voxtype post-process hook) writes.
// Agent app (LSUIElement): no Dock icon, only the status item.
// Built into ~/Applications/VoxHistBar.app by `voxhist app`.

import AppKit
import ServiceManagement

// Same default as the voxhist script. A GUI app gets no XDG_DATA_HOME, so the
// environment is read only when the app is started from a shell.
private let historyURL: URL = {
    if let path = ProcessInfo.processInfo.environment["VOXHIST_FILE"] {
        return URL(fileURLWithPath: path)
    }
    let base = ProcessInfo.processInfo.environment["XDG_DATA_HOME"]
        .map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share")
    return base.appendingPathComponent("terminal-tools/voxhist")
}()

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
    private let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd/MM HH:mm"
        return f
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let image = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: "Voxtype history")
        image?.isTemplate = true
        statusItem.button?.image = image
        menu.delegate = self
        statusItem.menu = menu
        registerLoginOnFirstLaunch()
    }

    // Read on every open: the hook writes the file, so there is nothing to watch.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let entries = loadEntries()

        if entries.isEmpty {
            menu.addItem(withTitle: "No transcriptions yet", action: nil, keyEquivalent: "").isEnabled = false
            menu.addItem(withTitle: "Run `voxhist hook` to save them", action: nil, keyEquivalent: "").isEnabled = false
        } else {
            menu.addItem(withTitle: "Click to copy", action: nil, keyEquivalent: "").isEnabled = false
            for entry in entries {
                let item = menu.addItem(withTitle: "\(timeFormat.string(from: entry.date))   \(preview(entry.text))",
                                        action: #selector(copyEntry(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = entry.text
                item.toolTip = entry.text
            }
            menu.addItem(.separator())
            menu.addItem(withTitle: "Clear History…", action: #selector(clearHistory), keyEquivalent: "").target = self
        }

        menu.addItem(.separator())
        let login = menu.addItem(withTitle: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(withTitle: "Quit VoxHistBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

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
            showError(error)
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
            showError(error)
        }
    }

    // Dictation runs all day, so the list starts at login by default; done
    // once, so turning it off in the menu sticks.
    private func registerLoginOnFirstLaunch() {
        let key = "didAutoRegisterLogin"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        try? SMAppService.mainApp.register()
    }

    private func showError(_ error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "VoxHistBar"
        alert.informativeText = "\(error)"
        alert.runModal()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
