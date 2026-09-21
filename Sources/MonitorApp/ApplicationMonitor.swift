import AppKit

@MainActor final class ApplicationMonitor {
    private(set) var isCodexForeground = false
    var onChange: ((Bool, Bool) -> Void)?
    private var observer: NSObjectProtocol?
    func start(bundleIDs: [String]) {
        stop()
        isCodexForeground = bundleIDs.contains(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "")
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            let id = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier ?? ""
            Task { @MainActor in self?.update(isCodex: bundleIDs.contains(id)) }
        }
    }
    func update(isCodex: Bool) {
        guard isCodex != isCodexForeground else { return }
        let previous = isCodexForeground; isCodexForeground = isCodex; onChange?(previous, isCodex)
    }
    func stop() { if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }; observer = nil }
}
