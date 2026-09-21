import Foundation

/// This storage never reads or modifies the Codex Desktop credential directory.
@MainActor final class QuotaAccountStore {
    static let shared = QuotaAccountStore()
    static var selectedHome: URL? { shared.selectedHome }
    let root: URL
    let defaults: UserDefaults
    init(root: URL? = nil, defaults: UserDefaults = .standard) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CodexTouchBarMonitor/QuotaAccounts", isDirectory: true)
        self.defaults = defaults
    }
    var selectedHome: URL? {
        guard let id = defaults.string(forKey: "QuotaAccountID"), UUID(uuidString: id) != nil else { return nil }
        return root.appendingPathComponent(id, isDirectory: true)
    }
    func createCandidate() throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let home = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return home
    }
    func commit(_ home: URL) throws {
        guard owns(home), FileManager.default.fileExists(atPath: home.appendingPathComponent("auth.json").path) else {
            throw CodexAppServerClient.Failure.unavailable
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: home.appendingPathComponent("auth.json").path)
        defaults.set(home.lastPathComponent, forKey: "QuotaAccountID")
        defaults.removeObject(forKey: "weeklyQuota")
    }
    func useDesktop() { defaults.removeObject(forKey: "QuotaAccountID"); defaults.removeObject(forKey: "weeklyQuota") }
    func discard(_ home: URL) {
        guard owns(home), home != selectedHome else { return }
        try? FileManager.default.removeItem(at: home)
    }
    private func owns(_ home: URL) -> Bool {
        UUID(uuidString: home.lastPathComponent) != nil && home.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL
    }
}
