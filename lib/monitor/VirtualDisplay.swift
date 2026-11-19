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
    /// and again when the set of displays changes.
    func place(_ config: MonitorConfig) throws {
        guard let id = displayID else { return }
        let active = try DisplayToggle.displays(online: false)
        guard active.contains(where: { $0.id == id }) else {
            throw DisplayToggleError(description: "the virtual display is not active")
        }
        // With no real display active, the virtual one is the whole desktop:
        // every window is on a screen that nobody can see.
        guard let anchor = Self.anchor(active) else {
            turnOff()
            throw DisplayToggleError(description: "no real display is active — virtual display turned off")
        }
        let bounds = CGDisplayBounds(id)
        let real = active.filter { !$0.isVirtual }.map { CGDisplayBounds($0.id) }
        let wanted = Self.origin(anchor: CGDisplayBounds(anchor), real: real, width: bounds.width,
                                 side: config.virtualSide, y: config.virtualY)
        guard bounds.origin != wanted else { return }

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

    /// AppKit counts y up from the bottom of the primary screen. Displays and
    /// the Accessibility API count y down from its top.
    static func global(cocoa rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}

/// The main window of another app, read and moved through the Accessibility
/// API. The user must allow MonitorBar in Privacy & Security > Accessibility.
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
    static func frame(pid: pid_t) throws -> CGRect {
        let window = try mainWindow(pid)
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard let position = value(window, kAXPositionAttribute), AXValueGetValue(position, .cgPoint, &origin),
              let extent = value(window, kAXSizeAttribute), AXValueGetValue(extent, .cgSize, &size) else {
            throw DisplayToggleError(description: "cannot read the window frame")
        }
        return CGRect(origin: origin, size: size)
    }

    static func setFrame(pid: pid_t, _ frame: CGRect) throws {
        let window = try mainWindow(pid)
        var origin = frame.origin
        var size = frame.size
        guard let position = AXValueCreate(.cgPoint, &origin), let extent = AXValueCreate(.cgSize, &size) else {
            throw DisplayToggleError(description: "cannot build the window frame")
        }
        // A window in native full screen has a Space of its own and refuses a
        // position. It leaves full screen, moves, and enters full screen again
        // on the display where it is then.
        let wasFullScreen = isFullScreen(window)
        if wasFullScreen { try leaveFullScreen(window) }
        // Size, position, size: macOS cuts a window that grows past the edge of
        // its current display, so the size is set again on the new display. A
        // window of fixed size refuses the size, and that is not an error.
        _ = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, extent)
        let err = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position)
        guard err == .success else {
            throw DisplayToggleError(description: "cannot move the window (AXError \(err.rawValue))")
        }
        _ = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, extent)
        if wasFullScreen {
            _ = AXUIElementSetAttributeValue(window, fullScreenAttribute as CFString, kCFBooleanTrue)
        }
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

    private static func mainWindow(_ pid: pid_t) throws -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        if let main = copy(app, kAXMainWindowAttribute), CFGetTypeID(main) == AXUIElementGetTypeID() {
            return unsafeDowncast(main, to: AXUIElement.self)
        }
        if let first = (copy(app, kAXWindowsAttribute) as? [AnyObject])?.first, CFGetTypeID(first) == AXUIElementGetTypeID() {
            return unsafeDowncast(first, to: AXUIElement.self)
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
