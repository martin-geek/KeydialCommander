import CoreBluetooth
import Foundation

/// Reads the standard Battery Service on the system-connected Keydial.
final class BatteryReader: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private let batteryService = CBUUID(string: "180F")
    private let batteryLevel = CBUUID(string: "2A19")
    private let hidService = CBUUID(string: "1812")
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var product: String?
    private var lastLookup = Date.distantPast
    var onLevel: ((Int?) -> Void)?

    func update(product: String?, requestPermission: Bool = false) {
        if self.product != product {
            stop()
            self.product = product
            lastLookup = .distantPast
        }
        guard product != nil else { return }
        if central == nil, requestPermission || CBManager.authorization == .allowedAlways {
            central = CBCentralManager(delegate: self, queue: .main,
                                       options: [CBCentralManagerOptionShowPowerAlertKey: false])
        }
        if requestPermission { lastLookup = .distantPast }
        lookUp()
    }

    private func lookUp() {
        guard let central, central.state == .poweredOn, let product, peripheral == nil,
              Date().timeIntervalSince(lastLookup) >= 15 else { return }
        lastLookup = Date()
        let matching = central.retrieveConnectedPeripherals(withServices: [hidService, batteryService]).filter {
            $0.name?.caseInsensitiveCompare(product) == .orderedSame
        }
        guard matching.count == 1, let found = matching.first else { return }
        peripheral = found
        found.delegate = self
        central.connect(found)
    }

    private func stop() {
        if let peripheral {
            peripheral.delegate = nil
            central?.cancelPeripheralConnection(peripheral)
        }
        peripheral = nil
        onLevel?(nil)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn { lookUp() }
        else { stop() }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral === self.peripheral else { return }
        peripheral.discoverServices([batteryService])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        if peripheral === self.peripheral { stop() }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if peripheral === self.peripheral { stop() }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral === self.peripheral else { return }
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == batteryService })
        else { stop(); return }
        peripheral.discoverCharacteristics([batteryLevel], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral === self.peripheral else { return }
        guard error == nil, let level = service.characteristics?.first(where: { $0.uuid == batteryLevel })
        else { stop(); return }
        peripheral.readValue(for: level)
        if level.properties.contains(.notify) { peripheral.setNotifyValue(true, for: level) }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === self.peripheral, error == nil, characteristic.uuid == batteryLevel,
              let level = characteristic.value?.first, level <= 100 else { return }
        onLevel?(Int(level))
    }
}
