import Foundation

/// Keeps multi-question answers in memory only and overwrites the owned byte storage on release.
/// Native text-system / JSON serialization copies cannot be guaranteed to be zeroed by Swift.
public final class InputSession {
    public let request: DecisionID
    private var buffers: [String: [UInt8]] = [:]
    public private(set) var questionIndex = 0
    public init(request: DecisionID) { self.request = request }
    public var isEmpty: Bool { buffers.isEmpty }
    public func answer(question: String, text: String) {
        erase(question); buffers[question] = Array(text.utf8); questionIndex += 1
    }
    public func response() -> [String: Any] {
        ["answers": buffers.mapValues { ["answers": [String(decoding: $0, as: UTF8.self)]] }]
    }
    private func erase(_ key: String) {
        guard buffers[key] != nil else { return }
        buffers[key]!.withUnsafeMutableBufferPointer { buffer in buffer.initialize(repeating: 0) }
        buffers.removeValue(forKey: key)
    }
    public func clear() { for key in Array(buffers.keys) { erase(key) }; questionIndex = 0 }
    deinit { clear() }
}
public enum InputPreview {
    public static func text(_ text: String, selection: NSRange, secure: Bool, width: Int = 40) -> String {
        if secure { return text.isEmpty ? "⌨ ▏" : "⌨ " + String(repeating: "•", count: min(12, text.count)) + " ▏" }
        let source = text as NSString
        let offset = max(0, min(source.length, selection.location == NSNotFound ? source.length : selection.location))
        let start = source.rangeOfComposedCharacterSequences(for: NSRange(location: 0, length: offset)).length
        let prefix = String(source.substring(to: min(start, source.length)))
        let suffix = String(source.substring(from: min(start, source.length)))
        let left = String(prefix.suffix(max(1, width * 2 / 3)))
        let right = String(suffix.prefix(max(1, width / 3)))
        return "⌨ " + (prefix.count > left.count ? "…" : "") + left + "▏" + right + (suffix.count > right.count ? "…" : "")
    }
}
public struct AppState {
    public let isCodexForeground: Bool
    public let executions: [MonitoredExecution]
    public let decisions: [DecisionRequest]
    public let connected: Bool
    public init(isCodexForeground: Bool, executions: [MonitoredExecution], decisions: [DecisionRequest], connected: Bool) {
        self.isCodexForeground = isCodexForeground; self.executions = executions; self.decisions = decisions; self.connected = connected
    }
    public var showsDynamicArea: Bool {
        !decisions.isEmpty || executions.contains { $0.state != .running } || (!isCodexForeground && !executions.isEmpty)
    }
}
public enum TaskNaming {
    public static func title(_ thread: [String: Any], fallback: String) -> String {
        if let title = thread["name"] as? String, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return title }
        if let git = thread["gitInfo"] as? [String: Any], let origin = git["repositoryUrl"] as? String {
            let name = origin.split(separator: "/").last.map(String.init)?.replacingOccurrences(of: ".git", with: "") ?? ""
            if !name.isEmpty { return name }
        }
        if let cwd = thread["cwd"] as? String, !cwd.isEmpty { return URL(fileURLWithPath: cwd).lastPathComponent }
        return fallback
    }
}
