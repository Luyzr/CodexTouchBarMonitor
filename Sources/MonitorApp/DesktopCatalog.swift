import Foundation
import SQLite3
import MonitorCore

/// Candidate IDs only. Runtime state and decisions always come from Desktop IPC.
struct DesktopTaskIdentity: Hashable {
    let host: String
    let thread: String
    var serverID: String { "desktop-ipc:" + host }
    init(host: String, thread: String) { self.host = host; self.thread = thread }
    init(_ execution: ExecutionID) {
        self.host = String(execution.serverID.dropFirst("desktop-ipc:".count))
        self.thread = execution.threadID
    }
}
enum DesktopCatalog {
    enum Failure: Error { case unavailable, readFailed }
    /// Read identities only; cached catalog status is never treated as live execution state.
    static func desktopTasks(home: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex")) throws -> [DesktopTaskIdentity] {
        let path = home.appendingPathComponent("sqlite/codex-dev.db").path
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }; throw Failure.unavailable
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1000)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT host_id, thread_id FROM local_thread_catalog WHERE missing_candidate = 0 ORDER BY source_updated_at DESC", -1, &statement, nil) == SQLITE_OK else { throw Failure.readFailed }
        defer { sqlite3_finalize(statement) }
        var values: [DesktopTaskIdentity] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            if let h = sqlite3_column_text(statement, 0), let t = sqlite3_column_text(statement, 1) {
                let host = String(cString: h), thread = String(cString: t)
                if (host == "local" || host.hasPrefix("remote-")), !thread.isEmpty {
                    values.append(DesktopTaskIdentity(host: host, thread: thread))
                }
            }
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw Failure.readFailed }
        return values
    }
    static func threadIDs(home: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex")) throws -> [String] {
        let files = try FileManager.default.contentsOfDirectory(at: home, includingPropertiesForKeys: nil)
        let databases: [(Int, URL)] = files.compactMap { url in
            let name = url.lastPathComponent
            guard name.hasPrefix("state_"), name.hasSuffix(".sqlite"),
                  let version = Int(name.dropFirst(6).dropLast(7)) else { return nil }
            return (version, url)
        }
        guard let database = databases.max(by: { $0.0 < $1.0 })?.1 else { throw Failure.unavailable }
        var db: OpaquePointer?
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }; throw Failure.unavailable
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1000)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id FROM threads WHERE archived = 0 ORDER BY updated_at DESC", -1, &statement, nil) == SQLITE_OK else { throw Failure.readFailed }
        defer { sqlite3_finalize(statement) }
        var ids: [String] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            if let value = sqlite3_column_text(statement, 0) { ids.append(String(cString: value)) }
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw Failure.readFailed }
        return ids
    }
}
