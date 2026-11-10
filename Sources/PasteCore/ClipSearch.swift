import Foundation

public struct ClipFilter: Sendable {
    public var query: String = ""
    public var kinds: Set<ClipKind> = []
    public var sourceBundleID: String?
    public var pinboardID: Int64?
    public var since: Date?

    public init(query: String = "", kinds: Set<ClipKind> = [], sourceBundleID: String? = nil,
                pinboardID: Int64? = nil, since: Date? = nil) {
        self.query = query; self.kinds = kinds; self.sourceBundleID = sourceBundleID
        self.pinboardID = pinboardID; self.since = since
    }
}

extension ClipStore {
    /// Builds an FTS5 MATCH expression: each whitespace token quoted, prefix-starred, AND-joined.
    static func ftsExpression(_ query: String) -> String? {
        let tokens = query.split(whereSeparator: { $0.isWhitespace }).compactMap { tok -> String? in
            let cleaned = tok.replacingOccurrences(of: "\"", with: "\"\"")
            return cleaned.isEmpty ? nil : "\"\(cleaned)\"*"
        }
        return tokens.isEmpty ? nil : tokens.joined(separator: " AND ")
    }

    public func search(_ f: ClipFilter, limit: Int) throws -> [Clip] {
        var conds: [String] = []
        var params: [Value] = []
        if let expr = Self.ftsExpression(f.query) {
            conds.append("clips.id IN (SELECT rowid FROM clips_fts WHERE clips_fts MATCH ?)")
            params.append(.text(expr))
        }
        if !f.kinds.isEmpty {
            conds.append("clips.kind IN (\(Array(repeating: "?", count: f.kinds.count).joined(separator: ",")))")
            params += f.kinds.map { .text($0.rawValue) }
        }
        if let b = f.sourceBundleID { conds.append("clips.source_bundle_id = ?"); params.append(.text(b)) }
        if let p = f.pinboardID { conds.append("clips.pinboard_id = ?"); params.append(.int(p)) }
        if let d = f.since { conds.append("clips.created_at >= ?"); params.append(.double(d.timeIntervalSince1970)) }
        let whereSQL = conds.isEmpty ? "" : "WHERE " + conds.joined(separator: " AND ")
        params.append(.int(Int64(limit)))
        let cols = Self.columns.split(separator: ",").map { "clips." + $0.trimmingCharacters(in: .whitespaces) }.joined(separator: ", ")
        lock.lock(); defer { lock.unlock() }
        return try run("SELECT \(cols) FROM clips \(whereSQL) ORDER BY clips.created_at DESC, clips.id DESC LIMIT ?;",
                       params, row: Self.clip)
    }
}
