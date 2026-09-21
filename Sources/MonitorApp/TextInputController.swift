import AppKit
import MonitorCore

final class InputPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
@MainActor final class InputTextView: NSTextView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "a": selectAll(nil)
            case "c": copy(nil)
            case "v": paste(nil)
            case "x": cut(nil)
            default: return super.performKeyEquivalent(with: event)
            }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
@MainActor final class TextInputController: NSObject, NSTextViewDelegate, NSTextFieldDelegate, NSWindowDelegate {
    private var panel: InputPanel?
    private var editor: InputTextView?
    private var secureField: NSSecureTextField?
    private var previousApp: NSRunningApplication?
    private weak var previousWindow: NSWindow?
    private var finishing = false
    private(set) var secure = false
    private(set) var preview = "⌨ ▏"
    var onChange: ((String) -> Void)?
    var onPreview: ((String) -> Void)?
    var onSubmit: ((String) -> Void)?
    var onCancel: (() -> Void)?
    var active: Bool { panel != nil }
    func begin(text: String, secure: Bool = false) {
        guard panel == nil else { return }
        self.secure = secure
        previousApp = NSWorkspace.shared.frontmostApplication; previousWindow = NSApp.keyWindow
        let screen = NSScreen.main?.visibleFrame ?? .init(x: 0, y: 0, width: 800, height: 600)
        let panel = InputPanel(contentRect: .init(x: screen.midX - 220, y: screen.minY + 36, width: 440, height: 36), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.isFloatingPanel = true; panel.level = .floating; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false; panel.delegate = self
        self.panel = panel
        if secure {
            let field = NSSecureTextField(frame: .init(x: 0, y: 0, width: 440, height: 36))
            field.isBordered = false; field.drawsBackground = false; field.textColor = .clear
            field.delegate = self; field.stringValue = ""; secureField = field
            panel.contentView = field; focus(panel, responder: field)
        } else {
            let editor = InputTextView(frame: .init(x: 0, y: 0, width: 440, height: 36))
            editor.isRichText = false; editor.drawsBackground = false; editor.textColor = .clear
            editor.insertionPointColor = .clear; editor.delegate = self; editor.string = text
            editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticDashSubstitutionEnabled = false
            editor.isAutomaticSpellingCorrectionEnabled = false; editor.allowsUndo = true
            editor.isAutomaticTextCompletionEnabled = false
            panel.contentView = editor; self.editor = editor
            focus(panel, responder: editor)
            editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        }
        publish()
        if CommandLine.arguments.contains("--input-diagnostics") {
            print("INPUT begin key=\(panel.isKeyWindow) active=\(NSApp.isActive) front=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none")")
            fflush(stdout)
        }
    }
    private func focus(_ panel: InputPanel, responder: NSResponder) {
        panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(responder)
    }
    private func publish() {
        if secure {
            // No plaintext is sent to display callbacks or stored in UI state.
            preview = InputPreview.text(secureField?.stringValue ?? "", selection: NSRange(location: 0, length: 0), secure: true)
            onChange?("")
        } else {
            let value = editor?.string ?? ""
            preview = InputPreview.text(value, selection: editor?.selectedRange() ?? NSRange(location: 0, length: 0), secure: false)
            onChange?(value)
        }
        onPreview?(preview)
    }
    func textDidChange(_ notification: Notification) { publish() }
    func textViewDidChangeSelection(_ notification: Notification) { publish() }
    func controlTextDidChange(_ obj: Notification) { publish() }
    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool { command(textView, selector) }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool { command(textView, commandSelector) }
    private func command(_ textView: NSTextView, _ selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            guard !textView.hasMarkedText() else { return false }; submit(); return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            if textView.hasMarkedText() { textView.unmarkText(); publish(); return true }
            cancel(); return true
        }
        return false
    }
    func submit() {
        guard active else { return }
        let fieldEditor = secureField?.currentEditor() as? NSTextView
        guard !(editor?.hasMarkedText() ?? false), !(fieldEditor?.hasMarkedText() ?? false) else { return }
        let value = secure ? (secureField?.stringValue ?? "") : (editor?.string ?? "")
        finish(); onSubmit?(value)
    }
    func cancel() { finish(); onCancel?() }
    func windowDidResignKey(_ notification: Notification) {
        guard active, !finishing else { return }
        if CommandLine.arguments.contains("--input-diagnostics") { print("INPUT resign-key front=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none")"); fflush(stdout) }
        // Switching applications while capturing ends capture, never steals focus back.
        finish(restoreFocus: false); onCancel?()
    }
    func exerciseComposition() throws {
        guard let editor else { throw CocoaError(.validationMissingMandatoryProperty) }
        editor.setMarkedText("gongneng", selectedRange: NSRange(location: 8, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        precondition(editor.hasMarkedText()); submit(); precondition(active)
        editor.insertText("功能分支🚀", replacementRange: NSRange(location: NSNotFound, length: 0))
        precondition(!editor.hasMarkedText()); publish()
    }
    func exerciseSecureInput() throws {
        guard let field = secureField else { throw CocoaError(.validationMissingMandatoryProperty) }
        field.stringValue = "fixture-secret-仅用于测试"; publish()
        precondition(!preview.contains("fixture") && !preview.contains("测试"))
    }
    func exerciseSelection() throws {
        guard let editor else { throw CocoaError(.validationMissingMandatoryProperty) }
        editor.string = String(repeating: "a", count: 100) + "光标" + String(repeating: "z", count: 100)
        editor.setSelectedRange(NSRange(location: 102, length: 0)); publish()
        precondition(preview.contains("光标▏") && preview.contains("…"))
        editor.selectAll(nil); editor.insertText("replacement", replacementRange: editor.selectedRange()); publish()
        precondition(editor.string == "replacement")
        let pasteboard = NSPasteboard(name: .init("monitor-test-" + UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        editor.selectAll(nil)
        let types = editor.writablePasteboardTypes
        precondition(!types.isEmpty)
        pasteboard.declareTypes(types, owner: nil)
        precondition(editor.writeSelection(to: pasteboard, types: types))
        editor.string = ""
        precondition(editor.readSelection(from: pasteboard, type: types[0]))
        precondition(editor.string == "replacement")
        publish()
    }
    func finish(restoreFocus: Bool = true) {
        guard let panel else { return }; finishing = true
        let shouldRestore = restoreFocus && panel.isKeyWindow
        editor?.delegate = nil; editor?.undoManager?.removeAllActions(); editor?.string = ""; editor = nil
        secureField?.delegate = nil
        secureField?.currentEditor()?.undoManager?.removeAllActions()
        secureField?.currentEditor()?.string = ""
        secureField?.stringValue = ""; secureField = nil
        panel.delegate = nil; panel.makeFirstResponder(nil); panel.orderOut(nil); panel.contentView = nil; panel.close(); self.panel = nil
        preview = "⌨ ▏"; secure = false
        if shouldRestore {
            if previousApp?.processIdentifier == ProcessInfo.processInfo.processIdentifier { previousWindow?.makeKey() }
            else { previousApp?.activate(options: []) }
        }
        previousApp = nil; previousWindow = nil; finishing = false
    }
}
