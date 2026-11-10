import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// One-time migration of the data directory from the app's former name ("PasteClone") to "CommandV".
public enum LegacyDataMigration {
    public static let legacyName = "PasteClone"
    public static let currentName = "CommandV"
    public static let databaseName = "history.sqlite"

    /// Moves `<appSupport>/PasteClone` to `<appSupport>/CommandV` when only the old one exists, then rewrites
    /// absolute blob/thumb paths in the database. Never deletes anything; on failure it logs and returns false.
    @discardableResult
    public static func migrateIfNeeded(appSupport: URL, fileManager: FileManager = .default) -> Bool {
        let old = appSupport.appendingPathComponent(legacyName, isDirectory: true)
        let new = appSupport.appendingPathComponent(currentName, isDirectory: true)
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: old.path, isDirectory: &isDir), isDir.boolValue else { return false }
        guard !fileManager.fileExists(atPath: new.path) else {
            NSLog("CommandV: both legacy and current data directories exist; skipping migration")
            return false
        }
        do {
            try fileManager.moveItem(at: old, to: new)
        } catch {
            NSLog("CommandV: couldn't move legacy data directory: \(error)")
            return false
        }
        let db = new.appendingPathComponent(databaseName).path
        guard fileManager.fileExists(atPath: db) else { return true }
        do {
            try rewritePaths(database: db, oldDir: old.path, newDir: new.path)
        } catch {
            NSLog("CommandV: moved data but couldn't rewrite stored paths: \(error)")
            return false
        }
        return true
    }

    private struct SQLiteFailure: Error { let message: String }

    static func rewritePaths(database: String, oldDir: String, newDir: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(database, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle)
            throw SQLiteFailure(message: msg)
        }
        defer { sqlite3_close(handle) }
        sqlite3_busy_timeout(handle, 2000)

        func fail() -> SQLiteFailure { SQLiteFailure(message: String(cString: sqlite3_errmsg(handle))) }

        guard sqlite3_exec(handle, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK else { throw fail() }
        do {
            let oldPrefix = oldDir + "/", newPrefix = newDir + "/"
            for column in ["blob_path", "thumb_path"] {
                // substr/length compare avoids LIKE wildcard issues in directory names.
                let sql = "UPDATE clips SET \(column) = ?1 || substr(\(column), length(?2) + 1) WHERE substr(\(column), 1, length(?2)) = ?2;"
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { throw fail() }
                defer { sqlite3_finalize(stmt) }
                sqlite3_bind_text(stmt, 1, newPrefix, -1, sqliteTransient)
                sqlite3_bind_text(stmt, 2, oldPrefix, -1, sqliteTransient)
                guard sqlite3_step(stmt) == SQLITE_DONE else { throw fail() }
            }
            guard sqlite3_exec(handle, "COMMIT;", nil, nil, nil) == SQLITE_OK else { throw fail() }
        } catch {
            sqlite3_exec(handle, "ROLLBACK;", nil, nil, nil)
            throw error
        }
    }
}
