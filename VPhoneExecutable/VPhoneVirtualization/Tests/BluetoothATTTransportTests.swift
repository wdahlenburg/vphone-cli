import Foundation

@main
struct BluetoothATTTransportTests {
    static func main() {
        let mtuRequest = Data([0x02, 0xB9, 0x00])
        let packet = VPhoneBluetoothATTTransport.makeACL(handle: 0x0042, cid: 0x0004, payload: mtuRequest)
        precondition(packet == Data([
            0x42, 0x20, 0x07, 0x00,
            0x03, 0x00, 0x04, 0x00,
            0x02, 0xB9, 0x00,
        ]))
        let decoded = VPhoneBluetoothATTTransport.parseACL(packet)
        precondition(decoded?.handle == 0x0042)
        precondition(decoded?.cid == 0x0004)
        precondition(decoded?.payload == mtuRequest)

        var malformedLength = packet
        malformedLength[2] = 0x08
        precondition(VPhoneBluetoothATTTransport.parseACL(malformedLength) == nil)

        var malformedL2CAP = packet
        malformedL2CAP[4] = 0x04
        precondition(VPhoneBluetoothATTTransport.parseACL(malformedL2CAP) == nil)
        precondition(VPhoneBluetoothATTTransport.parseACL(Data(repeating: 0, count: 7)) == nil)

        // A complete L2CAP PDU must consume the ACL payload; trailing bytes are
        // neither part of this request nor a second independently framed PDU.
        var trailing = packet + Data([0xFF])
        trailing[2] = 8
        precondition(VPhoneBluetoothATTTransport.parseACL(trailing) == nil)
        var continuation = packet
        continuation[1] = 0x10
        precondition(VPhoneBluetoothATTTransport.parseACL(continuation) == nil)

        var assembler = VPhoneBluetoothACLReassembler()
        // A real ATT write spanning two HCI packets. Only its first fragment
        // carries the L2CAP header; the response must contain the entire value.
        let first = Data([0x42, 0x20, 6, 0, 5, 0, 4, 0, 0x12, 1])
        let last = Data([0x42, 0x10, 3, 0, 0, 0xAA, 0xBB])
        precondition(assembler.consume(first) == nil)
        precondition(assembler.consume(last)?.payload == Data([0x12, 1, 0, 0xAA, 0xBB]))
        precondition(assembler.consume(last) == nil)
        precondition(assembler.consume(first) == nil)
        var otherHandle = last
        otherHandle[0] = 0x43
        precondition(assembler.consume(otherHandle) == nil)
        precondition(assembler.consume(last) == nil)
        precondition(assembler.consume(first) == nil)
        precondition(assembler.consume(packet)?.payload == mtuRequest)
        precondition(assembler.consume(last) == nil)
        var oversized = first
        oversized[4] = 0xFF; oversized[5] = 0xFF
        precondition(assembler.consume(oversized) == nil)
        precondition(assembler.consume(last) == nil)
        precondition(assembler.consume(first) == nil)
        var overrun = last + Data([0xCC])
        overrun[2] = 4
        precondition(assembler.consume(overrun) == nil)
        precondition(assembler.consume(last) == nil)

        let largeWrite = Data([0x12, 1, 0]) + Data(repeating: 0xA5, count: 514)
        let largePacket = VPhoneBluetoothATTTransport.makeACL(handle: 0x42, cid: 4, payload: largeWrite)
        var startFragment = Data([0x42, 0x20, 27, 0])
        startFragment.append(largePacket[4..<31])
        let tail = Data(largePacket.dropFirst(31))
        var tailFragment = Data([0x42, 0x10])
        VPhoneBluetoothATTTransport.append16(UInt16(tail.count), to: &tailFragment)
        tailFragment.append(tail)
        precondition(assembler.consume(startFragment) == nil)
        precondition(assembler.consume(tailFragment)?.payload == largeWrite)
        // Replacing the connection drops its pending fragment state.
        precondition(assembler.consume(startFragment) == nil)
        assembler = VPhoneBluetoothACLReassembler()
        precondition(assembler.consume(tailFragment) == nil)

        let maximumPayload = Data(repeating: 0xAB, count: 185)
        let maximumPacket = VPhoneBluetoothATTTransport.makeACL(
            handle: 0x0FFF, cid: 0x0004, payload: maximumPayload,
        )
        let maximumDecoded = VPhoneBluetoothATTTransport.parseACL(maximumPacket)
        precondition(maximumDecoded?.handle == 0x0FFF)
        precondition(maximumDecoded?.payload == maximumPayload)

        precondition(VPhoneBluetoothATTTransport.logicalConnectionHandle(0x0401) == 0x0001)
        precondition(VPhoneBluetoothATTTransport.logicalConnectionHandle(0x03FF) == 0x03FF)

        let readByType = VPhoneBluetoothATTTransport.readByTypeValueResponse(
            handle: 0x0012, value: Data("BLETest".utf8)
        )
        precondition(readByType == Data([0x09, 0x09, 0x12, 0x00]) + Data("BLETest".utf8))
        let boundedReadByType = VPhoneBluetoothATTTransport.readByTypeValueResponse(
            handle: 1, value: Data(repeating: 0xCC, count: 100), mtu: 23
        )
        precondition(boundedReadByType.count == 23)
        precondition(boundedReadByType[1] == 21)

        precondition(VPhoneBluetoothATTTransport.attUUID(Data([0x18, 0x0F])) == Data([0x0F, 0x18]))
        precondition(VPhoneBluetoothATTTransport.attUUID(Data([0x12, 0x34, 0x56, 0x78])) == Data([
            0xFB, 0x34, 0x9B, 0x5F, 0x80, 0x00, 0x00, 0x80,
            0x00, 0x10, 0x00, 0x00, 0x78, 0x56, 0x34, 0x12,
        ]))
        precondition(VPhoneBluetoothATTTransport.maximumMTU(writeWithoutResponseLength: 20) == 23)
        precondition(VPhoneBluetoothATTTransport.maximumMTU(writeWithoutResponseLength: 182) == 185)
        precondition(VPhoneBluetoothATTTransport.maximumMTU(writeWithoutResponseLength: 512) == 515)
        precondition(VPhoneBluetoothATTTransport.maximumMTU(writeWithoutResponseLength: 1000) == 517)
        let short = Data([1, 0, 2, 0, 0x0F, 0x18])
        let long = Data(repeating: 0xCC, count: 20)
        precondition(VPhoneBluetoothATTTransport.discoveryResponse(
            opcode: 0x11, rows: [short, long, short], mtu: 185
        ) == Data([0x11, 6]) + short)
        precondition(VPhoneBluetoothATTTransport.discoveryResponse(
            opcode: 0x11, rows: [short, short], mtu: 8
        ) == Data([0x11, 6]) + short)
        precondition(VPhoneBluetoothATTTransport.discoveryResponse(
            opcode: 0x11, rows: [], mtu: 23
        ) == nil)

        let captureURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: captureURL) }
        let capture = VPhoneBluetoothPacketCapture(path: captureURL.path)
        capture.recordACL(packet, received: false)
        let captureData = try! Data(contentsOf: captureURL)
        precondition(captureData.prefix(4) == Data([0xD4, 0xC3, 0xB2, 0xA1]))
        precondition(captureData.subdata(in: 20..<24) == Data([201, 0, 0, 0]))
        precondition(captureData.subdata(in: 40..<45) == Data([0, 0, 0, 0, 2]))
        precondition(captureData.suffix(packet.count) == packet)
        // A second capture must preserve the existing evidence.
        let collision = VPhoneBluetoothPacketCapture(path: captureURL.path)
        collision.recordACL(packet, received: true)
        precondition(try! Data(contentsOf: captureURL) == captureData)

        print("Bluetooth ATT tests passed: framing, UUID widths, discovery ordering, MTU and PCAP")
    }
}
