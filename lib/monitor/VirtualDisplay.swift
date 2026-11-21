// VirtualDisplay.swift — a display with no screen behind it.
//
// macOS extends the desktop onto it like onto a real monitor, but nothing shows
// the picture. MonitorBar uses it as a landing area: a borderless Moonlight
// window fills it, so moving the pointer past the edge of the real monitor
// enters the stream and controls the remote machine, whose own screen the user
// looks at.
//
// CGVirtualDisplay is private (no header). The classes are found by name and
// the methods by selector at run time, like the dlsym calls in DisplayToggle
// and DDC, so a macOS release that removes or changes them gives an error in
// the menu, not an app that cannot start.
//
// The display exists only while its CGVirtualDisplay object does. Its owner
// must be a process that stays: MonitorBar, never the CLI.

import ApplicationServices
import CoreGraphics
import Foundation

final class VirtualDisplay {
    // A fixed identity: macOS keys the remembered arrangement on it, and
    // DisplayToggle uses vendor + product to tell this display from a monitor.
    // The vendor is not a valid EDID manufacturer code (its first letter is
    // above Z), so no real monitor reports it.
    static let vendorID: UInt32 = 0x7474
    static let productID: UInt32 = 0x5644
    static let serialNumber: UInt32 = 1

    private var display: NSObject?

    static var isAvailable: Bool {
        ["CGVirtualDisplay", "CGVirtualDisplayDescriptor", "CGVirtualDisplaySettings", "CGVirtualDisplayMode"]
            .allSatisfy { NSClassFromString($0) != nil }
    }

    /// The id of the display object, also when WindowServer does not list it.
    var displayID: CGDirectDisplayID? {
        guard let display, display.responds(to: NSSelectorFromString("displayID")) else { return nil }
        return (display.value(forKey: "displayID") as? NSNumber)?.uint32Value
    }

    /// True when the object exists and WindowServer lists its display. The
    /// system can take the display away and leave the object.
    var isOn: Bool {
        guard let id = displayID, let online = try? DisplayToggle.displays(online: true) else { return false }
        return online.contains { $0.id == id }
    }

    func turnOn(_ config: MonitorConfig) throws {
        turnOff()
        let (descriptor, settings) = try Self.request(config)
        let created = try Self.makeDisplay(descriptor)
        guard try Self.apply(settings, to: created) else {
            throw DisplayToggleError(description: "macOS refused the virtual display mode \(config.virtualWidth)x\(config.virtualHeight)")
        }
        display = created
    }

    /// What `turnOn` asks macOS for. Both are plain objects: nothing reaches
    /// WindowServer until a CGVirtualDisplay is made from them, so the tests
    /// build them to check that the private classes still have this shape.
    static func request(_ config: MonitorConfig) throws -> (descriptor: NSObject, settings: NSObject) {
        let descriptor = try object("CGVirtualDisplayDescriptor")
        try set(descriptor, "queue", DispatchQueue.main)
        try set(descriptor, "name", "MonitorBar Virtual Display")
        try set(descriptor, "maxPixelsWide", config.virtualWidth)
        try set(descriptor, "maxPixelsHigh", config.virtualHeight)
        try set(descriptor, "sizeInMillimeters",
                NSValue(size: millimeters(width: config.virtualWidth, height: config.virtualHeight)))
        try set(descriptor, "vendorID", vendorID)
        try set(descriptor, "productID", productID)
        // Older releases only have the short name.
        let serialKey = descriptor.responds(to: NSSelectorFromString("setSerialNum:")) ? "serialNum" : "serialNumber"
        try set(descriptor, serialKey, serialNumber)

        // One mode and no HiDPI: a point is a pixel, so the stream maps 1:1.
        let settings = try object("CGVirtualDisplaySettings")
        try set(settings, "hiDPI", 0)
        try set(settings, "modes", [mode(width: config.virtualWidth, height: config.virtualHeight)])
        return (descriptor, settings)
    }

    /// Releasing the object removes the display; macOS moves its windows back.
    func turnOff() { display = nil }

    /// Moves the display beside its anchor. WindowServer adds a new display a
    /// moment after `turnOn` returns, so the caller runs this a little later
    /// and again when the set of displays changes. Returns false when the
    /// display is not active yet: while a monitor is plugged in or out,
    /// WindowServer leaves the virtual display out of the list for a moment,
    /// so the caller tries again.
    @discardableResult
    func place(_ config: MonitorConfig) throws -> Bool {
        guard let id = displayID else { return true }
        let active = try DisplayToggle.displays(online: false)
        // With no real display active, the virtual one is the whole desktop:
        // every window is on a screen that nobody can see. This comes first:
        // the virtual display can be out of the list at the same time.
        guard let anchor = Self.anchor(active) else {
            turnOff()
            throw DisplayToggleError(description: "no real display is active — virtual display turned off")
        }
        guard active.contains(where: { $0.id == id }) else { return false }
        let bounds = CGDisplayBounds(id)
        let real = active.filter { !$0.isVirtual }.map { CGDisplayBounds($0.id) }
        let wanted = Self.origin(anchor: CGDisplayBounds(anchor), real: real, width: bounds.width,
                                 side: config.virtualSide, y: config.virtualY)
        guard bounds.origin != wanted else { return true }

        var configuration: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&configuration) == .success else {
            throw DisplayToggleError(description: "cannot begin display configuration")
        }
        let err = CGConfigureDisplayOrigin(configuration, id, Int32(wanted.x), Int32(wanted.y))
        guard err == .success else {
            CGCancelDisplayConfiguration(configuration)
            throw DisplayToggleError(description: "cannot move the virtual display (CGError \(err.rawValue))")
        }
        // Permanent, so macOS brings the next virtual display up in place.
        guard CGCompleteDisplayConfiguration(configuration, .permanently) == .success else {
            throw DisplayToggleError(description: "cannot apply display configuration")
        }
        return true
    }

    // MARK: rules (pure)

    /// The display that the virtual one sits beside: the external monitor, or
    /// the built-in panel when there is none. Never the virtual display itself.
    static func anchor(_ active: [DisplayInfo]) -> CGDirectDisplayID? {
        (active.first(where: \.isExternal) ?? active.first(where: \.builtin))?.id
    }

    /// Global display coordinates: x grows to the right and y grows down. The
    /// anchor gives y. Every real display gives x: the place beside the anchor
    /// can hold another display, and the virtual one must not land on it.
    static func origin(anchor: CGRect, real: [CGRect], width: CGFloat, side: MonitorConfig.Side, y: Int) -> CGPoint {
        let x = side == .right
            ? real.reduce(anchor.maxX) { max($0, $1.maxX) }
            : real.reduce(anchor.minX) { min($0, $1.minX) } - width
        return CGPoint(x: x, y: anchor.minY + CGFloat(y))
    }

    /// What the app does after a placement that failed.
    enum PlacementRetry: Equatable { case again, recreate, stop }

    /// The failure is a false result of `place` (the display is not in the
    /// active list yet) or an error (WindowServer can refuse a configuration
    /// while it settles); both get the same attempts. `exists` is false when
    /// `place` released the object because no real display is active: there
    /// is nothing to retry. After the last attempt the app makes the display
    /// again, once (`recreated`): WindowServer can drop the display and keep
    /// the object, and a new object comes back listed.
    static func afterFailedPlacement(attempt: Int, attempts: Int, exists: Bool, recreated: Bool) -> PlacementRetry {
        guard exists else { return .stop }
        if attempt < attempts { return .again }
        return recreated ? .stop : .recreate
    }

    // macOS uses the physical size only to choose a default scale. 92 pixels
    // per inch is a 24-inch 1080p panel, which gets no scaling.
    static func millimeters(width: Int, height: Int) -> CGSize {
        CGSize(width: (Double(width) * 25.4 / 92).rounded(), height: (Double(height) * 25.4 / 92).rounded())
    }

    // MARK: private API plumbing

    private static func unavailable(_ what: String) -> DisplayToggleError {
        DisplayToggleError(description: "virtual displays are not available on this macOS version (\(what))")
    }

    private static func object(_ name: String) throws -> NSObject {
        guard let cls = NSClassFromString(name) as? NSObject.Type else { throw unavailable("no \(name)") }
        return cls.init()
    }

    // Key-value coding converts the value to the property's own type. A missing
    // setter must be found first: an unknown key raises an Objective-C
    // exception, and Swift cannot catch it.
    private static func set(_ object: NSObject, _ key: String, _ value: Any) throws {
        let setter = "set" + key.prefix(1).uppercased() + key.dropFirst() + ":"
        guard object.responds(to: NSSelectorFromString(setter)) else {
            throw unavailable("\(type(of: object)) has no \(key)")
        }
        object.setValue(value, forKey: key)
    }

    // The function behind a selector, cast to its C type. The type encoding is
    // compared first, without its frame offsets: a call through the wrong
    // signature does not fail, it corrupts the arguments.
    private static func implementation<Function>(_ cls: AnyClass, _ selector: String, encodings: [String],
                                                 as type: Function.Type) throws -> (Selector, Function) {
        let sel = NSSelectorFromString(selector)
        guard let method = class_getInstanceMethod(cls, sel), let raw = method_getTypeEncoding(method) else {
            throw unavailable("\(cls) has no \(selector)")
        }
        let encoding = String(cString: raw).filter { !$0.isNumber }
        guard encodings.contains(encoding) else {
            throw unavailable("\(selector) has the signature \(encoding)")
        }
        return (sel, unsafeBitCast(method_getImplementation(method), to: type))
    }

    // alloc, then an init that takes arguments. Raw pointers keep ARC out: an
    // init consumes the allocated object and returns it retained, or releases
    // it and returns nil, and Swift assumes neither for a C function pointer.
    private static func construct(_ cls: AnyClass,
                                  _ initialize: (UnsafeMutableRawPointer) -> UnsafeMutableRawPointer?) throws -> NSObject {
        typealias AllocFn = @convention(c) (AnyClass, Selector) -> UnsafeMutableRawPointer?
        let sel = NSSelectorFromString("alloc")
        guard let method = class_getClassMethod(cls, sel) else { throw unavailable("\(cls) has no alloc") }
        let alloc = unsafeBitCast(method_getImplementation(method), to: AllocFn.self)
        guard let allocated = alloc(cls, sel), let object = initialize(allocated) else {
            throw DisplayToggleError(description: "macOS did not create a \(cls)")
        }
        return Unmanaged<NSObject>.fromOpaque(object).takeRetainedValue()
    }

    private static func mode(width: Int, height: Int) throws -> NSObject {
        typealias InitFn = @convention(c) (UnsafeMutableRawPointer, Selector, UInt32, UInt32, Double) -> UnsafeMutableRawPointer?
        guard let cls = NSClassFromString("CGVirtualDisplayMode") else { throw unavailable("no CGVirtualDisplayMode") }
        let (sel, initialize) = try implementation(cls, "initWithWidth:height:refreshRate:",
                                                   encodings: ["@@:IId"], as: InitFn.self)
        return try construct(cls) { initialize($0, sel, UInt32(width), UInt32(height), 60) }
    }

    private static func makeDisplay(_ descriptor: NSObject) throws -> NSObject {
        typealias InitFn = @convention(c) (UnsafeMutableRawPointer, Selector, UnsafeMutableRawPointer) -> UnsafeMutableRawPointer?
        guard let cls = NSClassFromString("CGVirtualDisplay") else { throw unavailable("no CGVirtualDisplay") }
        let (sel, initialize) = try implementation(cls, "initWithDescriptor:", encodings: ["@@:@"], as: InitFn.self)
        return try withExtendedLifetime(descriptor) {
            try construct(cls) { initialize($0, sel, Unmanaged.passUnretained(descriptor).toOpaque()) }
        }
    }

    // BOOL is a C bool on Apple Silicon ("B") and a signed char on Intel ("c").
    private static func apply(_ settings: NSObject, to display: NSObject) throws -> Bool {
        typealias ApplyFn = @convention(c) (AnyObject, Selector, AnyObject) -> ObjCBool
        let (sel, apply) = try implementation(type(of: display), "applySettings:",
                                              encodings: ["B@:@", "c@:@"], as: ApplyFn.self)
        return apply(display, sel, settings).boolValue
    }
}

/// The Moonlight command that opens a stream on the virtual display.
enum Moonlight {
    static let bundleID = "com.moonlight-stream.Moonlight"

    // The stream window opens on the display that holds Moonlight's first
    // window, so the point only has to be clearly inside the virtual display.
    private static let inset = 100

    /// `display` is the virtual display's rectangle in global coordinates.
    /// Borderless and the display's own size make the video cover it exactly,
    /// and with an absolute mouse Moonlight does not capture the pointer, so
    /// the pointer leaves the stream at the edge of the display.
    static func arguments(_ config: MonitorConfig, display: CGRect) throws -> [String] {
        guard !config.moonlightHost.isEmpty else {
            throw DisplayToggleError(description: "set moonlight_host=<host> in ~/.config/terminal-tools/monitor.conf")
        }
        var arguments = ["stream", config.moonlightHost, config.moonlightApp,
                         "--display-mode", "borderless",
                         "--resolution", "\(Int(display.width))x\(Int(display.height))",
                         "--absolute-mouse"]
        if let geometry = windowGeometry(on: display) {
            arguments += ["-qwindowgeometry", geometry]
        }
        return arguments
    }

    /// The value of Qt's `-qwindowgeometry`, which positions the first window
    /// that Moonlight shows. Qt removes the option before Moonlight parses the
    /// command line. Its syntax has digits only: `+x+y` counts from the top
    /// left of the main display, and `-x` counts from the right edge. So it
    /// cannot name a negative coordinate (a display on the left of or above
    /// the main one), and the result is nil then. Moonlight then opens where
    /// it was last, and moving its window (below) takes it to the display.
    static func windowGeometry(on display: CGRect) -> String? {
        let x = Int(display.minX) + inset, y = Int(display.minY) + inset
        guard x >= 0, y >= 0 else { return nil }
        return "+\(x)+\(y)"
    }

    // MARK: a window that is already open

    /// Where a Moonlight window goes on the virtual display. A borderless
    /// stream covers its display, and it must cover the virtual one too: that
    /// is a window with the frame of the display that it is on (`current`), or
    /// with the virtual display's own size. Any other window has a title bar,
    /// which macOS keeps below the menu bar, so it fills the area that the
    /// menu bar leaves.
    static func frame(onVirtual bounds: CGRect, visible: CGRect, window: CGRect, current: CGRect?) -> CGRect {
        window.size == bounds.size || window == current ? bounds : visible
    }

    /// Where it goes back to. A window that is on a real display stays where
    /// it is. Otherwise it gets the frame from before the move, when a real
    /// display holds the middle of that frame's top edge: the title bar must
    /// be in reach. Otherwise it goes to the middle of `visible`, the usable
    /// area of a real display, and is no larger than that area.
    static func frame(onReal real: [CGRect], visible: CGRect, remembered: CGRect?, window: CGRect) -> CGRect {
        func onReal(_ point: CGPoint) -> Bool { real.contains { $0.contains(point) } }
        if onReal(CGPoint(x: window.midX, y: window.midY)) { return window }
        if let remembered, onReal(CGPoint(x: remembered.midX, y: remembered.minY)) { return remembered }
        let size = CGSize(width: min(window.width, visible.width), height: min(window.height, visible.height))
        return CGRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    /// True when a Moonlight window that the user sent to the virtual display
    /// is not there now. macOS moves windows off a display that leaves the
    /// list, also for a moment while a monitor is plugged in or out, and does
    /// not move them back. No window (nil) also counts: the window was lost.
    static func leftVirtual(window: CGRect?, virtual: CGRect) -> Bool {
        guard let window else { return true }
        return !virtual.contains(CGPoint(x: window.midX, y: window.midY))
    }

    /// AppKit counts y up from the bottom of the primary screen. Displays and
    /// the Accessibility API count y down from its top.
    static func global(cocoa rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}

/// A window as the window server lists it. `bounds` is in global coordinates,
/// y down, the same space as `CGDisplayBounds` and the Accessibility API.
struct ListedWindow: Equatable {
    let number: CGWindowID
    let pid: pid_t
    let layer: Int
    let alpha: Double
    let bounds: CGRect
}

/// The windows of other apps that land on the virtual display, where nobody
/// sees them, and where they go back to. Only a Moonlight stream belongs there.
enum WindowRescue {
    /// Automatic attempts per window. An app can put a moved window back, so
    /// every attempt counts, also one that moved the window: a window that
    /// keeps coming back stops after this many moves and gets the badge.
    static let attempts = 3

    /// The on-screen windows. Detection needs no Accessibility grant. A window
    /// on a Space that is not shown (for example the desktop Space of the
    /// virtual display behind a full screen Moonlight) is not on screen.
    static func onScreen() -> [ListedWindow] {
        listed(CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? [])
    }

    /// The entries of `CGWindowListCopyWindowInfo`. An entry with no number,
    /// owner or bounds is dropped.
    static func listed(_ info: [[String: Any]]) -> [ListedWindow] {
        info.compactMap { entry in
            guard let number = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let pid = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let raw = entry[kCGWindowBounds as String], CFGetTypeID(raw as CFTypeRef) == CFDictionaryGetTypeID(),
                  let bounds = CGRect(dictionaryRepresentation: raw as! CFDictionary) else { return nil }
            return ListedWindow(number: number, pid: pid,
                                layer: (entry[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0,
                                alpha: (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1,
                                bounds: bounds)
        }
    }

    /// The windows to take off the virtual display: layer 0 (menus, the Dock
    /// and overlays have other layers), visible, with their middle on the
    /// virtual display, and not of Moonlight or of MonitorBar. A Moonlight
    /// window is never moved by itself: it only gets a warning.
    static func stranded(_ windows: [ListedWindow], virtual: CGRect, moonlight: Set<pid_t>, own: pid_t) -> [ListedWindow] {
        windows.filter { window in
            window.layer == 0 && window.alpha > 0 && !window.bounds.isEmpty
                && !moonlight.contains(window.pid) && window.pid != own
                && virtual.contains(CGPoint(x: window.bounds.midX, y: window.bounds.midY))
        }
    }

    /// The windows that get an automatic attempt now.
    static func due(_ stranded: [ListedWindow], tried: [CGWindowID: Int]) -> [ListedWindow] {
        stranded.filter { tried[$0.number, default: 0] < attempts }
    }

    /// The number of every window that exists, also off screen (minimized,
    /// hidden, on another Space). Only for `pruned`: this list also holds
    /// hidden helper windows, which must never count as stranded.
    static func existing() -> Set<CGWindowID> {
        Set(listed(CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []).map(\.number))
    }

    /// The counts of the windows that still exist. A count is kept while its
    /// window exists, also after the window left the virtual display or the
    /// screen: the window can come back, and a count that starts again is a loop.
    static func pruned(_ tried: [CGWindowID: Int], existing: Set<CGWindowID>) -> [CGWindowID: Int] {
        tried.filter { existing.contains($0.key) }
    }

    /// Where the windows go: the main display (the one with the menu bar),
    /// else the display that the virtual one sits beside.
    static func target(main: CGDirectDisplayID, active: [DisplayInfo]) -> CGDirectDisplayID? {
        active.first { $0.id == main && !$0.isVirtual }?.id ?? VirtualDisplay.anchor(active)
    }

    /// The window on `visible`, the usable area of the target display. It
    /// keeps its size when that fits, and shrinks to fit when not. It keeps
    /// its relative place: a window in the top left corner of the virtual
    /// display goes to the top left corner, so several windows do not land
    /// on top of each other. A window as wide as the virtual display (or
    /// wider) is centered on that axis.
    static func frame(window: CGRect, virtual: CGRect, visible: CGRect) -> CGRect {
        let size = CGSize(width: min(window.width, visible.width), height: min(window.height, visible.height))
        func share(_ offset: CGFloat, _ room: CGFloat) -> CGFloat {
            room > 0 ? min(max(offset / room, 0), 1) : 0.5
        }
        let x = share(window.minX - virtual.minX, virtual.width - window.width)
        let y = share(window.minY - virtual.minY, virtual.height - window.height)
        return CGRect(x: (visible.minX + x * (visible.width - size.width)).rounded(),
                      y: (visible.minY + y * (visible.height - size.height)).rounded(),
                      width: size.width, height: size.height)
    }

    /// True when an Accessibility frame is the listed window. The two lists
    /// can round a fraction of a point differently.
    static func matches(_ frame: CGRect, _ bounds: CGRect) -> Bool {
        abs(frame.minX - bounds.minX) <= 1 && abs(frame.minY - bounds.minY) <= 1
            && abs(frame.width - bounds.width) <= 1 && abs(frame.height - bounds.height) <= 1
    }
}

/// A flag that one thread sets and another thread reads. The main thread
/// cancels a rescue pass; the rescue queue reads the flag before each window
/// and before each frame request, and stops the pass.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

/// A window of another app (its main window, or one found by its frame), read
/// and moved through the Accessibility API. The user must allow MonitorBar in
/// Privacy & Security > Accessibility.
enum AppWindow {
    /// Throws when the permission is missing, after macOS shows its request.
    /// The grant belongs to one build of the app: an ad-hoc signature changes
    /// with every rebuild, and macOS then keeps the entry but ignores it.
    static func requireAccess() throws {
        // The value of kAXTrustedCheckOptionPrompt. The constant is a global
        // variable, which Swift's concurrency checks do not accept.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else {
            throw DisplayToggleError(description: """
                MonitorBar needs the Accessibility permission to move a window: \
                System Settings > Privacy & Security > Accessibility. If MonitorBar is in the list \
                and this message still shows, remove it from the list and add it again.
                """)
        }
    }

    /// The frame in global coordinates: y grows down from the top of the main display.
    /// `timeout` is the wait for each AX call in seconds; nil keeps the default.
    static func frame(pid: pid_t, timeout: Float? = nil) throws -> CGRect {
        try currentFrame(mainWindow(pid, timeout: timeout))
    }

    /// The frame from the two Accessibility values. A value that the read did
    /// not give (nil, the call failed or timed out) or that has another type
    /// is an error. A frame of zeros in its place looks like a window with no
    /// size, and two failed reads look like a window that is at rest.
    static func frame(position: AXValue?, size: AXValue?) throws -> CGRect {
        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard let position, AXValueGetValue(position, .cgPoint, &origin),
              let size, AXValueGetValue(size, .cgSize, &extent) else {
            throw DisplayToggleError(description: "cannot read the window frame")
        }
        return CGRect(origin: origin, size: extent)
    }

    /// True when a frame can be asked for: a window with no width or no
    /// height is never the goal of a move.
    static func hasSize(_ frame: CGRect) -> Bool { frame.width > 0 && frame.height > 0 }

    static func isFullScreen(pid: pid_t) throws -> Bool { isFullScreen(try mainWindow(pid)) }

    /// Moves the window and returns the frame that it has afterwards: an app
    /// can refuse a size, or put the window back. `fullScreen` is the state at
    /// the end; nil keeps the state that the window has. `trace` gets one line
    /// for each step, for the log.
    @discardableResult
    static func setFrame(pid: pid_t, _ frame: CGRect, fullScreen: Bool? = nil,
                         trace: (String) -> Void = { _ in }) throws -> CGRect {
        try setFrame(try mainWindow(pid), fullScreen: fullScreen, trace: trace) { _ in frame }
    }

    /// The same for one window. `target` gets the frame that the window has
    /// out of full screen and gives the new one: a window in full screen has
    /// the frame of its display until it leaves full screen. `cancelled` is
    /// read before each frame request and before each of its writes: a true
    /// value ends the move with an error.
    @discardableResult
    static func setFrame(_ window: AXUIElement, fullScreen: Bool? = nil, cancelled: () -> Bool = { false },
                         trace: (String) -> Void = { _ in }, target: (CGRect) -> CGRect) throws -> CGRect {
        // A window in native full screen has a Space of its own and refuses a
        // position. It leaves full screen, moves, and enters full screen again
        // on the display where it is then.
        let wasFullScreen = isFullScreen(window)
        // A wait with no valid read throws here, before a target is computed from it.
        var start = try settledFrame(window)
        trace("window at \(start), full screen \(wasFullScreen)")
        if wasFullScreen {
            if cancelled() { throw moveCancelled }
            try leaveFullScreen(window)
            start = try settledFrame(window)
            trace("left full screen, window at \(start)")
        }
        // The exit from full screen takes some seconds.
        if cancelled() { throw moveCancelled }
        let frame = target(start)
        trace("target \(frame)")
        guard hasSize(frame) else {
            throw DisplayToggleError(description: "the target frame \(frame) has no size")
        }
        // A window that still ends a transition (out of full screen, out of a
        // zoom) ignores a request and reports no error, so the frame is read
        // back and the request is sent again until the window moves.
        var result = try apply(frame, to: window, cancelled: cancelled)
        var attempt = 1
        while result.origin == start.origin, start.origin != frame.origin, attempt < transitionAttempts {
            attempt += 1
            trace("the window did not move, attempt \(attempt)")
            usleep(500_000)
            if cancelled() { throw moveCancelled }
            result = try apply(frame, to: window, cancelled: cancelled)
        }
        trace("window at \(result)")
        if fullScreen ?? wasFullScreen {
            // The same rule for the way into full screen.
            for _ in 0..<transitionAttempts {
                if cancelled() { throw moveCancelled }
                _ = AXUIElementSetAttributeValue(window, fullScreenAttribute as CFString, kCFBooleanTrue)
                usleep(500_000)
                if isFullScreen(window) { break }
            }
            result = try settledFrame(window)
            trace("full screen \(isFullScreen(window)), window at \(result)")
        }
        return result
    }

    // 6 attempts, 0.5 s apart: a full screen animation takes about 1 s.
    private static let transitionAttempts = 6

    private static let moveCancelled = DisplayToggleError(description: "the move was cancelled")

    // `cancelled` is read before each of the three writes: each one can wait
    // for the AX timeout, and a cancel during the first one must not move the
    // window to a target that is stale.
    private static func apply(_ frame: CGRect, to window: AXUIElement, cancelled: () -> Bool) throws -> CGRect {
        var origin = frame.origin
        var size = frame.size
        guard let position = AXValueCreate(.cgPoint, &origin), let extent = AXValueCreate(.cgSize, &size) else {
            throw DisplayToggleError(description: "cannot build the window frame")
        }
        // Size, position, size: macOS cuts a window that grows past the edge of
        // its current display, so the size is set again on the new display. A
        // window of fixed size refuses the size, and that is not an error.
        if cancelled() { throw moveCancelled }
        _ = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, extent)
        if cancelled() { throw moveCancelled }
        let err = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position)
        guard err == .success else {
            throw DisplayToggleError(description: "cannot move the window (AXError \(err.rawValue))")
        }
        if cancelled() { throw moveCancelled }
        _ = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, extent)
        return try settledFrame(window)
    }

    private static func currentFrame(_ window: AXUIElement) throws -> CGRect {
        try frame(position: value(window, kAXPositionAttribute), size: value(window, kAXSizeAttribute))
    }

    // A frame change and a full screen change are animations. The frame is
    // settled when two reads, 150 ms apart, agree. A read can fail for a
    // moment while the window leaves full screen, so it is read again.
    private static func settledFrame(_ window: AXUIElement) throws -> CGRect {
        try settled { try currentFrame(window) }
    }

    /// The frame at rest: two valid reads one after the other that agree. A
    /// read that throws is skipped, and the next valid read is compared with
    /// the last valid one; a failed read is never a frame, because two frames
    /// of zeros looked like a window at rest. The wait ends after `tries`
    /// reads or `time` seconds from the first read, with the last valid read;
    /// with no valid read it throws the error of the last read. The time limit
    /// is there because a read that does not answer waits for the AX timeout.
    static func settled(tries: Int = 21, time: TimeInterval = 3,
                        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                        pause: () -> Void = { _ = usleep(150_000) },
                        read: () throws -> CGRect) throws -> CGRect {
        let start = now()
        var last: CGRect?
        var failure: Error?
        for attempt in 0..<tries {
            if attempt > 0 {
                if now() - start >= time { break }
                pause()
            }
            do {
                let frame = try read()
                if frame == last { return frame }
                last = frame
            } catch {
                failure = error
            }
        }
        if let last { return last }
        throw failure ?? DisplayToggleError(description: "cannot read the window frame")
    }

    // AppKit has no constant for it.
    private static let fullScreenAttribute = "AXFullScreen"

    private static func isFullScreen(_ window: AXUIElement) -> Bool {
        (copy(window, fullScreenAttribute) as? NSNumber)?.boolValue ?? false
    }

    // Leaving full screen is an animation: the call returns at once, and the
    // window takes a position only when the animation ends.
    private static func leaveFullScreen(_ window: AXUIElement) throws {
        let err = AXUIElementSetAttributeValue(window, fullScreenAttribute as CFString, kCFBooleanFalse)
        guard err == .success else {
            throw DisplayToggleError(description: "cannot take the window out of full screen (AXError \(err.rawValue))")
        }
        for _ in 0..<50 {
            usleep(100_000)
            var settable: DarwinBoolean = false
            _ = AXUIElementIsAttributeSettable(window, kAXPositionAttribute as CFString, &settable)
            if !isFullScreen(window), settable.boolValue { return }
        }
        throw DisplayToggleError(description: "the window did not leave full screen")
    }

    // The check reads the frame on the main thread, also at every menu open:
    // an app that does not answer must not freeze the menu for the default
    // wait of about 6 s per call. A move keeps the default: a window in a full
    // screen transition can answer late, and the move was verified with it.
    static let checkTimeout: Float = 1

    /// The window of `pid` whose frame is `bounds`, the frame of a listed
    /// window. Every Accessibility call on it then waits at most `timeout`.
    static func window(pid: pid_t, bounds: CGRect, timeout: Float) throws -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        for item in (copy(app, kAXWindowsAttribute) as? [AnyObject]) ?? [] where CFGetTypeID(item) == AXUIElementGetTypeID() {
            let window = unsafeDowncast(item, to: AXUIElement.self)
            AXUIElementSetMessagingTimeout(window, timeout)
            // A window that does not answer is not the match; another can be.
            if let frame = try? currentFrame(window), WindowRescue.matches(frame, bounds) { return window }
        }
        throw DisplayToggleError(description: "no Accessibility window of the app has the frame \(bounds)")
    }

    private static func mainWindow(_ pid: pid_t, timeout: Float? = nil) throws -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        if let timeout { AXUIElementSetMessagingTimeout(app, timeout) }
        var window: AXUIElement?
        if let main = copy(app, kAXMainWindowAttribute), CFGetTypeID(main) == AXUIElementGetTypeID() {
            window = unsafeDowncast(main, to: AXUIElement.self)
        } else if let first = (copy(app, kAXWindowsAttribute) as? [AnyObject])?.first, CFGetTypeID(first) == AXUIElementGetTypeID() {
            window = unsafeDowncast(first, to: AXUIElement.self)
        }
        if let window {
            if let timeout { AXUIElementSetMessagingTimeout(window, timeout) }
            return window
        }
        throw DisplayToggleError(description: "the app has no window to move")
    }

    private static func copy(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
        return result
    }

    private static func value(_ element: AXUIElement, _ attribute: String) -> AXValue? {
        guard let result = copy(element, attribute), CFGetTypeID(result) == AXValueGetTypeID() else { return nil }
        return unsafeDowncast(result, to: AXValue.self)
    }
}
