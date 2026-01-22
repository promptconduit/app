import Foundation
import Combine

// MARK: - Types

/// A candidate pattern that has been detected through repeated similar prompts
struct RepeatCandidate: Identifiable, Codable {
    let id: UUID
    let originalMessageId: Int64
    let content: String
    let repoPath: String
    var repeatCount: Int
    var lastSeenAt: Date
    var avgSimilarity: Double
    var dismissed: Bool
    var dismissedAt: Date?

    /// Threshold for surfacing this pattern (3+ repeats)
    var isReadyToSurface: Bool {
        repeatCount >= 3 && !dismissed
    }

    /// Check if pattern should resurface after being dismissed (2+ additional occurrences)
    var shouldResurface: Bool {
        guard dismissed, let dismissedAt = dismissedAt else { return false }
        // Only resurface if we've seen 2+ occurrences since dismissal
        return repeatCount >= 2 && lastSeenAt > dismissedAt
    }
}

/// Notification payload for a surfaced pattern
struct PatternSuggestion {
    let candidate: RepeatCandidate
    let originalMessage: IndexedMessage
    let suggestedSkillName: String
    let suggestedDescription: String
    let suggestedLocation: SkillSaveLocation
}

// MARK: - RepeatTracker Service

/// Service for tracking repeated prompts in real-time as they are indexed
/// Detects when users repeatedly ask similar questions and surfaces them as skill candidates
class RepeatTracker: ObservableObject {

    static let shared = RepeatTracker()

    // MARK: - Published State

    @Published private(set) var candidates: [RepeatCandidate] = []
    @Published private(set) var pendingSuggestions: [PatternSuggestion] = []

    /// Number of notifications sent today (for rate limiting)
    @Published private(set) var notificationsToday: Int = 0

    // MARK: - Configuration

    /// Minimum similarity threshold for considering prompts as repeats
    let similarityThreshold: Double = 0.80

    /// Minimum repeats before surfacing
    let minRepeatsToSurface: Int = 3

    /// Maximum notifications per day
    let maxNotificationsPerDay: Int = 2

    /// Minimum word count for a prompt to be considered valuable
    let minWordCount: Int = 5

    // MARK: - Private Properties

    private var database: TranscriptIndexDatabase?
    private let embedder = EmbeddingService()
    private let skillService = PatternSkillService()

    /// In-memory LRU cache of recent embeddings for fast comparison
    /// Key: message ID, Value: embedding
    private var recentEmbeddingsCache: [(id: Int64, embedding: [Double], timestamp: Date)] = []
    private let maxCacheSize = 500

    /// Date of last notification counter reset
    private var lastNotificationReset: Date = Date()

    private let trackerQueue = DispatchQueue(label: "com.promptconduit.repeattracker", qos: .utility)

    // MARK: - Initialization

    private init() {
        do {
            database = try TranscriptIndexDatabase()
            loadCandidatesFromDatabase()
            resetDailyCounterIfNeeded()
        } catch {
            print("RepeatTracker: Failed to initialize database: \(error)")
        }
    }

    // MARK: - Public API

    /// Called when a new message is indexed. Checks for similarity to recent messages.
    /// - Parameters:
    ///   - messageId: Database ID of the newly indexed message
    ///   - content: Text content of the message
    ///   - embedding: The embedding vector for the message
    ///   - repoPath: Repository path where the message originated
    ///   - timestamp: When the message was created
    func onMessageIndexed(
        messageId: Int64,
        content: String,
        embedding: [Double],
        repoPath: String,
        timestamp: Date
    ) {
        trackerQueue.async { [weak self] in
            self?.processNewMessage(
                messageId: messageId,
                content: content,
                embedding: embedding,
                repoPath: repoPath,
                timestamp: timestamp
            )
        }
    }

    /// Dismiss a candidate pattern (user doesn't want to see it again)
    func dismissCandidate(_ candidateId: UUID) {
        trackerQueue.async { [weak self] in
            guard let self = self else { return }

            if let index = self.candidates.firstIndex(where: { $0.id == candidateId }) {
                self.candidates[index].dismissed = true
                self.candidates[index].dismissedAt = Date()
                self.candidates[index].repeatCount = 0 // Reset count for resurface tracking
                self.saveCandidateToDatabase(self.candidates[index])
            }

            // Remove from pending suggestions
            DispatchQueue.main.async {
                self.pendingSuggestions.removeAll { $0.candidate.id == candidateId }
            }
        }
    }

    /// Get pattern suggestion for a candidate (for creating a skill)
    func getSuggestion(for candidateId: UUID) -> PatternSuggestion? {
        return pendingSuggestions.first { $0.candidate.id == candidateId }
    }

    /// Mark a candidate as converted to skill (removes from tracking)
    func markAsConverted(_ candidateId: UUID) {
        trackerQueue.async { [weak self] in
            guard let self = self else { return }

            // Remove from candidates
            self.candidates.removeAll { $0.id == candidateId }
            self.deleteCandidateFromDatabase(candidateId)

            // Remove from pending suggestions
            DispatchQueue.main.async {
                self.pendingSuggestions.removeAll { $0.candidate.id == candidateId }
            }
        }
    }

    /// Check if we can send another notification today
    var canSendNotification: Bool {
        resetDailyCounterIfNeeded()
        return notificationsToday < maxNotificationsPerDay
    }

    /// Record that a notification was sent
    func recordNotificationSent() {
        resetDailyCounterIfNeeded()
        DispatchQueue.main.async {
            self.notificationsToday += 1
        }
    }

    // MARK: - Private Methods

    private func processNewMessage(
        messageId: Int64,
        content: String,
        embedding: [Double],
        repoPath: String,
        timestamp: Date
    ) {
        // Skip very short prompts
        let wordCount = content.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count
        guard wordCount >= minWordCount else { return }

        // Check against existing candidates first (most efficient)
        let matchedCandidate = findMatchingCandidate(embedding: embedding)

        if var candidate = matchedCandidate {
            // Update existing candidate
            candidate.repeatCount += 1
            candidate.lastSeenAt = timestamp
            candidate.avgSimilarity = calculateNewAverage(
                current: candidate.avgSimilarity,
                newValue: embedder.cosineSimilarity(embedding, getEmbeddingForCandidate(candidate) ?? []),
                count: candidate.repeatCount
            )

            // Check for resurfacing
            if candidate.shouldResurface {
                candidate.dismissed = false
                candidate.dismissedAt = nil
            }

            updateCandidate(candidate)

            // Check if ready to surface
            if candidate.isReadyToSurface {
                checkAndSurfaceCandidate(candidate)
            }
        } else {
            // Check against recent embeddings cache for a new pattern
            let similarMessages = findSimilarInCache(embedding: embedding)

            if !similarMessages.isEmpty {
                // Found similar recent messages - start tracking as new candidate
                let newCandidate = RepeatCandidate(
                    id: UUID(),
                    originalMessageId: messageId,
                    content: content,
                    repoPath: repoPath,
                    repeatCount: similarMessages.count + 1, // Include current message
                    lastSeenAt: timestamp,
                    avgSimilarity: similarMessages.reduce(0.0) { $0 + $1.similarity } / Double(similarMessages.count),
                    dismissed: false,
                    dismissedAt: nil
                )

                addCandidate(newCandidate, embedding: embedding)

                // Check if immediately ready to surface (unlikely with new candidate)
                if newCandidate.isReadyToSurface {
                    checkAndSurfaceCandidate(newCandidate)
                }
            }
        }

        // Add to cache
        addToCache(id: messageId, embedding: embedding, timestamp: timestamp)
    }

    private func findMatchingCandidate(embedding: [Double]) -> RepeatCandidate? {
        for candidate in candidates {
            guard let candidateEmbedding = getEmbeddingForCandidate(candidate) else { continue }
            let similarity = embedder.cosineSimilarity(embedding, candidateEmbedding)
            if similarity >= similarityThreshold {
                return candidate
            }
        }
        return nil
    }

    private func findSimilarInCache(embedding: [Double]) -> [(id: Int64, similarity: Double)] {
        var similar: [(id: Int64, similarity: Double)] = []

        for cached in recentEmbeddingsCache {
            let similarity = embedder.cosineSimilarity(embedding, cached.embedding)
            if similarity >= similarityThreshold {
                similar.append((id: cached.id, similarity: similarity))
            }
        }

        return similar
    }

    private func getEmbeddingForCandidate(_ candidate: RepeatCandidate) -> [Double]? {
        // First check cache
        if let cached = recentEmbeddingsCache.first(where: { $0.id == candidate.originalMessageId }) {
            return cached.embedding
        }

        // Fall back to database
        if let message = database?.getMessage(id: candidate.originalMessageId) {
            return message.embedding
        }

        return nil
    }

    private func addToCache(id: Int64, embedding: [Double], timestamp: Date) {
        // Remove old entry if exists
        recentEmbeddingsCache.removeAll { $0.id == id }

        // Add new entry
        recentEmbeddingsCache.append((id: id, embedding: embedding, timestamp: timestamp))

        // Trim cache if too large (keep most recent)
        if recentEmbeddingsCache.count > maxCacheSize {
            recentEmbeddingsCache.sort { $0.timestamp > $1.timestamp }
            recentEmbeddingsCache = Array(recentEmbeddingsCache.prefix(maxCacheSize))
        }
    }

    private func calculateNewAverage(current: Double, newValue: Double, count: Int) -> Double {
        guard count > 0 else { return newValue }
        return ((current * Double(count - 1)) + newValue) / Double(count)
    }

    private func addCandidate(_ candidate: RepeatCandidate, embedding: [Double]) {
        candidates.append(candidate)
        saveCandidateToDatabase(candidate)

        // Ensure embedding is in cache
        addToCache(id: candidate.originalMessageId, embedding: embedding, timestamp: candidate.lastSeenAt)

        DispatchQueue.main.async {
            self.objectWillChange.send()
        }
    }

    private func updateCandidate(_ candidate: RepeatCandidate) {
        if let index = candidates.firstIndex(where: { $0.id == candidate.id }) {
            candidates[index] = candidate
            saveCandidateToDatabase(candidate)

            DispatchQueue.main.async {
                self.objectWillChange.send()
            }
        }
    }

    private func checkAndSurfaceCandidate(_ candidate: RepeatCandidate) {
        // Check if already in pending suggestions
        guard !pendingSuggestions.contains(where: { $0.candidate.id == candidate.id }) else { return }

        // Get the original message for full context
        guard let originalMessage = database?.getMessage(id: candidate.originalMessageId) else { return }

        // Generate skill suggestions
        let suggestedName = generateSkillName(from: candidate.content)
        let suggestedDescription = "Pattern: \(candidate.repeatCount) similar prompts"
        let suggestedLocation: SkillSaveLocation = candidates
            .filter { $0.id == candidate.id }
            .first
            .map { Set([$0.repoPath]).count <= 1 ? .project : .global } ?? .global

        let suggestion = PatternSuggestion(
            candidate: candidate,
            originalMessage: originalMessage,
            suggestedSkillName: suggestedName,
            suggestedDescription: suggestedDescription,
            suggestedLocation: suggestedLocation
        )

        DispatchQueue.main.async {
            self.pendingSuggestions.append(suggestion)
        }

        // Post notification to PatternNotificationService
        NotificationCenter.default.post(
            name: .patternReadyToSurface,
            object: nil,
            userInfo: ["suggestion": suggestion]
        )
    }

    private func generateSkillName(from content: String) -> String {
        let words = content.prefix(50)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && $0.count > 2 }
            .prefix(4)

        let name = words.joined(separator: "-")
        return name.isEmpty ? "repeated-prompt" : name
    }

    private func resetDailyCounterIfNeeded() {
        let calendar = Calendar.current
        if !calendar.isDateInToday(lastNotificationReset) {
            lastNotificationReset = Date()
            DispatchQueue.main.async {
                self.notificationsToday = 0
            }
        }
    }

    // MARK: - Database Operations

    private func loadCandidatesFromDatabase() {
        guard let database = database else { return }
        candidates = database.getAllRepeatCandidates()
    }

    private func saveCandidateToDatabase(_ candidate: RepeatCandidate) {
        try? database?.saveRepeatCandidate(candidate)
    }

    private func deleteCandidateFromDatabase(_ id: UUID) {
        try? database?.deleteRepeatCandidate(id)
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let patternReadyToSurface = Notification.Name("patternReadyToSurface")
}
