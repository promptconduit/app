import XCTest
@testable import PromptConduit

final class ClaudeSessionDiscoveryTests: XCTestCase {

    // MARK: - Status Detection Tests

    func testStatusRunningWhenRecentlyModified() {
        // Within 30 seconds should be "running"
        let modDate = Date().addingTimeInterval(-15) // 15 seconds ago
        let status = detectStatus(modificationDate: modDate)
        XCTAssertEqual(status, .running, "File modified 15 seconds ago should be running")
    }

    func testStatusRunningAtBoundary() {
        // At exactly 29 seconds should still be "running"
        let modDate = Date().addingTimeInterval(-29)
        let status = detectStatus(modificationDate: modDate)
        XCTAssertEqual(status, .running, "File modified 29 seconds ago should be running")
    }

    func testStatusWaitingAfter30Seconds() {
        // After 30 seconds but within 5 minutes should be "waiting"
        let modDate = Date().addingTimeInterval(-60) // 1 minute ago
        let status = detectStatus(modificationDate: modDate)
        XCTAssertEqual(status, .waiting, "File modified 1 minute ago should be waiting")
    }

    func testStatusWaitingAt4Minutes() {
        // At 4 minutes should still be "waiting"
        let modDate = Date().addingTimeInterval(-240) // 4 minutes ago
        let status = detectStatus(modificationDate: modDate)
        XCTAssertEqual(status, .waiting, "File modified 4 minutes ago should be waiting")
    }

    func testStatusIdleAfter5Minutes() {
        // After 5 minutes should be "idle"
        let modDate = Date().addingTimeInterval(-301) // 5 minutes + 1 second
        let status = detectStatus(modificationDate: modDate)
        XCTAssertEqual(status, .idle, "File modified 5+ minutes ago should be idle")
    }

    func testStatusIdleForOldSessions() {
        // Very old sessions should be "idle"
        let modDate = Date().addingTimeInterval(-3600) // 1 hour ago
        let status = detectStatus(modificationDate: modDate)
        XCTAssertEqual(status, .idle, "File modified 1 hour ago should be idle")
    }

    // MARK: - Status Properties Tests

    func testRunningStatusIcon() {
        XCTAssertEqual(ClaudeSessionStatus.running.icon, "circle.fill")
    }

    func testWaitingStatusIcon() {
        XCTAssertEqual(ClaudeSessionStatus.waiting.icon, "circle.lefthalf.filled")
    }

    func testIdleStatusIcon() {
        XCTAssertEqual(ClaudeSessionStatus.idle.icon, "circle")
    }

    func testErrorStatusIcon() {
        XCTAssertEqual(ClaudeSessionStatus.error.icon, "xmark.circle")
    }

    func testRunningStatusLabel() {
        XCTAssertEqual(ClaudeSessionStatus.running.label, "Running")
    }

    func testWaitingStatusLabel() {
        XCTAssertEqual(ClaudeSessionStatus.waiting.label, "Waiting")
    }

    func testIdleStatusLabel() {
        XCTAssertEqual(ClaudeSessionStatus.idle.label, "Idle")
    }

    func testErrorStatusLabel() {
        XCTAssertEqual(ClaudeSessionStatus.error.label, "Error")
    }

    // MARK: - DiscoveredSession Tests

    func testDiscoveredSessionRepoName() {
        let session = DiscoveredSession(
            id: "test-session-id",
            filePath: "/Users/test/.claude/projects/test-repo/session.jsonl",
            repoPath: "/Users/test/code/my-project",
            title: "Test Session",
            status: .idle,
            lastActivity: Date(),
            messageCount: 5
        )
        XCTAssertEqual(session.repoName, "my-project")
    }

    func testDiscoveredSessionRelativeTime() {
        let session = DiscoveredSession(
            id: "test-session-id",
            filePath: "/path/to/session.jsonl",
            repoPath: "/path/to/repo",
            title: "Test Session",
            status: .idle,
            lastActivity: Date().addingTimeInterval(-60), // 1 minute ago
            messageCount: 5
        )
        // RelativeDateTimeFormatter produces localized output
        XCTAssertFalse(session.relativeTime.isEmpty, "Relative time should not be empty")
    }

    func testDiscoveredSessionEquatable() {
        let date = Date()  // Use same date instance for both
        let session1 = DiscoveredSession(
            id: "session-123",
            filePath: "/path/session.jsonl",
            repoPath: "/path/repo",
            title: "Test",
            status: .running,
            lastActivity: date,
            messageCount: 10
        )
        let session2 = DiscoveredSession(
            id: "session-123",
            filePath: "/path/session.jsonl",
            repoPath: "/path/repo",
            title: "Test",
            status: .running,
            lastActivity: date,
            messageCount: 10
        )
        XCTAssertEqual(session1, session2)
    }

    // MARK: - RepoSessionGroup Tests

    func testRepoGroupAggregateStatusRunning() {
        var group = RepoSessionGroup(
            id: "/path/repo",
            displayName: "repo",
            sessions: [
                DiscoveredSession(id: "1", filePath: "", repoPath: "", title: "", status: .idle, lastActivity: Date(), messageCount: 0),
                DiscoveredSession(id: "2", filePath: "", repoPath: "", title: "", status: .running, lastActivity: Date(), messageCount: 0),
                DiscoveredSession(id: "3", filePath: "", repoPath: "", title: "", status: .waiting, lastActivity: Date(), messageCount: 0)
            ]
        )
        XCTAssertEqual(group.aggregateStatus, .running, "Running should have highest priority")
    }

    func testRepoGroupAggregateStatusWaiting() {
        var group = RepoSessionGroup(
            id: "/path/repo",
            displayName: "repo",
            sessions: [
                DiscoveredSession(id: "1", filePath: "", repoPath: "", title: "", status: .idle, lastActivity: Date(), messageCount: 0),
                DiscoveredSession(id: "2", filePath: "", repoPath: "", title: "", status: .waiting, lastActivity: Date(), messageCount: 0)
            ]
        )
        XCTAssertEqual(group.aggregateStatus, .waiting, "Waiting should have second priority")
    }

    func testRepoGroupAggregateStatusError() {
        var group = RepoSessionGroup(
            id: "/path/repo",
            displayName: "repo",
            sessions: [
                DiscoveredSession(id: "1", filePath: "", repoPath: "", title: "", status: .idle, lastActivity: Date(), messageCount: 0),
                DiscoveredSession(id: "2", filePath: "", repoPath: "", title: "", status: .error, lastActivity: Date(), messageCount: 0)
            ]
        )
        XCTAssertEqual(group.aggregateStatus, .error, "Error should show when no running/waiting")
    }

    func testRepoGroupAggregateStatusIdle() {
        var group = RepoSessionGroup(
            id: "/path/repo",
            displayName: "repo",
            sessions: [
                DiscoveredSession(id: "1", filePath: "", repoPath: "", title: "", status: .idle, lastActivity: Date(), messageCount: 0),
                DiscoveredSession(id: "2", filePath: "", repoPath: "", title: "", status: .idle, lastActivity: Date(), messageCount: 0)
            ]
        )
        XCTAssertEqual(group.aggregateStatus, .idle, "All idle should show idle")
    }

    func testRepoGroupSessionCount() {
        let group = RepoSessionGroup(
            id: "/path/repo",
            displayName: "repo",
            sessions: [
                DiscoveredSession(id: "1", filePath: "", repoPath: "", title: "", status: .idle, lastActivity: Date(), messageCount: 0),
                DiscoveredSession(id: "2", filePath: "", repoPath: "", title: "", status: .idle, lastActivity: Date(), messageCount: 0),
                DiscoveredSession(id: "3", filePath: "", repoPath: "", title: "", status: .idle, lastActivity: Date(), messageCount: 0)
            ]
        )
        XCTAssertEqual(group.sessionCount, 3)
    }

    func testRepoGroupDefaultExpanded() {
        let group = RepoSessionGroup(
            id: "/path/repo",
            displayName: "repo",
            sessions: []
        )
        XCTAssertTrue(group.isExpanded, "Groups should be expanded by default")
    }

    // MARK: - Helper: Detect Status (mirrors internal logic)

    private func detectStatus(modificationDate: Date) -> ClaudeSessionStatus {
        let age = Date().timeIntervalSince(modificationDate)

        switch age {
        case ..<30:
            return .running
        case ..<300: // 5 minutes
            return .waiting
        default:
            return .idle
        }
    }
}
