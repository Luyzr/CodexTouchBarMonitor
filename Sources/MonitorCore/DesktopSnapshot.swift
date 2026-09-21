import Foundation

/// Desktop IPC uses revisioned Immer patches, not JSON-RPC notifications.
public struct DesktopSnapshot {
    public private(set) var state: [String: Any] = [:]
    public private(set) var revision: Int?
    public init() {}
    public enum Failure: Error { case revisionGap, malformed }
    public mutating func apply(_ change: [String: Any]) throws {
        guard let next = change["revision"] as? Int else { throw Failure.malformed }
        if change["type"] as? String == "snapshot", let value = change["conversationState"] as? [String: Any] {
            state = value; revision = next; return
        }
        guard change["type"] as? String == "patches", let base = change["baseRevision"] as? Int, base == revision, next > base,
              let patches = change["patches"] as? [[String: Any]] else { throw Failure.revisionGap }
        var value: Any = state
        for patch in patches {
            guard let path = patch["path"] as? [Any], let op = patch["op"] as? String, ["add", "replace", "remove"].contains(op) else { throw Failure.malformed }
            value = try Self.patch(value, path: path[...], op: op, value: patch["value"] ?? NSNull())
        }
        guard let object = value as? [String: Any] else { throw Failure.malformed }
        state = object; revision = next
    }
    private static func patch(_ object: Any, path: ArraySlice<Any>, op: String, value: Any) throws -> Any {
        guard let head = path.first else { return value }
        let rest = path.dropFirst()
        if var dict = object as? [String: Any], let key = head as? String {
            if rest.isEmpty {
                if op != "add" && dict[key] == nil { throw Failure.malformed }
                if op == "remove" { dict.removeValue(forKey: key) } else { dict[key] = value }
            } else {
                guard let child = dict[key] else { throw Failure.malformed }
                dict[key] = try patch(child, path: rest, op: op, value: value)
            }
            return dict
        }
        if var array = object as? [Any], let index = head as? Int, index >= 0 {
            if rest.isEmpty && op == "add", index <= array.count { array.insert(value, at: index); return array }
            guard index < array.count else { throw Failure.malformed }
            if rest.isEmpty && op == "remove" { array.remove(at: index) }
            else { array[index] = try patch(array[index], path: rest, op: op, value: value) }
            return array
        }
        throw Failure.malformed
    }
    /// Async questions are agent messages, not outstanding JSON-RPC requests.
    public var pendingAsyncQuestions: [[String: Any]] {
        guard let turn = latestTurn, turn["status"] as? String == "inProgress" else { return [] }
        let items = turn["items"] as? [[String: Any]] ?? []
        var answered = Set<String>()
        let start = "<send_user_message_question_reply>"
        let end = "</send_user_message_question_reply>"
        for item in items {
            let type = item["type"] as? String
            guard type == "userMessage" || (type == "steeringUserMessage" && item["status"] as? String == "accepted"),
                  let content = item[type == "userMessage" ? "content" : "input"] as? [[String: Any]],
                  content.count == 1, content[0]["type"] as? String == "text",
                  let text = content[0]["text"] as? String else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix(start), trimmed.hasSuffix(end),
                  let data = String(trimmed.dropFirst(start.count).dropLast(end.count)).data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) else { continue }
            let replies = (json as? [[String: Any]]) ?? (json as? [String: Any]).map { [$0] } ?? []
            for reply in replies where reply["answer"] is String {
                if let id = reply["questionItemId"] as? String { answered.insert(id) }
            }
        }
        return items.flatMap { item -> [[String: Any]] in
            guard item["type"] as? String == "agentMessage", item["delivery"] as? String == "async",
                  let source = item["id"] as? String else { return [] }
            let questions = item["questions"] as? [[String: Any]] ?? []
            if questions.isEmpty {
                guard !answered.contains(source), let title = item["text"] as? String, !title.isEmpty else { return [] }
                return [["id": source, "question": title, "isOther": true, "options": [[String: Any]]()]]
            }
            return questions.enumerated().compactMap { index, question in
                guard let title = question["title"] as? String,
                      let data = try? JSONSerialization.data(withJSONObject: ["request_user_input_async", source, index], options: [.fragmentsAllowed, .withoutEscapingSlashes]),
                      let id = String(data: data, encoding: .utf8), !answered.contains(id) else { return nil }
                return ["id": id, "question": title, "isOther": true,
                        "options": (question["options"] as? [String] ?? []).map { ["label": $0] }]
            }
        }
    }
    public var decisionRequests: [[String: Any]] {
        var requests = state["requests"] as? [[String: Any]] ?? []
        for question in pendingAsyncQuestions {
            requests.append(["id": "async:" + (question["id"] as! String),
                             "method": "desktop/asyncQuestion",
                             "params": ["questions": [question]]])
        }
        return requests
    }
    public var isWaitingForUser: Bool {
        let runtime = state["threadRuntimeStatus"] as? [String: Any]
        let flags = runtime?["activeFlags"] as? [String] ?? []
        return !decisionRequests.isEmpty || flags.contains("waitingOnUserInput") || flags.contains("waitingOnApproval")
    }
    public static func asyncReply(questions: [[String: Any]], result: [String: Any]) -> String? {
        guard let answers = result["answers"] as? [String: [String: Any]] else { return nil }
        var replies: [[String: String]] = []
        for question in questions {
            guard let id = question["id"] as? String, let title = question["question"] as? String,
                  let values = answers[id]?["answers"] as? [String], values.count == 1,
                  !values[0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            replies.append(["questionItemId": id, "question": title, "answer": values[0]])
        }
        guard !replies.isEmpty, let data = try? JSONSerialization.data(withJSONObject: replies, options: [.sortedKeys, .withoutEscapingSlashes]),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return "<send_user_message_question_reply>\n" + json + "\n</send_user_message_question_reply>"
    }
    public var displayTitle: String {
        [state["title"], state["generatedTitle"]].compactMap { $0 as? String }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "Codex task"
    }
    public var latestTurn: [String: Any]? {
        let history = (state["turnHistory"] as? [String: Any])?["history"] as? [String: Any]
        let entities = history?["entitiesByKey"] as? [String: [String: Any]]
        let turns = entities.map { Array($0.values) } ?? (state["turns"] as? [[String: Any]] ?? [])
        return turns.max { ($0["turnStartedAtMs"] as? Double ?? 0) < ($1["turnStartedAtMs"] as? Double ?? 0) }
    }
}
