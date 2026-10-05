import Foundation
import CSQLite

/// A small, serialized SQLite store. Bind all values; table names are compile-time model constants.
public final class Store: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let tables = ["hosts", "folders", "identities", "snippets", "history", "pins"]

    public init(url: URL) throws {
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let error = BozhouError.storage("无法打开数据库")
            sqlite3_close(db); throw error
        }
        sqlite3_busy_timeout(db, 3000)
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA foreign_keys=ON")
        let version = try query("PRAGMA user_version").first?.first ?? "0"
        guard ["0", "1", "2"].contains(version) else {
            throw BozhouError.storage("数据库由更新版本的泊舟创建，请更新应用")
        }
        for table in tables {
            try execute("CREATE TABLE IF NOT EXISTS \(table) (id TEXT PRIMARY KEY, payload TEXT NOT NULL, updated REAL NOT NULL)")
        }
        try execute("CREATE TABLE IF NOT EXISTS settings (id TEXT PRIMARY KEY, payload TEXT NOT NULL)")
        // Existing duplicate pins are collapsed before enforcing uniqueness at the database boundary.
        try execute("""
        DELETE FROM pins WHERE rowid NOT IN (
          SELECT MIN(rowid) FROM pins GROUP BY
            json_extract(payload,'$.interaction.command'), json_extract(payload,'$.interaction.output')
        )
        """)
        try execute("""
        CREATE UNIQUE INDEX IF NOT EXISTS pins_content ON pins(
          json_extract(payload,'$.interaction.command'), json_extract(payload,'$.interaction.output'))
        """)
        try execute("PRAGMA user_version=2")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    deinit { sqlite3_close(db) }

    public func list<T: Record>(_ type: T.Type) throws -> [T] {
        lock.lock(); defer { lock.unlock() }
        try validate(T.table)
        return try query("SELECT payload FROM \(T.table) ORDER BY updated DESC").map {
            try decoder.decode(T.self, from: Data($0[0].utf8))
        }
    }

    public func save<T: Record>(_ record: T) throws {
        lock.lock(); defer { lock.unlock() }
        try validate(T.table)
        if let pin = record as? Pin,
           let existing = try list(Pin.self).first(where: {
               $0.interaction.command == pin.interaction.command && $0.interaction.output == pin.interaction.output
           }), existing.id != pin.id { return }
        let json = String(decoding: try encoder.encode(record), as: UTF8.self)
        try execute("INSERT INTO \(T.table)(id,payload,updated) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload, updated=excluded.updated",
                    [record.id.uuidString, json, String(Date().timeIntervalSince1970)])
    }

    public func delete<T: Record>(_ type: T.Type, id: UUID) throws {
        try validate(T.table)
        try execute("DELETE FROM \(T.table) WHERE id=?", [id.uuidString])
    }

    /// Update only the credential: the helper must not overwrite a simultaneous host edit.
    public func savePassword(_ password: String, hostID: UUID) throws {
        try execute("UPDATE hosts SET payload=json_set(payload,'$.password',?), updated=? WHERE id=?",
                    [password, String(Date().timeIntervalSince1970), hostID.uuidString])
    }

    public func clearHistory() throws { try execute("DELETE FROM history") }
    public func trimHistory(limit: Int) throws {
        try execute("DELETE FROM history WHERE id NOT IN (SELECT id FROM history ORDER BY updated DESC LIMIT ?)", [String(max(0, limit))])
    }
    public func loadSettings() throws -> AppSettings {
        lock.lock(); defer { lock.unlock() }
        guard let row = try query("SELECT payload FROM settings WHERE id='app'").first else { return AppSettings() }
        return try decoder.decode(AppSettings.self, from: Data(row[0].utf8))
    }
    public func saveSettings(_ settings: AppSettings) throws {
        lock.lock(); defer { lock.unlock() }
        let payload = String(decoding: try encoder.encode(settings), as: UTF8.self)
        try execute("INSERT INTO settings(id,payload) VALUES('app',?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload", [payload])
    }

    public func transaction(_ action: () throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE")
        do { try action(); try execute("COMMIT") }
        catch { try? execute("ROLLBACK"); throw error }
    }

    /// Online SQLite backup includes committed WAL pages without mutating the source.
    public func backup(to url: URL) throws {
        lock.lock(); defer { lock.unlock() }
        guard !FileManager.default.fileExists(atPath: url.path) else { throw BozhouError.storage("目标数据库已存在") }
        var destination: OpaquePointer?
        guard sqlite3_open(url.path, &destination) == SQLITE_OK else {
            sqlite3_close(destination); throw BozhouError.storage("无法创建目标数据库")
        }
        defer { sqlite3_close(destination) }
        guard let backup = sqlite3_backup_init(destination, "main", db, "main") else { throw failure() }
        let result = sqlite3_backup_step(backup, -1)
        let finish = sqlite3_backup_finish(backup)
        guard result == SQLITE_DONE, finish == SQLITE_OK else { throw BozhouError.storage("数据库备份失败") }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func validate(_ table: String) throws {
        guard tables.contains(table) else { throw BozhouError.storage("无效的数据类型") }
    }
    private func statement(_ sql: String, _ values: [String]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw failure() }
        for (index, value) in values.enumerated() {
            let result = value.withCString { sqlite3_bind_text(stmt, Int32(index + 1), $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            if result != SQLITE_OK { sqlite3_finalize(stmt); throw failure() }
        }
        return stmt
    }
    private func execute(_ sql: String, _ values: [String] = []) throws {
        lock.lock(); defer { lock.unlock() }
        let stmt = try statement(sql, values); defer { sqlite3_finalize(stmt) }
        let result = sqlite3_step(stmt)
        guard result == SQLITE_DONE || result == SQLITE_ROW else { throw failure() }
    }
    private func query(_ sql: String, _ values: [String] = []) throws -> [[String]] {
        lock.lock(); defer { lock.unlock() }
        let stmt = try statement(sql, values); defer { sqlite3_finalize(stmt) }
        var rows: [[String]] = []
        while true {
            let result = sqlite3_step(stmt)
            if result == SQLITE_DONE { return rows }
            guard result == SQLITE_ROW else { throw failure() }
            rows.append((0..<sqlite3_column_count(stmt)).map { column in
                sqlite3_column_text(stmt, column).map { String(cString: $0) } ?? ""
            })
        }
    }
    private func failure() -> BozhouError {
        .storage("数据库操作失败：\(db.map { String(cString: sqlite3_errmsg($0)) } ?? "未连接")")
    }
}
