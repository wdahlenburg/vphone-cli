@testable import FirmwarePatcher
import Foundation
import Testing
import VPhonePatchKit

@Suite("Virtual Bluetooth feature flag")
struct CustomFirmwareBluetoothVirtualControllerTests {
    @Test
    func `physical BLE discovery is opt in on iOS 26 and later`() throws {
        let identifier = FirmwareGuestSystemPatchSet.bluetoothAdvertisementPassup
        for base in ["18.6", "26.4", "26.6", "27.0", "27.2", "28.0"] {
            for preset in [FirmwarePatchSetCatalog.standardPreset, FirmwarePatchSetCatalog.experimentalPreset] {
                let plan = try VPhonePatchPlan.resolve(
                    preset: preset, patchSets: FirmwarePatchSetCatalog.bundled,
                    iOSBase: VPhoneVersion(base), cloudOS: VPhoneVersion("26.4")
                )
                #expect(plan.isEnabled(identifier) == (!base.hasPrefix("18.") && preset.identifier == "experimental"))
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
    func `selected from iOS 26`() throws {
        for base in ["18.6", "26.4", "27.0"] {
            let plan = try VPhonePatchPlan.resolve(
                preset: FirmwarePatchSetCatalog.standardPreset,
                patchSets: FirmwarePatchSetCatalog.bundled,
                iOSBase: VPhoneVersion(base), cloudOS: VPhoneVersion("26.4"),
            )
            #expect(plan.isEnabled(FirmwareGuestSystemPatchSet.virtualBluetooth) == !base.hasPrefix("18."))
        }
    }

    @Test
    func `TV and HomePod presets enable and admit virtual Bluetooth from OS 26`() throws {
        let identifier = FirmwareGuestSystemPatchSet.virtualBluetooth
        for preset in [FirmwarePatchSetCatalog.tvOSPreset, FirmwarePatchSetCatalog.tvOS4KPreset, FirmwarePatchSetCatalog.homePodMiniPreset] {
            for base in ["18.6", "26.4", "27.0", "27.2"] {
                let plan = try VPhonePatchPlan.resolve(
                    preset: preset,
                    patchSets: FirmwarePatchSetCatalog.bundled,
                    iOSBase: VPhoneVersion(base), cloudOS: VPhoneVersion("26.4"),
                )
                #expect(plan.isEnabled(identifier) == !base.hasPrefix("18."))
            }
        }
        let selection: Set<String> = [identifier]
        #expect(FirmwareGuestPatchResolution.unvalidatedTVGuestPatches(enabled: selection).isEmpty)
        #expect(FirmwareGuestPatchResolution.unvalidatedTVGuestPatches(enabled: selection, arm64eUserland: true).isEmpty)
        #expect(FirmwareGuestPatchResolution.unvalidatedHomePodGuestPatches(enabled: selection).isEmpty)
    }
}
