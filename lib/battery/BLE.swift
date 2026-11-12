// BLE.swift — reads the GATT Battery Service (0x180F, Battery Level 0x2A19)
// of every peripheral that is already connected to the Mac.
//
// No scan: retrieveConnectedPeripherals lists the devices the system holds,
// and `connect` on one of them only opens this app's link over the existing
// connection. This reaches devices that macOS shows no battery for (many BLE
// keyboards), because it asks the device itself. A device that reports its
// battery only through a vendor protocol (Logitech HID++ over a receiver, for
// example) has no Battery Service and does not show.

import CoreBluetooth
import Foundation

private let batteryServiceUUID = CBUUID(string: "180F")
private let batteryLevelUUID = CBUUID(string: "2A19")

final class BLEBatterySource: NSObject, BatterySource, CBCentralManagerDelegate, CBPeripheralDelegate {
    var onChange: (() -> Void)?
    private(set) var state: SourceState = .starting
    private(set) var lastUpdate: Date?

    private var central: CBCentralManager?
    // Strong references: CoreBluetooth drops the link of a peripheral that
    // nothing retains.
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var levels: [UUID: Int] = [:]
    private var characteristics: [UUID: CBCharacteristic] = [:]
    // Devices whose first read finished, with a value or with an error.
    private var answered: Set<UUID> = []

    var devices: [Device] {
        peripherals.values.map {
            Device(id: $0.identifier.uuidString, name: $0.name ?? "Unknown device",
                   percent: levels[$0.identifier])
        }
    }

    var pending: Int { peripherals.keys.filter { !answered.contains($0) }.count }

    func start() {
        guard central == nil else { return }
        // No system alert when Bluetooth is off: the menu says it.
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }

    /// Look for connected devices again, and read every value again.
    func refresh() {
        rescan()
        for (id, characteristic) in characteristics {
            peripherals[id]?.readValue(for: characteristic)
        }
    }

    // MARK: - Devices

    private func rescan() {
        guard let central, state == .ready else { return }
        let connected = central.retrieveConnectedPeripherals(withServices: [batteryServiceUUID])
        let ids = Set(connected.map(\.identifier))
        for id in Array(peripherals.keys) where !ids.contains(id) {
            if let gone = peripherals[id] { central.cancelPeripheralConnection(gone) }
            forget(id)
        }
        for peripheral in connected where peripherals[peripheral.identifier] == nil {
            peripherals[peripheral.identifier] = peripheral
            peripheral.delegate = self
            central.connect(peripheral)
        }
        onChange?()
    }

    private func forget(_ id: UUID) {
        peripherals[id] = nil
        levels[id] = nil
        characteristics[id] = nil
        answered.remove(id)
    }

    /// A read is over (value or error); the CLI stops waiting for this device.
    /// A failed read keeps the last good value.
    private func finish(_ id: UUID, level: Int?) {
        guard peripherals[id] != nil else { return }
        answered.insert(id)
        if let level {
            levels[id] = level
            lastUpdate = Date()
        }
        onChange?()
    }

    // MARK: - CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: state = .ready
        case .poweredOff: state = .poweredOff
        case .unauthorized: state = .unauthorized
        case .unsupported: state = .unsupported
        default: state = .starting   // .unknown, .resetting: another update follows
        }
        if state == .ready {
            rescan()   // retrieveConnectedPeripherals is empty before .poweredOn
        } else {
            for id in Array(peripherals.keys) { forget(id) }
            onChange?()
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([batteryServiceUUID])
    }

    // Dropped for now; the next rescan tries again.
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        forget(peripheral.identifier)
        onChange?()
    }

    // The device left the system, or this app's link to it dropped. A device
    // that is still connected comes back on the next rescan.
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        forget(peripheral.identifier)
        onChange?()
    }

    // MARK: - CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == batteryServiceUUID }) else {
            return finish(peripheral.identifier, level: nil)
        }
        peripheral.discoverCharacteristics([batteryLevelUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristic = service.characteristics?.first(where: { $0.uuid == batteryLevelUUID }) else {
            return finish(peripheral.identifier, level: nil)
        }
        characteristics[peripheral.identifier] = characteristic
        peripheral.readValue(for: characteristic)
        if characteristic.properties.contains(.notify) {
            peripheral.setNotifyValue(true, for: characteristic)
        }
    }

    // Reads and notifications both arrive here.
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == batteryLevelUUID else { return }
        finish(peripheral.identifier, level: error == nil ? batteryLevel(characteristic.value) : nil)
    }

    func peripheralDidUpdateName(_ peripheral: CBPeripheral) {
        onChange?()
    }
}
