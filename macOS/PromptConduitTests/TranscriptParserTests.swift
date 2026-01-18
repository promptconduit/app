import XCTest
@testable import PromptConduit

final class TranscriptParserTests: XCTestCase {

    var parser: TranscriptParser!
    var tempDir: URL!

    override func setUp() {
        super.setUp()
        parser = TranscriptParser()

        // Create temp directory for test files
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - User Message Tests

    func testParseUserMessageWithStringContent() {
        let jsonl = """
        {"type":"user","uuid":"user-123","message":{"content":"Help me fix this bug"},"timestamp":"2025-01-15T10:30:00.000Z"}
        """

        let filePath = createTempFile(content: jsonl)
        let messages = parser.parseSessionFile(filePath, sessionId: "test-session", repoPath: "/test/repo")

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].type, .user)
        XCTAssertEqual(messages[0].content, "Help me fix this bug")
        XCTAssertEqual(messages[0].id, "user-123")
    }

    func testParseUserMessageWithArrayContent() {
        let jsonl = """
        {"type":"user","uuid":"user-456","message":{"content":[{"type":"text","text":"First part"},{"type":"text","text":"Second part"}]},"timestamp":"2025-01-15T10:30:00.000Z"}
        """

        let filePath = createTempFile(content: jsonl)
        let messages = parser.parseSessionFile(filePath, sessionId: "test-session", repoPath: "/test/repo")

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].type, .user)
        XCTAssertEqual(messages[0].content, "First part\nSecond part")
    }

    // MARK: - Assistant Message Tests

    func testParseAssistantMessageWithTextBlocks() {
        let jsonl = """
        {"type":"assistant","uuid":"asst-789","message":{"content":[{"type":"text","text":"Here is the solution"}]},"timestamp":"2025-01-15T10:31:00.000Z"}
        """

        let filePath = createTempFile(content: jsonl)
        let messages = parser.parseSessionFile(filePath, sessionId: "test-session", repoPath: "/test/repo")

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].type, .assistant)
        XCTAssertEqual(messages[0].content, "Here is the solution")
    }

    func testSkipToolUseBlocks() {
        let jsonl = """
        {"type":"assistant","uuid":"asst-tool","message":{"content":[{"type":"text","text":"Let me help"},{"type":"tool_use","name":"read_file","input":{}}]},"timestamp":"2025-01-15T10:31:00.000Z"}
        """

        let filePath = createTempFile(content: jsonl)
        let messages = parser.parseSessionFile(filePath, sessionId: "test-session", repoPath: "/test/repo")

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].content, "Let me help")
    }

    // MARK: - Multiple Messages Tests

    func testParseMultipleMessages() {
        let jsonl = """
        {"type":"user","uuid":"u1","message":{"content":"Question 1"},"timestamp":"2025-01-15T10:00:00.000Z"}
        {"type":"assistant","uuid":"a1","message":{"content":[{"type":"text","text":"Answer 1"}]},"timestamp":"2025-01-15T10:01:00.000Z"}
        {"type":"user","uuid":"u2","message":{"content":"Question 2"},"timestamp":"2025-01-15T10:02:00.000Z"}
        {"type":"assistant","uuid":"a2","message":{"content":[{"type":"text","text":"Answer 2"}]},"timestamp":"2025-01-15T10:03:00.000Z"}
        """

        let filePath = createTempFile(content: jsonl)
        let messages = parser.parseSessionFile(filePath, sessionId: "test-session", repoPath: "/test/repo")

        XCTAssertEqual(messages.count, 4)
        XCTAssertEqual(messages[0].type, .user)
        XCTAssertEqual(messages[1].type, .assistant)
        XCTAssertEqual(messages[2].type, .user)
        XCTAssertEqual(messages[3].type, .assistant)
    }

    // MARK: - Edge Cases

    func testSkipSummaryMessages() {
        let jsonl = """
        {"type":"summary","summary":"Session about debugging","leafTitle":"Debug Session"}
        {"type":"user","uuid":"u1","message":{"content":"Help"},"timestamp":"2025-01-15T10:00:00.000Z"}
        """

        let filePath = createTempFile(content: jsonl)
        let messages = parser.parseSessionFile(filePath, sessionId: "test-session", repoPath: "/test/repo")

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].type, .user)
    }

    func testHandleMalformedJSON() {
        let jsonl = """
        {"type":"user","uuid":"u1","message":{"content":"Valid message"},"timestamp":"2025-01-15T10:00:00.000Z"}
        this is not valid json
        {"type":"assistant","uuid":"a1","message":{"content":[{"type":"text","text":"Another valid"}]},"timestamp":"2025-01-15T10:01:00.000Z"}
        """

        let filePath = createTempFile(content: jsonl)
        let messages = parser.parseSessionFile(filePath, sessionId: "test-session", repoPath: "/test/repo")

        // Should skip malformed line and continue
        XCTAssertEqual(messages.count, 2)
    }

    func testGenerateUUIDWhenMissing() {
        let jsonl = """
        {"type":"user","message":{"content":"No UUID here"},"timestamp":"2025-01-15T10:00:00.000Z"}
        """

        let filePath = createTempFile(content: jsonl)
        let messages = parser.parseSessionFile(filePath, sessionId: "test-session", repoPath: "/test/repo")

        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(messages[0].id.hasPrefix("user-"))
    }

    func testSkipEmptyContent() {
        let jsonl = """
        {"type":"user","uuid":"u1","message":{"content":""},"timestamp":"2025-01-15T10:00:00.000Z"}
        {"type":"user","uuid":"u2","message":{"content":"Has content"},"timestamp":"2025-01-15T10:01:00.000Z"}
        """

        let filePath = createTempFile(content: jsonl)
        let messages = parser.parseSessionFile(filePath, sessionId: "test-session", repoPath: "/test/repo")

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].content, "Has content")
    }

    func testParseTimestamp() {
        let jsonl = """
        {"type":"user","uuid":"u1","message":{"content":"Test"},"timestamp":"2025-01-15T10:30:00.000Z"}
        """

        let filePath = createTempFile(content: jsonl)
        let messages = parser.parseSessionFile(filePath, sessionId: "test-session", repoPath: "/test/repo")

        XCTAssertEqual(messages.count, 1)

        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents(in: TimeZone(identifier: "UTC")!, from: messages[0].timestamp)
        XCTAssertEqual(components.year, 2025)
        XCTAssertEqual(components.month, 1)
        XCTAssertEqual(components.day, 15)
    }

    // MARK: - Filter Methods

    func testFilterUserMessages() {
        let jsonl = """
        {"type":"user","uuid":"u1","message":{"content":"User 1"},"timestamp":"2025-01-15T10:00:00.000Z"}
        {"type":"assistant","uuid":"a1","message":{"content":[{"type":"text","text":"Asst 1"}]},"timestamp":"2025-01-15T10:01:00.000Z"}
        {"type":"user","uuid":"u2","message":{"content":"User 2"},"timestamp":"2025-01-15T10:02:00.000Z"}
        """

        let filePath = createTempFile(content: jsonl)
        let userMessages = parser.parseUserMessages(filePath, sessionId: "test-session", repoPath: "/test/repo")

        XCTAssertEqual(userMessages.count, 2)
        XCTAssertTrue(userMessages.allSatisfy { $0.type == .user })
    }

    func testFilterAssistantMessages() {
        let jsonl = """
        {"type":"user","uuid":"u1","message":{"content":"User 1"},"timestamp":"2025-01-15T10:00:00.000Z"}
        {"type":"assistant","uuid":"a1","message":{"content":[{"type":"text","text":"Asst 1"}]},"timestamp":"2025-01-15T10:01:00.000Z"}
        {"type":"assistant","uuid":"a2","message":{"content":[{"type":"text","text":"Asst 2"}]},"timestamp":"2025-01-15T10:02:00.000Z"}
        """

        let filePath = createTempFile(content: jsonl)
        let assistantMessages = parser.parseAssistantMessages(filePath, sessionId: "test-session", repoPath: "/test/repo")

        XCTAssertEqual(assistantMessages.count, 2)
        XCTAssertTrue(assistantMessages.allSatisfy { $0.type == .assistant })
    }

    // MARK: - File Hash

    func testComputeFileHash() {
        let content = "Test content for hashing"
        let filePath = createTempFile(content: content)

        let hash1 = parser.computeFileHash(filePath)
        let hash2 = parser.computeFileHash(filePath)

        XCTAssertNotNil(hash1)
        XCTAssertEqual(hash1, hash2, "Same content should produce same hash")
    }

    func testDifferentContentDifferentHash() {
        let filePath1 = createTempFile(content: "Content A")
        let filePath2 = createTempFile(content: "Content B")

        let hash1 = parser.computeFileHash(filePath1)
        let hash2 = parser.computeFileHash(filePath2)

        XCTAssertNotNil(hash1)
        XCTAssertNotNil(hash2)
        XCTAssertNotEqual(hash1, hash2, "Different content should produce different hash")
    }

    // MARK: - Helpers

    private func createTempFile(content: String) -> String {
        let filePath = tempDir.appendingPathComponent(UUID().uuidString + ".jsonl")
        try? content.write(to: filePath, atomically: true, encoding: .utf8)
        return filePath.path
    }
}
