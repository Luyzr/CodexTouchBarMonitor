import Foundation
import MonitorCore
@MainActor final class NetworkMonitor {
    var onUpdate: ((NetworkStatus) -> Void)?
    private var task: Task<Void, Never>?
    func restart() { stop(); start() }
    func start() {
        guard task == nil else { return }
        task = Task {
            var schedule = RecoverySchedule()
            while !Task.isCancelled {
                let status = await Self.probe()
                guard !Task.isCancelled else { return }
                onUpdate?(status)
                try? await Task.sleep(nanoseconds: UInt64((schedule.interval(reachable: status.latency != nil) == 10 ? max(3, min(300, UserDefaults.standard.double(forKey: "LatencyRefreshInterval"))) : 3) * 1_000_000_000))
            }
        }
    }
    func stop() { task?.cancel(); task = nil }
    nonisolated static func probe() async -> NetworkStatus {
        let ping = await Task.detached(priority: .utility) { () -> Int? in
            let process = Process(); let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/sbin/ping")
            process.arguments = ["-n", "-c", "1", "-W", "1500", "-t", "2", "chatgpt.com"]
            process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8),
                  let range = text.range(of: #"time[=<]([0-9.]+) ms"#, options: .regularExpression) else { return nil }
            let number = text[range].dropFirst(5).dropLast(3)
            return Double(number).map { max(1, Int($0.rounded())) }
        }.value
        if let ping { return NetworkStatus(latency: ping, source: .icmp, checked: true) }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4; config.timeoutIntervalForResource = 5
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "https://chatgpt.com/")!)
        request.httpMethod = "HEAD"; request.cachePolicy = .reloadIgnoringLocalCacheData
        let start = ProcessInfo.processInfo.systemUptime
        do {
            let (_, response) = try await session.data(for: request)
            // HTTP denial still proves TLS/HTTP reachability, not account/API availability.
            if let http = response as? HTTPURLResponse, http.url?.host == "chatgpt.com" {
                return NetworkStatus(latency: max(1, Int((ProcessInfo.processInfo.systemUptime-start)*1000)), source: .https, checked: true)
            }
        } catch {}
        return NetworkStatus(checked: true)
    }
}
