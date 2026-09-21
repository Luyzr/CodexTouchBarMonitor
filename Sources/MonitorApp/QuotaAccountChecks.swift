import Foundation

@MainActor func runQuotaAccountChecks() async throws {
    var assertions = 0
    func check(_ value: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard value() else { fatalError("FAIL account: " + message) }
    }
    let suite = "io.local.CodexTouchBarMonitor.accounts." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("work/tmp/accounts-" + UUID().uuidString, isDirectory: true)
    let store = QuotaAccountStore(root: root, defaults: defaults)
    defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
    let original = try store.createCandidate()
    try Data("fixture".utf8).write(to: original.appendingPathComponent("auth.json"))
    try store.commit(original)
    let originalBytes = try Data(contentsOf: original.appendingPathComponent("auth.json"))
    let binding = QuotaAccountBinding(store: store, makeClient: {
        let client = CodexAppServerClient()
        client.executableOverride = FileManager.default.currentDirectoryPath + "/scripts/mock_account_server.py"
        return client
    })
    var opens = 0; var commits = 0
    binding.openBrowser = { _ in opens += 1; return true }
    binding.onCommitted = { commits += 1 }
    func scenario(_ name: String) throws {
        try name.write(to: root.appendingPathComponent("scenario"), atomically: true, encoding: .utf8)
    }
    func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        fatalError("FAIL account: fixture timed out")
    }
    check(QuotaAccountBinding.safeLoginURL("https://auth.openai.com/authorize?a=b") != nil, "official sign-in allowed")
    for url in ["http://auth.openai.com/", "https://auth.openai.com.evil.invalid", "https://evil@auth.openai.com", "javascript:alert(1)", "https://auth.openai.com:444/"] {
        check(QuotaAccountBinding.safeLoginURL(url) == nil, "unsafe sign-in rejected")
    }
    let isolated = CodexAppServerClient(); isolated.isolatedHome = original
    do { try await isolated.connect(mode: .daemon("/nonexistent")); check(false, "isolated daemon accepted") }
    catch { check(true, "isolated login cannot use shared daemon") }

    for mode in ["cancel", "mismatch", "failure", "policy"] {
        try scenario(mode)
        defaults.set(Data("old cache".utf8), forKey: "weeklyQuota")
        binding.begin(); binding.begin()
        if mode == "cancel" || mode == "mismatch" {
            try await wait { binding.state == .waiting }
            check(opens > 0, "login page opened")
            binding.cancel()
            check(binding.state == .cancelled, "cancel state")
        } else {
            try await wait { binding.state == .failed }
        }
        check(store.selectedHome == original && commits == 0, "unsuccessful login leaves original selection")
        check(defaults.data(forKey: "weeklyQuota") != nil, "unsuccessful login preserves cache")
        let bytes = try Data(contentsOf: original.appendingPathComponent("auth.json"))
        check(bytes == originalBytes, "original credentials untouched")
        let homes = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { UUID(uuidString: $0.lastPathComponent) != nil }
        check(homes == [original], "candidate cleaned after failure or cancellation")
    }
    try scenario("success")
    binding.begin()
    try await wait { binding.state == .success }
    check(commits == 1 && store.selectedHome != original, "verified account committed exactly once")
    check(defaults.data(forKey: "weeklyQuota") == nil, "old quota cleared only on successful replacement")
    check(!FileManager.default.fileExists(atPath: original.path), "previous private credential store removed")
    check(binding.accountLabel == "fixture@example.invalid · pro", "account identity displayed")
    let restored = QuotaAccountStore(root: root, defaults: defaults)
    check(restored.selectedHome == store.selectedHome, "selection survives restart")
    let label = await binding.readAccount()
    check(label == binding.accountLabel, "bound account readable after login process closes")
    let selected = store.selectedHome!
    binding.useDesktop()
    check(store.selectedHome == nil && commits == 2, "explicit restore returns to Desktop source")
    check(!FileManager.default.fileExists(atPath: selected.path), "unlinked private credentials deleted")
    defaults.set("../../outside", forKey: "QuotaAccountID")
    check(store.selectedHome == nil, "invalid stored identifier cannot escape private root")
    print("PASS: \(assertions) isolated quota-account assertions")
}
