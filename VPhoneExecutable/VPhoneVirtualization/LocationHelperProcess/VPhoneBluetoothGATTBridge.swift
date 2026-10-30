import Foundation
@preconcurrency import CoreBluetooth

final class VPhoneBluetoothGATTSession {
    enum Attribute {
        case service(CBService)
        case characteristicDeclaration(CBCharacteristic)
        case characteristicValue(CBCharacteristic)
        case descriptor(CBDescriptor)
    }

    struct ServiceRange {
        let start: UInt16
        let end: UInt16
        let service: CBService
    }

    struct CharacteristicHandles {
        let declaration: UInt16
        let value: UInt16
        let characteristic: CBCharacteristic
    }

    struct PendingRead {
        enum Response {
            case read(requestOpcode: UInt8, offset: Int)
            case readByType
        }

        let handle: UInt16
        let response: Response
    }

    let handle: UInt16
    let identifier: String
    var transportHandle: UInt16?
    var aclReassembler = VPhoneBluetoothACLReassembler()
    let address: Data
    let peripheral: CBPeripheral
    var queuedATT: [Data] = []
    var servicesAwaitingCharacteristics: Set<ObjectIdentifier> = []
    var characteristicsAwaitingDescriptors: Set<ObjectIdentifier> = []
    var discoveryStarted = false
    var databaseReady = false
    var attributes: [UInt16: Attribute] = [:]
    var attributeUUIDs: [UInt16: CBUUID] = [:]
    var services: [ServiceRange] = []
    var characteristics: [CharacteristicHandles] = []
    var characteristicValueHandles: [ObjectIdentifier: UInt16] = [:]
    var descriptorHandles: [ObjectIdentifier: UInt16] = [:]
    var pendingRead: PendingRead?
    var pendingReadObject: ObjectIdentifier?
    var pendingWriteHandle: UInt16?
    var pendingWriteObject: ObjectIdentifier?
    var subscriptions: [ObjectIdentifier: UInt16] = [:]
    var pendingSubscriptions: [ObjectIdentifier: UInt16] = [:]
    var indicationPending = false
    var indications: [Data] = []
    var mtu = 23
    var writesWithoutResponse: [(CBCharacteristic, Data)] = []
    var connectWhenDisconnected = false

    init(handle: UInt16, identifier: String, address: Data, peripheral: CBPeripheral) {
        self.handle = handle
        self.identifier = identifier
        self.address = address
        self.peripheral = peripheral
    }
}

extension VPhoneBluetoothHelperDelegate {
    func handleGuestLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = message["type"] as? String
        else { return }
        switch type {
        case "reset":
            let peripherals = gattSessions.values.map(\.peripheral)
            gattSessions.removeAll()
            for peripheral in peripherals { central?.cancelPeripheralConnection(peripheral) }
        case "btvc":
            handleBTVCMessage(message)
        case "connection_ready":
            handleConnectRequest(message)
        case "disconnect_request":
            handleDisconnectRequest(message)
        case "hci":
            handleHCIPacket(message)
        default:
            break
        }
    }

    private func handleConnectRequest(_ message: [String: Any]) {
        guard let handleNumber = message["handle"] as? NSNumber,
              let identifier = message["connection"] as? String, !identifier.isEmpty,
              let encodedAddress = message["address"] as? String,
              let address = Data(base64Encoded: encodedAddress), address.count == 6
        else { return }
        let handle = handleNumber.uint16Value
        guard handle != 0, handle <= 0x0EFF else { return }
        let candidates = [peripheralsByAddress[address], peripheralsByAddress[Data(address.reversed())]].compactMap { $0 }
        guard Set(candidates.map(\.identifier)).count == 1, let peripheral = candidates.first else { return }
        if let old = gattSessions[handle], old.identifier == identifier { return }
        if let old = gattSessions.removeValue(forKey: handle), old.peripheral !== peripheral {
            central?.cancelPeripheralConnection(old.peripheral)
        }
        let session = VPhoneBluetoothGATTSession(handle: handle, identifier: identifier, address: address, peripheral: peripheral)
        gattSessions[handle] = session
        session.connectWhenDisconnected = peripheral.state == .disconnecting
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, let session = self.gattSessions[handle], session.identifier == identifier,
                  !session.databaseReady else { return }
            self.closeSessions(for: peripheral, message: "connection or GATT discovery timed out")
            self.central?.cancelPeripheralConnection(peripheral)
        }
        if peripheral.state == .connected {
            ensureDiscovery(session)
        } else {
            connect(peripheral)
        }
    }

    private func handleDisconnectRequest(_ message: [String: Any]) {
        guard let handleNumber = message["handle"] as? NSNumber else { return }
        let handle = handleNumber.uint16Value
        guard let session = gattSessions[handle],
              session.identifier == message["connection"] as? String else { return }
        gattSessions.removeValue(forKey: handle)
        let peripheral = session.peripheral
        guard sessions(for: peripheral).isEmpty, peripheral.state != .disconnected else { return }
        central?.cancelPeripheralConnection(peripheral)
    }

    private func handleBTVCMessage(_ message: [String: Any]) {
        guard let encoded = message["data"] as? String,
              let data = Data(base64Encoded: encoded),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let type = root["BTVCBonjourServiceMessageType"] as? String
        else { return }
        if type.hasSuffix("DataPacket"),
           let value = root["BTVCBonjourServiceMessageValue"] as? [String: Any],
           let header = value["header"] as? NSNumber,
           let payload = value["payload"] as? Data {
            handleLinkLayer(
                header: header.uint8Value,
                payload: payload,
                initiatorAddress: value["initA"] as? Data,
                peerAddress: value["peerA"] as? Data
            )
            return
        }
        guard let address = findData(named: "peerA", in: root).map({ Data($0.prefix(6)) }) else { return }
        guard let peripheral = peripheralsByAddress[address] else { return }
        if type.hasSuffix("Connect") {
            connect(peripheral)
        } else if type.hasSuffix("Disconnect") {
            central?.cancelPeripheralConnection(peripheral)
        }
    }

    private func handleLinkLayer(
        header: UInt8,
        payload: Data,
        initiatorAddress: Data?,
        peerAddress: Data?
    ) {
        guard header == 3, let opcode = payload.first else { return }
        let responsePayload: Data
        switch opcode {
        case 0x08 where payload.count == 9: // LL_FEATURE_REQ
            responsePayload = Data([0x09]) + payload.dropFirst()
        case 0x0C: // LL_VERSION_IND
            responsePayload = Data([0x0C, 0x0C, 0x4C, 0x00, 0x01, 0x00])
        case 0x14 where payload.count == 9: // LL_LENGTH_REQ
            responsePayload = Data([0x15]) + payload.dropFirst()
        case 0x16 where payload.count == 3: // LL_PHY_REQ
            responsePayload = Data([0x17]) + payload.dropFirst()
        default:
            return
        }
        emitBTVCDataPacket(
            header: 3,
            payload: responsePayload,
            initiatorAddress: nil,
            peerAddress: nil
        )
    }

    private func emitBTVCDataPacket(
        header: UInt8,
        payload: Data,
        initiatorAddress: Data?,
        peerAddress: Data?
    ) {
        var value: [String: Any] = ["header": header, "payload": payload]
        if let initiatorAddress { value["initA"] = initiatorAddress }
        if let peerAddress { value["peerA"] = peerAddress }
        let response: [String: Any] = [
            "BTVCBonjourServiceMessageType": "BTVCBonjourServiceMessageTypeDataPacket",
            "BTVCBonjourServiceMessageValue": value,
        ]
        guard let plist = try? PropertyListSerialization.data(
            fromPropertyList: response, format: .binary, options: 0
        ), let json = try? JSONSerialization.data(withJSONObject: [
            "type": "btvc_response", "data": plist.base64EncodedString(),
        ]) else { return }
        var line = json
        line.append(0x0A)
        FileHandle.standardOutput.write(line)
    }

    private func findData(named name: String, in value: Any) -> Data? {
        if let dictionary = value as? [String: Any] {
            if let data = dictionary[name] as? Data { return data }
            for child in dictionary.values {
                if let data = findData(named: name, in: child) { return data }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let data = findData(named: name, in: child) { return data }
            }
        }
        return nil
    }

    private func handleHCIPacket(_ message: [String: Any]) {
        guard let encoded = message["data"] as? String,
              let packet = Data(base64Encoded: encoded)
        else { return }
        VPhoneBluetoothPacketCapture.shared.recordACL(packet, received: false)
        guard let nativeHandle = message["handle"] as? NSNumber,
              let session = gattSessions[nativeHandle.uint16Value],
              session.identifier == message["connection"] as? String else { return }
        let peripheral = session.peripheral
        guard let acl = session.aclReassembler.consume(packet) else { return }
        session.transportHandle = acl.handle
        guard acl.payload.count <= 517, session.queuedATT.count < 128 else {
            closeSessions(for: peripheral, message: "ATT input limit exceeded")
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        guard peripheral.state == .connected else {
            session.queuedATT.append(acl.payload)
            connect(peripheral)
            return
        }
        ensureDiscovery(session)
        guard session.databaseReady else {
            session.queuedATT.append(acl.payload)
            return
        }
        processATT(acl.payload, session: session)
    }

    private func connect(_ peripheral: CBPeripheral) {
        guard let central, peripheral.state == .disconnected else { return }
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.delegate = self
        for session in sessions(for: peripheral) {
            ensureDiscovery(session)
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: (any Error)?,
    ) {
        closeSessions(for: peripheral, message: error?.localizedDescription ?? "connection failed")
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: (any Error)?,
    ) {
        let waiting = sessions(for: peripheral).filter(\.connectWhenDisconnected)
        if !waiting.isEmpty {
            for session in waiting { session.connectWhenDisconnected = false }
            connect(peripheral)
            return
        }
        closeSessions(for: peripheral, message: error?.localizedDescription ?? "disconnected")
    }

    private func closeSessions(for peripheral: CBPeripheral, message: String) {
        failQueuedRequests(for: peripheral, message: message)
        for session in sessions(for: peripheral) {
            gattSessions.removeValue(forKey: session.handle)
            emitControllerMessage([
                "type": "link_disconnected", "handle": session.handle,
                "connection": session.identifier,
            ])
        }
    }

    private func failQueuedRequests(for peripheral: CBPeripheral, message: String) {
        FileHandle.standardError.write(Data("[bluetooth] \(peripheral.identifier) \(message)\n".utf8))
        for session in sessions(for: peripheral) {
            for request in session.queuedATT where !request.isEmpty {
                sendError(request: request[request.startIndex], handle: 0, code: 0x0E, session: session)
            }
            if let pending = session.pendingRead {
                let opcode: UInt8 = switch pending.response {
                case let .read(requestOpcode, _): requestOpcode
                case .readByType: 0x08
                }
                sendError(request: opcode, handle: pending.handle, code: 0x0E, session: session)
            }
            if let handle = session.pendingWriteHandle {
                sendError(request: 0x12, handle: handle, code: 0x0E, session: session)
            }
            session.pendingRead = nil
            session.pendingReadObject = nil
            session.pendingWriteHandle = nil
            session.pendingWriteObject = nil
            session.writesWithoutResponse.removeAll()
            session.servicesAwaitingCharacteristics.removeAll()
            session.characteristicsAwaitingDescriptors.removeAll()
            session.queuedATT.removeAll()
            session.databaseReady = false
            session.discoveryStarted = false
        }
    }

    private func sessions(for peripheral: CBPeripheral) -> [VPhoneBluetoothGATTSession] {
        gattSessions.values.filter { $0.peripheral.identifier == peripheral.identifier }
    }

    private func ensureDiscovery(_ session: VPhoneBluetoothGATTSession) {
        guard !session.discoveryStarted else { return }
        session.discoveryStarted = true
        session.peripheral.delegate = self
        session.peripheral.discoverServices(nil)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        guard error == nil else {
            closeSessions(for: peripheral, message: error!.localizedDescription)
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        let services = peripheral.services ?? []
        for session in sessions(for: peripheral) {
            session.servicesAwaitingCharacteristics = Set(services.map(ObjectIdentifier.init))
        }
        for service in services { peripheral.discoverCharacteristics(nil, for: service) }
        if services.isEmpty { finishDiscovery(for: peripheral) }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: (any Error)?,
    ) {
        if let error {
            closeSessions(for: peripheral, message: error.localizedDescription)
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        let characteristics = service.characteristics ?? []
        for session in sessions(for: peripheral) {
            session.servicesAwaitingCharacteristics.remove(ObjectIdentifier(service))
            session.characteristicsAwaitingDescriptors.formUnion(characteristics.map(ObjectIdentifier.init))
        }
        for characteristic in characteristics { peripheral.discoverDescriptors(for: characteristic) }
        finishDiscoveryIfReady(for: peripheral)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverDescriptorsFor characteristic: CBCharacteristic,
        error: (any Error)?,
    ) {
        if let error {
            closeSessions(for: peripheral, message: error.localizedDescription)
            central?.cancelPeripheralConnection(peripheral)
            return
        }
        for session in sessions(for: peripheral) {
            session.characteristicsAwaitingDescriptors.remove(ObjectIdentifier(characteristic))
        }
        finishDiscoveryIfReady(for: peripheral)
    }

    private func finishDiscoveryIfReady(for peripheral: CBPeripheral) {
        guard sessions(for: peripheral).allSatisfy({
            $0.servicesAwaitingCharacteristics.isEmpty && $0.characteristicsAwaitingDescriptors.isEmpty
        }) else { return }
        finishDiscovery(for: peripheral)
    }

    private func finishDiscovery(for peripheral: CBPeripheral) {
        for session in sessions(for: peripheral) {
            buildDatabase(session)
            session.databaseReady = true
            let queued = session.queuedATT
            session.queuedATT.removeAll()
            for request in queued { processATT(request, session: session) }
        }
    }

    private func buildDatabase(_ session: VPhoneBluetoothGATTSession) {
        session.attributes.removeAll()
        session.attributeUUIDs.removeAll()
        session.services.removeAll()
        session.characteristics.removeAll()
        session.characteristicValueHandles.removeAll()
        session.descriptorHandles.removeAll()
        var next: UInt16 = 1
        for service in session.peripheral.services ?? [] {
            let serviceHandle = next
            session.attributes[next] = .service(service)
            session.attributeUUIDs[next] = CBUUID(string: "2800")
            next &+= 1
            for characteristic in service.characteristics ?? [] {
                let declaration = next
                let value = next &+ 1
                session.attributes[declaration] = .characteristicDeclaration(characteristic)
                session.attributeUUIDs[declaration] = CBUUID(string: "2803")
                session.attributes[value] = .characteristicValue(characteristic)
                session.attributeUUIDs[value] = characteristic.uuid
                session.characteristics.append(.init(
                    declaration: declaration, value: value, characteristic: characteristic,
                ))
                session.characteristicValueHandles[ObjectIdentifier(characteristic)] = value
                next &+= 2
                for descriptor in characteristic.descriptors ?? [] {
                    session.attributes[next] = .descriptor(descriptor)
                    session.attributeUUIDs[next] = descriptor.uuid
                    session.descriptorHandles[ObjectIdentifier(descriptor)] = next
                    next &+= 1
                }
            }
            session.services.append(.init(start: serviceHandle, end: next &- 1, service: service))
        }
        FileHandle.standardError.write(Data(
            "[bluetooth] GATT database ready for \(session.peripheral.identifier): \(session.attributes.count) attributes\n".utf8,
        ))
    }

    private func processATT(_ request: Data, session: VPhoneBluetoothGATTSession) {
        guard let opcode = request.first else { return }
        switch opcode {
        case 0x02:
            guard request.count == 3 else { return sendError(request: opcode, handle: 0, code: 0x04, session: session) }
            let requested = VPhoneBluetoothATTTransport.load16(request, 1)
            guard requested >= 23 else {
                return sendError(request: opcode, handle: 0, code: 0x04, session: session)
            }
            let maximum = VPhoneBluetoothATTTransport.maximumMTU(
                writeWithoutResponseLength: session.peripheral.maximumWriteValueLength(for: .withoutResponse)
            )
            session.mtu = min(Int(requested), maximum)
            var response = Data([0x03])
            VPhoneBluetoothATTTransport.append16(UInt16(maximum), to: &response)
            sendATT(response, session: session)
        case 0x04:
            findInformation(request, session: session)
        case 0x06:
            findByTypeValue(request, session: session)
        case 0x08:
            readByType(request, session: session)
        case 0x0A, 0x0C:
            read(request, session: session)
        case 0x10:
            readByGroupType(request, session: session)
        case 0x12, 0x52:
            write(request, session: session)
        case 0x1E:
            guard request.count == 1, session.indicationPending else { return }
            session.indicationPending = false
            if !session.indications.isEmpty {
                session.indicationPending = true
                sendATT(session.indications.removeFirst(), session: session)
            }
        default:
            sendError(request: opcode, handle: 0, code: 0x06, session: session)
        }
    }

    private func readByGroupType(_ request: Data, session: VPhoneBluetoothGATTSession) {
        guard request.count == 7 else { return sendError(request: 0x10, handle: 0, code: 0x04, session: session) }
        let start = VPhoneBluetoothATTTransport.load16(request, 1), end = VPhoneBluetoothATTTransport.load16(request, 3)
        guard request[5] == 0x00, request[6] == 0x28 else {
            return sendError(request: 0x10, handle: start, code: 0x10, session: session)
        }
        let matches = session.services.filter { $0.start >= start && $0.start <= end }
        guard !matches.isEmpty else {
            return sendError(request: 0x10, handle: start, code: 0x0A, session: session)
        }
        let rows = matches.map { item -> Data in
            var row = Data()
            VPhoneBluetoothATTTransport.append16(item.start, to: &row)
            VPhoneBluetoothATTTransport.append16(item.end, to: &row)
            row.append(Self.attUUID(item.service.uuid))
            return row
        }
        if let response = VPhoneBluetoothATTTransport.discoveryResponse(opcode: 0x11, rows: rows, mtu: session.mtu) {
            sendATT(response, session: session)
        }
    }

    private func readByType(_ request: Data, session: VPhoneBluetoothGATTSession) {
        guard request.count == 7 || request.count == 21 else {
            return sendError(request: 0x08, handle: 0, code: 0x04, session: session)
        }
        let start = VPhoneBluetoothATTTransport.load16(request, 1), end = VPhoneBluetoothATTTransport.load16(request, 3)
        let uuid = request.subdata(in: 5 ..< request.count)
        if uuid != Data([0x03, 0x28]) {
            guard let match = session.characteristics.first(where: {
                $0.value >= start && $0.value <= end
                    && Self.attUUID($0.characteristic.uuid) == uuid
                    && $0.characteristic.properties.contains(.read)
            }) else {
                return sendError(request: 0x08, handle: start, code: 0x0A, session: session)
            }
            guard !match.characteristic.isNotifying else {
                return sendError(request: 0x08, handle: match.value, code: 0x06, session: session)
            }
            session.pendingRead = .init(handle: match.value, response: .readByType)
            session.pendingReadObject = ObjectIdentifier(match.characteristic)
            session.peripheral.readValue(for: match.characteristic)
            return
        }
        let matches = session.characteristics.filter { $0.declaration >= start && $0.declaration <= end }
        guard !matches.isEmpty else {
            return sendError(request: 0x08, handle: start, code: 0x0A, session: session)
        }
        let rows = matches.map { item -> Data in
            var row = Data()
            VPhoneBluetoothATTTransport.append16(item.declaration, to: &row)
            row.append(UInt8(truncatingIfNeeded: item.characteristic.properties.rawValue))
            VPhoneBluetoothATTTransport.append16(item.value, to: &row)
            row.append(Self.attUUID(item.characteristic.uuid))
            return row
        }
        if let response = VPhoneBluetoothATTTransport.discoveryResponse(opcode: 0x09, rows: rows, mtu: session.mtu) {
            sendATT(response, session: session)
        }
    }

    private func findInformation(_ request: Data, session: VPhoneBluetoothGATTSession) {
        guard request.count == 5 else { return sendError(request: 0x04, handle: 0, code: 0x04, session: session) }
        let start = VPhoneBluetoothATTTransport.load16(request, 1), end = VPhoneBluetoothATTTransport.load16(request, 3)
        let matches = session.attributeUUIDs.keys.sorted().filter { $0 >= start && $0 <= end }
        guard let first = matches.first, let firstUUID = session.attributeUUIDs[first] else {
            return sendError(request: 0x04, handle: start, code: 0x0A, session: session)
        }
        let width = Self.attUUID(firstUUID).count
        var response = Data([0x05, width == 2 ? 0x01 : 0x02])
        for handle in matches {
            guard let uuid = session.attributeUUIDs[handle], Self.attUUID(uuid).count == width else { break }
            if response.count + 2 + width > session.mtu { break }
            VPhoneBluetoothATTTransport.append16(handle, to: &response)
            response.append(Self.attUUID(uuid))
        }
        sendATT(response, session: session)
    }

    private func findByTypeValue(_ request: Data, session: VPhoneBluetoothGATTSession) {
        guard request.count >= 9 else { return sendError(request: 0x06, handle: 0, code: 0x04, session: session) }
        let start = VPhoneBluetoothATTTransport.load16(request, 1), end = VPhoneBluetoothATTTransport.load16(request, 3)
        guard VPhoneBluetoothATTTransport.load16(request, 5) == 0x2800 else {
            return sendError(request: 0x06, handle: start, code: 0x0A, session: session)
        }
        let value = request.subdata(in: 7 ..< request.count)
        let matches = session.services.filter {
            $0.start >= start && $0.start <= end && Self.attUUID($0.service.uuid) == value
        }
        guard !matches.isEmpty else {
            return sendError(request: 0x06, handle: start, code: 0x0A, session: session)
        }
        var response = Data([0x07])
        for item in matches {
            if response.count + 4 > session.mtu { break }
            VPhoneBluetoothATTTransport.append16(item.start, to: &response)
            VPhoneBluetoothATTTransport.append16(item.end, to: &response)
        }
        sendATT(response, session: session)
    }

    private func read(_ request: Data, session: VPhoneBluetoothGATTSession) {
        let isBlob = request.first == 0x0C
        guard request.count == (isBlob ? 5 : 3) else {
            return sendError(request: request.first ?? 0, handle: 0, code: 0x04, session: session)
        }
        let handle = VPhoneBluetoothATTTransport.load16(request, 1)
        let offset = isBlob ? Int(VPhoneBluetoothATTTransport.load16(request, 3)) : 0
        guard let attribute = session.attributes[handle] else {
            return sendError(request: request[0], handle: handle, code: 0x01, session: session)
        }
        switch attribute {
        case let .service(service):
            sendReadValue(Self.attUUID(service.uuid), handle: handle, offset: offset, blob: isBlob, session: session)
        case let .characteristicDeclaration(characteristic):
            guard let row = session.characteristics.first(where: { $0.characteristic === characteristic }) else { return }
            var value = Data([UInt8(truncatingIfNeeded: characteristic.properties.rawValue)])
            VPhoneBluetoothATTTransport.append16(row.value, to: &value)
            value.append(Self.attUUID(characteristic.uuid))
            sendReadValue(value, handle: handle, offset: offset, blob: isBlob, session: session)
        case let .characteristicValue(characteristic):
            guard !characteristic.isNotifying else {
                return sendError(request: request[0], handle: handle, code: 0x06, session: session)
            }
            session.pendingRead = .init(
                handle: handle,
                response: .read(requestOpcode: request[0], offset: offset)
            )
            session.pendingReadObject = ObjectIdentifier(characteristic)
            session.peripheral.readValue(for: characteristic)
        case let .descriptor(descriptor):
            if descriptor.uuid == CBUUID(string: "2902"), let characteristic = descriptor.characteristic {
                var value = Data()
                VPhoneBluetoothATTTransport.append16(
                    session.subscriptions[ObjectIdentifier(characteristic), default: 0], to: &value
                )
                sendReadValue(value, handle: handle, offset: offset, blob: isBlob, session: session)
                return
            }
            session.pendingRead = .init(
                handle: handle,
                response: .read(requestOpcode: request[0], offset: offset)
            )
            session.pendingReadObject = ObjectIdentifier(descriptor)
            session.peripheral.readValue(for: descriptor)
        }
    }

    private func sendReadValue(
        _ value: Data, handle: UInt16, offset: Int, blob: Bool,
        session: VPhoneBluetoothGATTSession
    ) {
        guard offset <= value.count else {
            return sendError(request: blob ? 0x0C : 0x0A, handle: handle, code: 0x07, session: session)
        }
        var response = Data([blob ? 0x0D : 0x0B])
        response.append(value.dropFirst(offset).prefix(max(0, session.mtu - 1)))
        sendATT(response, session: session)
    }

    private func write(_ request: Data, session: VPhoneBluetoothGATTSession) {
        guard request.count >= 3 else { return sendError(request: request.first ?? 0, handle: 0, code: 0x04, session: session) }
        let opcode = request[0], handle = VPhoneBluetoothATTTransport.load16(request, 1)
        let value = request.subdata(in: 3 ..< request.count)
        guard let attribute = session.attributes[handle] else {
            return sendError(request: opcode, handle: handle, code: 0x01, session: session)
        }
        let wantsResponse = opcode == 0x12
        switch attribute {
        case let .characteristicValue(characteristic):
            if wantsResponse {
                guard characteristic.properties.contains(.write) else {
                    return sendError(request: opcode, handle: handle, code: 0x03, session: session)
                }
                guard value.count <= session.peripheral.maximumWriteValueLength(for: .withResponse) else {
                    return sendError(request: opcode, handle: handle, code: 0x0D, session: session)
                }
                session.pendingWriteHandle = handle
                session.pendingWriteObject = ObjectIdentifier(characteristic)
                session.peripheral.writeValue(value, for: characteristic, type: .withResponse)
            } else if characteristic.properties.contains(.writeWithoutResponse),
                      value.count <= session.peripheral.maximumWriteValueLength(for: .withoutResponse) {
                guard session.writesWithoutResponse.count < 256 else {
                    closeSessions(for: session.peripheral, message: "write backpressure limit exceeded")
                    central?.cancelPeripheralConnection(session.peripheral)
                    return
                }
                session.writesWithoutResponse.append((characteristic, value))
                drainWrites(session)
            }
        case let .descriptor(descriptor):
            if descriptor.uuid == CBUUID(string: "2902"), let characteristic = descriptor.characteristic {
                guard value.count == 2 else {
                    if wantsResponse { sendError(request: opcode, handle: handle, code: 0x0D, session: session) }
                    return
                }
                let configuration = VPhoneBluetoothATTTransport.load16(value, 0)
                var allowed: UInt16 = 0
                if characteristic.properties.contains(.notify) { allowed |= 0x0001 }
                if characteristic.properties.contains(.indicate) { allowed |= 0x0002 }
                guard configuration & ~allowed == 0 else {
                    if wantsResponse { sendError(request: opcode, handle: handle, code: 0x13, session: session) }
                    return
                }
                session.pendingSubscriptions[ObjectIdentifier(characteristic)] = configuration
                let enabled = configuration != 0
                if wantsResponse {
                    session.pendingWriteHandle = handle
                    session.pendingWriteObject = ObjectIdentifier(characteristic)
                }
                session.peripheral.setNotifyValue(enabled, for: characteristic)
            } else if wantsResponse {
                session.pendingWriteHandle = handle
                session.pendingWriteObject = ObjectIdentifier(descriptor)
                session.peripheral.writeValue(value, for: descriptor)
            }
        default:
            if wantsResponse { sendError(request: opcode, handle: handle, code: 0x03, session: session) }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        for session in sessions(for: peripheral) where session.databaseReady && !session.connectWhenDisconnected {
            let object = ObjectIdentifier(characteristic)
            if session.pendingReadObject == object, let pending = session.pendingRead {
                session.pendingRead = nil
                session.pendingReadObject = nil
                if error != nil {
                    let opcode: UInt8 = switch pending.response {
                    case let .read(requestOpcode, _): requestOpcode
                    case .readByType: 0x08
                    }
                    sendError(request: opcode, handle: pending.handle, code: 0x0E, session: session)
                } else {
                    switch pending.response {
                    case let .read(requestOpcode, offset):
                        sendReadValue(characteristic.value ?? Data(), handle: pending.handle,
                                      offset: offset, blob: requestOpcode == 0x0C, session: session)
                    case .readByType:
                        sendATT(VPhoneBluetoothATTTransport.readByTypeValueResponse(
                            handle: pending.handle, value: characteristic.value ?? Data(), mtu: session.mtu
                        ), session: session)
                    }
                }
            } else if error == nil, characteristic.isNotifying,
                      let handle = session.characteristicValueHandles[object], let value = characteristic.value {
                let configuration = session.subscriptions[object, default: 0]
                guard configuration != 0 else { continue }
                let indication = configuration & 1 == 0
                var notification = Data([indication ? 0x1D : 0x1B])
                VPhoneBluetoothATTTransport.append16(handle, to: &notification)
                notification.append(value.prefix(max(0, session.mtu - 3)))
                if indication && session.indicationPending {
                    guard session.indications.count < 128 else {
                        closeSessions(for: peripheral, message: "indication backpressure limit exceeded")
                        central?.cancelPeripheralConnection(peripheral)
                        return
                    }
                    session.indications.append(notification)
                } else {
                    if indication { session.indicationPending = true }
                    sendATT(notification, session: session)
                }
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor descriptor: CBDescriptor, error: (any Error)?) {
        for session in sessions(for: peripheral) where session.pendingReadObject == ObjectIdentifier(descriptor) {
            guard let pending = session.pendingRead else { continue }
            session.pendingRead = nil
            session.pendingReadObject = nil
            guard case let .read(requestOpcode, offset) = pending.response else { continue }
            if error != nil {
                sendError(request: requestOpcode, handle: pending.handle, code: 0x0E, session: session)
            } else {
                sendReadValue(Self.descriptorData(descriptor.value), handle: pending.handle,
                              offset: offset, blob: requestOpcode == 0x0C, session: session)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        finishWrite(object: ObjectIdentifier(characteristic), peripheral: peripheral, error: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor descriptor: CBDescriptor, error: (any Error)?) {
        finishWrite(object: ObjectIdentifier(descriptor), peripheral: peripheral, error: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: (any Error)?) {
        let object = ObjectIdentifier(characteristic)
        for session in sessions(for: peripheral) {
            if let configuration = session.pendingSubscriptions.removeValue(forKey: object), error == nil {
                session.subscriptions[object] = configuration
            }
        }
        finishWrite(object: ObjectIdentifier(characteristic), peripheral: peripheral, error: error)
    }

    private func finishWrite(object: ObjectIdentifier, peripheral: CBPeripheral, error: (any Error)?) {
        for session in sessions(for: peripheral) where session.pendingWriteObject == object {
            let handle = session.pendingWriteHandle ?? 0
            session.pendingWriteHandle = nil
            session.pendingWriteObject = nil
            if error != nil {
                sendError(request: 0x12, handle: handle, code: 0x0E, session: session)
            } else {
                sendATT(Data([0x13]), session: session)
            }
        }
    }

    private func sendError(request: UInt8, handle: UInt16, code: UInt8, session: VPhoneBluetoothGATTSession) {
        // ATT commands (including Write Without Response) never receive errors.
        guard request & 0x40 == 0 else { return }
        var response = Data([0x01, request])
        VPhoneBluetoothATTTransport.append16(handle, to: &response)
        response.append(code)
        sendATT(response, session: session)
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        for session in sessions(for: peripheral) { drainWrites(session) }
    }

    private func drainWrites(_ session: VPhoneBluetoothGATTSession) {
        while session.peripheral.canSendWriteWithoutResponse, !session.writesWithoutResponse.isEmpty {
            let (characteristic, value) = session.writesWithoutResponse.removeFirst()
            session.peripheral.writeValue(value, for: characteristic, type: .withoutResponse)
        }
    }

    private func sendATT(_ payload: Data, session: VPhoneBluetoothGATTSession) {
        let packet = VPhoneBluetoothATTTransport.makeACL(
            handle: session.transportHandle ?? session.handle, cid: 0x0004, payload: payload
        )
        VPhoneBluetoothPacketCapture.shared.recordACL(packet, received: true)
        let message: [String: Any] = [
            "type": "hci_response",
            "connection": session.identifier,
            "data": packet.base64EncodedString(),
        ]
        emitControllerMessage(message)
    }

    private func emitControllerMessage(_ message: [String: Any]) {
        guard var line = try? JSONSerialization.data(withJSONObject: message) else { return }
        line.append(0x0A)
        FileHandle.standardOutput.write(line)
    }

    static func attUUID(_ uuid: CBUUID) -> Data {
        VPhoneBluetoothATTTransport.attUUID(uuid.data)
    }

    static func descriptorData(_ value: Any?) -> Data {
        if let data = value as? Data { return data }
        if let number = value as? NSNumber {
            var data = Data()
            VPhoneBluetoothATTTransport.append16(number.uint16Value, to: &data)
            return data
        }
        if let string = value as? String { return Data(string.utf8) }
        return Data()
    }
}
