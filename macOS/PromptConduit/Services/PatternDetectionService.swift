import Foundation
import Combine

// MARK: - Data Types

/// A member of a detected pattern cluster
struct PatternMember: Identifiable {
    let id: Int64
    let message: IndexedMessage
    let similarityToRepresentative: Double
}

/// Scoring metrics for pattern ranking
struct PatternScore {
    let count: Int
    let sessionDiversity: Int
    let repoDiversity: Int
    let avgSimilarity: Double
    let mostRecent: Date

    // New scoring factors
    let promptComplexity: Double      // 0-1 based on word count and specificity
    let successSignal: Double         // 0-1 based on follow-up message analysis
    let contextSpecificity: Double    // 0-1 based on mentions of files, languages
    let burstFactor: Double           // Higher if spread out (habitual), lower if clustered (burst)

    var compositeScore: Double {
        // Logarithmic scaling for count (diminishing returns)
        let countScore = log(Double(count) + 1) * 2.0

        // Bonus for appearing across multiple sessions
        let diversityBonus = Double(sessionDiversity) * 0.5

        // Coherence bonus for tight clusters
        let coherenceBonus = avgSimilarity * 2.0

        // Recency bonus (decay over 30 days)
        let daysSinceMostRecent = Date().timeIntervalSince(mostRecent) / 86400
        let recencyBonus = max(0, 1.0 - (daysSinceMostRecent / 30.0))

        // Complexity bonus - longer, more specific prompts are better skill candidates
        let complexityBonus = promptComplexity * 1.5

        // Success signal bonus - patterns that led to successful outcomes
        let successBonus = successSignal * 1.0

        // Context specificity bonus - patterns with file/language mentions are more actionable
        let contextBonus = contextSpecificity * 0.5

        // Habitual pattern bonus - spread out usage indicates ongoing need
        let habitualBonus = burstFactor * 0.5

        return countScore + diversityBonus + coherenceBonus + recencyBonus +
               complexityBonus + successBonus + contextBonus + habitualBonus
    }

    /// Legacy initializer for backwards compatibility
    init(count: Int, sessionDiversity: Int, repoDiversity: Int, avgSimilarity: Double, mostRecent: Date) {
        self.count = count
        self.sessionDiversity = sessionDiversity
        self.repoDiversity = repoDiversity
        self.avgSimilarity = avgSimilarity
        self.mostRecent = mostRecent
        self.promptComplexity = 0.5
        self.successSignal = 0.5
        self.contextSpecificity = 0.0
        self.burstFactor = 0.5
    }

    /// Full initializer with all scoring factors
    init(
        count: Int,
        sessionDiversity: Int,
        repoDiversity: Int,
        avgSimilarity: Double,
        mostRecent: Date,
        promptComplexity: Double,
        successSignal: Double,
        contextSpecificity: Double,
        burstFactor: Double
    ) {
        self.count = count
        self.sessionDiversity = sessionDiversity
        self.repoDiversity = repoDiversity
        self.avgSimilarity = avgSimilarity
        self.mostRecent = mostRecent
        self.promptComplexity = promptComplexity
        self.successSignal = successSignal
        self.contextSpecificity = contextSpecificity
        self.burstFactor = burstFactor
    }
}

/// A detected pattern of similar user prompts
struct DetectedPattern: Identifiable {
    let id: UUID
    let representative: IndexedMessage
    let members: [PatternMember]
    let score: PatternScore

    var count: Int { members.count }
    var sessionCount: Int { Set(members.map { $0.message.sessionId }).count }
    var repoCount: Int { Set(members.map { $0.message.repoPath }).count }

    /// Preview of the pattern (first N characters of representative content)
    var preview: String {
        let content = representative.content
        if content.count <= 100 {
            return content
        }
        return String(content.prefix(100)) + "..."
    }
}

// MARK: - Union-Find for Clustering

/// Union-Find data structure for efficient clustering
private class UnionFind {
    private var parent: [Int]
    private var rank: [Int]

    init(count: Int) {
        parent = Array(0..<count)
        rank = Array(repeating: 0, count: count)
    }

    func find(_ x: Int) -> Int {
        if parent[x] != x {
            parent[x] = find(parent[x])  // Path compression
        }
        return parent[x]
    }

    func union(_ x: Int, _ y: Int) {
        let rootX = find(x)
        let rootY = find(y)

        if rootX == rootY { return }

        // Union by rank
        if rank[rootX] < rank[rootY] {
            parent[rootX] = rootY
        } else if rank[rootX] > rank[rootY] {
            parent[rootY] = rootX
        } else {
            parent[rootY] = rootX
            rank[rootX] += 1
        }
    }

    func getComponents() -> [[Int]] {
        var components: [Int: [Int]] = [:]
        for i in 0..<parent.count {
            let root = find(i)
            components[root, default: []].append(i)
        }
        return Array(components.values)
    }
}

// MARK: - Pattern Detection Service

/// Service for detecting patterns in user prompts across sessions
class PatternDetectionService: ObservableObject {

    static let shared = PatternDetectionService()

    // MARK: - Published State

    @Published private(set) var isAnalyzing = false
    @Published private(set) var patterns: [DetectedPattern] = []
    @Published private(set) var lastAnalyzed: Date?
    @Published private(set) var lastError: String?

    // MARK: - Private Properties

    private var database: TranscriptIndexDatabase?
    private let embedder = EmbeddingService()
    private let analysisQueue = DispatchQueue(label: "com.promptconduit.patterndetection", qos: .utility)

    // MARK: - Initialization

    private init() {
        do {
            database = try TranscriptIndexDatabase()
        } catch {
            lastError = "Failed to initialize database: \(error.localizedDescription)"
        }
    }

    // MARK: - Public API

    /// Detect patterns in user prompts
    /// - Parameters:
    ///   - minSimilarity: Minimum similarity threshold for grouping (default: 0.75)
    ///   - minClusterSize: Minimum messages to form a pattern (default: 2)
    ///   - maxPatterns: Maximum patterns to return (default: 50)
    func detectPatterns(
        minSimilarity: Double = 0.75,
        minClusterSize: Int = 2,
        maxPatterns: Int = 50
    ) {
        guard !isAnalyzing else { return }
        guard let database = database else {
            lastError = "Database not available"
            return
        }

        isAnalyzing = true
        lastError = nil

        analysisQueue.async { [weak self] in
            guard let self = self else { return }

            let detectedPatterns = self.performPatternDetection(
                database: database,
                minSimilarity: minSimilarity,
                minClusterSize: minClusterSize,
                maxPatterns: maxPatterns
            )

            DispatchQueue.main.async {
                self.patterns = detectedPatterns
                self.lastAnalyzed = Date()
                self.isAnalyzing = false
            }
        }
    }

    /// Get patterns filtered by repository
    func patternsForRepo(_ repoPath: String) -> [DetectedPattern] {
        return patterns.filter { pattern in
            pattern.members.contains { $0.message.repoPath == repoPath }
        }
    }

    /// Clear detected patterns
    func clearPatterns() {
        patterns = []
        lastAnalyzed = nil
    }

    // MARK: - Pattern Detection Algorithm

    private func performPatternDetection(
        database: TranscriptIndexDatabase,
        minSimilarity: Double,
        minClusterSize: Int,
        maxPatterns: Int
    ) -> [DetectedPattern] {

        // Step 1: Get all user message embeddings
        let userMessages = database.getUserMessageEmbeddings()
        guard userMessages.count >= minClusterSize else {
            return []
        }

        // Step 2: Build similarity graph and cluster using Union-Find
        let clusters = clusterMessages(
            messages: userMessages,
            minSimilarity: minSimilarity
        )

        // Step 3: Filter to minimum cluster size
        let validClusters = clusters.filter { $0.count >= minClusterSize }

        // Step 4: Fetch full message data for clusters
        let allIds = validClusters.flatMap { $0.map { userMessages[$0].id } }
        let messagesById = Dictionary(
            uniqueKeysWithValues: database.getMessagesByIds(allIds).map { ($0.id, $0) }
        )

        // Step 5: Build patterns with scoring
        var detectedPatterns: [DetectedPattern] = []

        for cluster in validClusters {
            let clusterMessages = cluster.compactMap { idx -> (idx: Int, message: IndexedMessage)? in
                let id = userMessages[idx].id
                guard let message = messagesById[id] else { return nil }
                return (idx: idx, message: message)
            }

            guard clusterMessages.count >= minClusterSize else { continue }

            // Find representative (most central message)
            let representative = findRepresentative(
                clusterMessages: clusterMessages,
                allMessages: userMessages
            )

            // Build pattern members with similarity to representative
            let members = clusterMessages.map { item -> PatternMember in
                let similarity = embedder.cosineSimilarity(
                    userMessages[item.idx].embedding,
                    userMessages[representative.idx].embedding
                )
                return PatternMember(
                    id: item.message.id,
                    message: item.message,
                    similarityToRepresentative: similarity
                )
            }.sorted { $0.similarityToRepresentative > $1.similarityToRepresentative }

            // Calculate pattern score
            let score = calculatePatternScore(members: members, allMessages: userMessages, clusterIndices: cluster)

            let pattern = DetectedPattern(
                id: UUID(),
                representative: representative.message,
                members: members,
                score: score
            )

            detectedPatterns.append(pattern)
        }

        // Step 6: Sort by composite score and limit
        detectedPatterns.sort { $0.score.compositeScore > $1.score.compositeScore }
        return Array(detectedPatterns.prefix(maxPatterns))
    }

    /// Cluster messages using Union-Find based on similarity threshold
    private func clusterMessages(
        messages: [(id: Int64, sessionId: String, repoPath: String, timestamp: Date, embedding: [Double])],
        minSimilarity: Double
    ) -> [[Int]] {
        let n = messages.count
        let uf = UnionFind(count: n)

        // O(n²) pairwise comparison - acceptable for <10K messages
        for i in 0..<n {
            for j in (i + 1)..<n {
                let similarity = embedder.cosineSimilarity(
                    messages[i].embedding,
                    messages[j].embedding
                )
                if similarity >= minSimilarity {
                    uf.union(i, j)
                }
            }
        }

        return uf.getComponents()
    }

    /// Find the most representative (central) message in a cluster
    private func findRepresentative(
        clusterMessages: [(idx: Int, message: IndexedMessage)],
        allMessages: [(id: Int64, sessionId: String, repoPath: String, timestamp: Date, embedding: [Double])]
    ) -> (idx: Int, message: IndexedMessage) {
        guard clusterMessages.count > 1 else {
            return clusterMessages[0]
        }

        // Find message with highest average similarity to all others
        var bestIdx = clusterMessages[0].idx
        var bestMessage = clusterMessages[0].message
        var bestAvgSimilarity = -1.0

        for item in clusterMessages {
            var totalSimilarity = 0.0
            for other in clusterMessages where other.idx != item.idx {
                totalSimilarity += embedder.cosineSimilarity(
                    allMessages[item.idx].embedding,
                    allMessages[other.idx].embedding
                )
            }
            let avgSimilarity = totalSimilarity / Double(clusterMessages.count - 1)

            if avgSimilarity > bestAvgSimilarity {
                bestAvgSimilarity = avgSimilarity
                bestIdx = item.idx
                bestMessage = item.message
            }
        }

        return (idx: bestIdx, message: bestMessage)
    }

    /// Calculate pattern score for ranking
    private func calculatePatternScore(
        members: [PatternMember],
        allMessages: [(id: Int64, sessionId: String, repoPath: String, timestamp: Date, embedding: [Double])],
        clusterIndices: [Int]
    ) -> PatternScore {
        let count = members.count
        let sessionDiversity = Set(members.map { $0.message.sessionId }).count
        let repoDiversity = Set(members.map { $0.message.repoPath }).count

        // Calculate average internal similarity
        var totalSimilarity = 0.0
        var pairCount = 0
        for i in 0..<clusterIndices.count {
            for j in (i + 1)..<clusterIndices.count {
                totalSimilarity += embedder.cosineSimilarity(
                    allMessages[clusterIndices[i]].embedding,
                    allMessages[clusterIndices[j]].embedding
                )
                pairCount += 1
            }
        }
        let avgSimilarity = pairCount > 0 ? totalSimilarity / Double(pairCount) : 1.0

        // Find most recent message
        let mostRecent = members.map { $0.message.timestamp }.max() ?? Date.distantPast

        // Calculate new scoring factors
        let promptComplexity = calculatePromptComplexity(members: members)
        let successSignal = calculateSuccessSignal(members: members)
        let contextSpecificity = calculateContextSpecificity(members: members)
        let burstFactor = calculateBurstFactor(members: members)

        return PatternScore(
            count: count,
            sessionDiversity: sessionDiversity,
            repoDiversity: repoDiversity,
            avgSimilarity: avgSimilarity,
            mostRecent: mostRecent,
            promptComplexity: promptComplexity,
            successSignal: successSignal,
            contextSpecificity: contextSpecificity,
            burstFactor: burstFactor
        )
    }

    // MARK: - Scoring Factor Calculations

    /// Calculate prompt complexity score (0-1)
    /// Higher for longer, more specific prompts
    private func calculatePromptComplexity(members: [PatternMember]) -> Double {
        guard !members.isEmpty else { return 0.5 }

        // Use representative (first member) for complexity analysis
        let content = members.first?.message.content ?? ""

        // Word count factor (scaled 0-1, optimal around 20-50 words)
        let words = content.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        let wordCount = words.count
        let wordCountScore: Double
        if wordCount < 5 {
            wordCountScore = 0.2  // Too short
        } else if wordCount < 15 {
            wordCountScore = 0.5  // Moderate
        } else if wordCount < 50 {
            wordCountScore = 1.0  // Optimal
        } else {
            wordCountScore = 0.8  // Longer is still good but slightly less ideal
        }

        // Specificity heuristics
        var specificityScore = 0.0

        // Technical terms boost
        let technicalPatterns = ["function", "class", "method", "api", "endpoint", "database",
                                  "error", "bug", "fix", "implement", "refactor", "test"]
        let contentLower = content.lowercased()
        let technicalMatches = technicalPatterns.filter { contentLower.contains($0) }.count
        specificityScore += min(Double(technicalMatches) * 0.1, 0.3)

        // Quoted strings suggest specific values
        let quoteMatches = content.components(separatedBy: "\"").count - 1 +
                          content.components(separatedBy: "'").count - 1
        specificityScore += min(Double(quoteMatches) * 0.1, 0.2)

        // Code-like patterns (backticks, file extensions)
        if content.contains("`") || content.contains(".ts") || content.contains(".swift") ||
           content.contains(".py") || content.contains(".js") {
            specificityScore += 0.2
        }

        return min(wordCountScore * 0.6 + specificityScore * 0.4, 1.0)
    }

    /// Calculate success signal score (0-1)
    /// Higher when pattern appears to have led to successful outcomes
    private func calculateSuccessSignal(members: [PatternMember]) -> Double {
        // This is a heuristic based on message content
        // In a fuller implementation, we'd look at the assistant's response and user's follow-up

        var successIndicators = 0.0
        let successPatterns = ["thanks", "perfect", "great", "worked", "awesome", "done", "solved"]
        let failurePatterns = ["doesn't work", "wrong", "error", "fix", "broken", "issue", "problem"]

        for member in members {
            let contentLower = member.message.content.lowercased()

            // Check for success language (usually not in the prompt itself, but sometimes)
            // This is a placeholder - full implementation would check follow-up messages
            for pattern in successPatterns {
                if contentLower.contains(pattern) {
                    successIndicators += 0.1
                }
            }

            // Penalize if prompt contains failure language (might indicate repeated failures)
            for pattern in failurePatterns {
                if contentLower.contains(pattern) {
                    successIndicators -= 0.05
                }
            }
        }

        // Normalize to 0-1 range, default to 0.5 (neutral)
        return max(0, min(1, 0.5 + successIndicators / Double(max(1, members.count))))
    }

    /// Calculate context specificity score (0-1)
    /// Higher for patterns that mention specific files, languages, or contexts
    private func calculateContextSpecificity(members: [PatternMember]) -> Double {
        guard !members.isEmpty else { return 0.0 }

        var specificity = 0.0

        // Check representative message for context indicators
        let content = members.first?.message.content ?? ""
        let contentLower = content.lowercased()

        // File path patterns
        if content.contains("/") && (content.contains(".") || content.contains("src/") || content.contains("lib/")) {
            specificity += 0.3
        }

        // Language/framework mentions
        let languages = ["swift", "python", "javascript", "typescript", "rust", "go", "java",
                        "react", "vue", "angular", "node", "django", "rails"]
        for lang in languages {
            if contentLower.contains(lang) {
                specificity += 0.15
                break  // Only count once
            }
        }

        // Tool/command mentions
        let tools = ["git", "npm", "pip", "cargo", "make", "docker", "kubectl", "terraform"]
        for tool in tools {
            if contentLower.contains(tool) {
                specificity += 0.1
                break
            }
        }

        // Function/class name patterns (CamelCase or snake_case)
        let camelCasePattern = try? NSRegularExpression(pattern: "[A-Z][a-z]+[A-Z]", options: [])
        let snakeCasePattern = try? NSRegularExpression(pattern: "[a-z]+_[a-z]+", options: [])
        let range = NSRange(content.startIndex..., in: content)

        if camelCasePattern?.firstMatch(in: content, options: [], range: range) != nil {
            specificity += 0.1
        }
        if snakeCasePattern?.firstMatch(in: content, options: [], range: range) != nil {
            specificity += 0.1
        }

        return min(specificity, 1.0)
    }

    /// Calculate burst factor score (0-1)
    /// Higher for patterns spread over time (habitual), lower for clustered (burst)
    private func calculateBurstFactor(members: [PatternMember]) -> Double {
        guard members.count >= 2 else { return 0.5 }

        // Get timestamps sorted
        let timestamps = members.map { $0.message.timestamp }.sorted()

        // Calculate time spread
        guard let earliest = timestamps.first, let latest = timestamps.last else { return 0.5 }
        let totalSpread = latest.timeIntervalSince(earliest)

        // If all within 1 hour, likely a burst (debugging session)
        if totalSpread < 3600 {
            return 0.2
        }

        // If spread over multiple days, more habitual
        let days = totalSpread / 86400
        if days >= 7 {
            return 1.0  // Week or more spread
        } else if days >= 1 {
            return 0.7  // Multiple days
        } else {
            return 0.4  // Same day but spread out
        }
    }
}
