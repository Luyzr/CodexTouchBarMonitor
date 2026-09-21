import Foundation
import CryptoKit
import Darwin
import MonitorCore

private final class ReadGate: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    private let descriptor: Int32
    init(_ descriptor: Int32) { self.descriptor = descriptor }
    func read() -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard active else { return Data() }
        var bytes = [UInt8](repeating: 0, count: 65536)
        let count = Darwin.read(descriptor, &bytes, bytes.count)
        if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { return nil }
        return count > 0 ? Data(bytes.prefix(count)) : Data()
    }
    func invalidate() { lock.lock(); active = false; lock.unlock() }
}
@MainActor final class CodexAppServerClient {
    enum Failure: Error { case unavailable, disconnected, timeout, rpc(Int), protocolError }
    enum Mode { case independent, daemon(String), desktop(String) }
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var readGate: ReadGate?
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var timeouts: [Int: Task<Void, Never>] = [:]
    private var buffer = Data()
    private var codec = WebSocketCodec()
    private var desktop = false
    private var desktopClientID = "initializing-client"
    private var websocket = false
    private var upgraded = false
    private var expectedAccept = ""
    private var handshake: CheckedContinuation<Void, Error>?
    private var handshakeTimeout: Task<Void, Never>?
    private(set) var generation = UUID()
    var onNotification: ((String, [String: Any]) -> Void)?
    var onRequest: ((RPCID, String, [String: Any]) -> Void)?
    var onDisconnect: (() -> Void)?
    var requestTimeoutNanoseconds: UInt64 = 15_000_000_000
    var executableOverride: String?
    static var executable: String? {
        let configured = UserDefaults.standard.string(forKey: "CodexExecutable")
        return ([configured].compactMap { $0 } + [
            "/Applications/Codex.app/Contents/Resources/codex", "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex"
        ]).first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    func connect(mode: Mode = .independent) async throws {
        disconnect()
        let connectingGeneration = generation
        desktop = false
        switch mode {
        case .desktop(let path):
            desktop = true; websocket = false; desktopClientID = "initializing-client"
            let descriptor = try await Task.detached(priority: .utility) { try Self.openSocket(path) }.value
            guard connectingGeneration == generation && !Task.isCancelled else { Darwin.close(descriptor); throw CancellationError() }
            let socket = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            input = socket; output = socket
        case .daemon(let path) where executableOverride == nil:
            websocket = true
            let descriptor = try await Task.detached(priority: .utility) { try Self.openSocket(path) }.value
            guard connectingGeneration == generation && !Task.isCancelled else { Darwin.close(descriptor); throw CancellationError() }
            let socket = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            input = socket; output = socket
        default:
            guard let executable = executableOverride ?? Self.executable else { throw Failure.unavailable }
            let child = Process(), stdinPipe = Pipe(), stdoutPipe = Pipe()
            child.executableURL = URL(fileURLWithPath: executable)
            switch mode {
            case .desktop: throw Failure.unavailable
            case .independent: websocket = false; child.arguments = ["app-server"]
            case .daemon(let path): websocket = true; child.arguments = ["app-server", "proxy", "--sock", path]
            }
            child.standardInput = stdinPipe; child.standardOutput = stdoutPipe; child.standardError = FileHandle.nullDevice
            try child.run()
            process = child; input = stdinPipe.fileHandleForWriting; output = stdoutPipe.fileHandleForReading
        }
        let session = generation
        _ = fcntl(output!.fileDescriptor, F_SETFL, fcntl(output!.fileDescriptor, F_GETFL) | O_NONBLOCK)
        let gate = ReadGate(output!.fileDescriptor); readGate = gate
        output?.readabilityHandler = { [weak self] _ in
            guard let data = gate.read() else { return }
            Task { @MainActor in
                guard let self, self.generation == session else { return }
                if data.isEmpty { self.failed(); return }
                do { try self.consume(data) } catch { self.failed() }
            }
        }
        do {
            if websocket {
                let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
                expectedAccept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    handshake = continuation
                    handshakeTimeout = Task { [weak self] in
                        try? await Task.sleep(nanoseconds: 10_000_000_000)
                        guard !Task.isCancelled, let self, self.generation == session else { return }
                        self.failed()
                    }
                    do { try input?.write(contentsOf: Data("GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n".utf8)) }
                    catch { failed() }
                }
            }
            if desktop {
                let result = try await request("initialize", ["clientType": "touchbar-monitor"])
                guard let id = result["clientId"] as? String else { throw Failure.protocolError }
                desktopClientID = id
                return
            }
            _ = try await request("initialize", ["clientInfo": ["name": "codex_touchbar_monitor", "version": "1.0.0"], "capabilities": ["experimentalApi": true]])
            try write(["method": "initialized", "params": [:]])
        } catch { disconnect(); throw error }
    }
    nonisolated private static func openSocket(_ path: String) throws -> Int32 {
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = path.utf8CString.map { UInt8(bitPattern: $0) }
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw Failure.unavailable }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Failure.unavailable }
        var noSignal: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if result != 0 {
            guard errno == EINPROGRESS else { Darwin.close(descriptor); throw Failure.unavailable }
            var wait = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
            guard poll(&wait, 1, 10000) > 0 else { Darwin.close(descriptor); throw Failure.timeout }
            var error: Int32 = 0; var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else { Darwin.close(descriptor); throw Failure.unavailable }
        }
        _ = fcntl(descriptor, F_SETFL, 0)
        return descriptor
    }
    func request(_ method: String, _ params: [String: Any] = [:], targetClientID: String? = nil, version: Int = 0) async throws -> [String: Any] {
        guard input != nil, process?.isRunning != false else { throw Failure.disconnected }
        nextID += 1; let id = nextID
        try Task.checkCancellation()
        return try await withTaskCancellationHandler(operation: {
        try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            timeouts[id] = Task { [weak self] in
                try? await Task.sleep(nanoseconds: self?.requestTimeoutNanoseconds ?? 15_000_000_000)
                guard !Task.isCancelled else { return }
                self?.pending.removeValue(forKey: id)?.resume(throwing: Failure.timeout)
                self?.timeouts.removeValue(forKey: id)
            }
            do {
                if desktop {
                    var object: [String: Any] = ["type": "request", "requestId": String(id), "method": method, "params": params, "sourceClientId": desktopClientID, "version": version]
                    if let targetClientID { object["targetClientId"] = targetClientID }
                    try write(object)
                } else { try write(["id": id, "method": method, "params": params]) }
            }
            catch { timeouts.removeValue(forKey: id)?.cancel(); pending.removeValue(forKey: id)?.resume(throwing: error) }
        }
        }, onCancel: { [weak self] in
            Task { @MainActor in self?.cancelRequest(id) }
        })
    }
    private func cancelRequest(_ id: Int) {
        timeouts.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
    func respond(_ id: RPCID, result: [String: Any], connection: UUID) throws {
        guard connection == generation else { throw Failure.disconnected }
        try write(["id": id.json, "result": result])
    }
    func desktopBroadcast(_ method: String, params: [String: Any], version: Int, targets: [String]? = nil) throws {
        guard desktop else { throw Failure.unavailable }
        var message: [String: Any] = ["type": "broadcast", "method": method, "params": params, "version": version, "sourceClientId": desktopClientID]
        if let targets { message["targetClientIds"] = targets }
        try write(message)
    }
    private func write(_ object: [String: Any]) throws {
        guard let input, process?.isRunning != false else { throw Failure.disconnected }
        var data = try JSONSerialization.data(withJSONObject: object)
        if desktop {
            var length = UInt32(data.count).littleEndian
            var framed = Data(bytes: &length, count: 4); framed.append(data); data = framed
        } else if websocket { guard upgraded else { throw Failure.protocolError }; data = WebSocketCodec.frame(data) }
        else { data.append(10) }
        try input.write(contentsOf: data)
    }
    private func consume(_ data: Data) throws {
        buffer.append(data)
        if desktop {
            while buffer.count >= 4 {
                var count = 0
                for (index, byte) in buffer.prefix(4).enumerated() { count |= Int(byte) << (8 * index) }
                guard count > 0 && count <= 64 * 1024 * 1024 else { throw Failure.protocolError }
                if buffer.count < count + 4 { break }
                let payload = Data(buffer.dropFirst(4).prefix(count)); buffer = Data(buffer.dropFirst(count + 4))
                receive(payload)
            }
            return
        }
        if websocket {
            if !upgraded {
                guard let range = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                    if buffer.count > 16384 { throw Failure.protocolError }; return
                }
                let header = String(decoding: buffer[..<range.lowerBound], as: UTF8.self)
                let lines = header.components(separatedBy: "\r\n")
                guard lines.first?.contains(" 101 ") == true,
                      lines.contains(where: { $0.lowercased().hasPrefix("sec-websocket-accept:") && $0.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) == expectedAccept }) else { throw Failure.protocolError }
                buffer = Data(buffer[range.upperBound...]); upgraded = true
                handshakeTimeout?.cancel(); handshakeTimeout = nil
                let waiter = handshake; handshake = nil; waiter?.resume()
            }
            let frames = try codec.append(buffer); buffer.removeAll(keepingCapacity: true)
            for (op, payload) in frames {
                if op == 9 { try input?.write(contentsOf: WebSocketCodec.frame(payload, opcode: 10)) }
                else if op == 1 { receive(payload) }
            }
        } else {
            guard buffer.count <= 8 * 1024 * 1024 else { throw Failure.protocolError }
            while let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<newline]); buffer = Data(buffer[buffer.index(after: newline)...]); receive(line)
            }
        }
    }
    private func receive(_ data: Data) {
        guard let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        if desktop, let type = value["type"] as? String {
            if type == "client-discovery-request", let id = value["requestId"] {
                try? write(["type": "client-discovery-response", "requestId": id, "response": ["canHandle": false]])
            } else if type == "broadcast" { onNotification?("desktop/message", value) }
            else if type == "response", let rawID = value["requestId"] as? String, let id = Int(rawID), let continuation = pending.removeValue(forKey: id) {
                timeouts.removeValue(forKey: id)?.cancel()
                if value["resultType"] as? String != "success" { continuation.resume(throwing: Failure.unavailable) }
                else {
                    var result = value["result"] as? [String: Any] ?? [:]
                    result["handledByClientId"] = value["handledByClientId"]
                    continuation.resume(returning: result)
                }
            }
            return
        }
        if let method = value["method"] as? String {
            let params = value["params"] as? [String: Any] ?? [:]
            if let raw = value["id"], let id = RPCID(raw) { onRequest?(id, method, params) }
            else { onNotification?(method, params) }
        } else if let id = value["id"] as? Int, let continuation = pending.removeValue(forKey: id) {
            timeouts.removeValue(forKey: id)?.cancel()
            if let error = value["error"] as? [String: Any] { continuation.resume(throwing: Failure.rpc(error["code"] as? Int ?? -1)) }
            else { continuation.resume(returning: value["result"] as? [String: Any] ?? [:]) }
        }
    }
    private func failed() { disconnect(); onDisconnect?() }
    func disconnect() {
        generation = UUID()
        output?.readabilityHandler = nil
        readGate?.invalidate(); readGate = nil
        if let output, output === input { Darwin.shutdown(output.fileDescriptor, SHUT_RDWR); input = nil }
        try? output?.close(); output = nil
        try? input?.close(); input = nil
        if process?.isRunning == true { process?.terminate() }; process = nil
        handshakeTimeout?.cancel(); handshakeTimeout = nil
        let waiter = handshake; handshake = nil; waiter?.resume(throwing: Failure.disconnected)
        for task in timeouts.values { task.cancel() }; timeouts.removeAll()
        let requests = pending; pending.removeAll()
        for continuation in requests.values { continuation.resume(throwing: Failure.disconnected) }
        buffer.removeAll(); codec = WebSocketCodec(); upgraded = false
    }
}
