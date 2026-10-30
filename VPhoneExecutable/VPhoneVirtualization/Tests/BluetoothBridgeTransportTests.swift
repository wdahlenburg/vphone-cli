import Foundation
import Darwin

@main
struct BluetoothBridgeTransportTests {
    static func main() {
        var sockets: [Int32] = [-1, -1]
        precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0)
        defer { close(sockets[0]); close(sockets[1]) }
        let message = Data("{\"type\":\"reset\"}\n".utf8)
        precondition(VPhoneBluetoothBridge.send(fd: sockets[0], data: message))
        var received = [UInt8](repeating: 0, count: message.count)
        precondition(read(sockets[1], &received, received.count) == message.count)
        precondition(Data(received) == message)
        // No peer reads this payload. A blocking implementation hits the socket
        // timeout; the production writer must then fail without changing the
        // reader's file status flags.
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        precondition(setsockopt(sockets[0], SOL_SOCKET, SO_SNDTIMEO, &timeout,
                               socklen_t(MemoryLayout<timeval>.size)) == 0)
        let started = ContinuousClock.now
        precondition(!VPhoneBluetoothBridge.send(fd: sockets[0], data: Data(repeating: 0x41, count: 8 * 1024 * 1024)))
        precondition(started.duration(to: .now) < .seconds(3))
        precondition(fcntl(sockets[0], F_GETFL) & O_NONBLOCK == 0)
        print("Bluetooth bridge transport tests passed: delivery and stalled peer")
    }
}
