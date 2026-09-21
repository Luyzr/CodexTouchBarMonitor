import AppKit
import OSLog
import MonitorCore

@MainActor final class ExecutionManager {
    let client = CodexAppServerClient()
    let applicationMonitor = ApplicationMonitor()
    private let discoveryClient = CodexAppServerClient()
    private var usingDesktopIPC = false
    private var desktopStates: [DesktopTaskIdentity: DesktopSnapshot] = [:]
    private var desktopOwners: [DesktopTaskIdentity: String] = [:]
    private var desktopSubscribed = Set<DesktopTaskIdentity>()
    private var catalogTask: Task<Void, Never>?
    private let pauseDefaults: UserDefaults?
    init(pauseDefaults: UserDefaults? = nil) { self.pauseDefaults = pauseDefaults }
    private(set) var store = ExecutionStore()
    private(set) var decisions: [DecisionID: DecisionRequest] = [:]
    private(set) var connection = "Connecting to Desktop daemon"
    private(set) var connected = false
    private(set) var serverID = "desktop"
    private(set) var telemetry: [ExecutionID: ExecutionTelemetry] = [:]
    private(set) var pauseRequests = Set<ExecutionID>()
    private(set) var controlPending = Set<ExecutionID>()
    private(set) var resumeUncertain = Set<ExecutionID>()
    enum ControlError: LocalizedError {
        case changed, uncertain
        var errorDescription: String? {
            switch self {
            case .changed: return "The task changed. Refresh and check Codex before continuing."
            case .uncertain: return "Delivery is uncertain. Check Codex; this action will not be retried automatically."
            }
        }
    }
    private var reconnectTask: Task<Void, Never>?
    private var syncTask: Task<Void, Never>?
    private var confirmations: [DecisionID: Task<Void, Never>] = [:]
    private var subscribed = Set<String>()
    private var discovering = false
    private var rediscover = false
    private var stopped = true
    private var titles: [String: String] = [:]
    private var directories: [String: String] = [:]
    private var revisions: [String: Int] = [:]
    private let logger = Logger(subsystem: "io.local.CodexTouchBarMonitor", category: "execution")
    var onChange: (() -> Void)?
    var demo = false
    var queue: [DecisionRequest] { decisions.values.sorted { $0.createdAt < $1.createdAt } }
    var state: AppState { AppState(isCodexForeground: applicationMonitor.isCodexForeground, executions: store.sorted, decisions: queue, connected: connected) }
    var bundleIDs: [String] { UserDefaults.standard.stringArray(forKey: "CodexBundleIDs") ?? ["com.openai.codex", "com.openai.chat"] }
    func start() {
        guard stopped else { return }; stopped = false
        if demo { seedDemo(); return }
        if client.executableOverride == nil || pauseDefaults != nil {
            for value in (pauseDefaults ?? .standard).array(forKey: "PausedExecutions") as? [[String: String]] ?? [] {
                guard let server = value["server"], let thread = value["thread"], let turn = value["turn"] else { continue }
                let id = ExecutionID(serverID: server, threadID: thread, turnID: turn)
                pauseRequests.insert(id)
                if value["uncertain"] == "true" { resumeUncertain.insert(id) }
                store.upsert(MonitoredExecution(id: id, title: "Paused task", state: .unknown))
            }
        }
        client.onNotification = { [weak self] method, params in
            if method == "desktop/message" { self?.desktopMessage(params) }
            else { self?.handle(method, params) }
        }
        client.onRequest = { [weak self] id, method, params in self?.requested(id, method, params) }
        client.onDisconnect = { [weak self] in self?.lost(); self?.connectWhenNeeded() }
        applicationMonitor.onChange = { [weak self] wasCodex, isCodex in
            self?.onChange?()
            if wasCodex && !isCodex { self?.requestDiscovery() }
        }
        applicationMonitor.start(bundleIDs: bundleIDs)
        connectWhenNeeded()
    }
    private func connectWhenNeeded() {
        guard !stopped, !demo, !connected, reconnectTask == nil else { return }
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            defer { self.reconnectTask = nil; if !self.connected && !self.stopped { self.connectWhenNeeded() } }
            var retry: UInt64 = 1
            while !Task.isCancelled && !self.stopped && !self.connected {
                do {
                    let path = UserDefaults.standard.string(forKey: "CodexDaemonSocket") ?? NSHomeDirectory() + "/.codex/app-server-control/app-server-control.sock"
                    let ipc = NSHomeDirectory() + "/.codex/ipc/ipc.sock"
                    self.usingDesktopIPC = self.client.executableOverride == nil && FileManager.default.fileExists(atPath: ipc)
                    self.serverID = self.usingDesktopIPC ? "desktop-ipc:local" : path
                    try await self.client.connect(mode: self.usingDesktopIPC ? .desktop(ipc) : .daemon(path))
                    guard !Task.isCancelled && !self.stopped else { return }
                    self.connected = true; self.connection = self.usingDesktopIPC ? "Desktop IPC connected" : "Desktop daemon connected"; self.onChange?()
                    await self.discover()
                    if self.usingDesktopIPC {
                        self.catalogTask?.cancel()
                        self.catalogTask = Task { [weak self] in
                            while !Task.isCancelled {
                                try? await Task.sleep(nanoseconds: 30_000_000_000)
                                guard !Task.isCancelled, let self, self.connected else { return }
                                await self.discoverDesktopCatalog()
                            }
                        }
                    }
                } catch {
                    guard !Task.isCancelled && !self.stopped else { return }
                    self.lost()
                    try? await Task.sleep(nanoseconds: retry * 1_000_000_000)
                    retry = min(30, retry * 2)
                }
            }
        }
    }
    private func lost() {
        connected = false; connection = "Desktop daemon unavailable — retrying"
        for id in Array(telemetry.keys) { telemetry[id]?.disconnect() }
        for host in Set(desktopSubscribed.map { $0.serverID }) { store.disconnected(server: host) }
        desktopStates.removeAll(); desktopOwners.removeAll(); desktopSubscribed.removeAll()
        catalogTask?.cancel(); catalogTask = nil
        subscribed.removeAll(); clearDecisions { _ in true }; store.disconnected(server: serverID)
        onChange?()
    }
    func requestDiscovery() {
        guard connected else { connectWhenNeeded(); return }
        if discovering { rediscover = true; return }
        guard syncTask == nil else { return }
        syncTask = Task { [weak self] in await self?.discover(); self?.syncTask = nil }
    }
    func discover() async {
        if usingDesktopIPC { await discoverDesktop(); return }
        guard connected, !discovering else { return }
        discovering = true
        defer {
            discovering = false
            if rediscover { rediscover = false; Task { [weak self] in await self?.discover() } }
        }
        let generation = client.generation
        do {
            var cursor: String?; var seen = Set<String>(); var loaded = Set<String>(); var failures = 0
            repeat {
                var params: [String: Any] = ["limit": 100]
                if let cursor { params["cursor"] = cursor }
                let result = try await client.request("thread/loaded/list", params)
                guard generation == client.generation && !Task.isCancelled else { return }
                loaded.formUnion(result["data"] as? [String] ?? [])
                cursor = result["nextCursor"] as? String
                if let cursor, !seen.insert(cursor).inserted { break }
            } while cursor != nil
            // Previously monitored turns may have completed and unloaded during a disconnect.
            let frozen = Set(store.sorted.filter { $0.id.serverID == serverID && (!$0.state.terminal || $0.state == .paused) }.map { $0.id.threadID })
            for id in loaded.union(frozen).sorted() {
                do {
                    try await syncThread(id, loaded: loaded.contains(id), generation: generation)
                } catch {
                    guard generation == client.generation else { return }; failures += 1
                }
            }
            guard generation == client.generation else { return }
            subscribed.formIntersection(loaded)
            connection = "Desktop daemon connected · \(subscribed.count) subscribed tasks" + (failures == 0 ? "" : " · \(failures) unavailable; refresh to retry")
        } catch {
            if generation == client.generation { connection = "Connected; synchronization unavailable — refresh to retry" }
        }
        onChange?()
    }
    private func syncThread(_ id: String, loaded: Bool, generation: UUID) async throws {
        let revision = revisions[id, default: 0]
        let method = loaded && !subscribed.contains(id) ? "thread/resume" : "thread/read"
        let result = try await client.request(method, method == "thread/resume" ? ["threadId": id, "excludeTurns": true] : ["threadId": id])
        guard generation == client.generation else { return }
        if loaded { subscribed.insert(id) }
        guard var thread = result["thread"] as? [String: Any] else { return }
        updateMetadata(thread)
        var unresolved = Set(store.sorted.filter { $0.id.serverID == serverID && $0.id.threadID == id && !$0.state.terminal }.map { $0.id.turnID })
        var cursor: String?; var seen = Set<String>(); var turns: [[String: Any]] = []
        repeat {
            var params: [String: Any] = ["threadId": id, "limit": 100, "itemsView": "notLoaded", "sortDirection": "desc"]
            if let cursor { params["cursor"] = cursor }
            let page = try await client.request("thread/turns/list", params)
            guard generation == client.generation && !Task.isCancelled else { return }
            let values = page["data"] as? [[String: Any]] ?? []
            turns += values; unresolved.subtract(values.compactMap { $0["id"] as? String })
            cursor = page["nextCursor"] as? String
            if let cursor, !seen.insert(cursor).inserted { break }
        } while cursor != nil && !unresolved.isEmpty
        thread["turns"] = turns
        // Events received after the read began are authoritative over the snapshot.
        if revision == revisions[id, default: 0] { snapshot(thread) }
    }
    private func updateMetadata(_ thread: [String: Any]) {
        guard let id = thread["id"] as? String else { return }
        titles[id] = TaskNaming.title(thread, fallback: titles[id] ?? "Task \(titles.count + 1)")
        directories[id] = thread["cwd"] as? String
    }
    func snapshot(_ thread: [String: Any]) {
        guard let id = thread["id"] as? String else { return }; updateMetadata(thread)
        for turn in thread["turns"] as? [[String: Any]] ?? [] {
            guard let turnID = turn["id"] as? String else { continue }
            let key = ExecutionID(serverID: serverID, threadID: id, turnID: turnID)
            if turn["status"] as? String == "inProgress" || store.executions[key] != nil { applyTurn(threadID: id, turn: turn) }
        }
        applyStatus(thread: id, status: thread["status"] as? [String: Any] ?? [:], fromSnapshot: true)
    }
    private func applyTurn(threadID: String, turn: [String: Any]) {
        guard let turnID = turn["id"] as? String else { return }
        let id = ExecutionID(serverID: serverID, threadID: threadID, turnID: turnID)
        let state: ExecutionState
        switch turn["status"] as? String {
        case "completed": state = .completed
        case "failed": state = .failed
        case "interrupted": state = pauseRequests.contains(id) ? .paused : .failed
        case "inProgress": state = .running
        default: state = .unknown
        }
        if store.executions[id] == nil && state.terminal { return }
        if state == .running { supersedePauses(thread: threadID, newTurn: turnID) }
        if titles[threadID] == nil { titles[threadID] = "Task \(titles.count + 1)" }
        let started = (turn["startedAt"] as? Double).map(Date.init(timeIntervalSince1970:)) ?? Date()
        var value = store.executions[id] ?? MonitoredExecution(id: id, title: titles[threadID] ?? "Task \(titles.count + 1)", cwd: directories[threadID], startedAt: started)
        value.title = titles[threadID] ?? value.title; value.cwd = directories[threadID] ?? value.cwd
        value.startedAt = min(value.startedAt, started)
        value.state = !state.terminal && decisions.keys.contains { $0.execution == id } ? .waitingDecision : state
        value.updatedAt = Date()
        if state.terminal { value.completedAt = (turn["completedAt"] as? Double).map(Date.init(timeIntervalSince1970:)) ?? Date() }
        store.upsert(value)
        if state.terminal {
            clearDecisions { $0.execution == id }; telemetry[id]?.finish()
            if state != .paused, pauseRequests.remove(id) != nil { resumeUncertain.remove(id); savePauses() }
        }
    }
    private func applyStatus(thread: String, status: [String: Any], fromSnapshot: Bool = false) {
        let kind = status["type"] as? String ?? ""
        let waiting = (status["activeFlags"] as? [String] ?? []).contains { ["waitingOnApproval", "waitingOnUserInput"].contains($0) }
        for value in store.sorted where value.id.serverID == serverID && value.id.threadID == thread && !value.state.terminal {
            switch kind {
            case "active": store.transition(value.id, to: waiting || decisions.keys.contains { $0.execution == value.id } ? .waitingDecision : .running)
            case "systemError": store.transition(value.id, to: .failed); clearDecisions { $0.execution == value.id }
            case "notLoaded": store.transition(value.id, to: .unknown)
            case "idle": if !fromSnapshot { requestDiscovery() }
            default: break
            }
        }
    }
    func handle(_ method: String, _ params: [String: Any]) {
        if let thread = params["threadId"] as? String { revisions[thread, default: 0] += 1 }
        switch method {
        case "thread/started":
            if let thread = params["thread"] as? [String: Any] { updateMetadata(thread) }
            requestDiscovery()
        case "thread/name/updated":
            if let id = params["threadId"] as? String, let name = params["threadName"] as? String ?? params["name"] as? String {
                titles[id] = name
                for var value in store.sorted where value.id.threadID == id { value.title = name; store.upsert(value) }
            }
        case "thread/closed":
            if let id = params["threadId"] as? String { subscribed.remove(id); requestDiscovery() }
        case "turn/started", "turn/completed":
            if let id = params["threadId"] as? String, let turn = params["turn"] as? [String: Any] {
                if method == "turn/started", let turnID = turn["id"] as? String { clearDecisions { $0.execution.threadID == id && $0.execution.turnID != turnID } }
                applyTurn(threadID: id, turn: turn)
            }
        case "serverRequest/resolved":
            if let raw = params["requestId"], let request = RPCID(raw) {
                let keys = decisions.keys.filter { $0.request == request && $0.connection == client.generation && $0.execution.threadID == params["threadId"] as? String }
                for key in keys {
                    clearDecisions { $0 == key }
                    if !decisions.keys.contains(where: { $0.execution == key.execution }) { store.transition(key.execution, to: .running) }
                }
            }
        case "turn/plan/updated", "thread/tokenUsage/updated":
            if let thread = params["threadId"] as? String, let turn = params["turnId"] as? String {
                let key = ExecutionID(serverID: serverID, threadID: thread, turnID: turn)
                if store.executions[key] == nil { applyTurn(threadID: thread, turn: ["id": turn, "status": "inProgress"]) }
                if store.executions[key] != nil {
                    if method == "turn/plan/updated" { telemetry[key, default: ExecutionTelemetry()].updatePlan(params) }
                    else { telemetry[key, default: ExecutionTelemetry()].updateUsage(params) }
                }
            }
        case "item/started", "item/completed":
            if let thread = params["threadId"] as? String, let turn = params["turnId"] as? String, let item = params["item"] as? [String: Any] {
                let key = ExecutionID(serverID: serverID, threadID: thread, turnID: turn)
                if store.executions[key] == nil { applyTurn(threadID: thread, turn: ["id": turn, "status": "inProgress"]) }
                if let value = store.executions[key], !value.state.terminal {
                    telemetry[key, default: ExecutionTelemetry()].updateItem(item, completed: method == "item/completed")
                    let activity = telemetry[key]?.currentActivities.last
                    store.transition(key, to: value.state, activity: activity?.command ?? activity?.tool ?? "")
                }
            }
        case "error":
            // A failed command or retryable error is not a failed turn.
            if params["willRetry"] as? Bool == false, let thread = params["threadId"] as? String, let turn = params["turnId"] as? String {
                applyTurn(threadID: thread, turn: ["id": turn, "status": "failed"])
            }
        case "thread/status/changed":
            if let thread = params["threadId"] as? String, let status = params["status"] as? [String: Any] {
                applyStatus(thread: thread, status: status)
                if status["type"] as? String == "active" && !subscribed.contains(thread) { requestDiscovery() }
            }
        default: break
        }
        onChange?()
    }
    func requested(_ request: RPCID, _ method: String, _ params: [String: Any], desktopIdentity: DesktopTaskIdentity? = nil) {
        guard let thread = params["threadId"] as? String, let turn = params["turnId"] as? String else { return }
        revisions[thread, default: 0] += 1
        let execution = ExecutionID(serverID: desktopIdentity?.serverID ?? serverID, threadID: thread, turnID: turn)
        guard store.executions[execution]?.state.terminal != true else { return }
        let id = DecisionID(execution: execution, connection: client.generation, request: request)
        guard decisions[id] == nil else { return }
        if store.executions[execution] == nil { applyTurn(threadID: thread, turn: ["id": turn, "status": "inProgress"]) }
        guard store.executions[execution] != nil else { return }
        decisions[id] = DecisionRequest(id: id, method: method, params: params)
        store.transition(execution, to: .waitingDecision); onChange?()
    }
    func respond(_ id: DecisionID, result: [String: Any]) throws {
        guard var decision = decisions[id], !decision.sent, decision.supported, id.connection == client.generation else { throw CodexAppServerClient.Failure.disconnected }
        if demo {
            clearDecisions { $0 == id }; store.transition(id.execution, to: decisions.keys.contains { $0.execution == id.execution } ? .waitingDecision : .running)
        } else if usingDesktopIPC {
            guard connected, let owner = desktopOwners[DesktopTaskIdentity(id.execution)],
                  let snapshot = desktopStates[DesktopTaskIdentity(id.execution)],
                  snapshot.latestTurn?["turnId"] as? String == id.execution.turnID,
                  snapshot.decisionRequests.contains(where: { ($0["id"].flatMap { RPCID($0) }) == id.request }) == true else { throw ControlError.changed }
            let route: String
            var params: [String: Any] = ["conversationId": id.execution.threadID, "requestId": id.request.json]
            switch decision.method {
            case "item/commandExecution/requestApproval": route = "thread-follower-command-approval-decision"; params["decision"] = result["decision"]
            case "item/fileChange/requestApproval": route = "thread-follower-file-approval-decision"; params["decision"] = result["decision"]
            case "item/permissions/requestApproval": route = "thread-follower-permissions-request-approval-response"; params["response"] = result
            case "item/tool/requestUserInput", "tool/requestUserInput": route = "thread-follower-submit-user-input"; params["response"] = result
            case "desktop/asyncQuestion":
                guard let text = DesktopSnapshot.asyncReply(questions: decision.questions, result: result) else { throw ControlError.changed }
                route = "thread-follower-steer-turn"
                params.removeValue(forKey: "requestId")
                params["input"] = [["type": "text", "text": text, "text_elements": []]]
                params["clientUserMessageId"] = UUID().uuidString
                params["attachments"] = []
                params["restoreMessage"] = ["cwd": snapshot.state["cwd"] ?? NSNull(),
                    "context": ["prompt": text, "turnTrigger": "send_user_message_async_question",
                                "addedFiles": [], "fileAttachments": [], "imageAttachments": []]]
            default: throw ControlError.changed
            }
            decision.sent = true; decisions[id] = decision
            confirmations[id] = Task { [weak self] in
                guard let self else { return }
                do {
                    _ = try await self.client.request(route, params, targetClientID: owner, version: 1, hostID: DesktopTaskIdentity(id.execution).host)
                    try? await Task.sleep(nanoseconds: 10_000_000_000)
                } catch {}
                guard !Task.isCancelled, self.decisions[id] != nil else { return }
                self.decisions[id]?.deliveryUncertain = true; self.confirmations.removeValue(forKey: id); self.onChange?()
            }
        } else {
            try client.respond(id.request, result: result, connection: id.connection)
            decision.sent = true; decisions[id] = decision
            confirmations[id] = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard !Task.isCancelled, let self, self.decisions[id] != nil else { return }
                self.decisions[id]?.deliveryUncertain = true; self.confirmations.removeValue(forKey: id); self.onChange?()
            }
        }
        onChange?()
    }
    func interrupt(_ id: ExecutionID) async throws {
        guard connected, id.serverID == serverID, let value = store.executions[id], !value.state.terminal, value.state != .unknown else { throw CodexAppServerClient.Failure.disconnected }
        guard !controlPending.contains(id) else { throw ControlError.changed }
        controlPending.insert(id); onChange?()
        defer { controlPending.remove(id); onChange?() }
        if demo { handle("turn/completed", ["threadId": id.threadID, "turn": ["id": id.turnID, "status": "interrupted"]]); return }
        _ = try await client.request("turn/interrupt", ["threadId": id.threadID, "turnId": id.turnID])
    }
    private func clearDecisions(where matches: (DecisionID) -> Bool) {
        for key in Array(decisions.keys) where matches(key) { decisions.removeValue(forKey: key); confirmations.removeValue(forKey: key)?.cancel() }
    }
    func acknowledge(_ id: ExecutionID) {
        guard store.executions[id]?.state.terminal == true else { return }
        store.acknowledge(id); telemetry.removeValue(forKey: id); pauseRequests.remove(id); resumeUncertain.remove(id); savePauses(); onChange?()
    }
    func pause(_ id: ExecutionID) async throws {
        guard !pauseRequests.contains(id), !controlPending.contains(id), connected, id.serverID == serverID,
              let value = store.executions[id], !value.state.terminal, value.state != .unknown else { throw ControlError.changed }
        pauseRequests.insert(id); savePauses()
        do { try await interrupt(id) }
        catch {
            // An RPC rejection is definitive. A transport timeout may have delivered the interrupt.
            if case CodexAppServerClient.Failure.rpc = error { pauseRequests.remove(id); savePauses() }
            onChange?(); throw error
        }
    }
    func continuePaused(_ id: ExecutionID) async throws {
        guard connected, id.serverID == serverID, pauseRequests.contains(id),
              store.executions[id]?.state == .paused, !controlPending.contains(id),
              !resumeUncertain.contains(id) else { throw ControlError.changed }
        controlPending.insert(id); onChange?()
        defer { controlPending.remove(id); onChange?() }
        if demo {
            handle("turn/started", ["threadId": id.threadID, "turn": ["id": UUID().uuidString, "status": "inProgress"]]); return
        }
        let generation = client.generation
        // Read-only preflight. Never resume history or change the thread's model/permissions.
        let page = try await client.request("thread/turns/list", ["threadId": id.threadID, "limit": 1, "sortDirection": "desc", "itemsView": "notLoaded"])
        guard generation == client.generation, pauseRequests.contains(id),
              let latest = (page["data"] as? [[String: Any]])?.first,
              latest["id"] as? String == id.turnID, latest["status"] as? String == "interrupted" else { throw ControlError.changed }
        // Persist uncertainty BEFORE writing; restart/timeout must never cause a duplicate continuation.
        resumeUncertain.insert(id); savePauses()
        do {
            let result = try await client.request("turn/start", ["threadId": id.threadID, "input": [["type": "text", "text": "Continue the task from where it was interrupted. Check the current state before repeating any operation."]]])
            guard generation == client.generation, let turn = result["turn"] as? [String: Any],
                  let newTurn = turn["id"] as? String, newTurn != id.turnID else { throw ControlError.uncertain }
            applyTurn(threadID: id.threadID, turn: turn)
        } catch {
            if case CodexAppServerClient.Failure.rpc = error { resumeUncertain.remove(id); savePauses() }
            throw error
        }
    }
    private func supersedePauses(thread: String, newTurn: String) {
        let previous = pauseRequests
        for id in Array(pauseRequests) where id.serverID == serverID && id.threadID == thread && id.turnID != newTurn {
            pauseRequests.remove(id); resumeUncertain.remove(id)
            // A restarted monitor may still have an unknown checkpoint when it observes the newer turn.
            store.transition(id, to: .paused); store.acknowledge(id); telemetry.removeValue(forKey: id)
        }
        if previous != pauseRequests { savePauses() }
    }
    private func savePauses() {
        guard !demo, client.executableOverride == nil || pauseDefaults != nil else { return }
        (pauseDefaults ?? .standard).set(pauseRequests.map { ["server": $0.serverID, "thread": $0.threadID, "turn": $0.turnID, "uncertain": resumeUncertain.contains($0) ? "true" : "false"] }, forKey: "PausedExecutions")
    }
    func simulateDisconnect() { client.disconnect(); lost() }
    func wake() { guard !demo else { return }; client.disconnect(); lost(); connectWhenNeeded() }
    func stop() {
        catalogTask?.cancel(); catalogTask = nil
        stopped = true; reconnectTask?.cancel(); reconnectTask = nil; syncTask?.cancel(); syncTask = nil
        rediscover = false; applicationMonitor.stop(); discoveryClient.disconnect(); client.disconnect(); clearDecisions { _ in true }
    }
    private func followDesktop(_ identity: DesktopTaskIdentity, force: Bool = false, targets: [String]? = nil) throws {
        guard force || !desktopSubscribed.contains(identity) else { return }
        try client.desktopBroadcast("thread-stream-following-changed", params: ["conversationId": identity.thread, "hostId": identity.host, "following": true], version: 1, targets: targets)
        desktopSubscribed.insert(identity)
    }
    private func discoverDesktopCatalog() async {
        let generation = client.generation
        let identities = await Task.detached(priority: .utility) { (try? DesktopCatalog.desktopTasks()) ?? [] }.value
        guard generation == client.generation, connected, !stopped, !Task.isCancelled else { return }
        for identity in identities { try? followDesktop(identity, force: desktopOwners[identity] == nil) }
    }
    private func discoverDesktop() async {
        guard connected, !discovering else { return }
        discovering = true; defer { discovering = false; discoveryClient.disconnect() }
        let generation = client.generation
        await discoverDesktopCatalog()
        // Some Desktop-created threads are absent from an independent app-server list.
        // Read candidate IDs only; never infer task state from the catalog.
        let localIDs = await Task.detached(priority: .utility) { try? DesktopCatalog.threadIDs() }.value ?? []
        guard generation == client.generation, !Task.isCancelled, !stopped else { return }
        do {
            for id in localIDs where !subscribed.contains(id) {
                subscribed.insert(id)
                try followDesktop(DesktopTaskIdentity(host: "local", thread: id))
            }
            if CommandLine.arguments.contains("--interaction-diagnostics") { print("CATALOG candidates=\(localIDs.count)"); fflush(stdout) }
            try await discoveryClient.connect()
            var cursor: String?
            var seenCursors = Set<String>()
            repeat {
                var params: [String: Any] = ["limit": 100, "archived": false, "sortKey": "updated_at", "useStateDbOnly": true]
                if let cursor { params["cursor"] = cursor }
                let result = try await discoveryClient.request("thread/list", params)
                if CommandLine.arguments.contains("--interaction-diagnostics") { print("DISCOVERY ids=\((result["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }.joined(separator: ","))"); fflush(stdout) }
                guard generation == client.generation, !Task.isCancelled, !stopped else { return }
                for (index, thread) in (result["data"] as? [[String: Any]] ?? []).enumerated() {
                    guard let id = thread["id"] as? String, !subscribed.contains(id) else { continue }
                    subscribed.insert(id)
                    try followDesktop(DesktopTaskIdentity(host: "local", thread: id))
                    if index % 16 == 0 { await Task.yield() }
                    guard generation == client.generation, !Task.isCancelled, !stopped else { return }
                }
                cursor = result["nextCursor"] as? String
                if let cursor, !seenCursors.insert(cursor).inserted { throw CodexAppServerClient.Failure.protocolError }
            } while cursor != nil
            // A runtime test can supply a thread outside the default local catalog.
            if let id = UserDefaults.standard.string(forKey: "MonitorThreadID"), !subscribed.contains(id) {
                subscribed.insert(id)
                try followDesktop(DesktopTaskIdentity(host: "local", thread: id))
            }
        } catch { connection = "Desktop IPC connected; discovery unavailable"; onChange?() }
    }
    private func invalidateDesktopOwner(_ owner: String) {
        for identity in desktopOwners.keys.filter({ desktopOwners[$0] == owner }) {
            desktopOwners[identity] = nil; desktopStates[identity] = nil
            clearDecisions { $0.execution.serverID == identity.serverID && $0.execution.threadID == identity.thread }
            for value in store.sorted where value.id.serverID == identity.serverID && value.id.threadID == identity.thread && !value.state.terminal {
                store.transition(value.id, to: .unknown)
            }
        }
        onChange?()
    }
    func desktopMessage(_ message: [String: Any]) {
        guard usingDesktopIPC else { return }
        let method = message["method"] as? String ?? ""
        let parameters = message["params"] as? [String: Any] ?? [:]
        if method == "thread-stream-following-status-requested",
           let host = parameters["hostId"] as? String, let thread = parameters["conversationId"] as? String {
            let identity = DesktopTaskIdentity(host: host, thread: thread)
            if desktopSubscribed.contains(identity) {
                try? followDesktop(identity, force: true, targets: (message["sourceClientId"] as? String).map { [$0] })
            }
            return
        }
        if method == "client-status-changed" {
            if parameters["status"] as? String == "connected" {
                let targets = parameters["isSelf"] as? Bool == true ? nil : (parameters["clientId"] as? String).map { [$0] }
                for identity in desktopSubscribed { try? followDesktop(identity, force: true, targets: targets) }
            } else if let owner = parameters["clientId"] as? String {
                invalidateDesktopOwner(owner)
            }
            return
        }
        if method == "ipc-connection-reset" {
            for owner in Set(desktopOwners.values) { invalidateDesktopOwner(owner) }
            for identity in desktopSubscribed { try? followDesktop(identity, force: true) }
            return
        }
        guard method == "thread-stream-state-changed",
              message["version"] as? Int == 11,
              let params = message["params"] as? [String: Any], let host = params["hostId"] as? String,
              let thread = params["conversationId"] as? String, let owner = message["sourceClientId"] as? String,
              let change = params["change"] as? [String: Any] else { return }
        let identity = DesktopTaskIdentity(host: host, thread: thread)
        guard desktopSubscribed.contains(identity) else { return }
        if let previous = desktopOwners[identity], previous != owner { desktopStates[identity] = nil; clearDecisions { $0.execution.serverID == identity.serverID && $0.execution.threadID == thread } }
        var snapshot = desktopStates[identity] ?? DesktopSnapshot()
        do { try snapshot.apply(change) }
        catch {
            desktopStates[identity] = nil; clearDecisions { $0.execution.serverID == identity.serverID && $0.execution.threadID == thread }
            try? client.desktopBroadcast("thread-stream-following-changed", params: ["conversationId": thread, "hostId": host, "following": true], version: 1, targets: [owner])
            return
        }
        desktopStates[identity] = snapshot; desktopOwners[identity] = owner
        if CommandLine.arguments.contains("--interaction-diagnostics"), change["type"] as? String != "patches" { print("SNAPSHOT thread=\(thread) hasTurn=\(snapshot.latestTurn != nil)"); fflush(stdout) }
        if change["type"] as? String == "patches", let patches = change["patches"] as? [[String: Any]] {
            let meaningful = patches.contains { patch in
                let path = patch["path"] as? [Any] ?? []
                let root = path.first as? String ?? ""
                if ["requests", "threadRuntimeStatus", "title", "generatedTitle"].contains(root) { return true }
                if root == "turnHistory" || root == "turns" {
                    if path.count <= 4 || ["turnId", "status"].contains(path.last as? String ?? "") { return true }
                    if let index = path.firstIndex(where: { $0 as? String == "items" }) {
                        if path.count <= index + 2 { return true }
                        return ["delivery", "questions", "content", "input"].contains { field in path.contains { $0 as? String == field } }
                    }
                    return false
                }
                return false
            }
            if !meaningful { return }
        }
        if CommandLine.arguments.contains("--interaction-diagnostics") {
            let turn = snapshot.latestTurn ?? [:]
            print("STATE thread=\(thread) turnKeys=\(turn.keys.sorted()) status=\(turn["status"] ?? "nil") runtime=\(snapshot.state["threadRuntimeStatus"] ?? "nil")")
            fflush(stdout)
        }
        guard let turn = snapshot.latestTurn, let turnID = turn["turnId"] as? String else { return }
        let id = ExecutionID(serverID: identity.serverID, threadID: thread, turnID: turnID)
        let requests = snapshot.decisionRequests
        let runtime = snapshot.state["threadRuntimeStatus"] as? [String: Any]
        let active = runtime?["type"] as? String == "active" || turn["status"] as? String == "inProgress"
        guard active || !requests.isEmpty || store.executions[id] != nil else { return }
        let status = turn["status"] as? String ?? ""
        let state: ExecutionState = snapshot.isWaitingForUser ? .waitingDecision : active ? .running : status == "completed" ? .completed : status == "failed" || status == "interrupted" ? .failed : .unknown
        let title = snapshot.displayTitle + (host == "local" ? "" : " · " + (host.split(separator: ":").last.map(String.init) ?? host))
        if store.executions[id] == nil {
            let start = (turn["turnStartedAtMs"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()
            store.upsert(MonitoredExecution(id: id, title: title, cwd: snapshot.state["cwd"] as? String, state: state, startedAt: start))
        } else {
            if var execution = store.executions[id] {
                execution.title = title
                execution.cwd = snapshot.state["cwd"] as? String ?? execution.cwd
                store.upsert(execution)
            }
            store.transition(id, to: state)
        }
        let currentIDs = Set(requests.compactMap { $0["id"].flatMap { RPCID($0) } })
        clearDecisions { $0.execution.serverID == identity.serverID && $0.execution.threadID == thread && ($0.execution.turnID != turnID || !currentIDs.contains($0.request)) }
        for request in requests {
            guard let raw = request["id"], let requestID = RPCID(raw), let method = request["method"] as? String else { continue }
            var values = request["params"] as? [String: Any] ?? [:]
            values["threadId"] = thread; values["turnId"] = turnID
            requested(requestID, method, values, desktopIdentity: identity)
        }
        onChange?()
    }
    func prepareDesktopFixture(_ identities: [DesktopTaskIdentity]) {
        usingDesktopIPC = true; connected = true; serverID = "desktop-ipc:local"
        desktopSubscribed = Set(identities)
    }
    private func seedDemo() {
        connection = "DEMO — no live requests"; connected = true
        if CommandLine.arguments.contains("--input-demo") {
            store.upsert(MonitoredExecution(id: .init(serverID: serverID, threadID: "input-fixture", turnID: "turn-1"), title: "DEMO Input", state: .running))
            requested(.string("input-fixture"), "item/tool/requestUserInput", ["threadId": "input-fixture", "turnId": "turn-1", "questions": [["id": "branch", "question": "输入分支名", "isOther": true, "options": [["label": "feature/monitor", "description": "Suggested branch"]]]]])
            onChange?(); return
        }
        for (index, state) in [ExecutionState.running, .completed, .failed].enumerated() {
            store.upsert(MonitoredExecution(id: .init(serverID: serverID, threadID: "demo-\(index)", turnID: "turn-1"), title: ["DEMO Sandbox", "DEMO UMDK", "DEMO openEuler"][index], state: state))
        }
        requested(.string("demo-approval"), "item/commandExecution/requestApproval", ["threadId": "demo-0", "turnId": "turn-1", "reason": "Demo: allow this single command?", "command": "git status"])
        store.upsert(MonitoredExecution(id: .init(serverID: serverID, threadID: "demo-input", turnID: "turn-1"), title: "DEMO Input", state: .running))
        requested(.string("demo-input"), "item/tool/requestUserInput", ["threadId": "demo-input", "turnId": "turn-1", "questions": [["id": "branch", "question": "输入分支名 / Branch name", "isOther": true, "options": [["label": "feature/monitor", "description": "Suggested branch"]]]]])
        onChange?()
    }
}
