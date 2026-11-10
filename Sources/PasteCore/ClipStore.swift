import Foundation
import SQLite3

public enum ClipStoreError: Error {
    case sqlite(code: Int32, message: String)
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public final class ClipStore: @unchecked Sendable {
    private var db: OpaquePointer?
    let lock = NSLock()

    public init(path: String) throws {
        let dir = (path as NSString).deletingLastPathComponent
        if !dir.isEmpty {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard rc == SQLITE_OK else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle)
            throw ClipStoreError.sqlite(code: rc, message: msg)
        }
        db = handle
        try exec("PRAGMA journal_mode=WAL;")
        try exec("PRAGMA foreign_keys=ON;")
        try exec("PRAGMA busy_timeout=2000;")
        try exec(Self.schema)
        try migrate()
    }

    /// Current schema version. Bump this and add a case to `migrate()` when the schema changes.
    public static let currentSchemaVersion = 1

    /// The database's `PRAGMA user_version`.
    public func userVersion() throws -> Int {
        lock.lock(); defer { lock.unlock() }
        return try readUserVersion()
    }

    private func readUserVersion() throws -> Int {
        Int(try run("PRAGMA user_version;") { sqlite3_column_int64($0, 0) }.first ?? 0)
    }

    /// Brings the database up to `currentSchemaVersion`. Version 0 is a brand-new or pre-versioning (v1) database;
    /// `schema` is idempotent, so it only needs stamping.
    private func migrate() throws {
        var v = try readUserVersion()
        guard v <= Self.currentSchemaVersion else {
            throw ClipStoreError.sqlite(code: SQLITE_MISUSE, message: "database schema version \(v) is newer than this app supports")
        }
        while v < Self.currentSchemaVersion {
            switch v {
            case 0: break   // v1 schema was created by `schema` above
            // case 1: try exec("ALTER TABLE ..."); future migrations go here
            default: break
            }
            v += 1
            try exec("PRAGMA user_version=\(v);")
        }
    }

    deinit { sqlite3_close(db) }

    private static let schema = """
    CREATE TABLE IF NOT EXISTS pinboards(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        color_hex TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS clips(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        kind TEXT NOT NULL,
        text TEXT,
        blob_path TEXT,
        thumb_path TEXT,
        source_bundle_id TEXT,
        source_name TEXT,
        created_at REAL NOT NULL,
        pinboard_id INTEGER REFERENCES pinboards(id) ON DELETE SET NULL,
        ocr_text TEXT,
        content_hash TEXT NOT NULL UNIQUE
    );
    CREATE INDEX IF NOT EXISTS clips_created_idx ON clips(created_at DESC);
    CREATE VIRTUAL TABLE IF NOT EXISTS clips_fts USING fts5(
        text, ocr_text, source_name, content='clips', content_rowid='id'
    );
    CREATE TRIGGER IF NOT EXISTS clips_ai AFTER INSERT ON clips BEGIN
        INSERT INTO clips_fts(rowid, text, ocr_text, source_name)
        VALUES (new.id, new.text, new.ocr_text, new.source_name);
    END;
    CREATE TRIGGER IF NOT EXISTS clips_ad AFTER DELETE ON clips BEGIN
        INSERT INTO clips_fts(clips_fts, rowid, text, ocr_text, source_name)
        VALUES ('delete', old.id, old.text, old.ocr_text, old.source_name);
    END;
    CREATE TRIGGER IF NOT EXISTS clips_au AFTER UPDATE ON clips BEGIN
        INSERT INTO clips_fts(clips_fts, rowid, text, ocr_text, source_name)
        VALUES ('delete', old.id, old.text, old.ocr_text, old.source_name);
        INSERT INTO clips_fts(rowid, text, ocr_text, source_name)
        VALUES (new.id, new.text, new.ocr_text, new.source_name);
    END;
    """

    // MARK: - Helpers (callers hold the lock)

    private func error(_ rc: Int32) -> ClipStoreError {
        .sqlite(code: rc, message: db.map { String(cString: sqlite3_errmsg($0)) } ?? "no db")
    }

    private func exec(_ sql: String) throws {
        let rc = sqlite3_exec(db, sql, nil, nil, nil)
        guard rc == SQLITE_OK else { throw error(rc) }
    }

    enum Value { case text(String?), int(Int64?), double(Double) }

    func run<T>(_ sql: String, _ params: [Value] = [], row: (OpaquePointer) -> T) throws -> [T] {
        var stmt: OpaquePointer?
        var rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else { throw error(rc) }
        defer { sqlite3_finalize(stmt) }
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            switch p {
            case .text(let s):
                if let s { sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, idx) }
            case .int(let n):
                if let n { sqlite3_bind_int64(stmt, idx, n) } else { sqlite3_bind_null(stmt, idx) }
            case .double(let d):
                sqlite3_bind_double(stmt, idx, d)
            }
        }
        var out: [T] = []
        while true {
            rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW { out.append(row(stmt)) }
            else if rc == SQLITE_DONE { break }
            else { throw error(rc) }
        }
        return out
    }

    private static func str(_ s: OpaquePointer, _ i: Int32) -> String? {
        sqlite3_column_type(s, i) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(s, i))
    }

    static let columns = "id, kind, text, blob_path, thumb_path, source_bundle_id, source_name, created_at, pinboard_id, ocr_text, content_hash"

    static func clip(_ s: OpaquePointer) -> Clip {
        Clip(id: sqlite3_column_int64(s, 0),
             kind: ClipKind(rawValue: str(s, 1) ?? "") ?? .text,
             text: str(s, 2), blobPath: str(s, 3), thumbPath: str(s, 4),
             sourceBundleID: str(s, 5), sourceName: str(s, 6),
             createdAt: Date(timeIntervalSince1970: sqlite3_column_double(s, 7)),
             pinboardID: sqlite3_column_type(s, 8) == SQLITE_NULL ? nil : sqlite3_column_int64(s, 8),
             ocrText: str(s, 9), contentHash: str(s, 10) ?? "")
    }

    // MARK: - Clips

    /// Inserts a clip. If a clip with the same `contentHash` exists, its `createdAt` is updated instead.
    public func insert(_ clip: Clip) throws -> Clip {
        lock.lock(); defer { lock.unlock() }
        let existing = try run("SELECT id FROM clips WHERE content_hash = ?;", [.text(clip.contentHash)]) {
            sqlite3_column_int64($0, 0)
        }
        let id: Int64
        if let found = existing.first {
            id = found
            _ = try run("UPDATE clips SET created_at = ? WHERE id = ?;",
                        [.double(clip.createdAt.timeIntervalSince1970), .int(id)]) { _ in () }
        } else {
            _ = try run("""
                INSERT INTO clips(kind, text, blob_path, thumb_path, source_bundle_id, source_name, created_at, pinboard_id, ocr_text, content_hash)
                VALUES (?,?,?,?,?,?,?,?,?,?);
                """,
                [.text(clip.kind.rawValue), .text(clip.text), .text(clip.blobPath), .text(clip.thumbPath),
                 .text(clip.sourceBundleID), .text(clip.sourceName),
                 .double(clip.createdAt.timeIntervalSince1970), .int(clip.pinboardID),
                 .text(clip.ocrText), .text(clip.contentHash)]) { _ in () }
            id = sqlite3_last_insert_rowid(db)
        }
        return try run("SELECT \(Self.columns) FROM clips WHERE id = ?;", [.int(id)], row: Self.clip)[0]
    }

    public func recent(limit: Int, offset: Int) throws -> [Clip] {
        lock.lock(); defer { lock.unlock() }
        return try run("SELECT \(Self.columns) FROM clips ORDER BY created_at DESC, id DESC LIMIT ? OFFSET ?;",
                       [.int(Int64(limit)), .int(Int64(offset))], row: Self.clip)
    }

    public func delete(id: Int64) throws {
        lock.lock(); defer { lock.unlock() }
        _ = try run("DELETE FROM clips WHERE id = ?;", [.int(id)]) { _ in () }
    }

    public func clipCount() throws -> Int {
        lock.lock(); defer { lock.unlock() }
        return Int(try run("SELECT COUNT(*) FROM clips;") { sqlite3_column_int64($0, 0) }.first ?? 0)
    }

    /// Number of clips not saved in a pinboard (what `deleteAll` removes).
    public func unpinnedClipCount() throws -> Int {
        lock.lock(); defer { lock.unlock() }
        return Int(try run("SELECT COUNT(*) FROM clips WHERE pinboard_id IS NULL;") { sqlite3_column_int64($0, 0) }.first ?? 0)
    }

    /// The subset of `ids` that still exist as clips.
    public func existingClipIDs(among ids: [Int64]) throws -> Set<Int64> {
        guard !ids.isEmpty else { return [] }
        lock.lock(); defer { lock.unlock() }
        let marks = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let found = try run("SELECT id FROM clips WHERE id IN (\(marks));", ids.map { .int($0) }) { sqlite3_column_int64($0, 0) }
        return Set(found)
    }

    /// Deletes the clip, then its blob and thumbnail files (only if they live inside `blobsDirectory`).
    public func deleteWithFiles(id: Int64, blobsDirectory: URL = defaultBlobsDirectory()) throws {
        lock.lock()
        let paths: [String]
        do {
            paths = try run("SELECT blob_path, thumb_path FROM clips WHERE id = ?;", [.int(id)]) {
                [Self.str($0, 0), Self.str($0, 1)].compactMap { $0 }
            }.first ?? []
            _ = try run("DELETE FROM clips WHERE id = ?;", [.int(id)]) { _ in () }
        } catch { lock.unlock(); throw error }
        lock.unlock()
        Self.removeFiles(paths, within: blobsDirectory)
    }

    /// Deletes every clip that isn't saved in a pinboard, and its files. Pinboards and pinned clips are kept.
    /// Returns how many clips were removed.
    @discardableResult
    public func deleteAll(blobsDirectory: URL = defaultBlobsDirectory()) throws -> Int {
        lock.lock()
        let paths: [String]
        let count: Int
        do {
            paths = try run("SELECT blob_path, thumb_path FROM clips WHERE pinboard_id IS NULL;") {
                [Self.str($0, 0), Self.str($0, 1)].compactMap { $0 }
            }.flatMap { $0 }
            count = Int(try run("SELECT COUNT(*) FROM clips WHERE pinboard_id IS NULL;") { sqlite3_column_int64($0, 0) }.first ?? 0)
            _ = try run("DELETE FROM clips WHERE pinboard_id IS NULL;") { _ in () }
        } catch { lock.unlock(); throw error }
        lock.unlock()
        Self.removeFiles(paths, within: blobsDirectory)
        return count
    }

    /// Removes files only when their resolved location is strictly inside `directory`.
    static func removeFiles(_ paths: [String], within directory: URL) {
        let root = directory.resolvingSymlinksInPath().standardizedFileURL.path
        for p in paths {
            let resolved = URL(fileURLWithPath: p).resolvingSymlinksInPath().standardizedFileURL.path
            guard resolved.hasPrefix(root + "/") else { continue }
            try? FileManager.default.removeItem(atPath: resolved)
        }
    }

    public func setPinboard(clipID: Int64, pinboardID: Int64?) throws {
        lock.lock(); defer { lock.unlock() }
        _ = try run("UPDATE clips SET pinboard_id = ? WHERE id = ?;", [.int(pinboardID), .int(clipID)]) { _ in () }
    }

    /// True once OCR has run for the clip (an empty string counts: only NULL means "not yet OCRed").
    public func hasOCRText(clipID: Int64) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        return try run("SELECT ocr_text IS NOT NULL FROM clips WHERE id = ?;", [.int(clipID)]) {
            sqlite3_column_int64($0, 0) != 0
        }.first ?? true   // clip gone: nothing to index
    }

    public func setOCRText(clipID: Int64, text: String) throws {
        lock.lock(); defer { lock.unlock() }
        _ = try run("UPDATE clips SET ocr_text = ? WHERE id = ?;", [.text(text), .int(clipID)]) { _ in () }
    }

    // MARK: - Pinboards

    public func pinboards() throws -> [Pinboard] {
        lock.lock(); defer { lock.unlock() }
        return try run("SELECT id, name, color_hex FROM pinboards ORDER BY id;") {
            Pinboard(id: sqlite3_column_int64($0, 0), name: Self.str($0, 1) ?? "", colorHex: Self.str($0, 2) ?? "")
        }
    }

    @discardableResult
    public func addPinboard(name: String, colorHex: String) throws -> Pinboard {
        lock.lock(); defer { lock.unlock() }
        _ = try run("INSERT INTO pinboards(name, color_hex) VALUES (?,?);", [.text(name), .text(colorHex)]) { _ in () }
        return Pinboard(id: sqlite3_last_insert_rowid(db), name: name, colorHex: colorHex)
    }

    public func deletePinboard(id: Int64) throws {
        lock.lock(); defer { lock.unlock() }
        _ = try run("DELETE FROM pinboards WHERE id = ?;", [.int(id)]) { _ in () }
    }

    public func renamePinboard(id: Int64, name: String) throws {
        lock.lock(); defer { lock.unlock() }
        _ = try run("UPDATE pinboards SET name = ? WHERE id = ?;", [.text(name), .int(id)]) { _ in () }
    }

    /// Distinct capture sources (most recently used first), for the source-app filter.
    public func sourceApps() throws -> [(bundleID: String, name: String)] {
        lock.lock(); defer { lock.unlock() }
        let rows = try run("""
            SELECT source_bundle_id, COALESCE(MAX(source_name), source_bundle_id) FROM clips
            WHERE source_bundle_id IS NOT NULL AND source_bundle_id != ''
            GROUP BY source_bundle_id ORDER BY MAX(created_at) DESC;
            """) { (Self.str($0, 0) ?? "", Self.str($0, 1) ?? "") }
        return rows.map { (bundleID: $0.0, name: $0.1) }
    }
}
