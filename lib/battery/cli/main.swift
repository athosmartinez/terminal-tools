// cli/main.swift — `battery [status] [-a]`: one line per connected device
// that reports its battery (name, label, percent), then exit.
// Built into ~/.cache/terminal-tools/battery by the `battery` wrapper.

import Foundation

let arguments = CommandLine.arguments.dropFirst()
let showAll = arguments.contains("-a") || arguments.contains("--all")

func fail(_ message: String, _ code: Int32) -> Never {
    FileHandle.standardError.write(Data("battery: \(message)\n".utf8))
    exit(code)
}

var config = BatteryConfig.load()
if showAll { config.show = nil }

let source: BatterySource = BLEBatterySource()
var done = false
source.onChange = {
    switch source.state {
    case .starting: break
    case .ready: done = source.pending == 0
    default: done = true
    }
}
source.start()

// A device answers in well under a second; one that never answers shows "--".
let deadline = Date().addingTimeInterval(6)
while !done && Date() < deadline {
    RunLoop.main.run(mode: .default, before: min(deadline, Date().addingTimeInterval(0.1)))
}

switch source.state {
case .unauthorized:
    fail("no Bluetooth permission — allow your terminal app in System Settings > Privacy & Security > Bluetooth", 2)
case .poweredOff:
    fail("Bluetooth is off", 1)
case .unsupported:
    fail("this Mac has no Bluetooth Low Energy", 1)
case .starting:
    fail("Bluetooth did not answer", 1)
case .ready:
    break
}

let devices = source.devices
let lines = statusLines(devices, config)
if lines.isEmpty {
    let hidden = devices.count
    fail(hidden > 0 ? "\(hidden) device(s) hidden by show= in \(BatteryConfig.defaultURL.path) — use -a"
                    : "no connected device reports its battery", 0)
}
for line in lines { print(line) }
