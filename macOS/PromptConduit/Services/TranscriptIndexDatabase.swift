import Foundation
import SQLite3

/// Represents an indexed message stored in the database
struct IndexedMessage: Identifiable {
    let id: Int64
    let sessionId: String
    let messageUuid: String
    let messageType: String
    let content: String
    let embedding: [Double]
    let repoPath: String
    let timestamp: Date
}

/// SQLite database for storing transcript embeddings
class TranscriptIndexDatabase {

    enum DatabaseError: Error {
        case openFailed(String)
        case prepareFailed(String)
        case executeFailed(String)
        case insertFailed(String)
    }

    private var db: OpaquePointer?
    private let dbPath: String

    private let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    // MARK: - Initialization

    init() throws {
        // Create application support directory if needed
        let appSupportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("PromptConduit", isDirectory: true)

        try FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)

        self.dbPath = appSupportDir.appendingPathComponent("transcript_index.sqlite").path

        try openDatabase()
        try createTables()
    }

    deinit {
        closeDatabase()
    }

    // MARK: - Database Setup

    private func openDatabase() throws {
        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            let errorMessage = String(cString: sqlite3_errmsg(db))
            throw DatabaseError.openFailed(errorMessage)
        }

        // Enable WAL mode for better concurrent performance
        try executeSQL("PRAGMA journal_mode = WAL")
    }

    private func closeDatabase() {
        if db != nil {
            sqlite3_close(db)
            db = nil
        }
    }

    private func createTables() throws {
        let createMessagesTable = """
        CREATE TABLE IF NOT EXISTS indexed_messages (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id TEXT NOT NULL,
            message_uuid TEXT NOT NULL,
            message_type TEXT NOT NULL,
            content TEXT NOT NULL,
            embedding BLOB NOT NULL,
            repo_path TEXT NOT NULL,
            timestamp TEXT NOT NULL,
            created_at TEXT DEFAULT CURRENT_TIMESTAMP,
            UNIQUE(session_id, message_uuid)
        )
        """

        let createIndexStateTable = """
        CREATE TABLE IF NOT EXISTS index_state (
            session_file TEXT PRIMARY KEY,
            last_indexed_at TEXT NOT NULL,
            file_hash TEXT NOT NULL,
            message_count INTEGER NOT NULL
        )
        """

        let createRepeatCandidatesTable = """
        CREATE TABLE IF NOT EXISTS repeat_candidates (
            id TEXT PRIMARY KEY,
            original_message_id INTEGER NOT NULL,
            content TEXT NOT NULL,
            repo_path TEXT NOT NULL,
            repeat_count INTEGER NOT NULL DEFAULT 1,
            last_seen_at TEXT NOT NULL,
            avg_similarity REAL NOT NULL DEFAULT 0.0,
            dismissed INTEGER NOT NULL DEFAULT 0,
            dismissed_at TEXT,
            created_at TEXT DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY (original_message_id) REFERENCES indexed_messages(id)
        )
        """

        let createSkillUsageTable = """
        CREATE TABLE IF NOT EXISTS skill_usage (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            skill_name TEXT NOT NULL UNIQUE,
            invocation_count INTEGER NOT NULL DEFAULT 0,
            last_used_at TEXT,
            created_at TEXT DEFAULT CURRENT_TIMESTAMP
        )
        """

        try executeSQL(createMessagesTable)
        try executeSQL(createIndexStateTable)
        try executeSQL(createRepeatCandidatesTable)
        try executeSQL(createSkillUsageTable)

        // Create indices for faster queries
        try executeSQL("CREATE INDEX IF NOT EXISTS idx_session ON indexed_messages(session_id)")
        try executeSQL("CREATE INDEX IF NOT EXISTS idx_repo ON indexed_messages(repo_path)")
        try executeSQL("CREATE INDEX IF NOT EXISTS idx_type ON indexed_messages(message_type)")
        try executeSQL("CREATE INDEX IF NOT EXISTS idx_repeat_dismissed ON repeat_candidates(dismissed)")
        try executeSQL("CREATE INDEX IF NOT EXISTS idx_skill_name ON skill_usage(skill_name)")
    }

    private func executeSQL(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errorMessage) != SQLITE_OK {
            let error = errorMessage.map { String(cString: $0) } ?? "Unknown error"
            sqlite3_free(errorMessage)
            throw DatabaseError.executeFailed(error)
        }
    }

    // MARK: - Message Operations

    /// Insert a new indexed message
    func insertMessage(
        sessionId: String,
        messageUuid: String,
        messageType: String,
        content: String,
        embedding: [Double],
        repoPath: String,
        timestamp: Date
    ) throws {
        _ = try insertMessageReturningId(
            sessionId: sessionId,
            messageUuid: messageUuid,
            messageType: messageType,
            content: content,
            embedding: embedding,
            repoPath: repoPath,
            timestamp: timestamp
        )
    }

    /// Insert a new indexed message and return its database ID
    func insertMessageReturningId(
        sessionId: String,
        messageUuid: String,
        messageType: String,
        content: String,
        embedding: [Double],
        repoPath: String,
        timestamp: Date
    ) throws -> Int64 {
        let sql = """
        INSERT OR REPLACE INTO indexed_messages
        (session_id, message_uuid, message_type, content, embedding, repo_path, timestamp)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            let error = String(cString: sqlite3_errmsg(db))
            throw DatabaseError.prepareFailed(error)
        }

        let embeddingData = EmbeddingService.embeddingToData(embedding)
        let timestampString = dateFormatter.string(from: timestamp)

        sqlite3_bind_text(statement, 1, (sessionId as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 2, (messageUuid as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 3, (messageType as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 4, (content as NSString).utf8String, -1, nil)
        embeddingData.withUnsafeBytes { pointer in
            sqlite3_bind_blob(statement, 5, pointer.baseAddress, Int32(embeddingData.count), nil)
        }
        sqlite3_bind_text(statement, 6, (repoPath as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 7, (timestampString as NSString).utf8String, -1, nil)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            let error = String(cString: sqlite3_errmsg(db))
            throw DatabaseError.insertFailed(error)
        }

        return sqlite3_last_insert_rowid(db)
    }

    /// Get a message by ID
    func getMessage(id: Int64) -> IndexedMessage? {
        let sql = "SELECT id, session_id, message_uuid, message_type, content, embedding, repo_path, timestamp FROM indexed_messages WHERE id = ?"

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return nil
        }

        sqlite3_bind_int64(statement, 1, id)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }

        return extractMessage(from: statement)
    }

    /// Get all embeddings for similarity search
    func getAllEmbeddings() -> [(id: Int64, embedding: [Double])] {
        let sql = "SELECT id, embedding FROM indexed_messages"

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return []
        }

        var results: [(id: Int64, embedding: [Double])] = []

        while sqlite3_step(statement) == SQLITE_ROW {
            let id = sqlite3_column_int64(statement, 0)

            if let blobPointer = sqlite3_column_blob(statement, 1) {
                let blobSize = sqlite3_column_bytes(statement, 1)
                let data = Data(bytes: blobPointer, count: Int(blobSize))

                if let embedding = EmbeddingService.dataToEmbedding(data) {
                    results.append((id: id, embedding: embedding))
                }
            }
        }

        return results
    }

    /// Get all user message embeddings with metadata for pattern detection
    func getUserMessageEmbeddings() -> [(id: Int64, sessionId: String, repoPath: String, timestamp: Date, embedding: [Double])] {
        let sql = "SELECT id, session_id, repo_path, timestamp, embedding FROM indexed_messages WHERE message_type = 'user'"

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return []
        }

        var results: [(id: Int64, sessionId: String, repoPath: String, timestamp: Date, embedding: [Double])] = []

        while sqlite3_step(statement) == SQLITE_ROW {
            let id = sqlite3_column_int64(statement, 0)

            guard let sessionIdPtr = sqlite3_column_text(statement, 1),
                  let repoPathPtr = sqlite3_column_text(statement, 2),
                  let timestampPtr = sqlite3_column_text(statement, 3),
                  let blobPointer = sqlite3_column_blob(statement, 4) else {
                continue
            }

            let blobSize = sqlite3_column_bytes(statement, 4)
            let data = Data(bytes: blobPointer, count: Int(blobSize))

            guard let embedding = EmbeddingService.dataToEmbedding(data) else {
                continue
            }

            let timestampString = String(cString: timestampPtr)
            let timestamp = dateFormatter.date(from: timestampString) ?? Date()

            results.append((
                id: id,
                sessionId: String(cString: sessionIdPtr),
                repoPath: String(cString: repoPathPtr),
                timestamp: timestamp,
                embedding: embedding
            ))
        }

        return results
    }

    /// Batch fetch messages by IDs
    func getMessagesByIds(_ ids: [Int64]) -> [IndexedMessage] {
        guard !ids.isEmpty else { return [] }

        // Build parameterized query with placeholders
        let placeholders = ids.map { _ in "?" }.joined(separator: ", ")
        let sql = "SELECT id, session_id, message_uuid, message_type, content, embedding, repo_path, timestamp FROM indexed_messages WHERE id IN (\(placeholders))"

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return []
        }

        // Bind all IDs
        for (index, id) in ids.enumerated() {
            sqlite3_bind_int64(statement, Int32(index + 1), id)
        }

        var results: [IndexedMessage] = []

        while sqlite3_step(statement) == SQLITE_ROW {
            if let message = extractMessage(from: statement) {
                results.append(message)
            }
        }

        return results
    }

    /// Get total indexed message count
    func getMessageCount() -> Int {
        let sql = "SELECT COUNT(*) FROM indexed_messages"

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else {
            return 0
        }

        return Int(sqlite3_column_int(statement, 0))
    }

    /// Delete all messages for a session
    func deleteMessagesForSession(_ sessionId: String) throws {
        let sql = "DELETE FROM indexed_messages WHERE session_id = ?"

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            let error = String(cString: sqlite3_errmsg(db))
            throw DatabaseError.prepareFailed(error)
        }

        sqlite3_bind_text(statement, 1, (sessionId as NSString).utf8String, -1, nil)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            let error = String(cString: sqlite3_errmsg(db))
            throw DatabaseError.executeFailed(error)
        }
    }

    // MARK: - Index State Operations

    /// Check if a session file needs to be (re)indexed
    func needsIndexing(sessionFile: String, currentHash: String) -> Bool {
        let sql = "SELECT file_hash FROM index_state WHERE session_file = ?"

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return true
        }

        sqlite3_bind_text(statement, 1, (sessionFile as NSString).utf8String, -1, nil)

        guard sqlite3_step(statement) == SQLITE_ROW,
              let storedHash = sqlite3_column_text(statement, 0) else {
            return true
        }

        return String(cString: storedHash) != currentHash
    }

    /// Mark a session file as indexed
    func markSessionIndexed(sessionFile: String, hash: String, messageCount: Int) throws {
        let sql = """
        INSERT OR REPLACE INTO index_state (session_file, last_indexed_at, file_hash, message_count)
        VALUES (?, ?, ?, ?)
        """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            let error = String(cString: sqlite3_errmsg(db))
            throw DatabaseError.prepareFailed(error)
        }

        let timestamp = dateFormatter.string(from: Date())

        sqlite3_bind_text(statement, 1, (sessionFile as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 2, (timestamp as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 3, (hash as NSString).utf8String, -1, nil)
        sqlite3_bind_int(statement, 4, Int32(messageCount))

        guard sqlite3_step(statement) == SQLITE_DONE else {
            let error = String(cString: sqlite3_errmsg(db))
            throw DatabaseError.executeFailed(error)
        }
    }

    /// Get number of indexed session files
    func getIndexedSessionCount() -> Int {
        let sql = "SELECT COUNT(*) FROM index_state"

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else {
            return 0
        }

        return Int(sqlite3_column_int(statement, 0))
    }

    // MARK: - Helper Methods

    private func extractMessage(from statement: OpaquePointer?) -> IndexedMessage? {
        guard let statement = statement else { return nil }

        let id = sqlite3_column_int64(statement, 0)

        guard let sessionIdPtr = sqlite3_column_text(statement, 1),
              let uuidPtr = sqlite3_column_text(statement, 2),
              let typePtr = sqlite3_column_text(statement, 3),
              let contentPtr = sqlite3_column_text(statement, 4),
              let blobPointer = sqlite3_column_blob(statement, 5),
              let repoPathPtr = sqlite3_column_text(statement, 6),
              let timestampPtr = sqlite3_column_text(statement, 7) else {
            return nil
        }

        let blobSize = sqlite3_column_bytes(statement, 5)
        let embeddingData = Data(bytes: blobPointer, count: Int(blobSize))

        guard let embedding = EmbeddingService.dataToEmbedding(embeddingData) else {
            return nil
        }

        let timestampString = String(cString: timestampPtr)
        let timestamp = dateFormatter.date(from: timestampString) ?? Date()

        return IndexedMessage(
            id: id,
            sessionId: String(cString: sessionIdPtr),
            messageUuid: String(cString: uuidPtr),
            messageType: String(cString: typePtr),
            content: String(cString: contentPtr),
            embedding: embedding,
            repoPath: String(cString: repoPathPtr),
            timestamp: timestamp
        )
    }

    // MARK: - Database Path

    /// Get the path to the database file
    var databasePath: String {
        return dbPath
    }

    // MARK: - Repeat Candidates Operations

    /// Save or update a repeat candidate
    func saveRepeatCandidate(_ candidate: RepeatCandidate) throws {
        let sql = """
        INSERT OR REPLACE INTO repeat_candidates
        (id, original_message_id, content, repo_path, repeat_count, last_seen_at, avg_similarity, dismissed, dismissed_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            let error = String(cString: sqlite3_errmsg(db))
            throw DatabaseError.prepareFailed(error)
        }

        let lastSeenAtString = dateFormatter.string(from: candidate.lastSeenAt)
        let dismissedAtString = candidate.dismissedAt.map { dateFormatter.string(from: $0) }

        sqlite3_bind_text(statement, 1, (candidate.id.uuidString as NSString).utf8String, -1, nil)
        sqlite3_bind_int64(statement, 2, candidate.originalMessageId)
        sqlite3_bind_text(statement, 3, (candidate.content as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 4, (candidate.repoPath as NSString).utf8String, -1, nil)
        sqlite3_bind_int(statement, 5, Int32(candidate.repeatCount))
        sqlite3_bind_text(statement, 6, (lastSeenAtString as NSString).utf8String, -1, nil)
        sqlite3_bind_double(statement, 7, candidate.avgSimilarity)
        sqlite3_bind_int(statement, 8, candidate.dismissed ? 1 : 0)
        if let dismissedAtString = dismissedAtString {
            sqlite3_bind_text(statement, 9, (dismissedAtString as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(statement, 9)
        }

        guard sqlite3_step(statement) == SQLITE_DONE else {
            let error = String(cString: sqlite3_errmsg(db))
            throw DatabaseError.insertFailed(error)
        }
    }

    /// Get all repeat candidates
    func getAllRepeatCandidates() -> [RepeatCandidate] {
        let sql = "SELECT id, original_message_id, content, repo_path, repeat_count, last_seen_at, avg_similarity, dismissed, dismissed_at FROM repeat_candidates"

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return []
        }

        var candidates: [RepeatCandidate] = []

        while sqlite3_step(statement) == SQLITE_ROW {
            if let candidate = extractRepeatCandidate(from: statement) {
                candidates.append(candidate)
            }
        }

        return candidates
    }

    /// Get non-dismissed repeat candidates ready to surface
    func getActiveCandidates(minRepeats: Int = 3) -> [RepeatCandidate] {
        let sql = """
        SELECT id, original_message_id, content, repo_path, repeat_count, last_seen_at, avg_similarity, dismissed, dismissed_at
        FROM repeat_candidates
        WHERE dismissed = 0 AND repeat_count >= ?
        ORDER BY repeat_count DESC, last_seen_at DESC
        """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return []
        }

        sqlite3_bind_int(statement, 1, Int32(minRepeats))

        var candidates: [RepeatCandidate] = []

        while sqlite3_step(statement) == SQLITE_ROW {
            if let candidate = extractRepeatCandidate(from: statement) {
                candidates.append(candidate)
            }
        }

        return candidates
    }

    /// Delete a repeat candidate
    func deleteRepeatCandidate(_ id: UUID) throws {
        let sql = "DELETE FROM repeat_candidates WHERE id = ?"

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            let error = String(cString: sqlite3_errmsg(db))
            throw DatabaseError.prepareFailed(error)
        }

        sqlite3_bind_text(statement, 1, (id.uuidString as NSString).utf8String, -1, nil)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            let error = String(cString: sqlite3_errmsg(db))
            throw DatabaseError.executeFailed(error)
        }
    }

    private func extractRepeatCandidate(from statement: OpaquePointer?) -> RepeatCandidate? {
        guard let statement = statement else { return nil }

        guard let idPtr = sqlite3_column_text(statement, 0),
              let contentPtr = sqlite3_column_text(statement, 2),
              let repoPathPtr = sqlite3_column_text(statement, 3),
              let lastSeenAtPtr = sqlite3_column_text(statement, 5) else {
            return nil
        }

        guard let id = UUID(uuidString: String(cString: idPtr)) else {
            return nil
        }

        let originalMessageId = sqlite3_column_int64(statement, 1)
        let content = String(cString: contentPtr)
        let repoPath = String(cString: repoPathPtr)
        let repeatCount = Int(sqlite3_column_int(statement, 4))
        let lastSeenAtString = String(cString: lastSeenAtPtr)
        let lastSeenAt = dateFormatter.date(from: lastSeenAtString) ?? Date()
        let avgSimilarity = sqlite3_column_double(statement, 6)
        let dismissed = sqlite3_column_int(statement, 7) != 0

        var dismissedAt: Date?
        if let dismissedAtPtr = sqlite3_column_text(statement, 8) {
            let dismissedAtString = String(cString: dismissedAtPtr)
            dismissedAt = dateFormatter.date(from: dismissedAtString)
        }

        return RepeatCandidate(
            id: id,
            originalMessageId: originalMessageId,
            content: content,
            repoPath: repoPath,
            repeatCount: repeatCount,
            lastSeenAt: lastSeenAt,
            avgSimilarity: avgSimilarity,
            dismissed: dismissed,
            dismissedAt: dismissedAt
        )
    }

    // MARK: - Skill Usage Operations

    /// Record a skill invocation
    func recordSkillUsage(skillName: String) throws {
        let sql = """
        INSERT INTO skill_usage (skill_name, invocation_count, last_used_at)
        VALUES (?, 1, ?)
        ON CONFLICT(skill_name) DO UPDATE SET
            invocation_count = invocation_count + 1,
            last_used_at = excluded.last_used_at
        """

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            let error = String(cString: sqlite3_errmsg(db))
            throw DatabaseError.prepareFailed(error)
        }

        let nowString = dateFormatter.string(from: Date())

        sqlite3_bind_text(statement, 1, (skillName as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 2, (nowString as NSString).utf8String, -1, nil)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            let error = String(cString: sqlite3_errmsg(db))
            throw DatabaseError.insertFailed(error)
        }
    }

    /// Get usage stats for a skill
    func getSkillUsage(skillName: String) -> (invocationCount: Int, lastUsedAt: Date?)? {
        let sql = "SELECT invocation_count, last_used_at FROM skill_usage WHERE skill_name = ?"

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return nil
        }

        sqlite3_bind_text(statement, 1, (skillName as NSString).utf8String, -1, nil)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }

        let invocationCount = Int(sqlite3_column_int(statement, 0))
        var lastUsedAt: Date?
        if let lastUsedAtPtr = sqlite3_column_text(statement, 1) {
            let lastUsedAtString = String(cString: lastUsedAtPtr)
            lastUsedAt = dateFormatter.date(from: lastUsedAtString)
        }

        return (invocationCount: invocationCount, lastUsedAt: lastUsedAt)
    }

    /// Get all skill usage stats
    func getAllSkillUsage() -> [(skillName: String, invocationCount: Int, lastUsedAt: Date?)] {
        let sql = "SELECT skill_name, invocation_count, last_used_at FROM skill_usage ORDER BY invocation_count DESC"

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return []
        }

        var results: [(skillName: String, invocationCount: Int, lastUsedAt: Date?)] = []

        while sqlite3_step(statement) == SQLITE_ROW {
            guard let skillNamePtr = sqlite3_column_text(statement, 0) else { continue }

            let skillName = String(cString: skillNamePtr)
            let invocationCount = Int(sqlite3_column_int(statement, 1))
            var lastUsedAt: Date?
            if let lastUsedAtPtr = sqlite3_column_text(statement, 2) {
                let lastUsedAtString = String(cString: lastUsedAtPtr)
                lastUsedAt = dateFormatter.date(from: lastUsedAtString)
            }

            results.append((skillName: skillName, invocationCount: invocationCount, lastUsedAt: lastUsedAt))
        }

        return results
    }
}
