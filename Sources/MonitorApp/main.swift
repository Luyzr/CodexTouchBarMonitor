import AppKit
import OSLog
import MonitorCore
import TouchBarPrivateBridge

@MainActor final class CodexLauncher: NSObject {
    var bundleIDs: [String] { UserDefaults.standard.stringArray(forKey: "CodexBundleIDs") ?? ["com.openai.codex", "com.openai.chat"] }
    var appURL: URL? { bundleIDs.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first }
    @objc func openCodex() {
        if let running = NSWorkspace.shared.runningApplications.first(where: { bundleIDs.contains($0.bundleIdentifier ?? "") }) {
            let activated = running.activate(options: [.activateIgnoringOtherApps])
            if CommandLine.arguments.contains("--interaction-diagnostics") { print("TRAY activate success=\(activated) bundle=\(running.bundleIdentifier ?? "none")"); fflush(stdout) }
            return
        }
        guard let url = appURL else { showError("Codex not installed"); return }
        let config = NSWorkspace.OpenConfiguration(); config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
            if error != nil { Task { @MainActor in self.showError("Unable to launch Codex") } }
        }
    }
    private func showError(_ message: String) {
        let alert = NSAlert(); alert.messageText = message
        alert.informativeText = "Set CodexBundleIDs if your Codex installation uses a different bundle identifier."
        alert.runModal()
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let logger = Logger(subsystem: "io.local.CodexTouchBarMonitor", category: "app")
    let launcher = CodexLauncher()
    lazy var quotaIcon: NSImage? = launcher.appURL.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage(systemSymbolName: "command", accessibilityDescription: "Open Codex")?.withSymbolConfiguration(.init(paletteColors: [.white]))
    let network = NetworkMonitor()
    let quota = QuotaMonitor()
    let executions = ExecutionManager()
    lazy var dashboard = DashboardController(manager: executions)
    let settings = SettingsController()
    let notifier = AttentionNotifier()
    var trays: [NSCustomTouchBarItem] = []
    var statusItem: NSStatusItem?
    var preview: NSWindow?
    var networkValue = NetworkStatus()
    var quotaValue = QuotaStatus()
    var trayButtons: [NSButton] = []
    var installed = false
    var connection = "App Server connecting"
    var diagnosticItem: NSMenuItem?
    var workspaceObservers: [NSObjectProtocol] = []
    var recoveryWork: DispatchWorkItem?
    private var started = false
    func applicationDidFinishLaunching(_ notification: Notification) { start() }
    func start() {
        guard !started else { return }
        started = true
        SettingsController.registerDefaults()
        NSApp.setActivationPolicy(.accessory)
        let mainMenu = NSMenu(); let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")
        for (title, selector, key) in [("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"), ("Paste", #selector(NSText.paste(_:)), "v"), ("Select All", #selector(NSText.selectAll(_:)), "a")] {
            editMenu.addItem(NSMenuItem(title: title, action: selector, keyEquivalent: key))
        }
        editItem.submenu = editMenu; mainMenu.addItem(editItem); NSApp.mainMenu = mainMenu
        executions.demo = CommandLine.arguments.contains("--demo") || CommandLine.arguments.contains("--ui-check")
        dashboard.openCodex = { [weak self] in self?.launcher.openCodex() }
        executions.onChange = { [weak self] in
            guard let self else { return }
            self.dashboard.render()
            if !self.executions.demo && !CommandLine.arguments.contains("--smoke-test") { self.notifier.reconcile(self.executions.state) }
        }
        notifier.onOpen = { [weak self] in self?.dashboard.show() }
        settings.onChange = { [weak self] in
            guard let self else { return }; self.render(); self.dashboard.render()
            if !self.executions.demo { self.notifier.reconcile(self.executions.state); self.network.restart() }
        }
        let item = NSCustomTouchBarItem(identifier: .init("io.local.CodexTouchBarMonitor.compact"))
        item.view = makeTray()
        trays = [item]
        if !CommandLine.arguments.contains("--disable-private-api"), CTBInstall(item) { installed = true }
        logger.info("Persistent tray registration: \(self.installed)")
        setupMenu()
        network.onUpdate = { [weak self] value in self?.networkValue = value; self?.render() }
        quota.onUpdate = { [weak self] value in self?.quotaValue = value; self?.render() }
        quota.onConnection = { [weak self] value in self?.connection = value; self?.updateDiagnostic() }
        if !executions.demo || CommandLine.arguments.contains("--background-demo") { network.start(); quota.start() }
        executions.start()
        if !executions.demo {
            installRecoveryObservers()
            if !CommandLine.arguments.contains("--smoke-test") { SettingsController.setupSystemIntegration() }
        }
        if executions.demo && !CommandLine.arguments.contains("--background-demo") { dashboard.show() }
        if CommandLine.arguments.contains("--ui-check") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                do { try self.dashboard.runUIChecks(output: FileManager.default.currentDirectoryPath + "/work"); NSApp.terminate(nil) }
                catch { fputs("UI check failed: \(error)\n", stderr); exit(1) }
            }
        }
        if CommandLine.arguments.contains("--preview") { showPreview() }
        if CommandLine.arguments.contains("--smoke-test") {
            DispatchQueue.main.asyncAfter(deadline: .now()+12) {
                print("trayRegistered=\(self.installed) network=\(self.networkValue.title) quota=\(self.quotaValue.title) stale=\(self.quotaValue.stale) connection=\(self.connection) tasks=\(self.executions.store.sorted.count) decisions=\(self.executions.queue.count) monitor=\(self.executions.connection)")
                NSApp.terminate(nil)
            }
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        start(); showPreview(); return true
    }
    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        start(); showPreview(); return true
    }
    func makeTray() -> NSView {
        let button = CompactTrayButton(frame: .zero)
        button.onSingleTap = { [weak self] in self?.launcher.openCodex() }
        button.onDoubleTap = { [weak self] in self?.dashboard.showBackgroundControls() }
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor.black.cgColor
        button.layer?.cornerRadius = 4
        button.widthAnchor.constraint(equalToConstant: 48).isActive = true
        button.heightAnchor.constraint(equalToConstant: 30).isActive = true
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        trayButtons.append(button)
        render()
        button.setFrameSize(NSSize(width: 48, height: 30))
        return button
    }
    func render() {
        let networkColor: NSColor
        switch networkValue.color {
        case .green: networkColor = .systemGreen
        case .yellow: networkColor = .systemYellow
        case .red: networkColor = .systemRed
        case .neutral: networkColor = .lightGray
        }
        let remaining = quotaValue.remainingPercent ?? 100
        let quotaColor: NSColor = remaining < 10 ? .systemRed : remaining <= 30 ? .systemYellow : .white
        let percent = UserDefaults.standard.bool(forKey: "ShowQuota") ? (quotaValue.remainingPercent.map { "\($0)%" } ?? "--%") : "Codex"
        let latency = UserDefaults.standard.bool(forKey: "ShowNetwork") ? networkValue.title : ""
        let quotaOpacity: CGFloat = quotaValue.stale ? 0.45 : 1
        let icon = quotaIcon
        // Draw two short rows into a single 44x28pt control image. This is
        // content within one slot, not an attempt to enlarge the system slot.
        let image = NSImage(size: NSSize(width: 44, height: 28), flipped: false) { rect in
            func row(_ text: String, y: CGFloat, color: NSColor, leadingIcon: NSImage? = nil) {
                let iconSpace: CGFloat = leadingIcon == nil ? 0 : 14
                var size: CGFloat = 11
                var font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .medium)
                while (text as NSString).size(withAttributes: [.font: font]).width > rect.width - 2 - iconSpace && size > 7 {
                    size -= 0.5
                    font = .monospacedDigitSystemFont(ofSize: size, weight: .medium)
                }
                let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
                let dimensions = (text as NSString).size(withAttributes: attributes)
                let startX = (rect.width-dimensions.width-iconSpace)/2
                if let leadingIcon {
                    leadingIcon.draw(in: NSRect(x: startX, y: y + 1, width: 12, height: 12),
                                     from: .zero, operation: .sourceOver, fraction: quotaOpacity)
                }
                (text as NSString).draw(at: NSPoint(x: startX + iconSpace, y: y), withAttributes: attributes)
            }
            row(latency, y: 14, color: networkColor)
            row(percent, y: 0, color: quotaColor.withAlphaComponent(quotaOpacity), leadingIcon: icon)
            return true
        }
        image.isTemplate = false
        for button in trayButtons {
            button.image = image
            button.setAccessibilityLabel("Network \(latency), Codex weekly quota remaining \(percent), tap to open Codex, double tap for task controls")
            button.toolTip = "Network \(latency) · Codex weekly remaining \(percent)\(quotaValue.stale ? " (cached/unavailable)" : "") · Tap: open Codex · Double tap: task controls"
        }
        updateDiagnostic()
    }
    func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.title = "CTB"
        let menu = NSMenu()
        diagnosticItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        menu.addItem(diagnosticItem!)
        let preview = NSMenuItem(title: "Show tray preview", action: #selector(showPreview), keyEquivalent: "")
        preview.target = self; menu.addItem(preview)
        let open = NSMenuItem(title: "Open Codex", action: #selector(CodexLauncher.openCodex), keyEquivalent: "")
        open.target = launcher; menu.addItem(open)
        let controls = NSMenuItem(title: "Show task controls", action: #selector(showTaskControls), keyEquivalent: "")
        controls.target = self; menu.addItem(controls)
        let dashboard = NSMenuItem(title: "Task diagnostics…", action: #selector(showDashboard), keyEquivalent: "d")
        dashboard.target = self; menu.addItem(dashboard)
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self; menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Monitor", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit); statusItem?.menu = menu; updateDiagnostic()
    }
    func updateDiagnostic() {
        diagnosticItem?.title = "\(installed ? "Tray registered (hardware unverified)" : "Tray unavailable") · \(networkValue.title) · \(quotaValue.title) · \(connection)"
    }
    @objc func showTaskControls() { dashboard.showBackgroundControls() }
    @objc func showDashboard() { dashboard.show() }
    @objc func showSettings() { settings.show() }
    @objc func showPreview() {
        if preview == nil {
            let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 460, height: 130), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Codex Monitor — compact"
            window.isReleasedWhenClosed = false
            let stack = NSStackView(views: [makeTray(), NSTextField(wrappingLabelWithString: "Single click opens Codex. Double click shows tasks. System X returns to the app.")])
            stack.orientation = .vertical; stack.spacing = 16
            window.contentView = stack; preview = window; window.center()
        }
        render(); preview?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    private func installRecoveryObservers() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.network.restart(); self?.quota.restart(); self?.executions.wake(); self?.scheduleTrayRecovery() }
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            let id = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            if id == "com.apple.controlstrip" { Task { @MainActor in self?.scheduleTrayRecovery() } }
        })
    }
    private func scheduleTrayRecovery() {
        recoveryWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !CommandLine.arguments.contains("--disable-private-api") else { return }
            self.installed = false
            for tray in self.trays { CTBRemove(tray); self.installed = CTBInstall(tray) || self.installed }
            self.dashboard.recoverTray(); self.render()
        }
        recoveryWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }
    func applicationWillTerminate(_ notification: Notification) {
        network.stop(); quota.stop(); executions.stop(); dashboard.stop(); notifier.stop()
        for tray in trays { CTBRemove(tray) }
        trays.removeAll(); recoveryWork?.cancel()
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        workspaceObservers.removeAll()
    }
}
MainActor.assumeIsolated {
    let application = NSApplication.shared
    if CommandLine.arguments.contains("--self-check") || CommandLine.arguments.contains("--probe-daemon") {
        Task { @MainActor in
            do {
                if CommandLine.arguments.contains("--probe-daemon") { try await probeDaemon() }
                else { try await runSelfChecks(mock: FileManager.default.currentDirectoryPath + "/scripts/mock_app_server.py") }
                exit(0)
            } catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
        }
        application.run()
    }
    let delegate = AppDelegate()
    application.delegate = delegate
    DispatchQueue.main.async { delegate.start() }
    withExtendedLifetime(delegate) { application.run() }
}
