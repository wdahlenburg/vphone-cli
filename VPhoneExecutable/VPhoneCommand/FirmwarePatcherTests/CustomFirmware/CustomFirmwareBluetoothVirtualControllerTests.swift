@testable import FirmwarePatcher
import Foundation
import Testing
import VPhonePatchKit

@Suite("Virtual Bluetooth feature flag")
struct CustomFirmwareBluetoothVirtualControllerTests {
    @Test
    func `capability queries accept released compiler layouts and preserve the return value`() throws {
        // Literal instruction windows from the three capability queries in
        // stock iOS 26.5 bluetoothd, independently decoded by llvm-objdump.
        let windows: [(Int32, [UInt8])] = [
            (0x808, [0x10, 0x09, 0x3f, 0xd7, 0xf4, 0x03, 0x00, 0xaa,
                     0xf5, 0x35, 0x00, 0xb0, 0xa0, 0x22, 0x20, 0x39]),
            (0x868, [0x10, 0x09, 0x3f, 0xd7, 0xf4, 0x03, 0x00, 0xaa, 0xa0, 0xa2, 0x21, 0x39]),
            (0x878, [0x10, 0x09, 0x3f, 0xd7, 0x80, 0xe2, 0x21, 0x39]),
        ]
        for (offset, bytes) in windows {
            let decoded = ARM64Disassembler().disassemble(Data(bytes), at: 0x1000)
            let queries = CustomFirmwareBluetoothAdvertisementPassup.capabilityQueries(in: decoded, storageOffset: offset)
            #expect(queries.map(\.address) == [0x1000])
            var patched = Data(bytes)
            patched.replaceSubrange(0..<4, with: try #require(ARM64Encoder.encodeMovzW(rd: 0, imm16: 1)))
            #expect(CustomFirmwareBluetoothAdvertisementPassup.capabilityQueries(
                in: ARM64Disassembler().disassemble(patched, at: 0x1000), storageOffset: offset
            ).map(\.address) == [0x1000])
        }
        // A real instruction that overwrites x0 must prevent correlation.
        let clobber = Data(windows[0].1.prefix(4)) + ARM64Encoder.encodeMovX(rd: 0, rm: 8) + Data(windows[0].1.suffix(8))
        #expect(CustomFirmwareBluetoothAdvertisementPassup.capabilityQueries(
            in: ARM64Disassembler().disassemble(clobber, at: 0x1000), storageOffset: 0x808
        ).isEmpty)
        let wrongPage = Data(windows[0].1.prefix(8))
            + Data([0xf4, 0x35, 0x00, 0xb0]) + Data(windows[0].1.suffix(4)) // adrp x20, store through x21
        #expect(CustomFirmwareBluetoothAdvertisementPassup.capabilityQueries(
            in: ARM64Disassembler().disassemble(wrongPage, at: 0x1000), storageOffset: 0x808
        ).isEmpty)
    }

    @Test
    func `physical BLE discovery is opt in on iOS 18 and later`() throws {
        let identifier = FirmwareGuestSystemPatchSet.bluetoothAdvertisementPassup
        for base in ["17.6", "18.6", "26.4", "26.6", "27.0", "27.2", "28.0"] {
            for preset in [FirmwarePatchSetCatalog.standardPreset, FirmwarePatchSetCatalog.experimentalPreset] {
                let plan = try VPhonePatchPlan.resolve(
                    preset: preset, patchSets: FirmwarePatchSetCatalog.bundled,
                    iOSBase: VPhoneVersion(base), cloudOS: VPhoneVersion("26.4")
                )
                #expect(plan.isEnabled(identifier) == (!base.hasPrefix("17.") && preset.identifier == "experimental"))
            }
        }
    }

    @Test(arguments: [PropertyListSerialization.PropertyListFormat.xml, .binary])
    func `turns the feature on and keeps the rest`(format: PropertyListSerialization.PropertyListFormat) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let original: [String: Any] = [
            "EnableBTVCLeConnection": ["DevelopmentPhase": "FeatureComplete"],
            "OtherFeature": ["Enabled": false],
        ]
        let input = try PropertyListSerialization.data(fromPropertyList: original, format: format, options: 0)
        try input.write(to: url)
        #expect(try CustomFirmwareBluetoothVirtualController.patch(at: url, dryRun: true))
        #expect(try Data(contentsOf: url) == input)
        #expect(try CustomFirmwareBluetoothVirtualController.patch(at: url))
        var outputFormat = PropertyListSerialization.PropertyListFormat.xml
        let root = try #require(PropertyListSerialization.propertyList(
            from: Data(contentsOf: url), format: &outputFormat,
        ) as? [String: Any])
        #expect(outputFormat == format)
        #expect((root["OtherFeature"] as? NSDictionary) == (original["OtherFeature"] as? NSDictionary))
        let feature = try #require(root["EnableBTVCLeConnection"] as? [String: Any])
        #expect(feature["Enabled"] as? Bool == true)
        #expect(feature["DevelopmentPhase"] as? String == "FeatureComplete")
        // On already: nothing to write.
        #expect(try !CustomFirmwareBluetoothVirtualController.patch(at: url))
    }

    @Test
    func `selected from iOS 18`() throws {
        for base in ["17.6", "18.6", "26.4", "27.0"] {
            let plan = try VPhonePatchPlan.resolve(
                preset: FirmwarePatchSetCatalog.standardPreset,
                patchSets: FirmwarePatchSetCatalog.bundled,
                iOSBase: VPhoneVersion(base), cloudOS: VPhoneVersion("26.4"),
            )
            #expect(plan.isEnabled(FirmwareGuestSystemPatchSet.virtualBluetooth) == !base.hasPrefix("17."))
        }
    }

    @Test
    func `TV and HomePod presets enable and admit virtual Bluetooth from OS 18`() throws {
        let identifier = FirmwareGuestSystemPatchSet.virtualBluetooth
        for preset in [FirmwarePatchSetCatalog.tvOSPreset, FirmwarePatchSetCatalog.tvOS4KPreset, FirmwarePatchSetCatalog.homePodMiniPreset] {
            for base in ["17.6", "18.6", "26.4", "27.0", "27.2"] {
                let plan = try VPhonePatchPlan.resolve(
                    preset: preset,
                    patchSets: FirmwarePatchSetCatalog.bundled,
                    iOSBase: VPhoneVersion(base), cloudOS: VPhoneVersion("26.4"),
                )
                #expect(plan.isEnabled(identifier) == !base.hasPrefix("17."))
            }
        }
        let selection: Set<String> = [identifier]
        #expect(FirmwareGuestPatchResolution.unvalidatedTVGuestPatches(enabled: selection).isEmpty)
        #expect(FirmwareGuestPatchResolution.unvalidatedTVGuestPatches(enabled: selection, arm64eUserland: true).isEmpty)
        #expect(FirmwareGuestPatchResolution.unvalidatedHomePodGuestPatches(enabled: selection).isEmpty)
    }
}
