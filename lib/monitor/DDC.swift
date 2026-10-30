// DDC.swift — switch the external monitor's input over DDC/CI (Apple Silicon).
//
// DDC/CI is the monitor-control channel inside the video link (I2C address
// 0x37). Apple Silicon exposes it through the private IOAVService API — the
// same calls m1ddc uses — resolved with dlsym like CGSConfigureDisplayEnabled.
// It keeps working while the display is disabled with DisplayToggle, because
// disabling stops the picture but not the link.

import Foundation
import IOKit

enum DDC {
    private typealias CreateWithServiceFn = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    private typealias WriteI2CFn = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

    // VCP 0x60 is "Input Source". Values are vendor-specific in practice:
    // MCCS says HDMI-1 = 17, but Samsung monitors (e.g. S27A600U) use 5.
    private static let inputSourceVCP: UInt8 = 0x60

    static func setInput(_ value: UInt16) throws {
        try write(vcp: inputSourceVCP, value: value)
    }

    private static func write(vcp: UInt8, value: UInt16) throws {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW),
              let createSym = dlsym(handle, "IOAVServiceCreateWithService"),
              let writeSym = dlsym(handle, "IOAVServiceWriteI2C") else {
            throw DisplayToggleError(description: "IOAVService DDC calls are not available on this macOS version")
        }
        let create = unsafeBitCast(createSym, to: CreateWithServiceFn.self)
        let writeI2C = unsafeBitCast(writeSym, to: WriteI2CFn.self)

        let service = try externalAVService()
        defer { IOObjectRelease(service) }
        guard let avService = create(kCFAllocatorDefault, service)?.takeRetainedValue() else {
            throw DisplayToggleError(description: "cannot open the DDC channel of the external display")
        }

        // Set VCP Feature: length|0x80, opcode 0x03, vcp, value hi, value lo,
        // checksum = XOR of destination (0x6E), source (0x51) and the payload.
        var packet: [UInt8] = [0x84, 0x03, vcp, UInt8(value >> 8), UInt8(value & 0xFF), 0]
        packet[5] = packet[0..<5].reduce(0x6E ^ 0x51) { $0 ^ $1 }

        // Monitors drop DDC writes now and then; sending twice is what m1ddc
        // and other DDC tools do too.
        var result: IOReturn = kIOReturnSuccess
        for _ in 0..<2 {
            result = packet.withUnsafeMutableBytes { writeI2C(avService, 0x37, 0x51, $0.baseAddress!, UInt32($0.count)) }
            usleep(10_000)
        }
        guard result == kIOReturnSuccess else {
            throw DisplayToggleError(description: "DDC write failed (IOReturn \(result))")
        }
    }

    // The external port's AV service is the DCPAVServiceProxy with
    // Location = External; the built-in panel has its own, Location = Embedded.
    private static func externalAVService() throws -> io_service_t {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator) == KERN_SUCCESS else {
            throw DisplayToggleError(description: "cannot list display services")
        }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            let location = IORegistryEntryCreateCFProperty(service, "Location" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            if location == "External" { return service }
            IOObjectRelease(service)
        }
        throw DisplayToggleError(description: "no external display with a DDC channel")
    }
}
