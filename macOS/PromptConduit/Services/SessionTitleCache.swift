import Foundation
import SQLite3

/// Caches generated session titles to avoid re-parsing transcripts
class SessionTitleCache {

    static let shared = SessionTitleCache()

    private var db: OpaquePointer?
    private let dbPath: String

    private init() {
        // Store in ~/.config/promptconduit/
        let configDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/promptconduit")

        // Create directory if needed
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)

        dbPath = configDir.appendingPathComponent("session_titles.db").path
        openDatabase()
        createTable()
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - Database Setup

    private func openDatabase() {
        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            print("SessionTitleCache: Failed to open database at \(dbPath)")
        }
    }

    private func createTable() {
        let sql = """
            CREATE TABLE IF NOT EXISTS session_titles (
                session_id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                source TEXT NOT NULL,
                created_at TEXT NOT NULL
            );
            """

        var errMsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errMsg) != SQLITE_OK {
            if let errMsg = errMsg {
                print("SessionTitleCache: Failed to create table: \(String(cString: errMsg))")
                sqlite3_free(errMsg)
            }
        }
    }

    // MARK: - Public API

    /// Get cached title for a session
    func getTitle(sessionId: String) -> String? {
        let sql = "SELECT title FROM session_titles WHERE session_id = ?;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, sessionId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        if sqlite3_step(stmt) == SQLITE_ROW {
            if let cString = sqlite3_column_text(stmt, 0) {
                return String(cString: cString)
            }
        }

        return nil
    }

    /// Store a generated title for a session
    func setTitle(sessionId: String, title: String, source: String = "first_prompt") {
        let sql = """
            INSERT OR REPLACE INTO session_titles (session_id, title, source, created_at)
            VALUES (?, ?, ?, ?);
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return
        }
        defer { sqlite3_finalize(stmt) }

        let timestamp = ISO8601DateFormatter().string(from: Date())
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        sqlite3_bind_text(stmt, 1, sessionId, -1, transient)
        sqlite3_bind_text(stmt, 2, title, -1, transient)
        sqlite3_bind_text(stmt, 3, source, -1, transient)
        sqlite3_bind_text(stmt, 4, timestamp, -1, transient)

        if sqlite3_step(stmt) != SQLITE_DONE {
            print("SessionTitleCache: Failed to insert title for \(sessionId)")
        }
    }

    /// Clear all cached titles (for debugging)
    func clearCache() {
        let sql = "DELETE FROM session_titles;"
        var errMsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errMsg) != SQLITE_OK {
            if let errMsg = errMsg {
                print("SessionTitleCache: Failed to clear cache: \(String(cString: errMsg))")
                sqlite3_free(errMsg)
            }
        }
    }

    /// Get total number of cached titles
    var count: Int {
        let sql = "SELECT COUNT(*) FROM session_titles;"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return 0
        }
        defer { sqlite3_finalize(stmt) }

        if sqlite3_step(stmt) == SQLITE_ROW {
            return Int(sqlite3_column_int(stmt, 0))
        }

        return 0
    }
}

// MARK: - Title Generation Utilities

extension SessionTitleCache {

    /// Generates a clean, display-friendly title from a user prompt
    /// - Parameter prompt: The raw user prompt text
    /// - Returns: A cleaned title suitable for display (max 60 chars)
    static func generateTitle(from prompt: String) -> String {
        var text = prompt

        // Take first line only
        if let firstLineEnd = text.firstIndex(of: "\n") {
            text = String(text[..<firstLineEnd])
        }

        // Trim whitespace
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip common conversational prefixes (case-insensitive)
        let prefixes = [
            "help me ", "can you ", "could you ", "please ", "i need to ",
            "i want to ", "i'd like to ", "let's ", "let me ", "we need to ",
            "hi, ", "hey, ", "hello, ", "hi ", "hey ", "hello "
        ]

        let lowercased = text.lowercased()
        for prefix in prefixes {
            if lowercased.hasPrefix(prefix) {
                text = String(text.dropFirst(prefix.count))
                // Capitalize first letter after stripping
                if let first = text.first {
                    text = first.uppercased() + text.dropFirst()
                }
                break
            }
        }

        // Trim again after stripping prefix
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // If still empty, return a default
        guard !text.isEmpty else {
            return "Untitled Session"
        }

        // If short enough, return as-is
        if text.count <= 60 {
            return text
        }

        // Truncate at word boundary
        let truncated = String(text.prefix(57))
        if let lastSpace = truncated.lastIndex(of: " ") {
            return String(truncated[..<lastSpace]) + "..."
        }

        // No space found, just truncate
        return truncated + "..."
    }
}
