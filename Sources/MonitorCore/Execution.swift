import Foundation
import CoreFoundation

public struct ExecutionID: Hashable {
    public let serverID: String
    public let threadID: String
    public let turnID: String
    public init(serverID: String, threadID: String, turnID: String) {
        self.serverID = serverID; self.threadID = threadID; self.turnID = turnID
    }
}
public enum ExecutionState: String {
    case running, waitingDecision, completed, failed, paused, unknown
    public var priority: Int {
        switch self { case .waitingDecision: return 0; case .failed: return 1; case .completed: return 2; case .paused: return 3; case .running: return 4; case .unknown: return 5 }
    }
    public var terminal: Bool { self == .completed || self == .failed || self == .paused }
}
public struct MonitoredExecution {
    public let id: ExecutionID
    public var title: String
    public var cwd: String?
    public var state: ExecutionState
    public var startedAt: Date
    public var updatedAt: Date
    public var repository: String?
    public var completedAt: Date?
    public var activity: String
    public init(id: ExecutionID, title: String, cwd: String? = nil, state: ExecutionState = .running, startedAt: Date = Date(), activity: String = "") {
        self.id = id; self.title = title; self.cwd = cwd; self.state = state
        self.startedAt = startedAt; updatedAt = startedAt; self.activity = activity; repository = nil; completedAt = nil
    }
}
/// Owns turn identity; acknowledging an old turn can never remove a newer turn.
public struct ExecutionStore {
    public private(set) var executions: [ExecutionID: MonitoredExecution] = [:]
    private var acknowledged = Set<ExecutionID>()
    public init() {}
    public var sorted: [MonitoredExecution] {
        executions.values.sorted {
            if $0.state.priority != $1.state.priority { return $0.state.priority < $1.state.priority }
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return ($0.id.serverID + $0.id.threadID + $0.id.turnID) < ($1.id.serverID + $1.id.threadID + $1.id.turnID)
        }
    }
    public mutating func upsert(_ execution: MonitoredExecution) {
        guard !acknowledged.contains(execution.id) else { return }
        if let old = executions[execution.id], old.state.terminal && !execution.state.terminal { return }
        var value = execution
        if let old = executions[execution.id] {
            value.startedAt = min(old.startedAt, value.startedAt)
            if old.state == value.state { value.updatedAt = old.updatedAt }
        }
        executions[execution.id] = value
    }
    public mutating func transition(_ id: ExecutionID, to state: ExecutionState, activity: String? = nil) {
        guard var value = executions[id], !value.state.terminal || state.terminal else { return }
        if value.state != state { value.updatedAt = Date() }; value.state = state
        if state.terminal && value.completedAt == nil { value.completedAt = Date() }
        if let activity { value.activity = activity }
        executions[id] = value
    }
    public mutating func acknowledge(_ id: ExecutionID) {
        guard executions[id]?.state.terminal == true else { return }
        acknowledged.insert(id)
        executions.removeValue(forKey: id)
    }
    public mutating func disconnected(server: String) {
        for id in Array(executions.keys) where id.serverID == server && executions[id]?.state.terminal == false {
            transition(id, to: .unknown)
        }
    }
}
public enum RPCID: Hashable {
    case number(Int), string(String)
    public init?(_ value: Any) {
        if let string = value as? String { self = .string(string) }
        else if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                let integer = value as? Int { self = .number(integer) }
        else { return nil }
    }
    public var json: Any { switch self { case .number(let v): return v; case .string(let v): return v } }
}
public struct DecisionID: Hashable {
    public let execution: ExecutionID
    public let connection: UUID
    public let request: RPCID
    public init(execution: ExecutionID, connection: UUID, request: RPCID) {
        self.execution = execution; self.connection = connection; self.request = request
    }
}
public struct DecisionRequest {
    public let id: DecisionID
    public let method: String
    public let params: [String: Any]
    public let createdAt: Date
    public var sent = false
    public var deliveryUncertain = false
    public init(id: DecisionID, method: String, params: [String: Any]) {
        self.id = id; self.method = method; self.params = params; createdAt = Date()
    }
    public var questions: [[String: Any]] { params["questions"] as? [[String: Any]] ?? [] }
    public var isInput: Bool { method == "item/tool/requestUserInput" || method == "tool/requestUserInput" || method == "desktop/asyncQuestion" }
    public var prompt: String { params["reason"] as? String ?? params["command"] as? String ?? questions.first?["question"] as? String ?? method }
    public var supported: Bool {
        isInput || ["item/commandExecution/requestApproval", "item/fileChange/requestApproval", "item/permissions/requestApproval"].contains(method)
    }
    public func approval(allow: Bool, forSession: Bool = false) -> [String: Any]? {
        guard supported, !isInput else { return nil }
        if method == "item/permissions/requestApproval" {
            return ["permissions": allow ? (params["permissions"] as? [String: Any] ?? [:]) : [:], "scope": allow && forSession ? "session" : "turn"]
        }
        let decision = allow ? (forSession ? "acceptForSession" : "accept") : "decline"
        if let available = params["availableDecisions"] as? [Any], !available.contains(where: { ($0 as? String) == decision }) { return nil }
        return ["decision": decision]
    }
}
