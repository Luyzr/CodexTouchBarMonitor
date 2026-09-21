import AppKit
import ServiceManagement
import UserNotifications

@MainActor final class SettingsController {
    private var window: NSWindow?
    var onChange: (() -> Void)?
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: ["ShowNetwork": true, "ShowQuota": true, "MaximumVisibleTasks": 4, "AutoShowDecision": true, "LatencyRefreshInterval": 10.0, "DecisionNotificationDelay": 30.0, "NotificationsEnabled": true, "LaunchAtLogin": true, "MonitorTheme": "dark", "ThemeBackground": "#1F1F1F", "ThemeAccent": "#4488FF", "SoundFeedback": false, "HapticFeedback": false])
    }
    static func setupSystemIntegration() {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        if UserDefaults.standard.bool(forKey: "NotificationsEnabled") {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        if UserDefaults.standard.bool(forKey: "LaunchAtLogin"),
           !UserDefaults.standard.bool(forKey: "LoginSetupAttempted"),
           Bundle.main.bundleURL.path.hasPrefix("/Applications/") {
            do { try SMAppService.mainApp.register(); UserDefaults.standard.set(true, forKey: "LoginSetupAttempted") }
            catch { /* Settings displays actual system status; retry only on an explicit action. */ }
        }
    }
    func show() {
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 590, height: 620), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Codex Monitor Settings"; window.isReleasedWhenClosed = false
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.edgeInsets = .init(top: 20, left: 20, bottom: 20, right: 20)
        for (key, title) in [("ShowNetwork", "Show network latency"), ("ShowQuota", "Show weekly quota"), ("AutoShowDecision", "Automatically show a single decision"), ("NotificationsEnabled", "Decision and failure notifications")] {
            let button = ActionButton(title) {}; button.setButtonType(.switch); button.state = UserDefaults.standard.bool(forKey: key) ? .on : .off
            button.handler = { [weak self, weak button] in
                let enabled = button?.state == .on; UserDefaults.standard.set(enabled, forKey: key)
                if key == "NotificationsEnabled" && enabled {
                    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
                }
                self?.onChange?()
            }
            stack.addArrangedSubview(button)
        }
        let tasks = NSPopUpButton(); tasks.addItems(withTitles: (1...6).map(String.init)); tasks.selectItem(at: UserDefaults.standard.integer(forKey: "MaximumVisibleTasks") - 1)
        let interval = NSTextField(string: String(UserDefaults.standard.double(forKey: "LatencyRefreshInterval")))
        let delay = NSTextField(string: String(UserDefaults.standard.double(forKey: "DecisionNotificationDelay")))
        for (title, view) in [("Maximum visible tasks", tasks as NSView), ("Network refresh (seconds, 3–300)", interval), ("Decision notification delay (0–300)", delay)] {
            stack.addArrangedSubview(NSStackView(views: [NSTextField(labelWithString: title), view]))
        }
        let message = NSTextField(wrappingLabelWithString: "")
        stack.addArrangedSubview(ActionButton("Apply") { [weak self] in
            guard let seconds = Double(interval.stringValue), seconds.isFinite, let wait = Double(delay.stringValue), wait.isFinite else { message.stringValue = "Enter valid numbers."; return }
            UserDefaults.standard.set(tasks.indexOfSelectedItem + 1, forKey: "MaximumVisibleTasks")
            UserDefaults.standard.set(max(3, min(300, seconds)), forKey: "LatencyRefreshInterval")
            UserDefaults.standard.set(max(0, min(300, wait)), forKey: "DecisionNotificationDelay")
            self?.onChange?(); message.stringValue = "Saved"
        })
        stack.addArrangedSubview(ActionButton(SMAppService.mainApp.status == .enabled ? "Disable launch at login" : "Enable launch at login") { [weak self] in
            do {
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister(); UserDefaults.standard.set(false, forKey: "LaunchAtLogin") }
                else { try SMAppService.mainApp.register(); UserDefaults.standard.set(true, forKey: "LaunchAtLogin") }
                self?.show()
            } catch { message.stringValue = "Login registration failed. Run the packaged .app from Applications." }
        })
        if SMAppService.mainApp.status == .requiresApproval {
            stack.addArrangedSubview(ActionButton("Approve in Login Items…") { SMAppService.openSystemSettingsLoginItems() })
        }
        stack.addArrangedSubview(message); window.contentView = stack
        self.window?.close(); self.window = window; window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
}
