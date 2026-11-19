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
        let wanted = Self.origin(anchor: CGDisplayBounds(anchor), width: bounds.width,
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

    /// Global display coordinates: x grows to the right and y grows down.
    static func origin(anchor: CGRect, width: CGFloat, side: MonitorConfig.Side, y: Int) -> CGPoint {
        CGPoint(x: side == .right ? anchor.maxX : anchor.minX - width, y: anchor.minY + CGFloat(y))
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
    /// the main one), and the result is nil then.
    ///
    /// TODO: when the result is nil, or if Moonlight ignores the option, move
    /// Moonlight's window with the Accessibility API (kAXPositionAttribute).
    /// That needs the Accessibility permission, which an ad-hoc rebuild of the
    /// app can lose.
    static func windowGeometry(on display: CGRect) -> String? {
        let x = Int(display.minX) + inset, y = Int(display.minY) + inset
        guard x >= 0, y >= 0 else { return nil }
        return "+\(x)+\(y)"
    }
}
