import AppKit
import MonitorCore
import TouchBarPrivateBridge

@MainActor final class TopAlignedClipView: NSClipView { override var isFlipped: Bool { true } }
@MainActor final class DashboardStack: NSStackView {
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        MonitorTheme.background.setFill(); dirtyRect.fill(); super.draw(dirtyRect)
    }
}
@MainActor final class ActionButton: NSButton {
    var handler: (() -> Void)?
    init(_ title: String, action: @escaping () -> Void) {
        handler = action; super.init(frame: .zero); self.title = title
        bezelStyle = .rounded; target = self; self.action = #selector(invoke)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func invoke() { handler?() }
}
@MainActor final class DashboardController: NSObject, NSTouchBarDelegate, NSWindowDelegate {
    let manager: ExecutionManager
    let input = TextInputController()
    var openCodex: (() -> Void)?
    private var window: NSWindow?
    private var content: NSStackView?
    private var taskTouchBar: NSTouchBar?
    private var touchBarVisibility: NSKeyValueObservation?
    private var dynamicPresented = false
    private var nativeDismissed = false
    private var manuallyRequested = false
    private var lastAttention = Set<DecisionID>()
    private var interactionGeneration = UUID()
    private var selected: DecisionID?
    private var selectionIsAutomatic = false
    private var detail: ExecutionID?
    private var page = 0
    private var session: InputSession?
    private var questionIndex: Int { session?.questionIndex ?? 0 }
    private var optionPage = 0
    private var decisionPage = 0
    private var suppressAutomatic = false
    private var durationTimer: Timer?
    private var durationLabels: [(NSTextField, ExecutionID)] = []
    private var warningButtons: [NSButton] = []
    private var controlsItem: NSCustomTouchBarItem?
    private var touchScroll: NSScrollView?
    private var lastControlsSignature = ""
    private var draft = ""
    private var inputLabels: [NSTextField] = []
    private var flash: Timer?
    private var flashOn = true
    private var errorMessage: String?
    init(manager: ExecutionManager) {
        self.manager = manager; super.init()
        input.onChange = { [weak self] text in
            self?.draft = text
        }
        input.onPreview = { [weak self] preview in self?.inputLabels.forEach { $0.stringValue = preview } }
        input.onSubmit = { [weak self] text in self?.answer(text) }
        input.onCancel = { [weak self] in self?.clearInput(); self?.render() }
    }
    func render() {
        if let selected, manager.decisions[selected] == nil {
            clearInput(); self.selected = nil; suppressAutomatic = true
        }
        if let detail, manager.store.executions[detail] == nil { self.detail = nil }
        if selectionIsAutomatic && manager.queue.count > 1 && !input.active { clearInput(); selected = nil; selectionIsAutomatic = false }
        if manager.queue.isEmpty { suppressAutomatic = false }
        if selected == nil && detail == nil && !suppressAutomatic && manager.queue.count == 1 && UserDefaults.standard.object(forKey: "AutoShowDecision") as? Bool != false {
            selected = manager.queue[0].id; session = InputSession(request: manager.queue[0].id); selectionIsAutomatic = true
        }
        if manager.store.sorted.contains(where: { $0.state == .waitingDecision }) && flash == nil {
            flash = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }; self.flashOn.toggle()
                    self.warningButtons.forEach { $0.alphaValue = self.flashOn ? 1 : 0.45 }
                }
            }
        } else if !manager.store.sorted.contains(where: { $0.state == .waitingDecision }) { flash?.invalidate(); flash = nil }
        window?.appearance = MonitorTheme.appearance
        content?.needsDisplay = true
        (window?.contentView as? NSScrollView)?.backgroundColor = MonitorTheme.background
        warningButtons.removeAll(); durationLabels.removeAll()
        updateTouchBar()
        diagnoseInputLayout()
        updateDurationTimer()
        inputLabels = inputLabels.filter { $0.superview != nil }
        if let content {
            for view in content.arrangedSubviews { content.removeArrangedSubview(view); view.removeFromSuperview() }
            content.addArrangedSubview(label(manager.connection))
            content.addArrangedSubview(makeControls(compact: false))
            if let errorMessage { content.addArrangedSubview(label(errorMessage)) }
            let footer = NSStackView(views: [ActionButton("Refresh") { [weak self] in Task { await self?.manager.discover() } }, ActionButton("Open Codex") { [weak self] in self?.openCodex?() }])
            content.addArrangedSubview(footer)
        }
    }
    private func diagnoseInputLayout() {
        guard CommandLine.arguments.contains("--input-diagnostics") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            print("LAYOUT capture=\(self.input.active) presented=\(self.dynamicPresented) barVisible=\(self.taskTouchBar?.isVisible ?? false) itemVisible=\(self.controlsItem?.isVisible ?? false) frame=\(self.controlsItem?.view.frame ?? .zero)")
            if let scroll = self.controlsItem?.view as? NSScrollView, let stack = scroll.documentView?.subviews.first as? NSStackView {
                print("SCROLL bounds=\(scroll.contentView.bounds) document=\(scroll.documentView?.frame ?? .zero) stack=\(stack.frame)")
                for view in stack.arrangedSubviews { print("VIEW kind=\(view is NSButton ? "button" : "text") frame=\(view.frame) hidden=\(view.isHidden)") }
            }
            fflush(stdout)
        }
    }
    func show() {
        if window == nil {
            let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 760, height: 520), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = manager.demo ? "Codex Monitor — Demo" : "Codex Monitor — Diagnostics"
            window.isReleasedWhenClosed = false; window.delegate = self
            let content = DashboardStack(); content.orientation = .vertical; content.alignment = .leading
            content.spacing = 16; content.edgeInsets = .init(top: 20, left: 20, bottom: 20, right: 20)
            let scroll = NSScrollView(); scroll.contentView = TopAlignedClipView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = true; scroll.backgroundColor = MonitorTheme.background
            content.translatesAutoresizingMaskIntoConstraints = false; scroll.documentView = content
            content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
            window.contentView = scroll; self.content = content; self.window = window; window.center()
        }
        render(); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    private func label(_ text: String, compact: Bool = false) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text); label.maximumNumberOfLines = 4; label.textColor = compact ? .white : MonitorTheme.foreground
        return label
    }
    private func choose(_ id: DecisionID) {
        clearInput(); selected = id; session = InputSession(request: id); selectionIsAutomatic = false; detail = nil; errorMessage = nil; render()
    }
    private func clearInput() { interactionGeneration = UUID(); input.finish(); session?.clear(); session = nil; optionPage = 0; draft = ""; inputLabels.forEach { $0.stringValue = "" }; inputLabels.removeAll() }
    private func back() { clearInput(); selected = nil; detail = nil; suppressAutomatic = true; render() }
    private var interactionIdentity: String {
        "\(interactionGeneration)/\(String(describing: selected))/\(String(describing: detail))/\(questionIndex)/\(input.active)/\(page)/\(optionPage)/\(decisionPage)"
    }
    private func makeControls(compact: Bool) -> NSView {
        let stack = NSStackView(); stack.orientation = compact ? .horizontal : .vertical; stack.spacing = 8; stack.alignment = compact ? .centerY : .leading
        func label(_ text: String) -> NSTextField { self.label(text, compact: compact) }
        let identity = interactionIdentity
        func guardedButton(_ title: String, _ action: @escaping () -> Void) -> ActionButton {
            ActionButton(title) { [weak self] in
                guard self?.interactionIdentity == identity else { return }
                action()
            }
        }
        func add(_ title: String, _ action: @escaping () -> Void) {
            let button = guardedButton(title, action)
            if MonitorTheme.name == "custom" { button.bezelColor = MonitorTheme.accent }
            if title.hasPrefix("⚠") {
                button.title = String(title.dropFirst()).trimmingCharacters(in: .whitespaces)
                button.image = WaitingIcon.image; button.imagePosition = .imageLeading
                button.setAccessibilityLabel("Waiting for reply: " + button.title)
                warningButtons.append(button)
            }
            stack.addArrangedSubview(button)
        }
        if let selected, let request = manager.decisions[selected] {
            add(compact ? "‹" : "‹ Tasks") { [weak self] in self?.back() }
            let title = manager.store.executions[selected.execution]?.title ?? "Task"
            stack.addArrangedSubview(label(compact ? String(title.prefix(10)) + (input.active ? "" : " · " + String(request.prompt.prefix(18))) : title + " · " + request.prompt))
            if request.sent {
                stack.addArrangedSubview(label(request.deliveryUncertain ? "Reply sent; confirmation unavailable. Check Codex before retrying." : "Waiting for server confirmation…"))
                add("Open Codex") { [weak self] in self?.openTask(selected.execution) }; return stack
            }
            guard request.supported else { add("Open Codex") { [weak self] in self?.openCodex?() }; return stack }
            if request.isInput {
                guard questionIndex < request.questions.count else {
                    add("Retry sending") { [weak self] in
                        guard let self else { return }
                        if let result = self.session?.response() { self.send(selected, result) }
                    }
                    return stack
                }
                let question = request.questions[questionIndex]
                let prompt = question["question"] as? String ?? "Reply"
                if !compact { stack.addArrangedSubview(label("\(questionIndex+1)/\(request.questions.count) · \(prompt)")) }
                let options = question["options"] as? [[String: Any]] ?? []
                if optionPage * 3 >= options.count { optionPage = 0 }
                for option in options.dropFirst(optionPage * 3).prefix(input.active ? 0 : 3) {
                    let title = option["label"] as? String ?? "Option"
                    let button = guardedButton(title) { [weak self] in self?.answer(title) }
                    button.toolTip = option["description"] as? String; stack.addArrangedSubview(button)
                }
                if !input.active && options.count > 3 { add("More… \(optionPage + 1)/\((options.count + 2) / 3)") { [weak self] in
                    guard let self else { return }; self.optionPage = (self.optionPage + 1) % ((options.count + 2) / 3); self.render()
                } }
                if options.isEmpty || question["isOther"] as? Bool == true {
                    if input.active {
                        let preview = label(input.preview)
                        if compact { preview.widthAnchor.constraint(equalToConstant: 200).isActive = true }
                        inputLabels.append(preview); stack.addArrangedSubview(preview)
                        add("Send") { [weak self] in self?.input.submit() }
                        add("Cancel") { [weak self] in self?.input.cancel() }
                    } else {
                        // Touch Bar text capture is deferred by the user after hardware validation.
                        // Leave the request pending and finish free-text replies in Codex.
                        add("Open Codex") { [weak self] in self?.openTask(selected.execution) }
                    }
                }
            } else {
                if !compact {
                    let keys = ["command", "cwd", "grantRoot", "permissions"]
                    for key in keys {
                        if let value = request.params[key] { stack.addArrangedSubview(label("\(key): \(value)")) }
                    }
                }
                // The desktop details remain available before deciding on truncated Touch Bar content.
                add(compact ? "ⓘ" : "Details") { [weak self] in self?.show() }
                if let result = request.approval(allow: true) { add(compact ? "Once" : "Allow once") { [weak self] in self?.send(selected, result) } }
                if let result = request.approval(allow: true, forSession: true) {
                    add(compact ? "Session" : "Allow session") { [weak self] in self?.send(selected, result) }
                }
                if let result = request.approval(allow: false) { add("Reject") { [weak self] in self?.send(selected, result) } }
            }
        } else if let detail, let execution = manager.store.executions[detail] {
            add(compact ? "‹" : "‹ Tasks") { [weak self] in self?.back() }
            let duration = label(durationText(execution))
            if compact { duration.widthAnchor.constraint(lessThanOrEqualToConstant: 280).isActive = true }
            durationLabels.append((duration, execution.id)); stack.addArrangedSubview(duration)
            if !compact, let cwd = execution.cwd { stack.addArrangedSubview(label(cwd)) }
            for request in manager.queue where request.id.execution == detail { add("⚠ " + String(request.prompt.prefix(30))) { [weak self] in self?.choose(request.id) } }
            if execution.state.terminal {
                add("Acknowledge") { [weak self] in self?.manager.acknowledge(detail) }
            }
            add("Open task") { [weak self] in self?.openTask(detail) }
        } else if !manager.queue.isEmpty && (manager.queue.count > 1 || suppressAutomatic) {
            stack.addArrangedSubview(label(compact ? "⚠ \(manager.queue.count)" : "Choose a decision (\(manager.queue.count) pending)"))
            if decisionPage * 3 >= manager.queue.count { decisionPage = 0 }
            for request in manager.queue.dropFirst(decisionPage * 3).prefix(3) {
                let title = manager.store.executions[request.id.execution]?.title ?? "Task"
                add("⚠ " + String(title.prefix(compact ? 12 : 40)) + (compact ? "" : " · " + String(request.prompt.prefix(70)))) { [weak self] in self?.choose(request.id) }
            }
            if manager.queue.count > 3 { add("More decisions…") { [weak self] in
                guard let self else { return }; self.decisionPage = (self.decisionPage + 1) % ((self.manager.queue.count + 2) / 3); self.render()
            } }
        } else {
            let values = manager.store.sorted
            let count = max(1, min(6, UserDefaults.standard.integer(forKey: "MaximumVisibleTasks") == 0 ? 4 : UserDefaults.standard.integer(forKey: "MaximumVisibleTasks")))
            if page * count >= values.count { page = 0 }
            if values.isEmpty { stack.addArrangedSubview(label("No monitored executions")) }
            for value in values.dropFirst(page * count).prefix(count) {
                let icon = value.state == .waitingDecision ? "⚠" : value.state == .completed ? "🟢" : value.state == .failed ? "🔴" : value.state == .running ? "🟡" : value.state == .paused ? "⏸" : "⚪"
                let remote = value.id.serverID.hasPrefix("desktop-ipc:remote-")
                let origin = compact && remote ? (SettingsController.isEnglish ? "Remote · " : "远端·") : ""
                add(icon + " " + origin + String(value.title.prefix(compact ? (remote ? 8 : 12) : 60))) { [weak self] in
                    guard let self else { return }
                    if value.state.terminal && value.state != .paused { self.manager.acknowledge(value.id) }
                    else { self.detail = value.id; self.render() }
                }
            }
            if values.count > count { add("+\(max(0, values.count - count)) ›") { [weak self] in guard let self else { return }; self.page = (self.page + 1) % ((values.count + count - 1) / count); self.render() } }
            for request in manager.queue { add("⚠ " + String((manager.store.executions[request.id.execution]?.title ?? "Task").prefix(14))) { [weak self] in self?.choose(request.id) } }
        }
        return stack
    }
    private func performControl(_ action: @escaping () async throws -> Void) {
        Task { @MainActor [weak self] in
            do { try await action(); self?.errorMessage = nil }
            catch { self?.errorMessage = error is ExecutionManager.ControlError ? error.localizedDescription : "Control request not confirmed. Refresh and check Codex before trying again." }
            self?.render()
        }
    }
    private func telemetryText(_ data: ExecutionTelemetry) -> [String] {
        var lines: [String] = []
        lines.append(data.plan.map { "Plan: \(data.completedSteps)/\($0.count) completed steps" + (data.planStale ? " · last known" : "") } ?? "Plan: not reported")
        if let used = data.contextTokens {
            lines.append("Context estimate: \(used)" + (data.contextWindow.map { " / \($0) tokens" } ?? " tokens · capacity unknown") + (data.contextStale ? " · last known" : ""))
        } else { lines.append("Context estimate: not reported") }
        if let total = data.totalTokens { lines.append("Cumulative thread tokens: \(total)") }
        lines.append(data.agentsReported ? "Sub-agents observed this turn: \(data.activeAgents) active / \(data.agents.count) known" + (data.agentsStale ? " · last known" : "") : "Sub-agents: not reported")
        if data.agentsReported {
            let groups = Dictionary(grouping: data.agents.values, by: { $0 }).map { "\($0.key): \($0.value.count)" }.sorted()
            if !groups.isEmpty { lines.append(groups.joined(separator: " · ")) }
        }
        if data.currentActivities.isEmpty { lines.append("Current tool / command: none reported") }
        for activity in data.currentActivities {
            lines.append("Tool: " + activity.tool)
            if let command = activity.command { lines.append("Command: " + command) }
        }
        return lines
    }
    private func answer(_ text: String) {
        guard let selected, let request = manager.decisions[selected], questionIndex < request.questions.count,
              let key = request.questions[questionIndex]["id"] as? String else { return }
        interactionGeneration = UUID()
        input.finish(); if session == nil { session = InputSession(request: selected) }
        session?.answer(question: key, text: text); draft = ""; optionPage = 0
        if questionIndex == request.questions.count, let result = session?.response() { send(selected, result) }
        else { render() }
    }
    private func send(_ id: DecisionID, _ result: [String: Any]) {
        do {
            // Clear before invoking manager callbacks; a successful write must not leave secret answers in views.
            clearInput(); suppressAutomatic = true
            try manager.respond(id, result: result); errorMessage = nil
        } catch { errorMessage = "Reply was not sent. Please enter your answers again or open Codex." }
        render()
    }
    private func confirm(_ title: String, detail: String, action: @escaping () -> Void) {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = detail
        alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Confirm")
        if alert.runModal() == .alertSecondButtonReturn { action() }
    }
    private func durationText(_ value: MonitoredExecution) -> String {
        let seconds = max(0, Int((value.completedAt ?? Date()).timeIntervalSince(value.startedAt)))
        return "\(value.title) · \(value.state.rawValue) · \(seconds / 60)m\(seconds % 60)s · \(value.activity)"
    }
    private func updateDurationTimer() {
        if detail != nil && durationTimer == nil {
            durationTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    for (label, id) in self.durationLabels { if let value = self.manager.store.executions[id] { label.stringValue = self.durationText(value) } }
                }
            }
        } else if detail == nil { durationTimer?.invalidate(); durationTimer = nil }
    }
    private func openTask(_ id: ExecutionID) {
        guard !manager.demo else { return }
        var components = URLComponents(); components.scheme = "codex"; components.host = "threads"; components.path = "/" + id.threadID
        if let url = components.url, NSWorkspace.shared.urlForApplication(toOpen: url) != nil { NSWorkspace.shared.open(url) }
        else { openCodex?() }
    }
    @objc func returnToNative() {
        nativeDismissed = true; manuallyRequested = false
        if input.active { input.cancel() }
        if let bar = taskTouchBar, dynamicPresented { CTBDismissDynamic(bar) }
        dynamicPresented = false
    }
    func showBackgroundControls() {
        if let bar = taskTouchBar { CTBDismissDynamic(bar) }
        dynamicPresented = false; taskTouchBar = nil; controlsItem = nil; touchScroll = nil; lastControlsSignature = ""
        manuallyRequested = true; nativeDismissed = false; updateTouchBar()
        if CommandLine.arguments.contains("--interaction-diagnostics") { print("TRAY show-controls requested; executions=\(manager.store.sorted.count) decisions=\(manager.queue.count) presented=\(dynamicPresented)"); fflush(stdout) }
    }
    private func updateTouchBar() {
        let attention = Set(manager.queue.map { $0.id })
        if !attention.subtracting(lastAttention).isEmpty { nativeDismissed = false }
        lastAttention = attention
        guard manuallyRequested || manager.state.showsDynamicArea || input.active else {
            if let bar = taskTouchBar, dynamicPresented { CTBDismissDynamic(bar) }
            dynamicPresented = false; nativeDismissed = false; window?.touchBar = nil
            return
        }
        if taskTouchBar == nil {
            let bar = NSTouchBar(); bar.delegate = self
            bar.defaultItemIdentifiers = [.init("monitor.controls")]
            taskTouchBar = bar
            touchBarVisibility = bar.observe(\.isVisible, options: [.old, .new]) { [weak self] observed, change in
                guard change.oldValue == true, change.newValue == false else { return }
                Task { @MainActor [weak self] in
                    guard let self, self.taskTouchBar === observed, self.dynamicPresented else { return }
                    // The system close button dismisses without calling returnToNative.
                    self.dynamicPresented = false; self.nativeDismissed = true; self.manuallyRequested = false
                    if CommandLine.arguments.contains("--interaction-diagnostics") { print("TRAY system-dismissed"); fflush(stdout) }
                }
            }
        }
        let signature = interactionIdentity
            + "\(page)/\(optionPage)/\(decisionPage)/\(questionIndex)/\(input.active)/\(suppressAutomatic)"
            + manager.store.sorted.map { "\($0.id):\($0.title):\($0.state):\($0.activity)" }.joined()
            + manager.queue.map { "\($0.id):\($0.prompt):\($0.sent):\($0.deliveryUncertain)" }.joined()
        if signature != lastControlsSignature {
            lastControlsSignature = signature
            if let controlsItem {
                let view = makeTouchBarControls()
                if controlsItem.view !== view { controlsItem.view = view }
            }
        }
        // This mode was explicitly accepted after the physical placement-0 probe:
        // temporarily replace app controls, retain Control Strip, never activate NSApp.
        if !nativeDismissed, !dynamicPresented, !CommandLine.arguments.contains("--disable-private-api"), let bar = taskTouchBar {
            // Materialize and lay out cached items before the system displays them.
            for identifier in bar.defaultItemIdentifiers {
                (bar.item(forIdentifier: identifier) as? NSCustomTouchBarItem)?.view.layoutSubtreeIfNeeded()
            }
            dynamicPresented = CTBPresentDynamic(bar)
        }
    }
    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        let item = NSCustomTouchBarItem(identifier: identifier)
        controlsItem = item; item.view = makeTouchBarControls(); return item
    }
    private func makeTouchBarControls() -> NSView {
        let scroll = touchScroll ?? NSScrollView(frame: .init(x: 0, y: 0, width: 480, height: 30))
        touchScroll = scroll
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false; scroll.hasVerticalScroller = false
        scroll.horizontalScrollElasticity = .automatic
        inputLabels.removeAll()
        let controls = makeControls(compact: true)
        for view in (controls as? NSStackView)?.arrangedSubviews ?? [] {
            if let label = view as? NSTextField {
                label.maximumNumberOfLines = 1; label.lineBreakMode = .byTruncatingTail
            }
        }
        let size = controls.fittingSize
        let height = min(30, size.height)
        let document = NSView(frame: .init(x: 0, y: 0, width: max(480, size.width), height: 30))
        controls.frame = .init(x: 0, y: (30 - height) / 2, width: size.width, height: height)
        document.addSubview(controls)
        scroll.documentView = document
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        document.layoutSubtreeIfNeeded()
        return scroll
    }
    func runUIChecks(output: String) throws {
        var checks = 0
        func check(_ value: Bool) { precondition(value, "UI self-check failed"); checks += 1 }
        show()
        check(manager.queue.count == 2 && selected == nil)
        capture(output + "/dashboard-demo.png")
        let approval = manager.queue.first { !$0.isInput }!
        choose(approval.id)
        check(selected == approval.id)
        send(approval.id, approval.approval(allow: false)!)
        check(manager.decisions[approval.id] == nil && selected == nil)
        let request = manager.queue.first { $0.isInput }!
        choose(request.id)
        let replyButtons = (makeControls(compact: true) as? NSStackView)?.arrangedSubviews.compactMap { $0 as? ActionButton } ?? []
        check(replyButtons.contains { $0.title == "Open Codex" })
        check(!replyButtons.contains { $0.title == "Other…" || $0.title.hasPrefix("⌨") })
        replyButtons.first { $0.title == "Open Codex" }?.performClick(nil)
        check(!input.active && manager.decisions[request.id] != nil)
        input.begin(text: "")
        render()
        let layoutHost = NSWindow(contentRect: .init(x: 0, y: 0, width: 480, height: 30), styleMask: [], backing: .buffered, defer: false)
        let compactView = makeTouchBarControls()
        layoutHost.contentView = compactView
        compactView.layoutSubtreeIfNeeded()
        if let scroll = compactView as? NSScrollView, let stack = scroll.documentView?.subviews.first as? NSStackView {
            for view in stack.arrangedSubviews where ["Send", "Cancel"].contains((view as? NSButton)?.title ?? "") {
                let rect = view.convert(view.bounds, to: scroll.contentView)
                check(rect.minX >= 0 && rect.maxX <= 480)
            }
        }
        try input.exerciseComposition()
        check(draft == "功能分支🚀")
        capture(output + "/input-demo.png")
        input.submit()
        check(manager.decisions[request.id] == nil)
        check(!input.active)
        let completed = manager.store.sorted.first { $0.state == .completed }!
        manager.acknowledge(completed.id)
        check(manager.store.executions[completed.id] == nil)
        manager.requested(.string("secure-ui"), "item/tool/requestUserInput", ["threadId": "secure-ui", "turnId": "1", "questions": [["id": "secret", "question": "Secret fixture", "isSecret": true]]])
        let secure = manager.queue.first { $0.id.request == .string("secure-ui") }!
        choose(secure.id); input.begin(text: "", secure: true); render()
        try input.exerciseSecureInput()
        check(draft.isEmpty && !input.preview.contains("fixture") && input.preview.contains("•"))
        capture(output + "/secure-input-demo.png")
        input.submit()
        check(manager.decisions[secure.id] == nil && session == nil && draft.isEmpty && !input.active)
        manager.requested(.string("multi-ui"), "item/tool/requestUserInput", ["threadId": "multi-ui", "turnId": "1", "questions": [
            ["id": "one", "question": "First", "options": (1...8).map { ["label": "Option \($0)", "description": "Fixture"] }],
            ["id": "two", "question": "Second", "isOther": true]
        ]])
        let multi = manager.queue.first { $0.id.request == .string("multi-ui") }!
        choose(multi.id)
        let options = (makeControls(compact: true) as? NSStackView)?.arrangedSubviews.compactMap { $0 as? ActionButton }.filter { $0.title.hasPrefix("Option") } ?? []
        check(options.count == 3)
        optionPage = 1
        let next = (makeControls(compact: true) as? NSStackView)?.arrangedSubviews.compactMap { $0 as? ActionButton }.filter { $0.title.hasPrefix("Option") } ?? []
        check(next.first?.title == "Option 4")
        next[0].performClick(nil); check(questionIndex == 1)
        next[0].performClick(nil)
        check(questionIndex == 1 && manager.decisions[multi.id] != nil)
        input.begin(text: ""); render(); try input.exerciseSelection()
        check(draft == "replacement")
        input.cancel(); check(!input.active && session == nil && draft.isEmpty)
        choose(multi.id); answer("Option 1"); answer("中文第二问")
        check(manager.decisions[multi.id] == nil && session == nil)
        back(); detail = manager.store.sorted.first { $0.state == .running }!.id
        render()
        let detailTitles = (makeControls(compact: true) as? NSStackView)?.arrangedSubviews.compactMap { ($0 as? ActionButton)?.title } ?? []
        check(detailTitles == ["‹", "Open task"])
        choose(multi.id)
        back()
        check(selected == nil && detail == nil)
        capture(output + "/baseline-detail.png")
        print("PASS: \(checks) UI flow assertions plus native NSTextView composition; no Touch Bar required")
    }
    private func capture(_ path: String) {
        guard let view = window?.contentView else { return }
        view.appearance = MonitorTheme.appearance
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let image = NSImage(size: view.bounds.size)
        image.lockFocus()
        NSColor.windowBackgroundColor.setFill(); view.bounds.fill()
        bitmap.draw(in: view.bounds)
        image.unlockFocus()
        if let tiff = image.tiffRepresentation, let flattened = NSBitmapImageRep(data: tiff) {
            try? flattened.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }
    func windowWillClose(_ notification: Notification) { if input.active { input.cancel() } }
    func recoverTray() { dynamicPresented = false; render() }
    func stop() { returnToNative(); clearInput(); durationTimer?.invalidate(); flash?.invalidate(); window?.touchBar = nil; taskTouchBar = nil }
}
