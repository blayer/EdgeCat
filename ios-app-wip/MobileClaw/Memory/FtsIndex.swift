import Foundation
import SQLite3

// FTS5 wrapper for the memory module. SwiftData has no FTS support, so we
// keep a parallel SQLite database at Application Support/memory_fts.sqlite
// with a single `episodes_fts` virtual table. The SwiftDataMemoryRepository
// pushes inserts here, and recallForPlanning queries this index first.
//
// Failure modes (open / prepare / step) are silent and fall through to the
// substring fallback in SwiftDataMemoryRepository — search is best-effort,
// not load-bearing.

final class FtsIndex: @unchecked Sendable {
    static let shared = FtsIndex()

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.mobileclaw.fts", qos: .utility)

    private init() {
        queue.sync { open() }
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: - Public API

    /// Insert (or replace) an episode in the FTS index.
    func index(episode: Episode) {
        queue.async { [weak self] in
            guard let self, let db = self.db else { return }
            // Replace by rowid — we use a deterministic hash of the id string
            // so re-indexing the same episode overwrites cleanly.
            let rowid = Self.rowid(for: episode.id)
            var stmt: OpaquePointer?
            let sql = "INSERT OR REPLACE INTO episodes_fts (rowid, episode_id, body) VALUES (?, ?, ?);"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, rowid)
            sqlite3_bind_text(stmt, 2, episode.id, -1, SQLITE_TRANSIENT)
            let body = "\(episode.userMessage)\n\(episode.goal)\n\(episode.finalOutput)"
            sqlite3_bind_text(stmt, 3, body, -1, SQLITE_TRANSIENT)
            _ = sqlite3_step(stmt)
        }
    }

    /// MATCH-search the index. Returns up to `limit` episode ids in
    /// FTS5-rank order. Empty result on failure or no matches.
    func search(query: String, limit: Int = 5) -> [String] {
        guard !query.isEmpty else { return [] }
        return queue.sync {
            guard let db else { return [] }
            var stmt: OpaquePointer?
            let sql = """
            SELECT episode_id FROM episodes_fts
            WHERE episodes_fts MATCH ?
            ORDER BY rank LIMIT ?;
            """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            // Sanitize the query: split into tokens, MATCH each as a prefix
            // term joined with OR — gives lenient recall without crashing on
            // FTS5 reserved characters.
            let tokens = query
                .components(separatedBy: .whitespacesAndNewlines)
                .map { $0.replacingOccurrences(of: "\"", with: "") }
                .filter { !$0.isEmpty }
            let matchExpr = tokens.map { "\($0)*" }.joined(separator: " OR ")
            sqlite3_bind_text(stmt, 1, matchExpr, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 2, Int32(limit))
            var ids: [String] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let cstr = sqlite3_column_text(stmt, 0) {
                    ids.append(String(cString: cstr))
                }
            }
            return ids
        }
    }

    /// Drop everything — used by `MemoryRepository.clearAll()`.
    func clear() {
        queue.async { [weak self] in
            guard let self, let db = self.db else { return }
            sqlite3_exec(db, "DELETE FROM episodes_fts;", nil, nil, nil)
        }
    }

    // MARK: - Private

    private func open() {
        let appSupport: URL
        do {
            appSupport = try FileManager.default.url(for: .applicationSupportDirectory,
                                                     in: .userDomainMask,
                                                     appropriateFor: nil, create: true)
        } catch {
            return
        }
        let path = appSupport.appendingPathComponent("memory_fts.sqlite").path
        if sqlite3_open_v2(path, &db,
                           SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                           nil) != SQLITE_OK {
            db = nil
            return
        }
        // Create the virtual table if missing. FTS5 ships with the system
        // SQLite on iOS 13+.
        let schema = """
        CREATE VIRTUAL TABLE IF NOT EXISTS episodes_fts USING fts5(
            episode_id UNINDEXED,
            body,
            tokenize='unicode61 remove_diacritics 1'
        );
        """
        sqlite3_exec(db, schema, nil, nil, nil)
    }

    /// FNV-1a 64-bit hash for a stable rowid per episode id.
    private static func rowid(for s: String) -> Int64 {
        var h: UInt64 = 0xcbf29ce484222325
        for byte in s.utf8 {
            h ^= UInt64(byte)
            h = h &* 0x100000001b3
        }
        // Sqlite rowid is signed 64-bit; clamp the top bit.
        return Int64(bitPattern: h & 0x7fff_ffff_ffff_ffff)
    }
}

// SQLITE_TRANSIENT — needed when binding strings that may go out of scope
// before sqlite3_step runs.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
