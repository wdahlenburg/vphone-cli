// vphone-location — reads privacy-controlled Mac sensor data for vphone-vm.
//
// locationd never answers a client whose executable sits in a generic bundle:
// from VPhone.bundle/Contents/MacOS, requestWhenInUseAuthorization neither
// prompts nor changes the status. A process inside an .app is prompted, so
// StageBundle.sh wraps this program in Contents/Helpers/VPhoneLocation.app with
// the usage descriptions and their translations.
//
// vphone-vm starts the default mode when Sync Host Location is turned on. In
// --bluetooth mode it scans nearby BLE advertisements for the persistent guest
// bridge. Both modes write one JSON object per line and exit when vphone-vm
// closes stdin.

import AppKit
@preconcurrency import CoreBluetooth
import CoreLocation

struct VPhoneLocationHelperMessage: Encodable {
    var authorization: Int32?
    var latitude: Double?
    var longitude: Double?
    var altitude: Double?
    var horizontalAccuracy: Double?
    var verticalAccuracy: Double?
    var speed: Double?
    var course: Double?
    var timestamp: Double?
}

func emit(_ message: VPhoneLocationHelperMessage) {
    guard var line = try? JSONEncoder().encode(message) else { return }
    line.append(0x0A)
    FileHandle.standardOutput.write(line)
}

struct VPhoneBluetoothHelperMessage: Encodable {
    let id: String
    let address: String
    let data: String
    let rssi: Int
    let tx: Int
    let connectable: Bool
    let scannable: Bool
    let scanResponse: Bool

    enum CodingKeys: String, CodingKey {
        case id, address, data, rssi, tx, connectable, scannable
        case scanResponse = "scan_response"
    }
}

func emit(_ message: VPhoneBluetoothHelperMessage) {
    guard var line = try? JSONEncoder().encode(message) else { return }
    line.append(0x0A)
    FileHandle.standardOutput.write(line)
}

final class VPhoneBluetoothHelperDelegate: NSObject, CBCentralManagerDelegate,
    CBPeripheralDelegate, @unchecked Sendable
{
    var central: CBCentralManager?
    var peripheralsByAddress: [Data: CBPeripheral] = [:]
    var addressesByPeripheral: [UUID: Data] = [:]
    var gattSessions: [UInt16: VPhoneBluetoothGATTSession] = [:]
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        self.central = central
        guard central.state == .poweredOn else {
            FileHandle.standardError.write(Data("[bluetooth] Mac adapter state = \(central.state.rawValue)\n".utf8))
            return
        }
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true],
        )
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber,
    ) {
        let reports = Self.encodeAdvertisements(advertisementData)
        guard !reports.advertisement.isEmpty else { return }
        var address = Self.syntheticAddress(for: peripheral)
        // BTVC and the Bluetooth stack expose opposite byte orderings at this
        // boundary. Mark both endpoint octets as static-random so the address
        // remains valid before and after BTVC converts it to an HCI report.
        address[address.startIndex] |= 0xC0
        address[address.index(before: address.endIndex)] |= 0xC0
        peripheralsByAddress[address] = peripheral
        addressesByPeripheral[peripheral.identifier] = address
        let id = peripheral.identifier.uuidString
        let encodedAddress = address.base64EncodedString()
        let rssi = RSSI.intValue
        let tx = (advertisementData[CBAdvertisementDataTxPowerLevelKey] as? NSNumber)?.intValue ?? 127
        let connectable = (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue ?? true
        let scannable = reports.scanResponse != nil
        emit(VPhoneBluetoothHelperMessage(
            id: id, address: encodedAddress,
            data: reports.advertisement.base64EncodedString(),
            rssi: rssi, tx: tx, connectable: connectable, scannable: scannable, scanResponse: false,
        ))
        if let scanResponse = reports.scanResponse {
            emit(VPhoneBluetoothHelperMessage(
                id: id, address: encodedAddress,
                data: scanResponse.base64EncodedString(),
                rssi: rssi, tx: tx, connectable: connectable, scannable: true, scanResponse: true,
            ))
        }
    }

    static func syntheticAddress(for peripheral: CBPeripheral) -> Data {
        var uuid = peripheral.identifier.uuid
        return withUnsafeBytes(of: &uuid) { Data($0.prefix(6)) }
    }

    static func encodeAdvertisements(_ values: [String: Any]) -> VPhoneBluetoothAdvertisementReports {
        var structures = [VPhoneBluetoothADStructure(type: 0x01, payload: Data([0x1A]))]
        if let uuids = values[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] {
            structures.append(contentsOf: uuidStructures(uuids))
        }
        if let uuids = values[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] {
            structures.append(contentsOf: uuidStructures(uuids))
        }
        if let serviceData = values[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] {
            for (uuid, data) in serviceData.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
                let bytes = uuid.data.reversed()
                let type: UInt8 = bytes.count == 2 ? 0x16 : (bytes.count == 4 ? 0x20 : 0x21)
                structures.append(VPhoneBluetoothADStructure(type: type, payload: Data(bytes) + data))
            }
        }
        if let manufacturer = values[CBAdvertisementDataManufacturerDataKey] as? Data {
            structures.append(VPhoneBluetoothADStructure(type: 0xFF, payload: manufacturer))
        }
        let name = (values[CBAdvertisementDataLocalNameKey] as? String).map { Data($0.utf8) }
        return VPhoneBluetoothAdvertisementEncoder.encode(structures: structures, localName: name)
    }

    static func uuidStructures(_ uuids: [CBUUID]) -> [VPhoneBluetoothADStructure] {
        var structures: [VPhoneBluetoothADStructure] = []
        for width in [2, 4, 16] {
            let matching = uuids.filter { $0.data.count == width }
            guard !matching.isEmpty else { continue }
            let maximumUUIDs = (VPhoneBluetoothAdvertisementEncoder.maximumLegacyPayload - 2) / width
            for start in stride(from: 0, to: matching.count, by: maximumUUIDs) {
                let end = min(start + maximumUUIDs, matching.count)
                let final = end == matching.count
                let completeType: UInt8 = width == 2 ? 0x03 : (width == 4 ? 0x05 : 0x07)
                let payload = matching[start ..< end].reduce(into: Data()) {
                    $0.append(contentsOf: $1.data.reversed())
                }
                structures.append(VPhoneBluetoothADStructure(
                    type: final ? completeType : completeType - 1,
                    payload: payload,
                ))
            }
        }
        return structures
    }
}

final class VPhoneLocationHelperDelegate: NSObject, CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        emit(VPhoneLocationHelperMessage(authorization: status.rawValue))
        if status == .authorized || status == .authorizedAlways {
            manager.startUpdatingLocation()
        }
    }

    func locationManager(_: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        emit(VPhoneLocationHelperMessage(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            altitude: location.altitude,
            horizontalAccuracy: location.horizontalAccuracy,
            verticalAccuracy: location.verticalAccuracy,
            speed: location.speed,
            course: location.course,
            timestamp: location.timestamp.timeIntervalSince1970,
        ))
    }

    func locationManager(_: CLLocationManager, didFailWithError error: any Error) {
        // kCLErrorLocationUnknown is transient: there is no fix yet.
        guard (error as NSError).code != CLError.locationUnknown.rawValue else { return }
        FileHandle.standardError.write(Data("[location] \(error.localizedDescription)\n".utf8))
    }
}

func monitorStandardInput(_ handleLine: (@Sendable (String) -> Void)? = nil) {
    Thread.detachNewThread {
        var pending = Data()
        while true {
            let data = FileHandle.standardInput.availableData
            guard !data.isEmpty else { exit(0) }
            pending.append(data)
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending[..<newline]
                pending.removeSubrange(pending.startIndex ... newline)
                if let string = String(data: line, encoding: .utf8) { handleLine?(string) }
            }
            if pending.count > 1024 * 1024 { pending.removeAll() }
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
if CommandLine.arguments.contains("--bluetooth") {
    let delegate = VPhoneBluetoothHelperDelegate()
    let manager = CBCentralManager(delegate: delegate, queue: .main)
    monitorStandardInput { [weak delegate] line in
        DispatchQueue.main.async { delegate?.handleGuestLine(line) }
    }
    withExtendedLifetime((delegate, manager)) { app.run() }
} else {
    let delegate = VPhoneLocationHelperDelegate()
    let manager = CLLocationManager()
    manager.delegate = delegate
    manager.desiredAccuracy = kCLLocationAccuracyBest
    manager.requestWhenInUseAuthorization()
    monitorStandardInput()
    withExtendedLifetime((delegate, manager)) { app.run() }
}
