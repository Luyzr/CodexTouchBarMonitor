import AppKit

/// Defer the single action so a double tap never activates Codex first.
@MainActor final class CompactTrayButton: NSButton {
    var onSingleTap: (() -> Void)?
    var onDoubleTap: (() -> Void)?
    private var pendingTap: DispatchWorkItem?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        target = self; action = #selector(tapped)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func tapped() {
        if CommandLine.arguments.contains("--interaction-diagnostics") { print("TRAY tap pending=\(pendingTap != nil)"); fflush(stdout) }
        if let pendingTap {
            pendingTap.cancel(); self.pendingTap = nil
            if CommandLine.arguments.contains("--interaction-diagnostics") { print("TRAY double"); fflush(stdout) }
            onDoubleTap?()
        } else {
            let pending = DispatchWorkItem { [weak self] in
                if CommandLine.arguments.contains("--interaction-diagnostics") { print("TRAY single"); fflush(stdout) }
                self?.pendingTap = nil; self?.onSingleTap?()
            }
            pendingTap = pending
            DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: pending)
        }
    }
}
