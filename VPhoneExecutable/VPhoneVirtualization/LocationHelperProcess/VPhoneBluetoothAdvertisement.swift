import Foundation

struct VPhoneBluetoothADStructure: Equatable {
    let type: UInt8
    let payload: Data

    var encoded: Data? {
        guard !payload.isEmpty, payload.count <= UInt8.max - 1 else { return nil }
        return Data([UInt8(payload.count + 1), type]) + payload
    }
}

struct VPhoneBluetoothAdvertisementReports: Equatable {
    let advertisement: Data
    let scanResponse: Data?
}

enum VPhoneBluetoothAdvertisementEncoder {
    static let maximumLegacyPayload = 31

    /// CoreBluetooth combines the advertising and scan-response payloads in
    /// one dictionary. Rebuild the two legacy reports instead of truncating
    /// the aggregate to one 31-byte report. Names are kept whole in the scan
    /// response whenever they fit there; typed values are never truncated.
    static func encode(
        structures: [VPhoneBluetoothADStructure],
        localName: Data?,
    ) -> VPhoneBluetoothAdvertisementReports {
        var advertisement = Data()
        var overflow: [VPhoneBluetoothADStructure] = []
        for structure in structures {
            if !append(structure, to: &advertisement) {
                overflow.append(structure)
            }
        }

        let name = localName.flatMap(nameStructure)
        if overflow.isEmpty {
            var combined = advertisement
            if let name {
                if append(name, to: &combined) {
                    return VPhoneBluetoothAdvertisementReports(advertisement: combined, scanResponse: nil)
                }
            } else {
                return VPhoneBluetoothAdvertisementReports(advertisement: combined, scanResponse: nil)
            }
        }

        var scanResponse = Data()
        if let name {
            _ = append(name, to: &scanResponse)
        }
        for structure in overflow {
            _ = append(structure, to: &scanResponse)
        }
        return VPhoneBluetoothAdvertisementReports(
            advertisement: advertisement,
            scanResponse: scanResponse.isEmpty ? nil : scanResponse,
        )
    }

    static func nameStructure(_ name: Data) -> VPhoneBluetoothADStructure? {
        guard !name.isEmpty else { return nil }
        let body = name.prefix(maximumLegacyPayload - 2)
        return VPhoneBluetoothADStructure(
            type: body.count == name.count ? 0x09 : 0x08,
            payload: Data(body),
        )
    }

    @discardableResult
    private static func append(_ structure: VPhoneBluetoothADStructure, to report: inout Data) -> Bool {
        guard let encoded = structure.encoded,
              report.count + encoded.count <= maximumLegacyPayload
        else { return false }
        report.append(encoded)
        return true
    }
}
