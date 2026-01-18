import XCTest
@testable import PromptConduit

final class PatternSkillServiceTests: XCTestCase {

    var service: PatternSkillService!

    override func setUp() {
        super.setUp()
        service = PatternSkillService()
    }

    override func tearDown() {
        service = nil
        super.tearDown()
    }

    // MARK: - Test Helpers

    private func createMockPattern(
        content: String = "Help me fix this authentication bug",
        repoPath: String = "/Users/test/myproject",
        memberCount: Int = 3,
        sessionDiversity: Int = 2,
        repoDiversity: Int = 1
    ) -> DetectedPattern {
        let message = IndexedMessage(
            id: 1,
            sessionId: "session-1",
            messageUuid: "uuid-1",
            messageType: "user",
            content: content,
            embedding: [],
            repoPath: repoPath,
            timestamp: Date()
        )

        var members: [PatternMember] = []
        for i in 0..<memberCount {
            let memberMessage = IndexedMessage(
                id: Int64(i + 1),
                sessionId: "session-\(i % sessionDiversity + 1)",
                messageUuid: "uuid-\(i + 1)",
                messageType: "user",
                content: "Similar message \(i)",
                embedding: [],
                repoPath: i < repoDiversity ? "/Users/test/project\(i)" : repoPath,
                timestamp: Date()
            )
            members.append(PatternMember(
                id: Int64(i + 1),
                message: memberMessage,
                similarityToRepresentative: 0.9 - Double(i) * 0.05
            ))
        }

        return DetectedPattern(
            id: UUID(),
            representative: message,
            members: members,
            score: PatternScore(
                count: memberCount,
                sessionDiversity: sessionDiversity,
                repoDiversity: repoDiversity,
                avgSimilarity: 0.85,
                mostRecent: Date()
            )
        )
    }

    // MARK: - Skill Name Suggestion Tests

    func testSuggestSkillNameFromPattern() {
        let pattern = createMockPattern(content: "Help me fix this authentication bug")
        let name = service.suggestSkillName(from: pattern)

        XCTAssertFalse(name.isEmpty, "Name should not be empty")
        XCTAssertTrue(name.contains("help") || name.contains("fix") || name.contains("auth"),
                      "Name should contain words from content")
        XCTAssertFalse(name.contains(" "), "Name should not contain spaces")
        XCTAssertEqual(name, name.lowercased(), "Name should be lowercase")
    }

    func testSuggestSkillNameHandlesSpecialCharacters() {
        let pattern = createMockPattern(content: "What's the best way to handle @#$% errors?!")
        let name = service.suggestSkillName(from: pattern)

        XCTAssertFalse(name.isEmpty, "Name should not be empty")
        XCTAssertFalse(name.contains("@"), "Name should not contain @")
        XCTAssertFalse(name.contains("#"), "Name should not contain #")
        XCTAssertFalse(name.contains("$"), "Name should not contain $")
        XCTAssertFalse(name.contains("%"), "Name should not contain %")
        XCTAssertFalse(name.contains("?"), "Name should not contain ?")
        XCTAssertFalse(name.contains("!"), "Name should not contain !")
    }

    func testSuggestSkillNameTruncatesLongContent() {
        let longContent = String(repeating: "word ", count: 100)
        let pattern = createMockPattern(content: longContent)
        let name = service.suggestSkillName(from: pattern)

        // Should be limited to ~5 words max
        let wordCount = name.components(separatedBy: "-").count
        XCTAssertLessThanOrEqual(wordCount, 5, "Name should have at most 5 words")
    }

    func testSuggestSkillNameHandlesEmptyContent() {
        let pattern = createMockPattern(content: "   ")
        let name = service.suggestSkillName(from: pattern)

        XCTAssertFalse(name.isEmpty, "Name should not be empty even for whitespace content")
        XCTAssertTrue(name.hasPrefix("pattern-"), "Empty content should generate fallback name")
    }

    // MARK: - Sanitize Skill Name Tests

    func testSanitizeSkillName() {
        XCTAssertEqual(service.sanitizeSkillName("My Skill Name"), "my-skill-name")
        XCTAssertEqual(service.sanitizeSkillName("skill@#$%name"), "skill-name")
        XCTAssertEqual(service.sanitizeSkillName("--double--dashes--"), "double-dashes")
        XCTAssertEqual(service.sanitizeSkillName("UPPERCASE"), "uppercase")
        XCTAssertEqual(service.sanitizeSkillName("already-valid"), "already-valid")
    }

    func testSanitizeSkillNameHandlesEmpty() {
        XCTAssertEqual(service.sanitizeSkillName(""), "skill")
        XCTAssertEqual(service.sanitizeSkillName("@#$%"), "skill")
    }

    // MARK: - Description Generation Tests

    func testSuggestDescription() {
        let pattern = createMockPattern(memberCount: 5, sessionDiversity: 3, repoDiversity: 1)
        let description = service.suggestDescription(from: pattern)

        XCTAssertTrue(description.contains("5"), "Description should mention count")
        XCTAssertTrue(description.contains("3"), "Description should mention session diversity")
        XCTAssertTrue(description.lowercased().contains("pattern"), "Description should mention pattern")
    }

    func testSuggestDescriptionMultiRepo() {
        let pattern = createMockPattern(memberCount: 5, sessionDiversity: 2, repoDiversity: 3)
        let description = service.suggestDescription(from: pattern)

        XCTAssertTrue(description.contains("repositor"), "Description should mention repositories for multi-repo patterns")
    }

    // MARK: - Location Suggestion Tests

    func testSuggestLocationReturnProjectForSingleRepo() {
        let pattern = createMockPattern(repoDiversity: 1)
        let location = service.suggestLocation(from: pattern)

        XCTAssertEqual(location, .project, "Single repo patterns should suggest project location")
    }

    func testSuggestLocationReturnsGlobalForMultipleRepos() {
        // Create pattern with multiple repos
        let message = IndexedMessage(
            id: 1,
            sessionId: "session-1",
            messageUuid: "uuid-1",
            messageType: "user",
            content: "Test content",
            embedding: [],
            repoPath: "/Users/test/project1",
            timestamp: Date()
        )

        let members = [
            PatternMember(id: 1, message: IndexedMessage(
                id: 1, sessionId: "s1", messageUuid: "u1", messageType: "user",
                content: "Test 1", embedding: [], repoPath: "/Users/test/project1", timestamp: Date()
            ), similarityToRepresentative: 1.0),
            PatternMember(id: 2, message: IndexedMessage(
                id: 2, sessionId: "s2", messageUuid: "u2", messageType: "user",
                content: "Test 2", embedding: [], repoPath: "/Users/test/project2", timestamp: Date()
            ), similarityToRepresentative: 0.9),
            PatternMember(id: 3, message: IndexedMessage(
                id: 3, sessionId: "s3", messageUuid: "u3", messageType: "user",
                content: "Test 3", embedding: [], repoPath: "/Users/test/project3", timestamp: Date()
            ), similarityToRepresentative: 0.85)
        ]

        let pattern = DetectedPattern(
            id: UUID(),
            representative: message,
            members: members,
            score: PatternScore(count: 3, sessionDiversity: 3, repoDiversity: 3, avgSimilarity: 0.9, mostRecent: Date())
        )

        let location = service.suggestLocation(from: pattern)
        XCTAssertEqual(location, .global, "Multi-repo patterns should suggest global location")
    }

    // MARK: - Markdown Generation Tests

    func testGenerateSkillMarkdownIncludesFrontmatter() {
        let pattern = createMockPattern()
        let markdown = service.generateSkillMarkdown(
            pattern: pattern,
            name: "test-skill",
            description: "A test description"
        )

        XCTAssertTrue(markdown.hasPrefix("---"), "Markdown should start with frontmatter delimiter")
        XCTAssertTrue(markdown.contains("description:"), "Markdown should include description field")
        XCTAssertTrue(markdown.contains("A test description"), "Markdown should include provided description")

        // Count frontmatter delimiters
        let delimiterCount = markdown.components(separatedBy: "---").count - 1
        XCTAssertEqual(delimiterCount, 2, "Markdown should have exactly two frontmatter delimiters")
    }

    func testGenerateSkillMarkdownIncludesContent() {
        let pattern = createMockPattern(content: "Help me fix this authentication bug")
        let markdown = service.generateSkillMarkdown(
            pattern: pattern,
            name: "auth-fix",
            description: "Authentication helper"
        )

        XCTAssertTrue(markdown.contains("Help me fix this authentication bug"),
                      "Markdown should include representative prompt content")
    }

    // MARK: - Path Tests

    func testSkillPathGlobal() {
        let path = service.skillPath(name: "my-skill", location: .global, projectPath: nil)

        XCTAssertTrue(path.contains(".claude/commands"), "Global path should contain .claude/commands")
        XCTAssertTrue(path.hasSuffix("my-skill.md"), "Path should end with skill name and .md extension")
    }

    func testSkillPathProject() {
        let projectPath = "/Users/test/myproject"
        let path = service.skillPath(name: "my-skill", location: .project, projectPath: projectPath)

        XCTAssertTrue(path.hasPrefix(projectPath), "Project path should start with project directory")
        XCTAssertTrue(path.contains(".claude/commands"), "Project path should contain .claude/commands")
        XCTAssertTrue(path.hasSuffix("my-skill.md"), "Path should end with skill name and .md extension")
    }

    func testSkillPathProjectFallsBackToGlobalWhenNoProjectPath() {
        let path = service.skillPath(name: "my-skill", location: .project, projectPath: nil)

        // Should fall back to global path when no project path provided
        XCTAssertTrue(path.contains(".claude/commands"), "Should fall back to global path")
    }

    // MARK: - Primary Repo Path Tests

    func testPrimaryRepoPath() {
        let pattern = createMockPattern(repoPath: "/Users/test/myproject")
        let repoPath = service.primaryRepoPath(from: pattern)

        XCTAssertNotNil(repoPath, "Primary repo path should not be nil")
    }

    // MARK: - Skill Exists Tests

    func testSkillExistsReturnsFalseForNonexistent() {
        let randomName = "nonexistent-skill-\(UUID().uuidString)"
        let exists = service.skillExists(name: randomName, location: .global, projectPath: nil)

        XCTAssertFalse(exists, "Non-existent skill should return false")
    }
}
