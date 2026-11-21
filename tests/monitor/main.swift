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
check("the last valid line of a repeated key wins",
      MonitorConfig.parse("hdmi_input=5\nhdmi_input=17\nhdmi_input=x").hdmiInput, 17)
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
let panelOnTheLeft = CGRect(x: -1710, y: 628, width: 1710, height: 1107)
check("right of the anchor, top edges aligned",
      VirtualDisplay.origin(anchor: main, real: [main, panelOnTheLeft], width: 1920, side: .right, y: 0),
      CGPoint(x: 2560, y: 0))
check("y moves it down",
      VirtualDisplay.origin(anchor: main, real: [main, panelOnTheLeft], width: 1920, side: .right, y: 360),
      CGPoint(x: 2560, y: 360))
check("left of the anchor, with no display there",
      VirtualDisplay.origin(anchor: main, real: [main], width: 1920, side: .left, y: 0), CGPoint(x: -1920, y: 0))
check("left: past a display that is already on that side",
      VirtualDisplay.origin(anchor: main, real: [main, panelOnTheLeft], width: 1920, side: .left, y: 0),
      CGPoint(x: -3630, y: 0))
check("right: past a display that is already on that side, y still from the anchor",
      VirtualDisplay.origin(anchor: CGRect(x: -2560, y: -200, width: 2560, height: 1440),
                            real: [CGRect(x: 0, y: 0, width: 1710, height: 1107), CGRect(x: -2560, y: -200, width: 2560, height: 1440)],
                            width: 1920, side: .right, y: 10),
      CGPoint(x: 1710, y: -190))
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

// MARK: a Moonlight window that is already open

let virtualBounds = CGRect(x: 2560, y: 0, width: 1920, height: 1080)
let virtualVisible = CGRect(x: 2560, y: 25, width: 1920, height: 1055)
let home = CGRect(x: 300, y: 200, width: 1280, height: 748)
check("a window of the virtual display's size covers the display",
      Moonlight.frame(onVirtual: virtualBounds, visible: virtualVisible,
                      window: CGRect(x: 320, y: 180, width: 1920, height: 1080), current: main), virtualBounds)
check("a borderless stream that covers a real display of another size covers the virtual one",
      Moonlight.frame(onVirtual: virtualBounds, visible: virtualVisible, window: main, current: main), virtualBounds)
check("any other window fills the area below the menu bar",
      Moonlight.frame(onVirtual: virtualBounds, visible: virtualVisible, window: home, current: main), virtualVisible)
check("a window on no display fills the area below the menu bar",
      Moonlight.frame(onVirtual: virtualBounds, visible: virtualVisible, window: home, current: nil), virtualVisible)

let mainVisible = CGRect(x: 0, y: 25, width: 2560, height: 1415)
let onVirtual = CGRect(x: 2600, y: 100, width: 1280, height: 748)
check("back: the frame from before the move",
      Moonlight.frame(onReal: [main, panelOnTheLeft], visible: mainVisible, remembered: home, window: virtualVisible),
      home)
check("back: no remembered frame is the middle of the real display, same size",
      Moonlight.frame(onReal: [main], visible: mainVisible, remembered: nil, window: onVirtual),
      CGRect(x: 640, y: 358.5, width: 1280, height: 748))
check("back: a remembered frame on a display that is gone is not used, and the window shrinks to fit",
      Moonlight.frame(onReal: [panelOnTheLeft], visible: CGRect(x: -1710, y: 653, width: 1710, height: 1082),
                      remembered: home, window: virtualBounds),
      CGRect(x: -1710, y: 654, width: 1710, height: 1080))
check("back: a remembered frame on the virtual display is not used",
      Moonlight.frame(onReal: [main], visible: mainVisible, remembered: virtualBounds,
                      window: CGRect(x: 2700, y: 100, width: 800, height: 600)),
      CGRect(x: 880, y: 432.5, width: 800, height: 600))
check("back: a remembered frame with its title bar above every display is not used",
      Moonlight.frame(onReal: [main], visible: mainVisible,
                      remembered: CGRect(x: 300, y: -800, width: 1280, height: 1800), window: onVirtual),
      CGRect(x: 640, y: 358.5, width: 1280, height: 748))
check("back: a window that is on a real display stays where it is",
      Moonlight.frame(onReal: [main], visible: mainVisible, remembered: CGRect(x: 10, y: 40, width: 800, height: 600),
                      window: home), home)

check("left: a full screen stream on the virtual display is there",
      Moonlight.leftVirtual(window: virtualBounds, virtual: virtualBounds), false)
check("left: a window that macOS moved to the built-in panel is not there",
      Moonlight.leftVirtual(window: CGRect(x: 0, y: 38, width: 1710, height: 1074), virtual: virtualBounds), true)
check("left: the virtual display moved beside the built-in panel and took the window with it",
      Moonlight.leftVirtual(window: CGRect(x: 1710, y: 0, width: 1920, height: 1080),
                            virtual: CGRect(x: 1710, y: 0, width: 1920, height: 1080)), false)
check("left: a lost window counts as not there",
      Moonlight.leftVirtual(window: nil, virtual: virtualBounds), true)

check("AppKit to global: the primary screen below its menu bar",
      Moonlight.global(cocoa: CGRect(x: 0, y: 0, width: 2560, height: 1415), primaryHeight: 1440), mainVisible)
check("AppKit to global: a screen on the right, top edges aligned",
      Moonlight.global(cocoa: CGRect(x: 2560, y: 360, width: 1920, height: 1055), primaryHeight: 1440), virtualVisible)

// MARK: windows of other apps on the virtual display

let moonlightPID: pid_t = 500, ownPID: pid_t = 600
func listedWindow(_ number: CGWindowID, pid: pid_t = 100, layer: Int = 0, alpha: Double = 1, _ bounds: CGRect) -> ListedWindow {
    ListedWindow(number: number, pid: pid, layer: layer, alpha: alpha, bounds: bounds)
}
let editor = listedWindow(1, CGRect(x: 2700, y: 100, width: 800, height: 600))
let windows = [
    editor,
    listedWindow(2, CGRect(x: 300, y: 200, width: 800, height: 600)),                    // on the main display
    listedWindow(3, layer: 25, CGRect(x: 2600, y: 0, width: 300, height: 400)),          // a menu
    listedWindow(4, alpha: 0, CGRect(x: 2600, y: 0, width: 300, height: 400)),           // invisible
    listedWindow(5, pid: moonlightPID, virtualBounds),                                   // the stream
    listedWindow(6, pid: ownPID, CGRect(x: 2600, y: 0, width: 300, height: 400)),        // MonitorBar
    listedWindow(7, CGRect(x: 2400, y: 100, width: 600, height: 400)),                   // middle at x 2700
    listedWindow(8, CGRect(x: 2200, y: 100, width: 600, height: 400)),                   // middle at x 2500
    listedWindow(9, CGRect(x: 2600, y: 100, width: 0, height: 0)),                       // no size
]
check("stranded: layer 0, visible, middle on the virtual display, not Moonlight or MonitorBar",
      WindowRescue.stranded(windows, virtual: virtualBounds, moonlight: [moonlightPID], own: ownPID).map(\.number), [1, 7])
check("stranded: a Moonlight window is never a candidate, also when it is not the stream",
      WindowRescue.stranded([listedWindow(1, pid: moonlightPID, CGRect(x: 2700, y: 100, width: 800, height: 600))],
                            virtual: virtualBounds, moonlight: [moonlightPID], own: ownPID), [])

check("due: a window with attempts left", WindowRescue.due([editor], tried: [1: 2]).map(\.number), [1])
check("due: a window that used its attempts waits for a reset", WindowRescue.due([editor], tried: [1: 3]), [])
check("due: a new window", WindowRescue.due([editor], tried: [:]).map(\.number), [1])
check("pruned: the count of a window that left the virtual display or the screen stays",
      WindowRescue.pruned([1: 1, 2: 3], existing: [1, 2, 5]), [1: 1, 2: 3])
check("pruned: the count of a window that is gone goes", WindowRescue.pruned([1: 1, 42: 3], existing: [1, 2]), [1: 1])

check("target: the main display", WindowRescue.target(main: 1, active: [builtin, monitor, virtual]), 1)
check("target: the anchor when the menu bar is on the virtual display",
      WindowRescue.target(main: 3, active: [builtin, monitor, virtual]), 2)
check("target: the anchor when the main display is not active",
      WindowRescue.target(main: 2, active: [builtin, virtual]), 1)
check("target: none with no real display", WindowRescue.target(main: 3, active: [virtual]), nil)

check("frame: the top left corner stays the top left corner, same size",
      WindowRescue.frame(window: CGRect(x: 2560, y: 0, width: 800, height: 600), virtual: virtualBounds, visible: mainVisible),
      CGRect(x: 0, y: 25, width: 800, height: 600))
check("frame: the bottom right corner stays the bottom right corner",
      WindowRescue.frame(window: CGRect(x: 3680, y: 480, width: 800, height: 600), virtual: virtualBounds, visible: mainVisible),
      CGRect(x: 1760, y: 840, width: 800, height: 600))
check("frame: the middle stays the middle",
      WindowRescue.frame(window: CGRect(x: 3120, y: 240, width: 800, height: 600), virtual: virtualBounds, visible: mainVisible),
      CGRect(x: 880, y: 433, width: 800, height: 600))
check("frame: a window of the virtual display's size shrinks to the usable area",
      WindowRescue.frame(window: virtualBounds, virtual: virtualBounds,
                         visible: CGRect(x: -1710, y: 653, width: 1710, height: 1082)),
      CGRect(x: -1710, y: 654, width: 1710, height: 1080))
check("frame: a window past the edge of the virtual display stays inside the usable area",
      WindowRescue.frame(window: CGRect(x: 4000, y: -100, width: 800, height: 600), virtual: virtualBounds, visible: mainVisible),
      CGRect(x: 1760, y: 25, width: 800, height: 600))

check("matches: the same frame", WindowRescue.matches(editor.bounds, editor.bounds), true)
check("matches: a fraction of a point apart",
      WindowRescue.matches(CGRect(x: 2700.5, y: 99.5, width: 800, height: 600.5), editor.bounds), true)
check("matches: another window of the same size",
      WindowRescue.matches(CGRect(x: 2720, y: 100, width: 800, height: 600), editor.bounds), false)

let entry: [String: Any] = [
    kCGWindowNumber as String: NSNumber(value: 77),
    kCGWindowOwnerPID as String: NSNumber(value: 123),
    kCGWindowLayer as String: NSNumber(value: 0),
    kCGWindowAlpha as String: NSNumber(value: 1.0),
    kCGWindowBounds as String: CGRect(x: 2700, y: 100, width: 800, height: 600).dictionaryRepresentation,
]
check("listed: an entry of the window list",
      WindowRescue.listed([entry]), [listedWindow(77, pid: 123, CGRect(x: 2700, y: 100, width: 800, height: 600))])
check("listed: an entry with no bounds is dropped",
      WindowRescue.listed([entry.filter { $0.key != kCGWindowBounds as String }]), [])
check("listed: an entry with bounds that are not a rectangle is dropped",
      WindowRescue.listed([entry.merging([kCGWindowBounds as String: "2700,100"]) { $1 }]), [])
check("listed: no layer is layer 0, no alpha is opaque",
      WindowRescue.listed([entry.filter { $0.key != kCGWindowLayer as String && $0.key != kCGWindowAlpha as String }]),
      [listedWindow(77, pid: 123, CGRect(x: 2700, y: 100, width: 800, height: 600))])

// MARK: cancel a rescue pass

let pass = CancelFlag()
check("cancel: a new pass is not cancelled", pass.isCancelled, false)
// The main thread cancels, and the rescue queue reads the flag.
let cancelling = DispatchGroup()
DispatchQueue.global().async(group: cancelling) { pass.cancel() }
cancelling.wait()
check("cancel: the queue sees a cancel from another thread",
      DispatchQueue(label: "rescue").sync { pass.isCancelled }, true)
check("cancel: the flag of the next pass is not cancelled", CancelFlag().isCancelled, false)

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
