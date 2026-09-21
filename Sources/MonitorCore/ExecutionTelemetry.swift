import Foundation

/// Only protocol-reported values. A plan's completed steps are not an estimate of remaining time.
public struct ExecutionTelemetry {
    public struct Step: Equatable {
        public let title: String
        public let status: String
    }
    public struct Activity: Equatable {
        public let tool: String
        public let command: String?
    }
    public private(set) var plan: [Step]?
    public private(set) var contextTokens: Int?
    public private(set) var contextWindow: Int?
    public private(set) var totalTokens: Int?
    public private(set) var agents: [String: String] = [:]
    public private(set) var agentsReported = false
    public private(set) var activities: [String: Activity] = [:]
    private var activityOrder: [String] = []
    public private(set) var planStale = false
    public private(set) var contextStale = false
    public private(set) var agentsStale = false
    public init() {}
    public var completedSteps: Int { plan?.filter { $0.status == "completed" }.count ?? 0 }
    public var planFraction: Double? {
        guard let plan, !plan.isEmpty else { return nil }
        return Double(completedSteps) / Double(plan.count)
    }
    public var contextFraction: Double? {
        guard let contextTokens, let contextWindow, contextWindow > 0 else { return nil }
        return min(1, Double(contextTokens) / Double(contextWindow))
    }
    public var activeAgents: Int { agents.values.filter { ["running", "pendingInit"].contains($0) }.count }
    public var currentActivities: [Activity] { activityOrder.compactMap { activities[$0] } }
    public mutating func updatePlan(_ payload: [String: Any]) {
        guard let values = payload["plan"] as? [[String: Any]] else { return }
        plan = values.prefix(200).compactMap { value in
            guard let title = value["step"] as? String, let status = value["status"] as? String,
                  ["pending", "inProgress", "completed"].contains(status) else { return nil }
            return Step(title: String(title.prefix(512)), status: status)
        }
        planStale = false
    }
    public mutating func updateUsage(_ payload: [String: Any]) {
        guard let usage = payload["tokenUsage"] as? [String: Any], let last = usage["last"] as? [String: Any] else { return }
        // last.totalTokens is the latest model context estimate; cumulative total is separately labelled.
        contextTokens = nonnegative(last["totalTokens"])
        contextWindow = nonnegative(usage["modelContextWindow"]).flatMap { $0 > 0 ? $0 : nil }
        totalTokens = (usage["total"] as? [String: Any]).flatMap { nonnegative($0["totalTokens"]) }
        contextStale = false
    }
    public mutating func updateItem(_ item: [String: Any], completed: Bool) {
        guard let id = item["id"] as? String, let type = item["type"] as? String else { return }
        if type == "collabAgentToolCall" {
            agentsReported = true; agentsStale = false
            let states = item["agentsStates"] as? [String: [String: Any]] ?? [:]
            for agent in item["receiverThreadIds"] as? [String] ?? [] where agents[agent] == nil && agents.count < 256 {
                agents[agent] = "unknown"
            }
            for (agent, value) in states where agents[agent] != nil || agents.count < 256 {
                agents[agent] = value["status"] as? String ?? "unknown"
            }
        }
        if completed {
            activities.removeValue(forKey: id); activityOrder.removeAll { $0 == id }; return
        }
        guard ["commandExecution", "mcpToolCall", "dynamicToolCall", "collabAgentToolCall", "fileChange", "webSearch"].contains(type) else { return }
        let name = item["tool"] as? String ?? type
        let namespace = item["server"] as? String ?? item["namespace"] as? String
        let tool = namespace.map { $0 + "." + name } ?? name
        activities[id] = Activity(tool: String(tool.prefix(160)), command: (item["command"] as? String).map { String($0.prefix(1024)) })
        activityOrder.removeAll { $0 == id }; activityOrder.append(id)
        while activityOrder.count > 32 { activities.removeValue(forKey: activityOrder.removeFirst()) }
    }
    public mutating func finish() { activities.removeAll(); activityOrder.removeAll() }
    public mutating func disconnect() {
        finish(); planStale = true; contextStale = true; agentsStale = true
    }
    private func nonnegative(_ value: Any?) -> Int? {
        guard let value, let id = RPCID(value), case .number(let number) = id, number >= 0 else { return nil }
        return number
    }
}
