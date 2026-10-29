// cli/main.swift — the `monitor` command; built and run by the `monitor` wrapper.

import Foundation

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(("monitor: " + msg + "\n").data(using: .utf8)!)
    exit(1)
}

do {
    switch CommandLine.arguments.dropFirst().first {
    case "off":
        try DisplayToggle.turnOff()
        print("external display off — USB-C charging continues; run 'monitor on' to restore")
    case "on":
        try DisplayToggle.turnOn()
        print("external display on")
    case "status", nil:
        switch DisplayToggle.state() {
        case .on: print("external display: on")
        case .off: print("external display: off")
        case .absent: print("external display: not connected")
        }
    default:
        fail("usage: monitor [on|off|status|app]")
    }
} catch {
    fail("\(error)")
}
