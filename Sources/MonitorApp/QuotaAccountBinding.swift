import Foundation
import MonitorCore

@MainActor final class QuotaAccountBinding {
    enum State: Equatable { case ready, starting, waiting, verifying, success, cancelled, failed }
    private(set) var state = State.ready
    private(set) var accountLabel: String?
    private(set) var loginURL: URL?
    var onChange: (() -> Void)?
    var onCommitted: (() -> Void)?
    var openBrowser: ((URL) -> Bool)?
    let store: QuotaAccountStore
    private let makeClient: @MainActor () -> CodexAppServerClient
    private var client: CodexAppServerClient?
    private var candidate: URL?
    private var attempt = UUID()
    private var loginID: String?
    private var earlyCompletion: [String: Any]?
    private var worker: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    init(store: QuotaAccountStore? = nil, makeClient: (@MainActor () -> CodexAppServerClient)? = nil) {
        self.store = store ?? .shared; self.makeClient = makeClient ?? { CodexAppServerClient() }
    }
    var busy: Bool { [.starting, .waiting, .verifying].contains(state) }
    static func safeLoginURL(_ value: String) -> URL? {
        guard let url = URL(string: value), url.scheme == "https", url.user == nil, url.password == nil,
              ["auth.openai.com", "chatgpt.com"].contains(url.host?.lowercased() ?? ""), url.port == nil || url.port == 443 else { return nil }
        return url
    }
    func begin() {
        guard !busy else { return }
        cleanup()
        attempt = UUID(); let token = attempt
        state = .starting; onChange?()
        worker = Task { [weak self] in
            guard let self else { return }
            do {
                let home = try store.createCandidate(); candidate = home
                let connection = makeClient(); client = connection; connection.isolatedHome = home
                connection.onNotification = { [weak self] method, params in
                    guard let self, self.attempt == token, method == "account/login/completed" else { return }
                    if self.loginID == nil { self.earlyCompletion = params }
                    else { self.completed(params, token: token) }
                }
                connection.onDisconnect = { [weak self] in
                    guard let self, self.attempt == token, self.busy else { return }
                    self.fail()
                }
                try await connection.connect()
                let result = try await connection.request("account/login/start", ["type": "chatgpt"])
                guard token == attempt, !Task.isCancelled,
                      let id = result["loginId"] as? String, let raw = result["authUrl"] as? String,
                      let url = Self.safeLoginURL(raw) else { throw CodexAppServerClient.Failure.protocolError }
                loginID = id; loginURL = url; state = .waiting; onChange?()
                guard openBrowser?(url) != false else { throw CodexAppServerClient.Failure.unavailable }
                timeout = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 600_000_000_000)
                    guard !Task.isCancelled, let self, self.attempt == token, self.busy else { return }
                    self.fail()
                }
                if let earlyCompletion { self.earlyCompletion = nil; completed(earlyCompletion, token: token) }
            } catch {
                guard token == attempt, !Task.isCancelled else { return }
                fail()
            }
        }
    }
    private func completed(_ params: [String: Any], token: UUID) {
        guard token == attempt, state == .waiting, params["loginId"] as? String == loginID else { return }
        guard params["success"] as? Bool == true, let connection = client, let home = candidate else { fail(); return }
        state = .verifying; onChange?()
        worker = Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await connection.request("account/read", ["refreshToken": false])
                guard let account = response["account"] as? [String: Any], account["type"] as? String == "chatgpt" else {
                    throw CodexAppServerClient.Failure.protocolError
                }
                // Bind only after the new account can actually provide rate limits.
                let limits = try await connection.request("account/rateLimits/read")
                guard QuotaStatus.parse(limits) != nil else { throw CodexAppServerClient.Failure.protocolError }
                guard token == attempt, !Task.isCancelled else { return }
                let previous = store.selectedHome
                try store.commit(home)
                accountLabel = Self.label(account)
                candidate = nil; state = .success; cleanup()
                onCommitted?() // Stop old quota reads before removing their credential store.
                if let previous { store.discard(previous) }
                onChange?()
            } catch {
                guard token == attempt, !Task.isCancelled else { return }
                fail()
            }
        }
    }
    static func label(_ account: [String: Any]) -> String {
        [account["email"] as? String, account["planType"] as? String].compactMap { $0 }.joined(separator: " · ")
    }
    func cancel() {
        guard busy else { return }
        attempt = UUID(); state = .cancelled
        cleanup(); onChange?()
    }
    private func fail() { attempt = UUID(); state = .failed; cleanup(); onChange?() }
    private func cleanup() {
        worker?.cancel(); worker = nil; timeout?.cancel(); timeout = nil
        client?.onDisconnect = nil; client?.onNotification = nil
        // Terminating the owned login process also closes its callback listener.
        client?.disconnect(); client = nil; loginID = nil; loginURL = nil; earlyCompletion = nil
        if let candidate { store.discard(candidate) }; candidate = nil
    }
    func useDesktop() {
        cancel()
        let previous = store.selectedHome
        store.useDesktop(); accountLabel = nil; state = .ready
        onCommitted?()
        if let previous { store.discard(previous) }
        onChange?()
    }
    func readAccount() async -> String? {
        guard let home = store.selectedHome else { return nil }
        let connection = makeClient(); connection.isolatedHome = home
        defer { connection.disconnect() }
        do {
            try await connection.connect()
            let response = try await connection.request("account/read", ["refreshToken": false])
            guard home == store.selectedHome, let account = response["account"] as? [String: Any] else { return nil }
            return Self.label(account)
        } catch { return nil }
    }
}
