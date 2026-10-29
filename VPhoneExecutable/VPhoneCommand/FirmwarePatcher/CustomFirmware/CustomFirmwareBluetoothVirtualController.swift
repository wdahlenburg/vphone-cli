import Foundation
import VPhonePatchKit

/// Let bluetoothd connect over its virtual controller. On a VM (DT
/// `arm-io/bluetooth` `transport-encoding` 10, `kern.hv_vmm_present`)
/// bluetoothd drives a built-in virtual LE controller, BTVC, whose radio is
/// Bonjour `_btvc._tcp` on the VMs' shared network. The shipped feature flag
/// `EnableBTVCLeConnection` is off, which keeps it from connecting: a watch and
/// its phone pair over NetworkRelay, then talk over this link.
/// See Research/Guest/watch_pairing.md.
public enum CustomFirmwareBluetoothVirtualController {
    public static let relativePath = "System/Library/FeatureFlags/Domain/BluetoothFeatures.plist"
    public static let feature = "EnableBTVCLeConnection"

    /// Turn the feature on, keeping every other feature and the plist's
    /// encoding. Returns false when it already is on.
    @discardableResult
    public static func patch(at url: URL, dryRun: Bool = false) throws -> Bool {
        let input = try Data(contentsOf: url)
        var format = PropertyListSerialization.PropertyListFormat.xml
        guard var root = try PropertyListSerialization.propertyList(
            from: input, options: [], format: &format,
        ) as? [String: Any] else {
            throw PatcherError.invalidFormat("Not a feature flag dictionary: \(url.path)")
        }
        var feature = root[Self.feature] as? [String: Any] ?? [:]
        if let enabled = feature["Enabled"] as? NSNumber, CFGetTypeID(enabled) == CFBooleanGetTypeID(), enabled.boolValue {
            return false
        }
        feature["Enabled"] = true
        root[Self.feature] = feature
        let output = try PropertyListSerialization.data(fromPropertyList: root, format: format, options: 0)
        if !dryRun {
            try output.write(to: url, options: .atomic)
        }
        return true
    }
}

/// Marks advertisements delivered by BTVC eligible for CoreBluetooth clients.
///
/// Apple's physical controller appends private scan metadata to HCI advertising
/// reports. BTVC emits the standard report only, so bluetoothd leaves the
/// internal scan-source metadata clear. BTVC also reports that extended
/// scanning, scan-source metadata, and pass-up advertising are unsupported
/// even though it emits extended advertising reports. Force those
/// capabilities and mark BTVC reports as MainCore pass-up advertisements so
/// they reach the per-session CoreBluetooth scan path. All later per-session
/// filtering remains intact.
public enum CustomFirmwareBluetoothAdvertisementPassup {
    public static let relativePath = "usr/sbin/bluetoothd"

    public enum Outcome: Sendable { case patched, alreadyPatched }

    struct Site: Sendable {
        enum State { case pristine, forcedZero, forcedOne }
        let reportState: State
        let conditionalAddress: UInt64
        let conditionalOffset: Int
        let fallbackAddress: UInt64
        let fallbackOffset: Int
        let register: UInt32
        let scanSourceConditional: InstructionSite
        let scanSourceFirstGate: InstructionSite
        let scanSourceSecondGate: InstructionSite
        let deliveryGate: DeliveryGate
        let wakeMetadata: InstructionSite
        let wakeRoute: DeliveryGate
        let extendedScanCapability: Capability
        let scanSourceCapability: Capability
        let passupCapability: Capability

        var isPatched: Bool {
            reportState == .forcedOne
                && scanSourceConditional.state == .forcedOne
                && scanSourceFirstGate.state == .forcedOne
                && scanSourceSecondGate.state == .forcedOne
                && deliveryGate.state == .forcedOne
                && wakeMetadata.state == .forcedOne
                && wakeRoute.state == .forcedOne
                && extendedScanCapability.state == .forcedOne
                && scanSourceCapability.state == .forcedOne
                && passupCapability.state == .forcedOne
        }
    }

    struct InstructionSite: Sendable {
        let state: Site.State
        let address: UInt64
        let offset: Int
        let register: UInt32
    }

    struct Capability: Sendable {
        let state: Site.State
        let address: UInt64
        let offset: Int
    }

    struct DeliveryGate: Sendable {
        let state: Site.State
        let address: UInt64
        let offset: Int
        let callbackAddress: UInt64
    }

    @discardableResult
    public static func patch(at url: URL, log: ((String) -> Void)? = nil) throws -> Outcome {
        var data = try Data(contentsOf: url)
        let outcome = try patch(&data, log: log)
        if outcome == .patched {
            try data.write(to: url, options: .atomic)
        }
        return outcome
    }

    @discardableResult
    public static func patch(_ data: inout Data, log: ((String) -> Void)? = nil) throws -> Outcome {
        if data.startIndex != 0 { data = Data(data) }
        let site = try locateSite(in: data)
        guard !site.isPatched else {
            log?("  [.] BTVC advertisement pass-up is already enabled")
            return .alreadyPatched
        }
        guard let forceOne = ARM64Encoder.encodeMovzW(rd: site.register, imm16: 1) else {
            throw PatcherError.patchVerificationFailed("could not encode BTVC scan metadata values")
        }
        guard let forceCapability = ARM64Encoder.encodeMovzW(rd: 0, imm16: 1) else {
            throw PatcherError.patchVerificationFailed("could not encode BTVC pass-up capability")
        }
        data.replaceSubrange(site.conditionalOffset ..< site.conditionalOffset + 4, with: forceOne)
        data.replaceSubrange(site.fallbackOffset ..< site.fallbackOffset + 4, with: forceOne)
        data.replaceSubrange(
            site.scanSourceConditional.offset ..< site.scanSourceConditional.offset + 4,
            with: forceOne,
        )
        data.replaceSubrange(
            site.scanSourceFirstGate.offset ..< site.scanSourceFirstGate.offset + 4,
            with: ARM64.nop,
        )
        data.replaceSubrange(
            site.scanSourceSecondGate.offset ..< site.scanSourceSecondGate.offset + 4,
            with: ARM64.nop,
        )
        guard let deliver = ARM64Encoder.encodeB(
            from: Int(site.deliveryGate.address),
            to: Int(site.deliveryGate.callbackAddress),
        ) else {
            throw PatcherError.patchVerificationFailed("could not encode BTVC advertisement delivery branch")
        }
        data.replaceSubrange(
            site.deliveryGate.offset ..< site.deliveryGate.offset + 4,
            with: deliver,
        )
        guard let forceWakeMetadata = ARM64Encoder.encodeMovzW(
            rd: site.wakeMetadata.register,
            imm16: 1,
        ) else {
            throw PatcherError.patchVerificationFailed("could not encode BTVC wake metadata value")
        }
        data.replaceSubrange(
            site.wakeMetadata.offset ..< site.wakeMetadata.offset + 4,
            with: forceWakeMetadata,
        )
        guard let routeAsDiscovery = ARM64Encoder.encodeB(
            from: Int(site.wakeRoute.address),
            to: Int(site.wakeRoute.callbackAddress),
        ) else {
            throw PatcherError.patchVerificationFailed("could not encode BTVC wake discovery branch")
        }
        data.replaceSubrange(
            site.wakeRoute.offset ..< site.wakeRoute.offset + 4,
            with: routeAsDiscovery,
        )
        data.replaceSubrange(
            site.extendedScanCapability.offset ..< site.extendedScanCapability.offset + 4,
            with: forceCapability,
        )
        data.replaceSubrange(
            site.scanSourceCapability.offset ..< site.scanSourceCapability.offset + 4,
            with: forceCapability,
        )
        data.replaceSubrange(
            site.passupCapability.offset ..< site.passupCapability.offset + 4,
            with: forceCapability,
        )
        let slots = try CustomFirmwareMachOCodeSignature.reattest(
            &data,
            modifiedOffsets: [
                site.conditionalOffset,
                site.fallbackOffset,
                site.scanSourceConditional.offset,
                site.scanSourceFirstGate.offset,
                site.scanSourceSecondGate.offset,
                site.deliveryGate.offset,
                site.wakeMetadata.offset,
                site.wakeRoute.offset,
                site.extendedScanCapability.offset,
                site.scanSourceCapability.offset,
                site.passupCapability.offset,
            ],
        )
        log?("  [+] bluetoothd BTVC pass-up @ 0x\(String(site.conditionalAddress, radix: 16)), "
            + "0x\(String(site.fallbackAddress, radix: 16)); extended scan @ "
            + "0x\(String(site.extendedScanCapability.address, radix: 16)); scan source @ "
            + "0x\(String(site.scanSourceConditional.address, radix: 16)), capability @ "
            + "0x\(String(site.scanSourceCapability.address, radix: 16)); delivery gate @ "
            + "0x\(String(site.deliveryGate.address, radix: 16)); wake metadata @ "
            + "0x\(String(site.wakeMetadata.address, radix: 16)), discovery route @ "
            + "0x\(String(site.wakeRoute.address, radix: 16)); pass-up capability @ "
            + "0x\(String(site.passupCapability.address, radix: 16)); re-attested \(slots.count) slot(s)")
        let verified = try locateSite(in: data)
        guard verified.isPatched else {
            throw PatcherError.patchVerificationFailed("BTVC pass-up instructions did not verify")
        }
        return .patched
    }

    static func locateSite(in data: Data) throws -> Site {
        guard let text = MachOParser.parseSections(from: data)["__TEXT,__text"] else {
            throw PatcherError.invalidFormat("bluetoothd has no __TEXT,__text")
        }
        let start = Int(text.fileOffset)
        let end = start + Int(text.size)
        guard start >= 0, end <= data.count else {
            throw PatcherError.invalidFormat("bluetoothd __TEXT,__text falls outside the file")
        }
        let instructions = ARM64Disassembler().disassemble(data.subdata(in: start ..< end), at: text.address)
        guard instructions.count >= 24 else {
            throw PatcherError.patchSiteNotFound("bluetoothd text is too short for BTVC scan metadata")
        }
        var reportMatches: [(state: Site.State, conditional: ARM64Instruction, fallback: ARM64Instruction, register: UInt32)] = []
        for index in 6 ..< instructions.count {
            let store = instructions[index]
            guard store.mnemonic == "strb",
                  let valueName = registerName(store, 0),
                  let valueRegister = wRegisterNumber(valueName),
                  let storeMemory = memory(store), storeMemory.disp == 0x16F
            else { continue }

            let fallback = instructions[index - 1]
            let branch = instructions[index - 2]
            let conditional = instructions[index - 3]
            let compare = instructions[index - 4]
            let metadata = instructions[index - 5]
            let gate = instructions[index - 6]
            guard branch.mnemonic == "b", immediate(branch, 0) == Int64(store.address),
                  compare.mnemonic == "cmp", registerName(compare, 0) == valueName,
                  immediate(compare, 1) == 0,
                  metadata.mnemonic == "ldrb", registerName(metadata, 0) == valueName,
                  gate.mnemonic == "cbz", registerName(gate, 0) == "w0",
                  immediate(gate, 1) == Int64(fallback.address),
                  registerName(conditional, 0) == valueName,
                  registerName(fallback, 0) == valueName
            else { continue }

            let pristine = conditional.mnemonic == "cset"
                && conditional.detail?.conditionCode == .ne
                && fallback.mnemonic == "mov" && immediate(fallback, 1) == 0
            let forcedOne = isMoveOne(conditional) && isMoveOne(fallback)
            let forcedZero = isMoveZero(conditional) && isMoveZero(fallback)
            guard pristine || forcedOne || forcedZero else { continue }
            let state: Site.State = pristine ? .pristine : (forcedOne ? .forcedOne : .forcedZero)
            reportMatches.append((state, conditional, fallback, valueRegister))
        }
        guard reportMatches.count == 1, let report = reportMatches.first else {
            throw PatcherError.patchSiteNotFound(
                "expected one bluetoothd isPassup derivation, found \(reportMatches.count)",
            )
        }

        var scanSourceMatches: [(
            conditional: ARM64Instruction,
            conditionalState: Site.State,
            firstGate: ARM64Instruction,
            firstGateState: Site.State,
            secondGate: ARM64Instruction,
            secondGateState: Site.State,
            register: UInt32
        )] = []
        for index in 14 ..< instructions.count - 9 {
            let conditional = instructions[index]
            guard let valueName = registerName(conditional, 0),
                  let valueRegister = wRegisterNumber(valueName)
            else { continue }
            let conditionalPristine = conditional.mnemonic == "cset"
                && conditional.detail?.conditionCode == .ne
            let conditionalForcedZero = isMoveZero(conditional)
            let conditionalForcedOne = isMoveOne(conditional)
            guard conditionalPristine || conditionalForcedZero || conditionalForcedOne else { continue }

            let firstGate = instructions[index - 14]
            let secondGate = instructions[index - 3]
            let reportStore = instructions[index + 2]
            let fallbackValue = instructions[index + 7]
            let fallbackStore = instructions[index + 9]
            guard reportStore.mnemonic == "strb",
                  registerName(reportStore, 0) == valueName,
                  memory(reportStore)?.disp == 0x16D,
                  fallbackValue.mnemonic == "mov",
                  registerName(fallbackValue, 0) == valueName,
                  immediate(fallbackValue, 1) == 0,
                  fallbackStore.mnemonic == "strb",
                  registerName(fallbackStore, 0) == "wzr",
                  memory(fallbackStore)?.disp == 0x16D
            else { continue }

            func gateState(_ instruction: ARM64Instruction) -> Site.State? {
                if instruction.mnemonic == "cbz",
                   registerName(instruction, 0) == "w0",
                   immediate(instruction, 1) == Int64(fallbackValue.address) {
                    return .pristine
                }
                if instruction.mnemonic == "nop" { return .forcedOne }
                return nil
            }
            guard let firstGateState = gateState(firstGate),
                  let secondGateState = gateState(secondGate)
            else { continue }
            scanSourceMatches.append((
                conditional,
                conditionalPristine ? .pristine : (conditionalForcedOne ? .forcedOne : .forcedZero),
                firstGate,
                firstGateState,
                secondGate,
                secondGateState,
                valueRegister,
            ))
        }
        guard scanSourceMatches.count == 1, let scanSource = scanSourceMatches.first else {
            throw PatcherError.patchSiteNotFound(
                "expected one bluetoothd scanSourceCore derivation, found \(scanSourceMatches.count)",
            )
        }
        guard scanSource.register == report.register else {
            throw PatcherError.patchVerificationFailed(
                "bluetoothd scan metadata derivations use different value registers",
            )
        }

        var deliveryMatches: [DeliveryGate] = []
        for index in 5 ..< instructions.count - 1 {
            let gate = instructions[index]
            guard gate.mnemonic == "b",
                  let gateTarget = immediate(gate, 0)
            else { continue }
            let bitGate = instructions[index - 1]
            let metadataLoad = instructions[index - 2]
            let scanModeGate = instructions[index - 3]
            let scanModeCompare = instructions[index - 4]
            let scanModeLoad = instructions[index - 5]
            guard bitGate.mnemonic == "tbnz",
                  let callbackTarget = immediate(bitGate, 2),
                  metadataLoad.mnemonic == "ldrb",
                  scanModeGate.mnemonic == "b.ne",
                  immediate(scanModeGate, 0) == callbackTarget,
                  scanModeCompare.mnemonic == "cmp",
                  immediate(scanModeCompare, 1) == 1,
                  scanModeLoad.mnemonic == "ldrb"
            else { continue }
            let state: Site.State
            if gateTarget > callbackTarget, gateTarget <= callbackTarget + 0x20 {
                state = .pristine
            } else if gateTarget == callbackTarget {
                state = .forcedOne
            } else {
                continue
            }
            deliveryMatches.append(DeliveryGate(
                state: state,
                address: gate.address,
                offset: start + Int(gate.address - text.address),
                callbackAddress: UInt64(callbackTarget),
            ))
        }
        guard deliveryMatches.count == 1, let deliveryGate = deliveryMatches.first else {
            throw PatcherError.patchSiteNotFound(
                "expected one bluetoothd parsed-advertisement delivery gate, found \(deliveryMatches.count)",
            )
        }

        // Apple's physical controller supplies private metadata after the
        // standard HCI advertising fields. The high-level discovery path can
        // create a UUID for a previously unseen address only when the parsed
        // report carries its AP-wakeup marker. BTVC leaves that byte clear.
        var wakeMetadataMatches: [InstructionSite] = []
        for index in 0 ..< instructions.count - 1 {
            let value = instructions[index]
            let store = instructions[index + 1]
            guard let valueName = registerName(value, 0),
                  let valueRegister = wRegisterNumber(valueName),
                  store.mnemonic == "strb",
                  registerName(store, 0) == valueName,
                  memory(store)?.disp == 0x9FC
            else { continue }
            let pristine = value.mnemonic == "ldrb" && memory(value)?.disp == 0x19
            let forcedOne = isMoveOne(value)
            guard pristine || forcedOne else { continue }
            wakeMetadataMatches.append(InstructionSite(
                state: pristine ? .pristine : .forcedOne,
                address: value.address,
                offset: start + Int(value.address - text.address),
                register: valueRegister,
            ))
        }
        guard wakeMetadataMatches.count == 1, let wakeMetadata = wakeMetadataMatches.first else {
            throw PatcherError.patchSiteNotFound(
                "expected one bluetoothd advertising wake-metadata derivation, found \(wakeMetadataMatches.count)",
            )
        }

        // The synthesized marker is needed to allocate a UUID for a new
        // address, but bluetoothd normally treats that same marker as an
        // AP-wakeup-only report later in the function. Route that one branch
        // to the ordinary discovery continuation so active app scans receive
        // the report after UUID creation.
        var wakeRouteMatches: [DeliveryGate] = []
        for index in 0 ..< instructions.count - 4 {
            let load = instructions[index]
            let compare = instructions[index + 1]
            let route = instructions[index + 2]
            let payload = instructions[index + 3]
            let call = instructions[index + 4]
            guard load.mnemonic == "ldrb",
                  let loadOperands = load.detail?.operands,
                  loadOperands.count >= 2,
                  loadOperands[0].type == .register,
                  loadOperands[1].type == .memory,
                  loadOperands[1].mem.disp == 0xE,
                  compare.mnemonic == "cmp",
                  compare.detail?.operands.first?.reg == loadOperands[0].reg,
                  immediate(compare, 1) == 1,
                  let target = immediate(route, 0),
                  payload.mnemonic == "add",
                  let payloadOperands = payload.detail?.operands,
                  payloadOperands.count >= 3,
                  payloadOperands[0].reg == .x(1),
                  payloadOperands[1].reg == loadOperands[1].mem.base,
                  payloadOperands[2].imm == 0x30,
                  call.mnemonic == "bl" || call.mnemonic == "blr" || call.mnemonic == "blraa"
            else { continue }
            let state: Site.State
            if route.mnemonic == "b.ne" {
                state = .pristine
            } else if route.mnemonic == "b" {
                state = .forcedOne
            } else {
                continue
            }
            wakeRouteMatches.append(DeliveryGate(
                state: state,
                address: route.address,
                offset: start + Int(route.address - text.address),
                callbackAddress: UInt64(target),
            ))
        }
        guard wakeRouteMatches.count == 1, let wakeRoute = wakeRouteMatches.first else {
            throw PatcherError.patchSiteNotFound(
                "expected one bluetoothd wake-only discovery route, found \(wakeRouteMatches.count)",
            )
        }

        var capabilityMatches: [(state: Site.State, instruction: ARM64Instruction, storageOffset: Int32)] = []
        for index in 0 ..< instructions.count - 2 {
            let query = instructions[index]
            let preserve = instructions[index + 1]
            let store = instructions[index + 2]
            guard preserve.mnemonic == "mov",
                  registerName(preserve, 1) == "x0",
                  store.mnemonic == "strb", registerName(store, 0) == "w0",
                  let storeMemory = memory(store),
                  storeMemory.disp == 0x808 || storeMemory.disp == 0x868 || storeMemory.disp == 0x878
            else { continue }

            let pristine = query.mnemonic == "bl" || query.mnemonic == "blr" || query.mnemonic == "blraa"
            let forcedOne = isMoveOne(query) && registerName(query, 0) == "w0"
            guard pristine || forcedOne else { continue }
            capabilityMatches.append((pristine ? .pristine : .forcedOne, query, storeMemory.disp))
        }
        let extendedScanMatches = capabilityMatches.filter { $0.storageOffset == 0x808 }
        let scanSourceCapabilityMatches = capabilityMatches.filter { $0.storageOffset == 0x868 }
        let passupMatches = capabilityMatches.filter { $0.storageOffset == 0x878 }
        guard extendedScanMatches.count == 1, let extendedScan = extendedScanMatches.first else {
            throw PatcherError.patchSiteNotFound(
                "expected one bluetoothd extended scan capability query, found \(extendedScanMatches.count)",
            )
        }
        guard scanSourceCapabilityMatches.count == 1, let scanSourceCapability = scanSourceCapabilityMatches.first else {
            throw PatcherError.patchSiteNotFound(
                "expected one bluetoothd scan-source capability query, found \(scanSourceCapabilityMatches.count)",
            )
        }
        guard passupMatches.count == 1, let passup = passupMatches.first else {
            throw PatcherError.patchSiteNotFound(
                "expected one bluetoothd extended pass-up capability query, found \(passupMatches.count)",
            )
        }
        return Site(
            reportState: report.state,
            conditionalAddress: report.conditional.address,
            conditionalOffset: start + Int(report.conditional.address - text.address),
            fallbackAddress: report.fallback.address,
            fallbackOffset: start + Int(report.fallback.address - text.address),
            register: report.register,
            scanSourceConditional: InstructionSite(
                state: scanSource.conditionalState,
                address: scanSource.conditional.address,
                offset: start + Int(scanSource.conditional.address - text.address),
                register: scanSource.register,
            ),
            scanSourceFirstGate: InstructionSite(
                state: scanSource.firstGateState,
                address: scanSource.firstGate.address,
                offset: start + Int(scanSource.firstGate.address - text.address),
                register: scanSource.register,
            ),
            scanSourceSecondGate: InstructionSite(
                state: scanSource.secondGateState,
                address: scanSource.secondGate.address,
                offset: start + Int(scanSource.secondGate.address - text.address),
                register: scanSource.register,
            ),
            deliveryGate: deliveryGate,
            wakeMetadata: wakeMetadata,
            wakeRoute: wakeRoute,
            extendedScanCapability: Capability(
                state: extendedScan.state,
                address: extendedScan.instruction.address,
                offset: start + Int(extendedScan.instruction.address - text.address),
            ),
            scanSourceCapability: Capability(
                state: scanSourceCapability.state,
                address: scanSourceCapability.instruction.address,
                offset: start + Int(scanSourceCapability.instruction.address - text.address),
            ),
            passupCapability: Capability(
                state: passup.state,
                address: passup.instruction.address,
                offset: start + Int(passup.instruction.address - text.address),
            ),
        )
    }

    private static func registerName(_ instruction: ARM64Instruction, _ index: Int) -> String? {
        guard let operands = instruction.detail?.operands, index < operands.count,
              operands[index].type == .register else { return nil }
        return operands[index].reg.name
    }

    private static func immediate(_ instruction: ARM64Instruction, _ index: Int) -> Int64? {
        guard let operands = instruction.detail?.operands, index < operands.count,
              operands[index].type == .immediate else { return nil }
        return operands[index].imm
    }

    private static func memory(_ instruction: ARM64Instruction) -> ARM64MemoryOperand? {
        instruction.detail?.operands.first(where: { $0.type == .memory })?.mem
    }

    private static func wRegisterNumber(_ name: String) -> UInt32? {
        guard name.first == "w", let number = UInt32(name.dropFirst()), number <= 30 else { return nil }
        return number
    }

    private static func isMoveOne(_ instruction: ARM64Instruction) -> Bool {
        instruction.mnemonic == "mov" && immediate(instruction, 1) == 1
    }

    private static func isMoveZero(_ instruction: ARM64Instruction) -> Bool {
        instruction.mnemonic == "mov" && immediate(instruction, 1) == 0
    }
}
