import Foundation
import Darwin

final class VPhoneBluetoothPacketCapture: @unchecked Sendable {
    static let shared = VPhoneBluetoothPacketCapture()

    private let handle: FileHandle?
    private let lock = NSLock()

    init(path: String? = ProcessInfo.processInfo.environment["VPHONE_BLUETOOTH_PCAP"]) {
        guard let path, !path.isEmpty else {
            handle = nil
            return
        }
        let fd = Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            handle = nil
            FileHandle.standardError.write(Data("[bluetooth] cannot create capture at \(path): \(String(cString: strerror(errno)))\n".utf8))
            return
        }
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var header = Data()
        append32(0xA1B2C3D4, to: &header)
        append16(2, to: &header)
        append16(4, to: &header)
        append32(0, to: &header)
        append32(0, to: &header)
        append32(65_535, to: &header)
        append32(201, to: &header)
        try? handle?.write(contentsOf: header)
    }

    func recordACL(_ packet: Data, received: Bool) {
        guard let handle else { return }
        let now = Date().timeIntervalSince1970
        let seconds = UInt32(now)
        let microseconds = UInt32((now - Double(seconds)) * 1_000_000)
        var payload = Data()
        var direction = (received ? UInt32(1) : UInt32(0)).bigEndian
        withUnsafeBytes(of: &direction) { payload.append(contentsOf: $0) }
        payload.append(0x02)
        payload.append(packet)
        var record = Data()
        append32(seconds, to: &record)
        append32(microseconds, to: &record)
        append32(UInt32(payload.count), to: &record)
        append32(UInt32(payload.count), to: &record)
        record.append(payload)
        lock.lock()
        defer { lock.unlock() }
        try? handle.write(contentsOf: record)
    }

    private func append16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    private func append32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 24))
    }
}

enum VPhoneBluetoothATTTransport {
    static func logicalConnectionHandle(_ transportHandle: UInt16) -> UInt16 {
        transportHandle & 0x03ff
    }

    static func parseACL(_ packet: Data) -> (handle: UInt16, cid: UInt16, payload: Data)? {
        guard packet.count >= 8 else { return nil }
        let header = load16(packet, 0)
        let length = Int(load16(packet, 2))
        let boundary = (header >> 12) & 3
        guard boundary == 0 || boundary == 2,
              packet.count == length + 4, length >= 4 else { return nil }
        let l2capLength = Int(load16(packet, 4))
        let cid = load16(packet, 6)
        guard l2capLength + 4 == length else { return nil }
        return (header & 0x0fff, cid, packet.subdata(in: 8 ..< 8 + l2capLength))
    }

    static func makeACL(handle: UInt16, cid: UInt16, payload: Data) -> Data {
        var packet = Data()
        append16((handle & 0x0fff) | 0x2000, to: &packet)
        append16(UInt16(payload.count + 4), to: &packet)
        append16(UInt16(payload.count), to: &packet)
        append16(cid, to: &packet)
        packet.append(payload)
        return packet
    }

    static func readByTypeValueResponse(handle: UInt16, value: Data, mtu: Int = 185) -> Data {
        let boundedValue = value.prefix(max(0, min(253, mtu - 4)))
        var response = Data([0x09, UInt8(2 + boundedValue.count)])
        append16(handle, to: &response)
        response.append(boundedValue)
        return response
    }

    /// ATT carries 16- or 128-bit UUIDs. CoreBluetooth can also return 32-bit
    /// UUIDs, which must be expanded using the Bluetooth base UUID.
    static func attUUID(_ bigEndian: Data) -> Data {
        if bigEndian.count == 4 {
            return Data((bigEndian + Data([
                0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0x80,
                0x5F, 0x9B, 0x34, 0xFB,
            ])).reversed())
        }
        return Data(bigEndian.reversed())
    }

    static func maximumMTU(writeWithoutResponseLength: Int) -> Int {
        min(517, max(23, writeWithoutResponseLength + 3))
    }

    /// A discovery response may contain only contiguous entries of one width.
    /// Skipping an intervening width makes the client advance past that entry.
    static func discoveryResponse(opcode: UInt8, rows: [Data], mtu: Int) -> Data? {
        guard let first = rows.first, first.count <= 255 else { return nil }
        var response = Data([opcode, UInt8(first.count)])
        for row in rows {
            guard row.count == first.count, response.count + row.count <= mtu else { break }
            response.append(row)
        }
        return response.count > 2 ? response : nil
    }

    static func load16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[data.startIndex + offset]) | UInt16(data[data.startIndex + offset + 1]) << 8
    }

    static func append16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
    }
}

/// One incomplete ATT PDU per native connection lifetime. Disconnecting drops
/// this value with the session, so continuations cannot cross handle reuse.
struct VPhoneBluetoothACLReassembler {
    private var pending = Data()
    private var handle: UInt16?
    private var expected = 0

    mutating func consume(_ packet: Data) -> (handle: UInt16, cid: UInt16, payload: Data)? {
        guard packet.count >= 4 else { reset(); return nil }
        let header = VPhoneBluetoothATTTransport.load16(packet, 0)
        let length = Int(VPhoneBluetoothATTTransport.load16(packet, 2))
        let boundary = (header >> 12) & 3
        let incomingHandle = header & 0x0fff
        guard length == packet.count - 4, length > 0 else { reset(); return nil }
        let fragment = packet.dropFirst(4)
        if boundary == 0 || boundary == 2 {
            reset()
            guard fragment.count >= 4 else { return nil }
            expected = Int(VPhoneBluetoothATTTransport.load16(Data(fragment), 0)) + 4
            guard expected <= 521, expected >= 5,
                  VPhoneBluetoothATTTransport.load16(Data(fragment), 2) == 4 else { reset(); return nil }
            handle = incomingHandle
        } else if boundary != 1 || handle != incomingHandle || pending.isEmpty {
            reset()
            return nil
        }
        guard pending.count + fragment.count <= expected else { reset(); return nil }
        pending.append(contentsOf: fragment)
        guard pending.count == expected else { return nil }
        let payload = Data(pending.dropFirst(4))
        reset()
        return (incomingHandle, 4, payload)
    }

    private mutating func reset() {
        pending.removeAll(keepingCapacity: false)
        handle = nil
        expected = 0
    }
}
