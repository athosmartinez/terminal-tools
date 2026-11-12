// Tests for lib/battery/Battery.swift: the config, the label rules, the order
// and the title. No Bluetooth: tests/battery.test.sh compiles this file with
// Battery.swift only, and the devices are fakes.

import Foundation

var failures = 0
func check<T: Equatable>(_ name: String, _ actual: T, _ expected: T) {
    if actual == expected {
        print("ok   \(name)")
    } else {
        failures += 1
        print("FAIL \(name)\n     expected: \(expected)\n     actual:   \(actual)")
    }
}

let keyboard = Device(id: "1", name: "Keyboard K1", percent: 100)
let mouse = Device(id: "2", name: "Mouse M2", percent: 85)
let pad = Device(id: "3", name: "Pad=Pro 7", percent: 20)

// MARK: config

let config = BatteryConfig.parse("""
    # labels
    Keyboard K1=KB
      Mouse M2 = MS
    Pad=Pro 7=PD
    no equals sign here
    =orphan
    Empty Label=
    low=15
    interval=60
    """)
check("label from config", config.labels["Keyboard K1"], "KB")
check("spaces around = are trimmed", config.labels["Mouse M2"], "MS")
check("a name may hold =; the label is after the last one", config.labels["Pad=Pro 7"], "PD")
check("lines with no key, no value or no = are ignored", config.labels.count, 3)
check("low", config.low, 15)
check("interval", config.interval, 60)
check("no show= line means show everything", config.show, nil)

let defaults = BatteryConfig.parse("")
check("default low is 20", defaults.low, 20)
check("default interval is 5 min", defaults.interval, 300)
check("bad low keeps the default", BatteryConfig.parse("low=abc\nlow=150").low, 20)
check("too short interval keeps the default", BatteryConfig.parse("interval=1").interval, 300)
check("show list is trimmed, empty items dropped",
      BatteryConfig.parse("show= KB , ,Mouse M2").show, ["KB", "Mouse M2"])
check("the template parses to the defaults", BatteryConfig.parse(BatteryConfig.template), defaults)

// MARK: labels

check("configured label wins", config.label(for: "Keyboard K1"), "KB")
check("no label: first two letters, upper case", defaults.label(for: "Keyboard K1"), "KE")
check("no label: punctuation and spaces are skipped", defaults.label(for: "@x-9 pad"), "X9")
check("no label and no letters", defaults.label(for: "-- ++"), "?")
check("a one-letter name", defaults.label(for: "Q"), "Q")

// MARK: low threshold

check("at the threshold is low", defaults.isLow(20), true)
check("above the threshold is not low", defaults.isLow(21), false)
check("unknown is not low", defaults.isLow(nil), false)

// MARK: order and show=

check("no show=: sorted by name, not by discovery order",
      defaults.visible([mouse, pad, keyboard]).map(\.name), ["Keyboard K1", "Mouse M2", "Pad=Pro 7"])
var only = config
only.show = ["MS", "Keyboard K1"]
check("show=: only listed devices, by label or name, in show= order",
      only.visible([keyboard, pad, mouse]).map(\.name), ["Mouse M2", "Keyboard K1"])
only.show = []
check("an empty show= hides everything", only.visible([keyboard, mouse]).count, 0)

// MARK: title

check("title: labels and percents, two spaces apart, name order",
      titleText([mouse, keyboard], config), "KB 100%  MS 85%")
check("title: no device is an empty title (icon only)", titleText([], config), "")
check("title: a low device gets the warning mark",
      titleText([Device(id: "2", name: "Mouse M2", percent: 15)], config), "⚠\u{FE0E}MS 15%")
check("title: low part flagged for the color",
      titleParts([Device(id: "2", name: "Mouse M2", percent: 15), keyboard], config).map(\.low), [false, true])
check("title: not read yet shows --",
      titleText([Device(id: "1", name: "Keyboard K1", percent: nil)], config), "KB --")
check("title: unlabeled device uses its first letters",
      titleText([Device(id: "9", name: "Headset", percent: 40)], defaults), "HE 40%")

// MARK: status lines

check("status: name, label, percent aligned; low marked",
      statusLines([mouse, keyboard, Device(id: "3", name: "Pad=Pro 7", percent: 5)], config),
      ["Keyboard K1  KB  100%",
       "Mouse M2     MS   85%",
       "Pad=Pro 7    PD    5%  low"])

// MARK: a fake source drives the title, as BLEBatterySource does in the app

final class FakeSource: BatterySource {
    var onChange: (() -> Void)?
    var state: SourceState = .starting
    var devices: [Device] = []
    var pending: Int { devices.filter { $0.percent == nil }.count }
    func start() { state = .ready; onChange?() }
    func refresh() {}
    func poll() {}
    func report(_ devices: [Device]) { self.devices = devices; onChange?() }
}

let fake = FakeSource()
let source: BatterySource = fake   // the app and the CLI see only the protocol
var titles: [String] = []
source.onChange = { titles.append(titleText(source.devices, config)) }
source.start()
fake.report([Device(id: "2", name: "Mouse M2", percent: nil)])
check("source: pending counts the devices not read yet", source.pending, 1)
fake.report([Device(id: "2", name: "Mouse M2", percent: 12), keyboard])
check("source: every change renders a new title",
      titles, ["", "MS --", "KB 100%  ⚠\u{FE0E}MS 12%"])
check("source: nothing pending once every device answered", source.pending, 0)

// MARK: GATT value

check("battery level: first byte", batteryLevel(Data([85, 1])), 85)
check("battery level: empty value", batteryLevel(Data()), nil)
check("battery level: missing value", batteryLevel(nil), nil)
check("battery level: out of spec is clamped", batteryLevel(Data([255])), 100)

if failures > 0 {
    print("\(failures) failed")
    exit(1)
}
print("all passed")
