import Foundation

@main
struct BluetoothAdvertisementTests {
    static func main() {
        let vendorService = Data([
            0xA4, 0xD0, 0x87, 0xA7, 0xB4, 0xD1, 0x79, 0x89,
            0x2D, 0x45, 0x37, 0x1C, 0x10, 0x00, 0xD1, 0x2D,
        ])
        let deviceName = Data("Test-BLE-12345".utf8)
        let peripheral = VPhoneBluetoothAdvertisementEncoder.encode(
            structures: [
                .init(type: 0x01, payload: Data([0x1A])),
                .init(type: 0x07, payload: vendorService),
                .init(type: 0xFF, payload: Data([0x12, 0x0A, 0x01, 0x01])),
            ],
            localName: deviceName,
        )
        precondition(peripheral.advertisement == Data([0x02, 0x01, 0x1A, 0x11, 0x07])
            + vendorService + Data([0x05, 0xFF, 0x12, 0x0A, 0x01, 0x01]))
        precondition(peripheral.scanResponse == Data([UInt8(deviceName.count + 1), 0x09]) + deviceName)
        precondition(peripheral.advertisement.count == 27 && peripheral.scanResponse!.count <= 31)

        let compact = VPhoneBluetoothAdvertisementEncoder.encode(
            structures: [.init(type: 0x01, payload: Data([0x1A]))],
            localName: Data("Probe".utf8),
        )
        precondition(compact.advertisement == Data([0x02, 0x01, 0x1A, 0x06, 0x09]) + Data("Probe".utf8))
        precondition(compact.scanResponse == nil)

        let tooLarge = VPhoneBluetoothAdvertisementEncoder.encode(
            structures: [
                .init(type: 0x01, payload: Data([0x1A])),
                .init(type: 0xFF, payload: Data(repeating: 0xAA, count: 30)),
            ],
            localName: Data("preserved-name".utf8),
        )
        precondition(tooLarge.advertisement == Data([0x02, 0x01, 0x1A]))
        precondition(tooLarge.scanResponse == Data([0x0F, 0x09]) + Data("preserved-name".utf8))
        precondition(!tooLarge.advertisement.contains(0xAA) && !tooLarge.scanResponse!.contains(0xAA))

        let shortened = VPhoneBluetoothAdvertisementEncoder.encode(
            structures: [.init(type: 0x01, payload: Data([0x1A]))],
            localName: Data(repeating: 0x4E, count: 40),
        )
        precondition(shortened.advertisement == Data([0x02, 0x01, 0x1A]))
        precondition(shortened.scanResponse?.count == 31)
        precondition(shortened.scanResponse?.prefix(2) == Data([0x1E, 0x08]))

        print("Bluetooth advertisement tests passed: compact, split scan response, intact overflow and long-name shortening")
    }
}
