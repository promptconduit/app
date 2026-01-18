import XCTest
@testable import PromptConduit

final class PatternDetectionServiceTests: XCTestCase {

    var embedder: EmbeddingService!

    override func setUp() {
        super.setUp()
        embedder = EmbeddingService()
    }

    // MARK: - Pattern Score Tests

    func testPatternScoreCompositeCalculation() {
        let score = PatternScore(
            count: 5,
            sessionDiversity: 3,
            repoDiversity: 2,
            avgSimilarity: 0.85,
            mostRecent: Date()
        )

        // Composite score should be positive and reasonable
        XCTAssertGreaterThan(score.compositeScore, 0)
        XCTAssertLessThan(score.compositeScore, 20)  // Sanity check upper bound
    }

    func testHigherCountIncreasesScore() {
        let lowCountScore = PatternScore(
            count: 2,
            sessionDiversity: 1,
            repoDiversity: 1,
            avgSimilarity: 0.8,
            mostRecent: Date()
        )

        let highCountScore = PatternScore(
            count: 10,
            sessionDiversity: 1,
            repoDiversity: 1,
            avgSimilarity: 0.8,
            mostRecent: Date()
        )

        XCTAssertGreaterThan(highCountScore.compositeScore, lowCountScore.compositeScore)
    }

    func testHigherDiversityIncreasesScore() {
        let lowDiversityScore = PatternScore(
            count: 5,
            sessionDiversity: 1,
            repoDiversity: 1,
            avgSimilarity: 0.8,
            mostRecent: Date()
        )

        let highDiversityScore = PatternScore(
            count: 5,
            sessionDiversity: 5,
            repoDiversity: 3,
            avgSimilarity: 0.8,
            mostRecent: Date()
        )

        XCTAssertGreaterThan(highDiversityScore.compositeScore, lowDiversityScore.compositeScore)
    }

    func testRecentPatternsScoreHigherThanOld() {
        let recentScore = PatternScore(
            count: 5,
            sessionDiversity: 2,
            repoDiversity: 1,
            avgSimilarity: 0.8,
            mostRecent: Date()
        )

        let oldScore = PatternScore(
            count: 5,
            sessionDiversity: 2,
            repoDiversity: 1,
            avgSimilarity: 0.8,
            mostRecent: Date().addingTimeInterval(-60 * 24 * 3600)  // 60 days ago
        )

        XCTAssertGreaterThan(recentScore.compositeScore, oldScore.compositeScore)
    }

    func testHigherSimilarityIncreasesScore() {
        let lowSimilarityScore = PatternScore(
            count: 5,
            sessionDiversity: 2,
            repoDiversity: 1,
            avgSimilarity: 0.6,
            mostRecent: Date()
        )

        let highSimilarityScore = PatternScore(
            count: 5,
            sessionDiversity: 2,
            repoDiversity: 1,
            avgSimilarity: 0.95,
            mostRecent: Date()
        )

        XCTAssertGreaterThan(highSimilarityScore.compositeScore, lowSimilarityScore.compositeScore)
    }

    // MARK: - Detected Pattern Tests

    func testDetectedPatternCountMatchesMembers() {
        // Create a mock pattern with members
        let mockMessage = IndexedMessage(
            id: 1,
            sessionId: "session-1",
            messageUuid: "uuid-1",
            messageType: "user",
            content: "Test content",
            embedding: [Double](repeating: 0.1, count: 512),
            repoPath: "/test/repo",
            timestamp: Date()
        )

        let members = [
            PatternMember(id: 1, message: mockMessage, similarityToRepresentative: 1.0),
            PatternMember(id: 2, message: mockMessage, similarityToRepresentative: 0.9),
            PatternMember(id: 3, message: mockMessage, similarityToRepresentative: 0.85),
        ]

        let pattern = DetectedPattern(
            id: UUID(),
            representative: mockMessage,
            members: members,
            score: PatternScore(count: 3, sessionDiversity: 1, repoDiversity: 1, avgSimilarity: 0.9, mostRecent: Date())
        )

        XCTAssertEqual(pattern.count, 3)
        XCTAssertEqual(pattern.count, pattern.members.count)
    }

    func testDetectedPatternPreview() {
        let shortContent = "Short content"
        let shortMessage = IndexedMessage(
            id: 1,
            sessionId: "session-1",
            messageUuid: "uuid-1",
            messageType: "user",
            content: shortContent,
            embedding: [Double](repeating: 0.1, count: 512),
            repoPath: "/test/repo",
            timestamp: Date()
        )

        let shortPattern = DetectedPattern(
            id: UUID(),
            representative: shortMessage,
            members: [],
            score: PatternScore(count: 1, sessionDiversity: 1, repoDiversity: 1, avgSimilarity: 1.0, mostRecent: Date())
        )

        XCTAssertEqual(shortPattern.preview, shortContent)

        // Test truncation for long content
        let longContent = String(repeating: "a", count: 200)
        let longMessage = IndexedMessage(
            id: 2,
            sessionId: "session-2",
            messageUuid: "uuid-2",
            messageType: "user",
            content: longContent,
            embedding: [Double](repeating: 0.1, count: 512),
            repoPath: "/test/repo",
            timestamp: Date()
        )

        let longPattern = DetectedPattern(
            id: UUID(),
            representative: longMessage,
            members: [],
            score: PatternScore(count: 1, sessionDiversity: 1, repoDiversity: 1, avgSimilarity: 1.0, mostRecent: Date())
        )

        XCTAssertEqual(longPattern.preview.count, 103)  // 100 + "..."
        XCTAssertTrue(longPattern.preview.hasSuffix("..."))
    }

    func testDetectedPatternSessionCount() {
        let message1 = IndexedMessage(
            id: 1,
            sessionId: "session-1",
            messageUuid: "uuid-1",
            messageType: "user",
            content: "Content 1",
            embedding: [Double](repeating: 0.1, count: 512),
            repoPath: "/test/repo",
            timestamp: Date()
        )

        let message2 = IndexedMessage(
            id: 2,
            sessionId: "session-2",
            messageUuid: "uuid-2",
            messageType: "user",
            content: "Content 2",
            embedding: [Double](repeating: 0.1, count: 512),
            repoPath: "/test/repo",
            timestamp: Date()
        )

        let message3 = IndexedMessage(
            id: 3,
            sessionId: "session-1",  // Same session as message1
            messageUuid: "uuid-3",
            messageType: "user",
            content: "Content 3",
            embedding: [Double](repeating: 0.1, count: 512),
            repoPath: "/test/repo",
            timestamp: Date()
        )

        let members = [
            PatternMember(id: 1, message: message1, similarityToRepresentative: 1.0),
            PatternMember(id: 2, message: message2, similarityToRepresentative: 0.9),
            PatternMember(id: 3, message: message3, similarityToRepresentative: 0.85),
        ]

        let pattern = DetectedPattern(
            id: UUID(),
            representative: message1,
            members: members,
            score: PatternScore(count: 3, sessionDiversity: 2, repoDiversity: 1, avgSimilarity: 0.9, mostRecent: Date())
        )

        XCTAssertEqual(pattern.sessionCount, 2)  // session-1 and session-2
    }

    func testDetectedPatternRepoCount() {
        let message1 = IndexedMessage(
            id: 1,
            sessionId: "session-1",
            messageUuid: "uuid-1",
            messageType: "user",
            content: "Content 1",
            embedding: [Double](repeating: 0.1, count: 512),
            repoPath: "/test/repo1",
            timestamp: Date()
        )

        let message2 = IndexedMessage(
            id: 2,
            sessionId: "session-2",
            messageUuid: "uuid-2",
            messageType: "user",
            content: "Content 2",
            embedding: [Double](repeating: 0.1, count: 512),
            repoPath: "/test/repo2",
            timestamp: Date()
        )

        let members = [
            PatternMember(id: 1, message: message1, similarityToRepresentative: 1.0),
            PatternMember(id: 2, message: message2, similarityToRepresentative: 0.9),
        ]

        let pattern = DetectedPattern(
            id: UUID(),
            representative: message1,
            members: members,
            score: PatternScore(count: 2, sessionDiversity: 2, repoDiversity: 2, avgSimilarity: 0.9, mostRecent: Date())
        )

        XCTAssertEqual(pattern.repoCount, 2)
    }

    // MARK: - Embedding Similarity Tests (Prerequisites for Pattern Detection)

    func testSimilarPromptsHaveHighSimilarity() {
        guard embedder.isAvailable else {
            XCTSkip("Embedding service not available")
            return
        }

        guard let emb1 = embedder.embed("How do I fix this bug?"),
              let emb2 = embedder.embed("Help me debug this issue") else {
            XCTFail("Failed to generate embeddings")
            return
        }

        let similarity = embedder.cosineSimilarity(emb1, emb2)
        XCTAssertGreaterThan(similarity, 0.3, "Similar prompts should have positive similarity")
    }

    func testDissimilarPromptsHaveLowSimilarity() {
        guard embedder.isAvailable else {
            XCTSkip("Embedding service not available")
            return
        }

        guard let emb1 = embedder.embed("How do I fix this bug?"),
              let emb2 = embedder.embed("The weather is sunny today") else {
            XCTFail("Failed to generate embeddings")
            return
        }

        let similarity = embedder.cosineSimilarity(emb1, emb2)
        XCTAssertLessThan(similarity, 0.5, "Dissimilar prompts should have lower similarity")
    }

    // MARK: - Pattern Member Tests

    func testPatternMemberIdentifiable() {
        let message = IndexedMessage(
            id: 42,
            sessionId: "session-1",
            messageUuid: "uuid-1",
            messageType: "user",
            content: "Test",
            embedding: [],
            repoPath: "/test",
            timestamp: Date()
        )

        let member = PatternMember(id: 42, message: message, similarityToRepresentative: 0.95)

        XCTAssertEqual(member.id, 42)
        XCTAssertEqual(member.similarityToRepresentative, 0.95)
    }
}
