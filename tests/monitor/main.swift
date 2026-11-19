// Tests for the pure rules of lib/monitor: the config, which displays count as
// external, where the virtual display goes, and the Moonlight command.
// tests/monitor.test.sh compiles this file with the core sources. Nothing here
// lists, creates or changes a display: the displays are fakes.

import CoreGraphics
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

/// The message of the error that `body` throws, or "no error".
func failure(_ body: () throws -> Any) -> String {
    do { _ = try body(); return "no error" } catch { return "\(error)" }
}

// MARK: config

let config = MonitorConfig.parse("""
    # a comment
    hdmi_input=5
      virtual_size = 1280X720
    virtual_side=LEFT
    virtual_y=-360
    moonlight_host=box.example
    moonlight_app=Steam Big Picture
    no equals sign here
    unknown_key=1
    """)
check("hdmi_input", config.hdmiInput, 5)
check("virtual_size, spaces trimmed, any case of x", [config.virtualWidth, config.virtualHeight], [1280, 720])
check("virtual_side in any case", config.virtualSide, .left)
check("virtual_y can be negative", config.virtualY, -360)
check("moonlight_host", config.moonlightHost, "box.example")
check("moonlight_app keeps its spaces", config.moonlightApp, "Steam Big Picture")

let defaults = MonitorConfig.parse("")
check("default hdmi_input is the MCCS value", defaults.hdmiInput, 17)
check("default size is 1920x1080", [defaults.virtualWidth, defaults.virtualHeight], [1920, 1080])
check("default side is right", defaults.virtualSide, .right)
check("default y is 0", defaults.virtualY, 0)
check("no default Moonlight host", defaults.moonlightHost, "")
check("default Moonlight app", defaults.moonlightApp, "Desktop")
check("bad values keep the defaults",
      MonitorConfig.parse("hdmi_input=x\nvirtual_size=1920\nvirtual_size=0x0\nvirtual_size=99999x1080\nvirtual_side=up\nvirtual_y=top\nmoonlight_app="),
      defaults)
check("a virtual_y out of range keeps the default, also the smallest integer",
      [MonitorConfig.parse("virtual_y=10001").virtualY, MonitorConfig.parse("virtual_y=\(Int.min)").virtualY], [0, 0])
check("a host may hold =", MonitorConfig.parse("moonlight_host=a=b").moonlightHost, "a=b")

// MARK: which displays are external

let builtin = DisplayInfo(id: 1, builtin: true, vendor: 0x0610, product: 0xA001)
let monitor = DisplayInfo(id: 2, builtin: false, vendor: 0x1234, product: 0x5678)
let virtual = DisplayInfo(id: 3, builtin: false, vendor: VirtualDisplay.vendorID, product: VirtualDisplay.productID)

check("a monitor is external", monitor.isExternal, true)
check("the built-in panel is not external", builtin.isExternal, false)
check("the virtual display is not external", virtual.isExternal, false)
check("the vendor alone does not make a display virtual",
      DisplayInfo(id: 4, builtin: false, vendor: VirtualDisplay.vendorID, product: 1).isExternal, true)

check("state: a monitor is active",
      DisplayToggle.state(active: [monitor, builtin, virtual], online: [monitor, builtin, virtual], remembered: []), .on)
check("state: the virtual display alone is not an external display",
      DisplayToggle.state(active: [builtin, virtual], online: [builtin, virtual], remembered: []), .absent)
check("state: the monitor is off while the virtual display is on",
      DisplayToggle.state(active: [builtin, virtual], online: [builtin, monitor, virtual], remembered: [2]), .off)
check("state: a remembered id counts, also when it left the online list",
      DisplayToggle.state(active: [builtin, virtual], online: [builtin, virtual], remembered: [2]), .off)
check("state: a remembered id that is active again is on",
      DisplayToggle.state(active: [monitor, builtin], online: [monitor, builtin], remembered: [2]), .on)

check("restore: an inactive monitor is a candidate",
      DisplayToggle.disabledCandidates(active: [builtin], online: [builtin, monitor], remembered: []), [2])
check("restore: an inactive virtual display is not",
      DisplayToggle.disabledCandidates(active: [builtin], online: [builtin, virtual], remembered: []), [])

check("off: only the monitor is disabled",
      try? DisplayToggle.externalsSafeToDisable(active: [monitor, builtin, virtual]), [2])
check("off: the virtual display alone is nothing to disable",
      failure { try DisplayToggle.externalsSafeToDisable(active: [builtin, virtual]) }, "no active external display")
check("off: refused with the lid closed, also when the virtual display is active",
      failure { try DisplayToggle.externalsSafeToDisable(active: [monitor, virtual]) }
          .hasPrefix("built-in display is inactive"), true)

// MARK: where the virtual display goes

check("anchor: the monitor, when there is one", VirtualDisplay.anchor([builtin, monitor, virtual]), 2)
check("anchor: the built-in panel, when there is no monitor", VirtualDisplay.anchor([virtual, builtin]), 1)
check("anchor: never the virtual display itself", VirtualDisplay.anchor([virtual]), nil)

let main = CGRect(x: 0, y: 0, width: 2560, height: 1440)
check("right of the anchor, top edges aligned",
      VirtualDisplay.origin(anchor: main, width: 1920, side: .right, y: 0), CGPoint(x: 2560, y: 0))
check("y moves it down",
      VirtualDisplay.origin(anchor: main, width: 1920, side: .right, y: 360), CGPoint(x: 2560, y: 360))
check("left of the anchor",
      VirtualDisplay.origin(anchor: main, width: 1920, side: .left, y: 0), CGPoint(x: -1920, y: 0))
check("an anchor that is not the main display",
      VirtualDisplay.origin(anchor: CGRect(x: -1710, y: 628, width: 1710, height: 1107), width: 1920, side: .right, y: 10),
      CGPoint(x: 0, y: 638))
check("physical size of 1920x1080 is a 24-inch panel",
      VirtualDisplay.millimeters(width: 1920, height: 1080), CGSize(width: 530, height: 298))

// MARK: the Moonlight command

let onTheRight = CGRect(x: 2560, y: 0, width: 1920, height: 1080)
check("the stream command",
      try? Moonlight.arguments(config, display: onTheRight),
      ["stream", "box.example", "Steam Big Picture", "--display-mode", "borderless",
       "--resolution", "1920x1080", "--absolute-mouse", "-qwindowgeometry", "+2660+100"])
check("no host is an error that names the key",
      failure { try Moonlight.arguments(defaults, display: onTheRight) }.contains("moonlight_host="), true)
check("a negative x has no Qt geometry",
      Moonlight.windowGeometry(on: CGRect(x: -1920, y: 0, width: 1920, height: 1080)), nil)
check("a negative y has no Qt geometry",
      Moonlight.windowGeometry(on: CGRect(x: 2560, y: -500, width: 1920, height: 1080)), nil)
check("without a geometry the command has no Qt option",
      (try? Moonlight.arguments(config, display: CGRect(x: -1920, y: 0, width: 1920, height: 1080)))?.last,
      "--absolute-mouse")

// MARK: the private classes

// Builds the request only; no CGVirtualDisplay is made, so no display appears.
if VirtualDisplay.isAvailable {
    do {
        let (descriptor, settings) = try VirtualDisplay.request(defaults)
        check("descriptor: width", (descriptor.value(forKey: "maxPixelsWide") as? NSNumber)?.intValue, 1920)
        check("descriptor: height", (descriptor.value(forKey: "maxPixelsHigh") as? NSNumber)?.intValue, 1080)
        check("descriptor: vendor", (descriptor.value(forKey: "vendorID") as? NSNumber)?.uint32Value, VirtualDisplay.vendorID)
        check("descriptor: product", (descriptor.value(forKey: "productID") as? NSNumber)?.uint32Value, VirtualDisplay.productID)
        let modes = settings.value(forKey: "modes") as? [NSObject] ?? []
        check("settings: one mode", modes.count, 1)
        check("mode: width", (modes.first?.value(forKey: "width") as? NSNumber)?.intValue, 1920)
        check("mode: height", (modes.first?.value(forKey: "height") as? NSNumber)?.intValue, 1080)
        check("mode: refresh rate", (modes.first?.value(forKey: "refreshRate") as? NSNumber)?.doubleValue, 60)
    } catch {
        failures += 1
        print("FAIL the private classes changed: \(error)")
    }
} else {
    print("skip the private classes: this macOS has no CGVirtualDisplay")
}

print(failures == 0 ? "all passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
