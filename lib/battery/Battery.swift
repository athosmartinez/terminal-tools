// Battery.swift — the logic shared by the `battery` CLI and BatteryBar, with
// no Bluetooth: the config file, the label rules, the order, and the menu bar
// title. The Bluetooth reader (BLE.swift) only produces [Device] values, so
// everything here is testable with fake devices (tests/battery.test.sh).

import Foundation

/// One connected peripheral that exposes the GATT Battery Service.
/// `percent` is nil until the first read answers (or when a read fails).
struct Device: Equatable {
    let id: String
    let name: String
    var percent: Int?
}

/// The Bluetooth state the reader reports, so an app without permission
/// does not look the same as "no device connected".
enum SourceState: Equatable {
    case starting, ready, poweredOff, unauthorized, unsupported
}

/// What the CLI and the app need from a battery reader. The real one is
/// BLEBatterySource; tests use a fake.
protocol BatterySource: AnyObject {
    /// Called on the main queue after any change: a device, a value, the state.
    var onChange: (() -> Void)? { get set }
    var state: SourceState { get }
    var devices: [Device] { get }
    /// Devices found but not read yet; the CLI waits until this is zero.
    var pending: Int { get }
    func start()
    /// Look for connected devices again and read every value again.
    func refresh()
    /// The timer path: look for devices again, and read again only the values
    /// that do not arrive as notifications.
    func poll()
}

/// ~/.config/terminal-tools/battery.conf, one `key=value` per line:
///   <device name>=<label>   short label for the menu bar
///   show=<a>,<b>            only these devices (name or label), in this order
///   low=<n>                 mark a value at or below n percent (default 20)
///   interval=<s>            seconds between reads when a device has no
///                           notifications (default 300)
/// `#` starts a comment. A name may hold `=`; the label is after the last one.
struct BatteryConfig: Equatable {
    var labels: [String: String] = [:]
    var show: [String]? = nil
    var low = 20
    var interval: TimeInterval = 300

    static let defaultURL: URL = {
        if let path = ProcessInfo.processInfo.environment["BATTERY_CONFIG"] {
            return URL(fileURLWithPath: path)
        }
        // A GUI app gets no XDG_CONFIG_HOME; same default as the other tools.
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/terminal-tools/battery.conf")
    }()

    static let template = """
        # battery.conf — labels for the `battery` command and BatteryBar.
        # One line per device: <name as `battery status` prints it>=<label>
        #   My Keyboard=KB
        # Optional: show only these devices (name or label), in this order.
        #   show=KB,MS
        # Optional: mark a value at or below this percent (default 20).
        #   low=20
        # Optional: seconds between reads for a device without notifications (default 300).
        #   interval=300

        """

    static func load(from url: URL = defaultURL) -> BatteryConfig {
        parse((try? String(contentsOf: url, encoding: .utf8)) ?? "")
    }

    static func parse(_ text: String) -> BatteryConfig {
        var config = BatteryConfig()
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"),
                  let eq = line.lastIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            switch key {
            case "show":
                config.show = value.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            case "low":
                if let n = Int(value), (0...100).contains(n) { config.low = n }
            case "interval":
                if let n = TimeInterval(value), n >= 10 { config.interval = n }
            default:
                if !value.isEmpty { config.labels[key] = value }
            }
        }
        return config
    }

    /// The configured label, else the first two letters or digits of the name,
    /// in upper case ("MX Master 3S" → "MX"), else "?".
    func label(for name: String) -> String {
        if let label = labels[name] { return label }
        let short = String(name.filter { $0.isLetter || $0.isNumber }.prefix(2)).uppercased()
        return short.isEmpty ? "?" : short
    }

    func isLow(_ percent: Int?) -> Bool {
        guard let percent else { return false }
        return percent <= low
    }

    /// Position in the `show=` list, matched by full name or by label.
    private func showIndex(_ device: Device) -> Int? {
        let label = label(for: device.name)
        return show?.firstIndex { $0 == device.name || $0 == label }
    }

    /// The devices to display, in a stable order: the `show=` order when the
    /// line exists (and only those devices), else by name. Discovery order
    /// changes from run to run, so it is never used.
    func visible(_ devices: [Device]) -> [Device] {
        let byName = devices.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order != .orderedSame ? order == .orderedAscending : $0.id < $1.id
        }
        guard show != nil else { return byName }
        return byName.compactMap { d in showIndex(d).map { (d, $0) } }
            .enumerated()
            .sorted { $0.element.1 != $1.element.1 ? $0.element.1 < $1.element.1 : $0.offset < $1.offset }
            .map(\.element.0)
    }
}

/// "85%", or "--" when the value is not known yet.
func percentText(_ percent: Int?) -> String {
    percent.map { "\($0)%" } ?? "--"
}

/// One part of the menu bar title, e.g. "MX 85%". A low part starts with ⚠.
struct TitlePart: Equatable {
    let text: String
    let low: Bool
}

func titleParts(_ devices: [Device], _ config: BatteryConfig) -> [TitlePart] {
    config.visible(devices).map { d in
        let low = config.isLow(d.percent)
        // U+FE0E keeps ⚠ a text glyph that takes the menu bar tint, not an emoji.
        let mark = low ? "⚠\u{FE0E}" : ""
        return TitlePart(text: "\(mark)\(config.label(for: d.name)) \(percentText(d.percent))", low: low)
    }
}

/// The menu bar title: "LF 100%  MX 85%". Empty when no device is visible,
/// and the app then shows only a battery icon.
func titleText(_ devices: [Device], _ config: BatteryConfig) -> String {
    titleParts(devices, config).map(\.text).joined(separator: "  ")
}

/// One line per device for `battery status`: name, label, percent, aligned.
func statusLines(_ devices: [Device], _ config: BatteryConfig) -> [String] {
    let shown = config.visible(devices)
    let nameWidth = shown.map(\.name.count).max() ?? 0
    let labelWidth = shown.map { config.label(for: $0.name).count }.max() ?? 0
    return shown.map { d in
        let name = d.name.padding(toLength: nameWidth, withPad: " ", startingAt: 0)
        let label = config.label(for: d.name).padding(toLength: labelWidth, withPad: " ", startingAt: 0)
        let percent = percentText(d.percent)
        let padded = String(repeating: " ", count: max(0, 4 - percent.count)) + percent
        return "\(name)  \(label)  \(padded)\(config.isLow(d.percent) ? "  low" : "")"
    }
}

/// The first byte of the Battery Level characteristic (0x2A19) is the
/// percent. A value over 100 is out of spec and is clamped.
func batteryLevel(_ data: Data?) -> Int? {
    guard let byte = data?.first else { return nil }
    return min(Int(byte), 100)
}
