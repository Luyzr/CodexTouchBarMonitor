import Foundation
import MonitorCore
@MainActor final class QuotaMonitor {
    var onUpdate: ((QuotaStatus) -> Void)?
    var onConnection: ((String) -> Void)?
    private let client = CodexAppServerClient()
    private var task: Task<Void, Never>?
    private var value = QuotaStatus()
    private var connected = false
    private var ephemeral = false
    private var generation = UUID()
    private let defaults = UserDefaults.standard
    func restart() { stop(); start() }
    func start() {
        guard task == nil else { return }
        if let data = defaults.data(forKey: "weeklyQuota"), let cached = try? JSONDecoder().decode(QuotaStatus.self, from: data) {
            value = cached; value.stale = true; onUpdate?(value)
        }
        client.onNotification = { [weak self] method, params in
            if method == "account/rateLimits/updated" { self?.apply(params) }
        }
        client.onDisconnect = { [weak self] in self?.connected = false; self?.markStale() }
        let session = generation
        task = Task {
            while !Task.isCancelled {
                do {
                    if !connected {
                        let socket = defaults.string(forKey: "CodexDaemonSocket") ?? NSHomeDirectory() + "/.codex/app-server-control/app-server-control.sock"
                        do { try await client.connect(mode: .daemon(socket)); ephemeral = false }
                        catch {
                            guard session == generation && !Task.isCancelled else { return }
                            try await client.connect(); ephemeral = true
                        }
                        guard session == generation && !Task.isCancelled else { return }
                        connected = true
                        onConnection?(ephemeral ? "Quota connected (independent fallback)" : "Quota connected (daemon)")
                    }
                    let payload = try await client.request("account/rateLimits/read")
                    guard session == generation && !Task.isCancelled else { return }
                    apply(payload)
                    // An absent Desktop daemon must not require a permanent extra Codex process.
                    if ephemeral { client.disconnect(); connected = false }
                } catch {
                    guard session == generation && !Task.isCancelled else { return }
                    connected = false; client.disconnect(); markStale()
                    onConnection?("App Server unavailable; cached quota retained")
                }
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
    }
    private func apply(_ payload: [String: Any]) {
        guard let status = QuotaStatus.parse(payload) else { markStale(); return }
        value = status; onUpdate?(value)
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: "weeklyQuota") }
    }
    private func markStale() { value.stale = true; onUpdate?(value) }
    func stop() { generation = UUID(); task?.cancel(); task = nil; connected = false; client.disconnect() }
}
