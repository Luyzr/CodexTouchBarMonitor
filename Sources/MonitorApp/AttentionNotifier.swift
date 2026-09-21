import Foundation
import MonitorCore
import UserNotifications

@MainActor final class AttentionNotifier: NSObject, UNUserNotificationCenterDelegate {
    private var pending: [DecisionID: Task<Void, Never>] = [:]
    private var delivered = Set<DecisionID>()
    private var failures = Set<ExecutionID>()
    private var notificationIDs: [DecisionID: String] = [:]
    let feedback = AttentionFeedback()
    var onOpen: (() -> Void)?
    var delivery: ((String) -> Void)? // In-memory test seam; message never contains task content.
    func reconcile(_ state: AppState) {
        guard ["NotificationsEnabled", "SoundFeedback", "HapticFeedback"].contains(where: { UserDefaults.standard.bool(forKey: $0) }) else { stop(); return }
        let active = Set(state.decisions.filter { !$0.sent }.map { $0.id })
        for id in Array(pending.keys) where !active.contains(id) { pending.removeValue(forKey: id)?.cancel() }
        for id in Array(notificationIDs.keys) where !active.contains(id) {
            if let notification = notificationIDs.removeValue(forKey: id), delivery == nil, Bundle.main.bundleURL.pathExtension == "app" {
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [notification])
            }
        }
        delivered.formIntersection(active)
        for request in state.decisions where active.contains(request.id) && pending[request.id] == nil && !delivered.contains(request.id) {
            let id = request.id
            let delay = max(0, min(300, UserDefaults.standard.double(forKey: "DecisionNotificationDelay")) - Date().timeIntervalSince(request.createdAt))
            pending[id] = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled, let self, self.pending[id] != nil else { return }
                self.pending.removeValue(forKey: id); self.delivered.insert(id)
                let notification = UUID().uuidString; self.notificationIDs[id] = notification
                self.send("A Codex task is waiting for your decision.", id: notification)
            }
        }
        let failed = Set(state.executions.filter { $0.state == .failed }.map { $0.id })
        for id in failed.subtracting(failures) { send("A monitored Codex execution failed.", id: "failure-" + UUID().uuidString); failures.insert(id) }
        failures.formIntersection(failed)
    }
    private func send(_ message: String, id: String) {
        feedback.play()
        guard UserDefaults.standard.bool(forKey: "NotificationsEnabled") else { return }
        if let delivery { delivery(message); return }
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let center = UNUserNotificationCenter.current(); center.delegate = self
        let content = UNMutableNotificationContent(); content.title = "Codex Monitor"; content.body = message
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { _ in }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor [weak self] in self?.onOpen?(); completionHandler() }
    }
    func stop() {
        for task in pending.values { task.cancel() }; pending.removeAll(); delivered.removeAll(); failures.removeAll()
        if delivery == nil, Bundle.main.bundleURL.pathExtension == "app" {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: Array(notificationIDs.values))
        }
        notificationIDs.removeAll()
    }
}
