@testable import FirmwarePatcher
import Foundation
import Testing
import VPhonePatchKit

@Suite("VideoSubscriberAccount exception policy")
struct DyldSharedCacheVideoSubscriberAccountTests {
    @Test func observedPolicyPrologue() throws {
        // Observed on iOS 26.5 (23F77), 26.6.1 (23G83) and 26.6.2 (23G90):
        // pacibsp; stp x20, x19, [sp, #-32]!
        let original = Data([0x7f, 0x23, 0x03, 0xd5, 0xf4, 0x4f, 0xbe, 0xa9])
        let result = try DyldSharedCacheVideoSubscriberAccountPatcher.replacement(for: original, at: 0x1000)
        // Independently frozen AArch64 mov w0,#0; ret. Authentication has not
        // run, so the early return must use ret rather than retab.
        #expect(result == Data([0x00, 0x00, 0x80, 0x52, 0xc0, 0x03, 0x5f, 0xd6]))
        #expect(try DyldSharedCacheVideoSubscriberAccountPatcher.replacement(for: result, at: 0x1000) == result)
    }

    @Test func refusesUnexpectedCode() {
        #expect(throws: (any Error).self) {
            try DyldSharedCacheVideoSubscriberAccountPatcher.replacement(
                for: Data(repeating: 0, count: 8), at: 0x1000,
            )
        }
    }

    @Test func selectionAndVersionGate() throws {
        let id = DyldSharedCacheVideoSubscriberAccountPatcher.patchID
        for base in ["18.6", "26.4", "26.5", "26.6", "26.6.1", "26.6.2", "26.7", "27.0"] {
            var preset = FirmwarePatchSetCatalog.standardPreset
            let plan = try VPhonePatchPlan.resolve(
                preset: preset, patchSets: FirmwarePatchSetCatalog.bundled,
                iOSBase: VPhoneVersion(base), cloudOS: VPhoneVersion("26.4"),
            )
            #expect(plan.isEnabled(id) == ["26.5", "26.6", "26.6.1", "26.6.2"].contains(base))
            preset.selection = preset.selection.blocking([id])
            let blocked = try VPhonePatchPlan.resolve(
                preset: preset, patchSets: FirmwarePatchSetCatalog.bundled,
                iOSBase: VPhoneVersion(base), cloudOS: VPhoneVersion("26.4"),
            )
            #expect(!blocked.isEnabled(id))
        }
    }
}
