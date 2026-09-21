import Foundation
import AppKit
import SQLite3
import MonitorCore

@MainActor func runSelfChecks(mock: String) async throws {
    try await runQuotaAccountChecks()
    var assertions = 0
    func check(_ condition: @autoclosure () -> Bool, _ label: String) {
        assertions += 1
        guard condition() else { fatalError("FAIL: " + label) }
    }
    // The external workspace volume does not support Unix sockets. Only this
    // ephemeral kernel endpoint uses the Mac mini system temp directory.
    let catalogHome = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("work/tmp/catalog-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: catalogHome, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: catalogHome) }
    var fixtureDB: OpaquePointer?
    let fixtureDBPath = catalogHome.appendingPathComponent("state_5.sqlite").path
    check(sqlite3_open(fixtureDBPath, &fixtureDB) == SQLITE_OK, "open disposable catalog fixture")
    check(sqlite3_exec(fixtureDB, "CREATE TABLE threads(id TEXT, archived INTEGER, updated_at INTEGER); INSERT INTO threads VALUES('desktop-created',0,20),('older',0,10),('archived',1,30);", nil, nil, nil) == SQLITE_OK, "seed disposable catalog fixture")
    sqlite3_close(fixtureDB)
    let catalogBefore = try Data(contentsOf: URL(fileURLWithPath: fixtureDBPath))
    let catalogIDs = try DesktopCatalog.threadIDs(home: catalogHome)
    check(catalogIDs == ["desktop-created", "older"], "discover unarchived candidate IDs in recency order")
    let catalogAfter = try Data(contentsOf: URL(fileURLWithPath: fixtureDBPath))
    check(catalogAfter == catalogBefore, "catalog discovery does not mutate the database")
    let desktopDBDir = catalogHome.appendingPathComponent("sqlite")
    try FileManager.default.createDirectory(at: desktopDBDir, withIntermediateDirectories: true)
    var desktopDB: OpaquePointer?
    check(sqlite3_open(desktopDBDir.appendingPathComponent("codex-dev.db").path, &desktopDB) == SQLITE_OK, "open desktop host catalog fixture")
    check(sqlite3_exec(desktopDB, "CREATE TABLE local_thread_catalog(host_id TEXT, thread_id TEXT, missing_candidate INTEGER, source_updated_at REAL); INSERT INTO local_thread_catalog VALUES('local','shared',0,3),('remote-ssh-discovered:fixture','shared',0,2),('chatgpt:fixture','chat',0,1),('remote-ssh-discovered:fixture','removed',1,0);", nil, nil, nil) == SQLITE_OK, "seed multi-host catalog")
    sqlite3_close(desktopDB)
    let identities = try DesktopCatalog.desktopTasks(home: catalogHome)
    check(identities.count == 2 && Set(identities.map { $0.host }).count == 2, "host catalog excludes chats and removed candidates")
    let remoteManager = ExecutionManager()
    remoteManager.prepareDesktopFixture(identities)
    func desktopEvent(host: String, owner: String = "owner", status: String = "inProgress", requests: [[String: Any]] = []) -> [String: Any] {
        ["method": "thread-stream-state-changed", "version": 11, "sourceClientId": owner,
         "params": ["hostId": host, "conversationId": "shared", "change": ["type": "snapshot", "revision": 1,
          "conversationState": ["title": "Fixture task", "requests": requests,
           "threadRuntimeStatus": ["type": status == "inProgress" ? "active" : "idle"],
           "turnHistory": ["history": ["entitiesByKey": ["turn": ["turnId": "turn", "turnStartedAtMs": 1.0, "status": status]]]]]]]]
    }
    let remoteHost = "remote-ssh-discovered:fixture"
    let request: [String: Any] = ["id": "q", "method": "item/tool/requestUserInput", "params": ["questions": [["id": "q", "question": "Fixture?", "options": [["label": "Yes"]]]]]]
    remoteManager.desktopMessage(desktopEvent(host: "local", requests: [request]))
    remoteManager.desktopMessage(desktopEvent(host: remoteHost, owner: "remote-owner", requests: [request]))
    check(remoteManager.store.sorted.count == 2 && remoteManager.queue.count == 2, "same thread and request IDs remain separate across hosts")
    check(remoteManager.store.sorted.allSatisfy { $0.state == .waitingDecision }, "remote and local questions both show warning state")
    remoteManager.desktopMessage(["method": "client-status-changed", "params": ["clientId": "remote-owner", "status": "disconnected"]])
    check(remoteManager.queue.count == 1 && remoteManager.store.sorted.first { $0.id.serverID == "desktop-ipc:" + remoteHost }?.state == .unknown, "remote owner disconnect clears only remote decisions")
    remoteManager.desktopMessage(desktopEvent(host: remoteHost, owner: "reconnected-owner", requests: [request]))
    check(remoteManager.queue.count == 2, "new remote owner snapshot restores pending decision")
    remoteManager.desktopMessage(desktopEvent(host: remoteHost, status: "completed"))
    check(remoteManager.queue.count == 1 && remoteManager.queue.first?.id.execution.serverID == "desktop-ipc:local", "remote completion cannot clear local decision")
    check(remoteManager.store.sorted.first { $0.id.serverID == "desktop-ipc:" + remoteHost }?.state == .completed, "remote completion updates correct host")
    remoteManager.desktopMessage(desktopEvent(host: "remote-ssh-discovered:unsubscribed"))
    check(remoteManager.store.sorted.count == 2, "unsolicited host state ignored")
    remoteManager.desktopMessage(desktopEvent(host: remoteHost, owner: "new-owner", status: "completed"))
    check(remoteManager.queue.count == 1, "remote owner change preserves local request")
    remoteManager.simulateDisconnect()
    check(remoteManager.queue.isEmpty && remoteManager.store.sorted.first { $0.id.serverID == "desktop-ipc:local" }?.state == .unknown, "disconnect invalidates all host decisions")
    let tapButton = CompactTrayButton(frame: .zero)
    var singles = 0; var doubles = 0
    tapButton.onSingleTap = { singles += 1 }; tapButton.onDoubleTap = { doubles += 1 }
    tapButton.performClick(nil); tapButton.performClick(nil)
    check(doubles == 1 && singles == 0, "double tap opens controls without activating Codex")
    try await Task.sleep(nanoseconds: UInt64((NSEvent.doubleClickInterval + 0.1) * 1_000_000_000))
    check(singles == 0, "cancelled first tap does not fire after double tap")
    tapButton.performClick(nil)
    try await Task.sleep(nanoseconds: UInt64((NSEvent.doubleClickInterval + 0.1) * 1_000_000_000))
    check(singles == 1 && doubles == 1, "single tap still opens Codex once")
    let fixturePath = "/private/tmp/ctb-ipc-" + String(ProcessInfo.processInfo.processIdentifier) + ".sock"
    let fixture = Process(); fixture.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    fixture.arguments = [FileManager.default.currentDirectoryPath + "/scripts/mock_desktop_ipc.py", fixturePath]
    try fixture.run()
    defer { if fixture.isRunning { fixture.terminate() }; try? FileManager.default.removeItem(atPath: fixturePath) }
    for _ in 0..<100 where !FileManager.default.fileExists(atPath: fixturePath) { try await Task.sleep(nanoseconds: 10_000_000) }
    let desktopClient = remoteManager.client
    try await desktopClient.connect(mode: .desktop(fixturePath))
    remoteManager.prepareDesktopFixture(identities)
    remoteManager.desktopMessage(["method": "thread-stream-following-status-requested", "sourceClientId": "restored-owner", "params": ["hostId": remoteHost, "conversationId": "shared"]])
    let requestedReplay = try await desktopClient.request("fixture/broadcasts", [:])
    let requestedMessages = requestedReplay["messages"] as? [[String: Any]] ?? []
    check(requestedMessages.count == 1
          && requestedMessages.first?["targetClientIds"] as? [String] == ["restored-owner"]
          && (requestedMessages.first?["params"] as? [String: Any])?["hostId"] as? String == remoteHost
          && (requestedMessages.first?["params"] as? [String: Any])?["following"] as? Bool == true,
          "owner status request resends targeted remote subscription on the wire")
    remoteManager.desktopMessage(["method": "client-status-changed", "params": ["clientId": "restored-owner", "status": "connected"]])
    let connectedReplay = try await desktopClient.request("fixture/broadcasts", [:])
    let connectedMessages = connectedReplay["messages"] as? [[String: Any]] ?? []
    check(connectedMessages.count == 2
          && connectedMessages.allSatisfy { $0["targetClientIds"] as? [String] == ["restored-owner"] }
          && Set(connectedMessages.compactMap { ($0["params"] as? [String: Any])?["hostId"] as? String }) == Set(["local", remoteHost]),
          "reconnected owner receives subscriptions for both hosts")
    remoteManager.desktopMessage(["method": "thread-stream-following-status-requested", "sourceClientId": "other-owner", "params": ["hostId": "remote-ssh-discovered:unknown", "conversationId": "shared"]])
    let unsolicitedReplay = try await desktopClient.request("fixture/broadcasts", [:])
    check((unsolicitedReplay["messages"] as? [[String: Any]])?.isEmpty == true, "unknown host cannot solicit a subscription")
    remoteManager.desktopMessage(["method": "ipc-connection-reset"])
    let resetReplay = try await desktopClient.request("fixture/broadcasts", [:])
    let resetMessages = resetReplay["messages"] as? [[String: Any]] ?? []
    check(resetMessages.count == 2 && resetMessages.allSatisfy { $0["targetClientIds"] == nil },
          "IPC reset rebroadcasts all desired subscriptions")

    let desktopReply = try await desktopClient.request("thread-follower-submit-user-input", ["conversationId": "fixture-thread", "requestId": "input-1", "response": ["answers": ["branch": ["answers": ["功能分支🚀"]]]]], targetClientID: "fixture-owner", version: 1)
    check(desktopReply["ok"] as? Bool == true, "desktop fragmented frames and exact targeted Unicode reply")
    let asyncTransport = try await desktopClient.request("thread-follower-steer-turn",
        ["conversationId": "fixture-thread", "input": [["type": "text", "text": "<send_user_message_question_reply>fixture</send_user_message_question_reply>"]],
         "restoreMessage": ["context": ["turnTrigger": "send_user_message_async_question"]]], targetClientID: "fixture-owner", version: 1)
    check(asyncTransport["ok"] as? Bool == true, "async reply uses targeted steering route")
    let remoteTransport = try await desktopClient.request("thread-follower-submit-user-input",
        ["conversationId": "fixture-thread", "requestId": "input-1", "response": ["answers": ["branch": ["answers": ["功能分支🚀"]]]]],
        targetClientID: "fixture-owner", version: 1, hostID: "remote-ssh-discovered:fixture")
    check(remoteTransport["ok"] as? Bool == true, "remote reply uses explicit envelope host and version two")
    let beforeDesktopDisconnect = desktopClient.generation
    desktopClient.disconnect()
    check(desktopClient.generation != beforeDesktopDisconnect, "desktop disconnect invalidates request identity")
    let manager = ExecutionManager(); manager.demo = true
    let base: [String: Any] = ["threadId": "T", "turn": ["id": "one", "status": "inProgress"]]
    manager.handle("turn/started", base)
    manager.requested(.number(1), "item/commandExecution/requestApproval", ["threadId": "T", "turnId": "one"])
    manager.requested(.string("1"), "item/fileChange/requestApproval", ["threadId": "T", "turnId": "one"])
    check(manager.queue.count == 2, "mixed RPC ids coexist")
    let first = manager.queue[0]
    try manager.respond(first.id, result: first.approval(allow: false)!)
    check(manager.queue.count == 1, "one click resolves only one decision")
    manager.handle("turn/completed", ["threadId": "T", "turn": ["id": "one", "status": "completed"]])
    check(manager.queue.isEmpty, "completion clears pending decision")
    manager.handle("turn/started", ["threadId": "T", "turn": ["id": "two", "status": "inProgress"]])
    manager.acknowledge(first.id.execution)
    check(manager.store.sorted.count == 1 && manager.store.sorted[0].id.turnID == "two", "new turn survives acknowledgement")
    manager.requested(.number(3), "item/tool/requestUserInput", ["threadId": "T", "turnId": "two", "questions": [["id": "q", "question": "分支名"]]])
    let stale = manager.queue[0].id
    manager.simulateDisconnect()
    do { try manager.respond(stale, result: ["answers": [:]]); check(false, "stale reply accepted") } catch { assertions += 1 }
    check(manager.store.sorted[0].state == .unknown, "disconnect becomes unknown")

    let client = CodexAppServerClient(); client.executableOverride = mock
    var received = false; var replySeen = false; var lost = false
    client.onRequest = { id, method, params in
        received = id == .string("approval-7") && method == "item/commandExecution/requestApproval" && params["turnId"] as? String == "turn"
        try? client.respond(id, result: ["decision": "decline"], connection: client.generation)
    }
    client.onNotification = { method, params in
        if method == "fixture/received" { replySeen = params["decision"] as? String == "decline" }
    }
    client.onDisconnect = { lost = true }
    try await client.connect()
    _ = try await client.request("fixture/request")
    for _ in 0..<100 where !replySeen { try await Task.sleep(nanoseconds: 10_000_000) }
    check(received && replySeen, "stdio request response roundtrip")
    do { _ = try await client.request("fixture/error"); check(false, "rpc error ignored") }
    catch CodexAppServerClient.Failure.rpc(let code) { check(code == -32601, "rpc error preserved") }
    let oldGeneration = client.generation
    do { _ = try await client.request("fixture/exit"); check(false, "EOF not propagated") } catch { assertions += 1 }
    check(lost && oldGeneration != client.generation, "EOF invalidates session")
    try await client.connect()
    check(client.generation != oldGeneration, "reconnect has new generation")
    client.disconnect()
    // State reconciliation and error classification.
    manager.snapshot(["id": "T", "name": "Restored", "turns": [["id": "two", "status": "completed", "startedAt": 1, "completedAt": 9]], "status": ["type": "idle"]])
    check(manager.store.sorted.first?.state == .completed, "offline completion reconciles")
    for index in 0..<12 { manager.handle("turn/started", ["threadId": "parallel-\(index)", "turn": ["id": "turn", "status": "inProgress"]]) }
    check(manager.store.sorted.filter { $0.state == .running }.count == 12, "twelve concurrent executions")
    manager.handle("error", ["threadId": "parallel-0", "turnId": "turn", "willRetry": true])
    check(manager.store.sorted.first { $0.id.threadID == "parallel-0" }?.state == .running, "retryable errors not failures")
    manager.handle("error", ["threadId": "parallel-0", "turnId": "turn", "willRetry": false])
    check(manager.store.sorted.first { $0.id.threadID == "parallel-0" }?.state == .failed, "unrecoverable error fails turn")
    manager.handle("thread/status/changed", ["threadId": "parallel-1", "status": ["type": "systemError"]])
    check(manager.store.sorted.first { $0.id.threadID == "parallel-1" }?.state == .failed, "system error fails active turn")
    let appMonitor = ApplicationMonitor(); var transitions = 0
    appMonitor.onChange = { was, isNow in if was && !isNow { transitions += 1 } }
    appMonitor.update(isCodex: true); appMonitor.update(isCodex: false); appMonitor.update(isCodex: false)
    check(transitions == 1, "snapshot triggered only leaving Codex")

    // Full manager uses the production WebSocket transport against an offline peer.
    let suite = "io.local.CodexTouchBarMonitor.tests." + UUID().uuidString
    let pauseDefaults = UserDefaults(suiteName: suite)!
    defer { pauseDefaults.removePersistentDomain(forName: suite) }
    let live = ExecutionManager(pauseDefaults: pauseDefaults); live.client.executableOverride = mock
    live.start()
    defer { live.stop() }
    for _ in 0..<600 {
        if live.store.sorted.filter({ $0.id.threadID.hasPrefix("fixture-") && $0.id.turnID == "turn" }).count == 12 { break }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    check(live.connected && live.store.sorted.filter { $0.id.turnID == "turn" }.count == 12, "WebSocket loaded-list pagination and subscription")
    live.handle("turn/started", ["threadId": "fixture-0", "turn": ["id": "old", "status": "inProgress"]])
    await live.discover()
    check(live.store.sorted.first { $0.id.turnID == "old" }?.state == .completed, "older turn page reconciled")
    _ = try await live.client.request("fixture/decision")
    check(live.queue.count == 1, "WebSocket server request routed to manager")
    let pending = live.queue[0]
    try live.respond(pending.id, result: ["answers": ["q": ["answers": ["fixture secret 中文"]]]])
    for _ in 0..<100 where !live.queue.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
    check(live.queue.isEmpty, "WebSocket resolution clears sent decision")
    let stats = try await live.client.request("fixture/stats")
    check(stats["replies"] as? Int == 1, "exactly one response delivered")
    try await live.interrupt(ExecutionID(serverID: live.serverID, threadID: "fixture-1", turnID: "turn"))
    check(live.store.sorted.first { $0.id.threadID == "fixture-1" }?.state == .failed, "confirmed interrupt event closes only target turn")
    let pauseID = ExecutionID(serverID: live.serverID, threadID: "fixture-2", turnID: "turn")
    try await live.pause(pauseID)
    check(live.store.executions[pauseID]?.state == .paused && live.pauseRequests.contains(pauseID), "pause requires interrupted event")
    do { try await live.pause(pauseID); check(false, "duplicate pause sent") } catch { assertions += 1 }
    try await live.continuePaused(pauseID)
    check(!live.pauseRequests.contains(pauseID) && live.store.executions[pauseID] == nil, "new turn consumes pause checkpoint")
    let continuationStats = try await live.client.request("fixture/stats")
    check(continuationStats["starts"] as? Int == 1 && continuationStats["interrupts"] as? Int == 2, "one pause and one explicit continuation")
    let rejected = ExecutionID(serverID: live.serverID, threadID: "fixture-3", turnID: "turn")
    _ = try await live.client.request("fixture/control", ["reject": true])
    do { try await live.pause(rejected); check(false, "pause rejection ignored") } catch { assertions += 1 }
    check(!live.pauseRequests.contains(rejected) && live.store.executions[rejected]?.state == .running, "RPC rejection leaves execution running")
    let uncertain = ExecutionID(serverID: live.serverID, threadID: "fixture-4", turnID: "turn")
    try await live.pause(uncertain)
    _ = try await live.client.request("fixture/control", ["dropStart": true])
    live.client.requestTimeoutNanoseconds = 100_000_000
    do { try await live.continuePaused(uncertain); check(false, "continue timeout ignored") } catch { assertions += 1 }
    check(live.resumeUncertain.contains(uncertain), "uncertain continuation stays locked")
    let restored = ExecutionManager(pauseDefaults: pauseDefaults); restored.client.executableOverride = mock
    restored.start()
    check(restored.pauseRequests.contains(uncertain) && restored.resumeUncertain.contains(uncertain), "restart restores uncertain pause without resending")
    check((pauseDefaults.array(forKey: "PausedExecutions") as? [[String: String]])?.allSatisfy { Set($0.keys).isSubset(of: ["server", "thread", "turn", "uncertain"]) } == true, "checkpoint stores identities only")
    restored.stop()
    do { try await live.continuePaused(uncertain); check(false, "uncertain continuation retried") } catch { assertions += 1 }
    live.client.requestTimeoutNanoseconds = 15_000_000_000
    await live.discover()
    check(!live.pauseRequests.contains(uncertain), "read-only reconciliation finds delivered continuation")
    let advanced = ExecutionID(serverID: live.serverID, threadID: "fixture-5", turnID: "turn")
    try await live.pause(advanced)
    _ = try await live.client.request("fixture/advance", ["threadId": advanced.threadID])
    do { try await live.continuePaused(advanced); check(false, "stale paused task resumed") } catch { assertions += 1 }
    let protectedStats = try await live.client.request("fixture/stats")
    check(protectedStats["starts"] as? Int == 2, "stale or uncertain state never sends another start")
    let telemetryID = ExecutionID(serverID: live.serverID, threadID: "fixture-6", turnID: "turn")
    live.handle("turn/plan/updated", ["threadId": "fixture-6", "turnId": "turn", "plan": [["step": "Ready", "status": "completed"]]])
    live.handle("item/started", ["threadId": "fixture-6", "turnId": "turn", "item": ["id": "tool", "type": "commandExecution", "command": "fixture only"]])
    check(live.telemetry[telemetryID]?.planFraction == 1 && live.telemetry[telemetryID]?.currentActivities.count == 1, "telemetry routed by exact turn")
    live.handle("turn/completed", ["threadId": "fixture-6", "turn": ["id": "turn", "status": "completed"]])
    check(live.telemetry[telemetryID]?.currentActivities.isEmpty == true, "terminal turn clears running tool")
    live.acknowledge(telemetryID)
    check(live.telemetry[telemetryID] == nil, "acknowledgement releases telemetry")
    live.client.requestTimeoutNanoseconds = 20_000_000
    do { _ = try await live.client.request("fixture/timeout"); check(false, "missing timeout") }
    catch CodexAppServerClient.Failure.timeout { assertions += 1 }
    live.client.requestTimeoutNanoseconds = 15_000_000_000
    let cancelled = Task { try await live.client.request("fixture/timeout") }
    try await Task.sleep(nanoseconds: 10_000_000); cancelled.cancel()
    do { _ = try await cancelled.value; check(false, "missing cancellation") } catch is CancellationError { assertions += 1 }
    live.stop()
    let defaults = UserDefaults.standard
    let previousDomain = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
    defaults.setVolatileDomain(["NotificationsEnabled": true, "DecisionNotificationDelay": 0.08], forName: UserDefaults.argumentDomain)
    defer { defaults.setVolatileDomain(previousDomain, forName: UserDefaults.argumentDomain) }
    let notifier = AttentionNotifier(); var notifications: [String] = []
    notifier.delivery = { notifications.append($0) }
    let noticeDecision = DecisionRequest(id: pending.id, method: pending.method, params: [:])
    let noticeState = AppState(isCodexForeground: false, executions: [], decisions: [noticeDecision], connected: true)
    let emptyState = AppState(isCodexForeground: false, executions: [], decisions: [], connected: true)
    notifier.reconcile(noticeState); notifier.reconcile(emptyState)
    try await Task.sleep(nanoseconds: 120_000_000)
    check(notifications.isEmpty, "resolved decisions cancel delayed notifications")
    notifier.reconcile(noticeState)
    try await Task.sleep(nanoseconds: 120_000_000)
    notifier.reconcile(noticeState)
    try await Task.sleep(nanoseconds: 100_000_000)
    check(notifications.count == 1, "decision notified once per exact request")
    let failedExecution = MonitoredExecution(id: pending.id.execution, title: "Never include this title", state: .failed)
    notifier.reconcile(AppState(isCodexForeground: false, executions: [failedExecution], decisions: [], connected: true))
    check(notifications.count == 2 && !notifications.joined().contains("Never include"), "failure notifies independently without content")
    notifier.stop()
    defaults.setVolatileDomain(["NotificationsEnabled": false, "DecisionNotificationDelay": 0, "SoundFeedback": true, "HapticFeedback": true], forName: UserDefaults.argumentDomain)
    let feedbackOnly = AttentionNotifier(); var feedbacks = 0; var banners = 0
    feedbackOnly.feedback.output = { sound, haptic in if sound && haptic { feedbacks += 1 } }
    feedbackOnly.delivery = { _ in banners += 1 }
    feedbackOnly.reconcile(noticeState)
    try await Task.sleep(nanoseconds: 30_000_000)
    feedbackOnly.reconcile(noticeState)
    check(feedbacks == 1 && banners == 0, "feedback works without banners and deduplicates")
    feedbackOnly.feedback.play()
    check(feedbacks == 1, "burst feedback throttled")
    feedbackOnly.stop()
    print("PASS: \(assertions) integration assertions; no Touch Bar required")
}

@MainActor func probeDaemon() async throws {
    let client = CodexAppServerClient()
    defer { client.disconnect() }
    try await client.connect(mode: .daemon(NSHomeDirectory() + "/.codex/app-server-control/app-server-control.sock"))
    let result = try await client.request("thread/loaded/list")
    print("PASS: daemon WebSocket initialization; loaded task count = \((result["data"] as? [String] ?? []).count)")
}
