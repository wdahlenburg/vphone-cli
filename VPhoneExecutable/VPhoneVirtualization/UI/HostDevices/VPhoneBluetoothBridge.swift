import Foundation
import Virtualization

/// Relays BLE advertisements from the privacy-attributed host helper to the
/// guest bridge. CoreBluetooth must run from an application bundle on macOS;
/// the helper is VPhoneLocation.app in its `--bluetooth` mode.
@MainActor
final class VPhoneBluetoothBridge {
    nonisolated static let vsockPort: UInt32 = 1340

    private var device: VZVirtioSocketDevice?
    private var connection: VZVirtioSocketConnection?
    private var connectionFD: Int32 = -1
    private var connectionToken: UInt64 = 0
    private var helper: Process?
    private var helperInput: Pipe?
    private var helperOutput: FileHandle?
    private var helperOutputBuffer = Data()
    private var guestReader: Task<Void, Never>?
    private var guestInput: FileHandle?

    func connect(device: VZVirtioSocketDevice) {
        disconnect()
        self.device = device
        startHelper()
        attemptConnect()
    }

    func disconnect() {
        connectionToken &+= 1
        stopHelperOutput()
        guestReader?.cancel()
        guestReader = nil
        try? guestInput?.close()
        guestInput = nil
        try? helperInput?.fileHandleForWriting.close()
        helperInput = nil
        helper?.terminate()
        helper = nil
        connectionFD = -1
        connection = nil
        device = nil
    }

    private static var helperURL: URL {
        let executable = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
            .resolvingSymlinksInPath()
        return executable.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Helpers/VPhoneLocation.app/Contents/MacOS/vphone-location")
    }

    private func startHelper() {
        guard device != nil, helper == nil else { return }
        let process = Process()
        process.executableURL = Self.helperURL
        process.arguments = ["--bluetooth"]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        process.terminationHandler = { [weak self] process in
            Task { @MainActor in
                guard let self, self.helper === process else { return }
                print("[bluetooth] host helper exited with status \(process.terminationStatus)")
                self.stopHelperOutput()
                self.helper = nil
                self.helperInput = nil
                if self.device != nil {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.startHelper() }
                }
            }
        }
        do {
            try process.run()
            helper = process
            helperInput = input
            let reader = output.fileHandleForReading
            helperOutput = reader
            reader.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                Task { @MainActor [weak self] in
                    self?.receiveHelperOutput(data, from: handle)
                }
            }
        } catch {
            print("[bluetooth] cannot start host helper: \(error.localizedDescription)")
        }
    }

    private func receiveHelperOutput(_ data: Data, from handle: FileHandle) {
        guard helperOutput === handle else { return }
        guard !data.isEmpty else {
            stopHelperOutput()
            return
        }
        helperOutputBuffer.append(data)
        while let newline = helperOutputBuffer.firstIndex(of: 0x0A) {
            let line = helperOutputBuffer[..<newline]
            helperOutputBuffer.removeSubrange(helperOutputBuffer.startIndex ... newline)
            if let string = String(data: line, encoding: .utf8) {
                send(line: string)
            }
        }
    }

    private func stopHelperOutput() {
        helperOutput?.readabilityHandler = nil
        helperOutput = nil
        helperOutputBuffer.removeAll(keepingCapacity: false)
    }

    private func send(line: String) {
        guard connectionFD >= 0 else { return }
        var data = Data(line.utf8)
        data.append(0x0A)
        if !Self.send(fd: connectionFD, data: data) { handleDisconnect() }
    }

    private func attemptConnect() {
        guard let device else { return }
        connectionToken &+= 1
        let token = connectionToken
        device.connect(toPort: Self.vsockPort) { [weak self] result in
            Task { @MainActor in
                guard let self, self.connectionToken == token else { return }
                switch result {
                case let .success(connection):
                    self.connection = connection
                    self.connectionFD = connection.fileDescriptor
                    self.startGuestReader(fd: connection.fileDescriptor, token: token)
                    print("[bluetooth] guest bridge connected on vsock port \(Self.vsockPort)")
                case let .failure(error):
                    print("[bluetooth] guest bridge unavailable: \(error.localizedDescription). Retrying in 3s.")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                        guard let self, self.connectionToken == token else { return }
                        self.attemptConnect()
                    }
                }
            }
        }
    }

    private func handleDisconnect() {
        guestReader?.cancel()
        guestReader = nil
        try? guestInput?.close()
        guestInput = nil
        sendToHelper(line: "{\"type\":\"reset\"}")
        connectionFD = -1
        connection = nil
        attemptConnect()
    }

    private func startGuestReader(fd: Int32, token: UInt64) {
        guestReader?.cancel()
        let readerFD = Darwin.dup(fd)
        guard readerFD >= 0 else {
            print("[bluetooth] cannot duplicate guest bridge socket: \(String(cString: strerror(errno)))")
            return
        }
        let input = FileHandle(fileDescriptor: readerFD, closeOnDealloc: true)
        guestInput = input
        guestReader = Task { @MainActor [weak self] in
            do {
                for try await line in input.bytes.lines {
                    guard let self, self.connectionToken == token else { break }
                    self.sendToHelper(line: line)
                }
            } catch {
                if !Task.isCancelled {
                    print("[bluetooth] guest bridge input failed: \(error.localizedDescription)")
                }
            }
            try? input.close()
            guard let self, !Task.isCancelled, self.connectionToken == token else { return }
            self.handleDisconnect()
        }
    }

    private func sendToHelper(line: String) {
        guard let handle = helperInput?.fileHandleForWriting else { return }
        var data = Data(line.utf8)
        data.append(0x0A)
        do {
            try handle.write(contentsOf: data)
        } catch {
            print("[bluetooth] cannot forward guest controller data to host helper: \(error.localizedDescription)")
        }
    }

    private nonisolated static func send(fd: Int32, data: Data) -> Bool {
        data.withUnsafeBytes { bytes in
            guard var cursor = bytes.baseAddress else { return false }
            var remaining = bytes.count
            while remaining > 0 {
                let count = Darwin.send(fd, cursor, remaining, MSG_NOSIGNAL)
                if count < 0 && errno == EINTR { continue }
                if count <= 0 { return false }
                remaining -= count
                cursor = cursor.advanced(by: count)
            }
            return true
        }
    }
}
