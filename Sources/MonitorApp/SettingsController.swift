import AppKit
import ServiceManagement
import UserNotifications

@MainActor final class SettingsController {
    private var window: NSWindow?
    var onChange: (() -> Void)?
    var onAccountSettings: (() -> Void)?
    var onLanguageChange: (() -> Void)?
    static var isEnglish: Bool { UserDefaults.standard.string(forKey: "SettingsLanguage") == "en" }
    static func text(_ value: String) -> String {
        let key = translations.first(where: { $0.value == value })?.key ?? value
        return isEnglish ? translations[key] ?? value : key
    }
    @objc private func changeLanguage(_ sender: NSPopUpButton) {
        UserDefaults.standard.set(sender.indexOfSelectedItem == 1 ? "en" : "zh-Hans", forKey: "SettingsLanguage")
        // Update labels in place: unsaved numeric edits and independent switches survive.
        func translate(_ view: NSView) {
            if let button = view as? NSButton, !(button is NSPopUpButton) { button.title = Self.text(button.title) }
            if let label = view as? NSTextField, !label.isEditable { label.stringValue = Self.text(label.stringValue) }
            for child in view.subviews { translate(child) }
        }
        if let content = window?.contentView { translate(content) }
        window?.title = Self.text("Codex Monitor 设置")
        refreshSystemStatus(); onLanguageChange?()
    }
    private static let translations: [String: String] = [
        "Codex Monitor 设置": "Codex Monitor Settings",
        "显示网络时延": "Show network latency",
        "显示 Codex 周剩余额度": "Show Codex weekly quota",
        "只有一个待处理问题时，自动展开": "Automatically open a single pending question",
        "每页最多显示任务": "Tasks per page",
        "个": "tasks",
        "网络刷新间隔": "Network refresh interval",
        "秒（3–300）": "seconds (3–300)",
        "系统通知": "System notifications",
        "任务等待回复或失败时通知我": "Notify me when a task needs a reply or fails",
        "等待回复多久后通知": "Notify after waiting",
        "秒（0–300）": "seconds (0–300)",
        "默认等待 30 秒再发系统通知；0 表示立即通知。任务失败立即通知。Touch Bar 的警示三角会立即显示，不受此时间影响。": "Wait 30 seconds by default before sending a notification; 0 means immediately. Failures notify immediately. The Touch Bar warning appears immediately, regardless of this delay.",
        "保存刷新间隔和通知时间": "Save task count and timing",
        "网络间隔需为 3–300 秒，通知等待需为 0–300 秒。": "Network interval must be 3–300 seconds; notification wait must be 0–300 seconds.",
        "已保存": "Saved",
        "登录启动": "Launch at login",
        "登录 Mac 后自动运行此 App。此项与系统通知互相独立。": "Run this app when you log in to your Mac. This setting is independent of notifications.",
        "登录启动未能更改。请确认 App 位于“应用程序”，再检查系统的登录项设置。": "Could not change launch at login. Run the app from Applications and check Login Items in System Settings.",
        "打开系统登录项设置…": "Open system Login Items…",
        "正在读取通知权限…": "Checking notification permission…",
        "通知已关闭（不影响登录启动）": "Notifications off (launch at login is unchanged)",
        "系统已允许通知": "System notifications allowed",
        "系统未允许通知，请在系统设置 → 通知中开启": "Notifications blocked. Enable them in System Settings → Notifications.",
        "尚未授予系统通知权限": "Notification permission not granted yet",
        "关闭登录启动": "Disable launch at login",
        "已开启": "Enabled",
        "取消登录启动": "Cancel launch at login",
        "等待你在系统登录项中允许": "Awaiting your approval in system Login Items",
        "开启登录启动": "Enable launch at login",
        "已关闭": "Disabled",
        "暂不可用，请从“应用程序”运行 App": "Unavailable. Run the app from Applications.",
        "设置…": "Settings…",
        "额度账号…": "Quota account…"
    ]
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: ["SettingsLanguage": "zh-Hans", "ShowNetwork": true, "ShowQuota": true, "MaximumVisibleTasks": 4, "AutoShowDecision": true, "LatencyRefreshInterval": 10.0, "DecisionNotificationDelay": 30.0, "NotificationsEnabled": true, "LaunchAtLogin": true, "MonitorTheme": "dark", "ThemeBackground": "#1F1F1F", "ThemeAccent": "#4488FF", "SoundFeedback": false, "HapticFeedback": false])
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
        if let window { refreshSystemStatus(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 580, height: 700), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = Self.text("Codex Monitor 设置"); window.isReleasedWhenClosed = false
        let content = NSView()
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24)])
        func note(_ text: String) {
            let label = NSTextField(wrappingLabelWithString: text); label.textColor = .secondaryLabelColor
            label.font = .systemFont(ofSize: 12); stack.addArrangedSubview(label)
            label.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        func heading(_ text: String) {
            let label = NSTextField(labelWithString: text); label.font = .boldSystemFont(ofSize: 14)
            stack.addArrangedSubview(label)
        }
        func toggle(_ key: String, _ title: String) {
            let button = ActionButton(title) {}; button.setButtonType(.switch)
            button.state = UserDefaults.standard.bool(forKey: key) ? .on : .off
            button.handler = { [weak self, weak button] in
                let enabled = button?.state == .on
                UserDefaults.standard.set(enabled, forKey: key)
                self?.onChange?()
                if key == "NotificationsEnabled" {
                    self?.delayField?.isEnabled = enabled
                    if enabled {
                        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] _, _ in
                            Task { @MainActor in self?.refreshSystemStatus() }
                        }
                    } else { self?.refreshSystemStatus() }
                }
            }
            stack.addArrangedSubview(button)
        }
        let language = NSPopUpButton()
        language.addItems(withTitles: ["中文", "English"])
        language.selectItem(at: Self.isEnglish ? 1 : 0)
        language.target = self; language.action = #selector(changeLanguage(_:))
        let languageRow = NSStackView(views: [NSTextField(labelWithString: "语言 / Language"), language])
        languageRow.addArrangedSubview(ActionButton(Self.text("额度账号…")) { [weak self] in self?.onAccountSettings?() })
        languageRow.spacing = 16
        stack.addArrangedSubview(languageRow)
        heading("Touch Bar")
        toggle("ShowNetwork", Self.text("显示网络时延"))
        toggle("ShowQuota", Self.text("显示 Codex 周剩余额度"))
        toggle("AutoShowDecision", Self.text("只有一个待处理问题时，自动展开"))
        let tasks = NSPopUpButton(); tasks.addItems(withTitles: (1...6).map(String.init))
        tasks.selectItem(at: max(0, min(5, UserDefaults.standard.integer(forKey: "MaximumVisibleTasks") - 1)))
        let interval = NSTextField(string: String(Int(UserDefaults.standard.double(forKey: "LatencyRefreshInterval"))))
        let delay = NSTextField(string: String(Int(UserDefaults.standard.double(forKey: "DecisionNotificationDelay"))))
        self.delayField = delay; delay.isEnabled = UserDefaults.standard.bool(forKey: "NotificationsEnabled")
        func row(_ title: String, _ view: NSView, _ unit: String = "") {
            view.widthAnchor.constraint(equalToConstant: 80).isActive = true
            let label = NSTextField(labelWithString: title); label.widthAnchor.constraint(equalToConstant: 220).isActive = true
            let row = NSStackView(views: [label, view, NSTextField(labelWithString: unit)])
            row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 12
            stack.addArrangedSubview(row)
        }
        row(Self.text("每页最多显示任务"), tasks, Self.text("个"))
        row(Self.text("网络刷新间隔"), interval, Self.text("秒（3–300）"))
        heading(Self.text("系统通知"))
        toggle("NotificationsEnabled", Self.text("任务等待回复或失败时通知我"))
        stack.addArrangedSubview(notificationStatus)
        notificationStatus.font = .systemFont(ofSize: 12); notificationStatus.textColor = .secondaryLabelColor
        row(Self.text("等待回复多久后通知"), delay, Self.text("秒（0–300）"))
        note(Self.text("默认等待 30 秒再发系统通知；0 表示立即通知。任务失败立即通知。Touch Bar 的警示三角会立即显示，不受此时间影响。"))
        let message = NSTextField(wrappingLabelWithString: "")
        stack.addArrangedSubview(ActionButton(Self.text("保存刷新间隔和通知时间")) { [weak self] in
            guard let seconds = Double(interval.stringValue), seconds.isFinite, (3...300).contains(seconds),
                  let wait = Double(delay.stringValue), wait.isFinite, (0...300).contains(wait) else {
                message.stringValue = Self.text("网络间隔需为 3–300 秒，通知等待需为 0–300 秒。"); return
            }
            UserDefaults.standard.set(tasks.indexOfSelectedItem + 1, forKey: "MaximumVisibleTasks")
            UserDefaults.standard.set(seconds, forKey: "LatencyRefreshInterval")
            UserDefaults.standard.set(wait, forKey: "DecisionNotificationDelay")
            self?.onChange?(); message.stringValue = Self.text("已保存")
        })
        heading(Self.text("登录启动"))
        note(Self.text("登录 Mac 后自动运行此 App。此项与系统通知互相独立。"))
        loginButton = ActionButton("") { [weak self] in
            guard let self else { return }
            do {
                switch SMAppService.mainApp.status {
                case .enabled, .requiresApproval:
                    try SMAppService.mainApp.unregister()
                    UserDefaults.standard.set(false, forKey: "LaunchAtLogin")
                default:
                    try SMAppService.mainApp.register()
                    UserDefaults.standard.set(true, forKey: "LaunchAtLogin")
                    UserDefaults.standard.set(true, forKey: "LoginSetupAttempted")
                }
                self.refreshSystemStatus()
            } catch { message.stringValue = Self.text("登录启动未能更改。请确认 App 位于“应用程序”，再检查系统的登录项设置。") }
        }
        stack.addArrangedSubview(loginButton!)
        stack.addArrangedSubview(loginStatus)
        loginStatus.font = .systemFont(ofSize: 12); loginStatus.textColor = .secondaryLabelColor
        let approval = ActionButton(Self.text("打开系统登录项设置…")) { SMAppService.openSystemSettingsLoginItems() }
        stack.addArrangedSubview(approval)
        stack.addArrangedSubview(message); window.contentView = content
        self.window = window; refreshSystemStatus()
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    private let notificationStatus = NSTextField(labelWithString: "")
    private let loginStatus = NSTextField(labelWithString: "")
    private var loginButton: ActionButton?
    private weak var delayField: NSTextField?
    private func refreshSystemStatus() {
        let enabled = UserDefaults.standard.bool(forKey: "NotificationsEnabled")
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            let status = settings.authorizationStatus
            Task { @MainActor in
                self?.notificationStatus.stringValue = !enabled ? Self.text("通知已关闭（不影响登录启动）") :
                    status == .authorized || status == .provisional ? Self.text("系统已允许通知") :
                    status == .denied ? Self.text("系统未允许通知，请在系统设置 → 通知中开启") : Self.text("尚未授予系统通知权限")
            }
        }
        switch SMAppService.mainApp.status {
        case .enabled: loginButton?.title = Self.text("关闭登录启动"); loginStatus.stringValue = Self.text("已开启")
        case .requiresApproval: loginButton?.title = Self.text("取消登录启动"); loginStatus.stringValue = Self.text("等待你在系统登录项中允许")
        case .notRegistered: loginButton?.title = Self.text("开启登录启动"); loginStatus.stringValue = Self.text("已关闭")
        default: loginButton?.title = Self.text("开启登录启动"); loginStatus.stringValue = Self.text("暂不可用，请从“应用程序”运行 App")
        }
    }
}
