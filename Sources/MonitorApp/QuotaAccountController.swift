import AppKit

@MainActor final class QuotaAccountController: NSObject, NSWindowDelegate {
    let binding = QuotaAccountBinding()
    var onChanged: (() -> Void)?
    private var window: NSWindow?
    private let source = NSTextField(wrappingLabelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let explanation = NSTextField(wrappingLabelWithString: "")
    private var signIn: ActionButton!
    private var cancelButton: ActionButton!
    private var desktopButton: ActionButton!
    private var reopenButton: ActionButton!
    private var readTask: Task<Void, Never>?
    private var displayedAccount: String?
    private var accountReadFinished = false
    private func text(_ zh: String, _ en: String) -> String { SettingsController.isEnglish ? en : zh }
    override init() {
        super.init()
        binding.openBrowser = { NSWorkspace.shared.open($0) }
        binding.onChange = { [weak self] in self?.render() }
        binding.onCommitted = { [weak self] in self?.onChanged?() }
    }
    func show() {
        if window == nil {
            let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 560, height: 360), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.delegate = self
            let container = NSView()
            let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 18
            stack.translatesAutoresizingMaskIntoConstraints = false; container.addSubview(stack)
            NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
                stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
                stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 24)])
            source.font = .boldSystemFont(ofSize: 14)
            explanation.textColor = .secondaryLabelColor; explanation.font = .systemFont(ofSize: 12)
            for label in [source, detail, explanation] {
                stack.addArrangedSubview(label); label.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
            signIn = ActionButton("") { [weak self] in self?.displayedAccount = nil; self?.binding.begin() }
            cancelButton = ActionButton("") { [weak self] in self?.binding.cancel() }
            desktopButton = ActionButton("") { [weak self] in self?.binding.useDesktop(); self?.displayedAccount = nil; self?.render() }
            reopenButton = ActionButton("") { [weak self] in
                if let url = self?.binding.loginURL { NSWorkspace.shared.open(url) }
            }
            let actions = NSStackView(views: [signIn, cancelButton, reopenButton]); actions.spacing = 12
            stack.addArrangedSubview(actions); stack.addArrangedSubview(desktopButton)
            window.contentView = container; self.window = window; window.center()
        }
        render(); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        refreshAccount()
    }
    func languageChanged() { if window != nil { render() } }
    private func refreshAccount() {
        readTask?.cancel(); accountReadFinished = false
        readTask = Task { [weak self] in
            guard let self else { return }
            let label = await binding.readAccount()
            guard !Task.isCancelled else { return }
            displayedAccount = label; accountReadFinished = true; render()
        }
    }
    private func render() {
        guard window != nil else { return }
        window?.title = text("额度账号", "Quota account")
        let bound = binding.store.selectedHome != nil
        source.stringValue = bound ? text("额度来源：独立绑定账号", "Quota source: separately linked account") : text("额度来源：Codex 当前账号", "Quota source: current Codex account")
        explanation.stringValue = text("仅影响 Touch Bar 额度，不改变 Codex 登录或正在运行的任务。请在浏览器中选择需要绑定的账号；成功前仍使用原额度来源。", "Only changes Touch Bar quota. Codex sign-in and running tasks stay unchanged. Choose the account in your browser; the current quota source remains until verification succeeds.")
        signIn.title = text("绑定 / 更换账号…", "Link / change account…")
        signIn.isEnabled = !binding.busy
        cancelButton.title = text("取消登录", "Cancel sign-in"); cancelButton.isHidden = !binding.busy
        reopenButton.title = text("打开登录页", "Open sign-in page"); reopenButton.isHidden = binding.loginURL == nil
        desktopButton.title = text("恢复使用 Codex 当前账号", "Use current Codex account")
        desktopButton.isEnabled = bound && !binding.busy
        switch binding.state {
        case .starting: detail.stringValue = text("正在准备安全登录…", "Preparing sign-in…")
        case .waiting: detail.stringValue = text("请在浏览器完成登录。可取消或重新打开登录页。", "Complete sign-in in your browser. You can cancel or reopen the sign-in page.")
        case .verifying: detail.stringValue = text("登录成功，正在核对账号和额度…", "Signed in. Verifying the account and quota…")
        case .failed: detail.stringValue = text("绑定未完成，原额度来源保持不变。请检查网络后重试；账号需提供 ChatGPT 周额度。", "Linking did not complete; your previous quota source is unchanged. Check connectivity and retry. The account must provide ChatGPT weekly quota.")
        case .cancelled: detail.stringValue = text("已取消，原额度来源保持不变。", "Cancelled. Your previous quota source is unchanged.")
        case .success: detail.stringValue = text("已绑定：", "Linked: ") + (binding.accountLabel ?? "")
        case .ready: detail.stringValue = bound ? (displayedAccount ?? (accountReadFinished ? text("暂时无法读取账号信息，可重开此窗口重试。", "Account details unavailable. Reopen this window to retry.") : text("正在读取绑定账号…", "Reading linked account…"))) : text("尚未单独绑定，可在下方登录另一个账号。", "No separate account linked. Sign in below to use another account.")
        }
    }
    func windowWillClose(_ notification: Notification) { binding.cancel(); readTask?.cancel() }
    func stop() { binding.cancel(); readTask?.cancel() }
}
