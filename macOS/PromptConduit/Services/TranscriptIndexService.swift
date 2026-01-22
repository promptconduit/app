import Foundation
import Combine

/// Search result with similarity score
struct TranscriptSearchResult: Identifiable {
    let id: Int64
    let message: IndexedMessage
    let similarity: Double
    let matchPercentage: Int  // 0-100 for display

    init(message: IndexedMessage, similarity: Double) {
        self.id = message.id
        self.message = message
        self.similarity = similarity
        self.matchPercentage = Int(similarity * 100)
    }
}

/// Service for indexing and searching Claude Code transcripts
class TranscriptIndexService: ObservableObject {

    static let shared = TranscriptIndexService()

    // MARK: - Published State

    @Published private(set) var isIndexing = false
    @Published private(set) var indexedCount = 0
    @Published private(set) var totalCount = 0
    @Published private(set) var lastError: String?
    @Published private(set) var searchResults: [TranscriptSearchResult] = []

    /// Indexing progress (0.0 to 1.0)
    var progress: Double {
        guard totalCount > 0 else { return 0 }
        return Double(indexedCount) / Double(totalCount)
    }

    // MARK: - Private Properties

    private let parser = TranscriptParser()
    private let embedder = EmbeddingService()
    private var database: TranscriptIndexDatabase?

    /// Cached embeddings for fast search
    private var embeddingCache: [(id: Int64, embedding: [Double])] = []
    private var cacheLoaded = false

    private let indexQueue = DispatchQueue(label: "com.promptconduit.indexing", qos: .utility)

    // MARK: - Initialization

    private init() {
        do {
            database = try TranscriptIndexDatabase()
        } catch {
            lastError = "Failed to initialize database: \(error.localizedDescription)"
        }
    }

    // MARK: - Public API

    /// Start or resume indexing all session files
    func startIndexing() {
        guard !isIndexing else { return }
        guard embedder.isAvailable else {
            lastError = "NLEmbedding not available on this system"
            return
        }

        isIndexing = true
        lastError = nil

        indexQueue.async { [weak self] in
            self?.performIndexing()
        }
    }

    /// Search for similar messages using semantic search
    func search(query: String, limit: Int = 20) {
        guard embedder.isAvailable else {
            searchResults = []
            return
        }

        // Ensure cache is loaded
        loadEmbeddingCacheIfNeeded()

        // Preprocess and embed the query
        let preprocessed = embedder.preprocessText(query)
        guard let queryEmbedding = embedder.embed(preprocessed) else {
            searchResults = []
            return
        }

        // Find similar embeddings
        let similar = embedder.findSimilar(
            query: queryEmbedding,
            in: embeddingCache,
            limit: limit,
            threshold: 0.3  // Minimum 30% similarity
        )

        // Fetch full messages for results
        var results: [TranscriptSearchResult] = []
        for (id, similarity) in similar {
            if let message = database?.getMessage(id: id) {
                results.append(TranscriptSearchResult(message: message, similarity: similarity))
            }
        }

        DispatchQueue.main.async {
            self.searchResults = results
        }
    }

    /// Clear search results
    func clearSearch() {
        searchResults = []
    }

    /// Force reload of embedding cache
    func reloadCache() {
        cacheLoaded = false
        loadEmbeddingCacheIfNeeded()
    }

    /// Get indexed message count
    var messageCount: Int {
        database?.getMessageCount() ?? 0
    }

    /// Get indexed session count
    var sessionCount: Int {
        database?.getIndexedSessionCount() ?? 0
    }

    // MARK: - Indexing

    private func performIndexing() {
        defer {
            DispatchQueue.main.async {
                self.isIndexing = false
                self.reloadCache()
            }
        }

        // Discover all session files
        let sessionFiles = discoverSessionFiles()

        DispatchQueue.main.async {
            self.totalCount = sessionFiles.count
            self.indexedCount = 0
        }

        for sessionFile in sessionFiles {
            indexSessionFile(sessionFile)

            DispatchQueue.main.async {
                self.indexedCount += 1
            }
        }
    }

    private func discoverSessionFiles() -> [(path: String, sessionId: String, repoPath: String)] {
        let projectsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")

        guard FileManager.default.fileExists(atPath: projectsDir.path) else {
            return []
        }

        var files: [(path: String, sessionId: String, repoPath: String)] = []

        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: projectsDir.path) else {
            return []
        }

        for entry in entries {
            let projectDir = projectsDir.appendingPathComponent(entry)

            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: projectDir.path, isDirectory: &isDir),
                  isDir.boolValue else {
                continue
            }

            // Decode repo path from directory name
            guard let repoPath = decodeProjectPath(entry) else {
                continue
            }

            // Find session files
            let sessionFiles = findSessionFiles(in: projectDir.path)

            for sessionFile in sessionFiles {
                let sessionId = URL(fileURLWithPath: sessionFile)
                    .deletingPathExtension()
                    .lastPathComponent

                files.append((path: sessionFile, sessionId: sessionId, repoPath: repoPath))
            }
        }

        return files
    }

    private func findSessionFiles(in directory: String) -> [String] {
        guard let enumerator = FileManager.default.enumerator(atPath: directory) else {
            return []
        }

        var files: [String] = []
        while let file = enumerator.nextObject() as? String {
            if file.hasSuffix(".jsonl") && !file.hasPrefix("agent-") {
                files.append(directory + "/" + file)
            }
        }
        return files
    }

    private func decodeProjectPath(_ encoded: String) -> String? {
        // Handle URL-encoded paths
        if let decoded = encoded.removingPercentEncoding, decoded != encoded {
            return decoded
        }

        // Handle dash-encoded paths (older format)
        if encoded.hasPrefix("-") {
            return "/" + encoded.dropFirst().replacingOccurrences(of: "-", with: "/")
        }

        return encoded
    }

    private func indexSessionFile(_ file: (path: String, sessionId: String, repoPath: String)) {
        guard let database = database else { return }

        // Check if file needs indexing
        guard let hash = parser.computeFileHash(file.path),
              database.needsIndexing(sessionFile: file.path, currentHash: hash) else {
            return
        }

        // Parse messages
        let messages = parser.parseSessionFile(file.path, sessionId: file.sessionId, repoPath: file.repoPath)

        // Delete old messages for this session (for re-indexing)
        try? database.deleteMessagesForSession(file.sessionId)

        var indexedCount = 0
        let repeatTracker = RepeatTracker.shared

        for message in messages {
            // Preprocess and embed
            let preprocessed = embedder.preprocessText(message.content)
            guard let embedding = embedder.embed(preprocessed) else {
                continue
            }

            // Store in database
            do {
                let messageId = try database.insertMessageReturningId(
                    sessionId: message.sessionId,
                    messageUuid: message.id,
                    messageType: message.type.rawValue,
                    content: message.content,
                    embedding: embedding,
                    repoPath: message.repoPath,
                    timestamp: message.timestamp
                )

                indexedCount += 1

                // Notify RepeatTracker for user messages only
                if message.type == .user {
                    repeatTracker.onMessageIndexed(
                        messageId: messageId,
                        content: message.content,
                        embedding: embedding,
                        repoPath: message.repoPath,
                        timestamp: message.timestamp
                    )
                }
            } catch {
                // Log but continue
                print("Failed to index message: \(error)")
            }
        }

        // Mark session as indexed
        try? database.markSessionIndexed(sessionFile: file.path, hash: hash, messageCount: indexedCount)
    }

    // MARK: - Cache Management

    private func loadEmbeddingCacheIfNeeded() {
        guard !cacheLoaded, let database = database else { return }

        embeddingCache = database.getAllEmbeddings()
        cacheLoaded = true
    }
}
