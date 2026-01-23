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

    // MARK: - JSONL Event Detection Tests

    /// Test that a "user" event indicates running state (user just submitted prompt)
    func testUserEventIndicatesRunning() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let testFile = tempDir.appendingPathComponent("test-user-event-\(UUID().uuidString).jsonl")

        // Write a JSONL file with a user event
        let userEvent = """
        {"type":"user","message":{"content":"Hello Claude"}}
        """
        try userEvent.write(to: testFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: testFile) }

        // Get the file modification date (just created, so recent)
        let attrs = try FileManager.default.attributesOfItem(atPath: testFile.path)
        let modDate = attrs[.modificationDate] as! Date

        let discovery = ClaudeSessionDiscovery.shared
        let (status, eventType, _) = discovery.detectStatusFromJSONL(
            path: testFile.path,
            modDate: modDate,
            repoPath: "/test/repo"
        )

        XCTAssertEqual(status, .running, "User event should indicate running state")
        XCTAssertEqual(eventType, "user", "Event type should be 'user'")
    }

    /// Test that an "assistant" event with end_turn stop_reason indicates waiting state
    func testAssistantEndTurnIndicatesWaiting() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let testFile = tempDir.appendingPathComponent("test-assistant-end-\(UUID().uuidString).jsonl")

        // Write a JSONL file with an assistant event that has end_turn
        let assistantEvent = """
        {"type":"assistant","message":{"content":"I can help with that.","stop_reason":"end_turn"}}
        """
        try assistantEvent.write(to: testFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: testFile) }

        let attrs = try FileManager.default.attributesOfItem(atPath: testFile.path)
        let modDate = attrs[.modificationDate] as! Date

        let discovery = ClaudeSessionDiscovery.shared
        let (status, eventType, stopReason) = discovery.detectStatusFromJSONL(
            path: testFile.path,
            modDate: modDate,
            repoPath: "/test/repo"
        )

        XCTAssertEqual(status, .waiting, "Assistant with end_turn should indicate waiting state")
        XCTAssertEqual(eventType, "assistant", "Event type should be 'assistant'")
        XCTAssertEqual(stopReason, "end_turn", "Stop reason should be 'end_turn'")
    }

    /// Test that an "assistant" event with tool_use stop_reason indicates running state
    func testAssistantToolUseIndicatesRunning() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let testFile = tempDir.appendingPathComponent("test-assistant-tool-\(UUID().uuidString).jsonl")

        // Write a JSONL file with an assistant event that has tool_use
        let assistantEvent = """
        {"type":"assistant","message":{"content":"Let me check that file.","stop_reason":"tool_use"}}
        """
        try assistantEvent.write(to: testFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: testFile) }

        let attrs = try FileManager.default.attributesOfItem(atPath: testFile.path)
        let modDate = attrs[.modificationDate] as! Date

        let discovery = ClaudeSessionDiscovery.shared
        let (status, eventType, stopReason) = discovery.detectStatusFromJSONL(
            path: testFile.path,
            modDate: modDate,
            repoPath: "/test/repo"
        )

        XCTAssertEqual(status, .running, "Assistant with tool_use should indicate running state")
        XCTAssertEqual(eventType, "assistant", "Event type should be 'assistant'")
        XCTAssertEqual(stopReason, "tool_use", "Stop reason should be 'tool_use'")
    }

    /// Test that a "progress" event indicates running state (Claude is thinking/working)
    func testProgressEventIndicatesRunning() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let testFile = tempDir.appendingPathComponent("test-progress-\(UUID().uuidString).jsonl")

        // Write a JSONL file with a progress event
        let progressEvent = """
        {"type":"progress","data":"Analyzing code..."}
        """
        try progressEvent.write(to: testFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: testFile) }

        let attrs = try FileManager.default.attributesOfItem(atPath: testFile.path)
        let modDate = attrs[.modificationDate] as! Date

        let discovery = ClaudeSessionDiscovery.shared
        let (status, eventType, _) = discovery.detectStatusFromJSONL(
            path: testFile.path,
            modDate: modDate,
            repoPath: "/test/repo"
        )

        XCTAssertEqual(status, .running, "Progress event should indicate running state")
        XCTAssertEqual(eventType, "progress", "Event type should be 'progress'")
    }

    /// Test that a "tool_result" event indicates running state
    func testToolResultEventIndicatesRunning() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let testFile = tempDir.appendingPathComponent("test-tool-result-\(UUID().uuidString).jsonl")

        // Write a JSONL file with a tool_result event
        let toolResultEvent = """
        {"type":"tool_result","content":"File contents here"}
        """
        try toolResultEvent.write(to: testFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: testFile) }

        let attrs = try FileManager.default.attributesOfItem(atPath: testFile.path)
        let modDate = attrs[.modificationDate] as! Date

        let discovery = ClaudeSessionDiscovery.shared
        let (status, eventType, _) = discovery.detectStatusFromJSONL(
            path: testFile.path,
            modDate: modDate,
            repoPath: "/test/repo"
        )

        XCTAssertEqual(status, .running, "Tool result event should indicate running state")
        XCTAssertEqual(eventType, "tool_result", "Event type should be 'tool_result'")
    }

    /// Test that a "result" event indicates running state
    func testResultEventIndicatesRunning() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let testFile = tempDir.appendingPathComponent("test-result-\(UUID().uuidString).jsonl")

        // Write a JSONL file with a result event
        let resultEvent = """
        {"type":"result","data":"Operation completed"}
        """
        try resultEvent.write(to: testFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: testFile) }

        let attrs = try FileManager.default.attributesOfItem(atPath: testFile.path)
        let modDate = attrs[.modificationDate] as! Date

        let discovery = ClaudeSessionDiscovery.shared
        let (status, eventType, _) = discovery.detectStatusFromJSONL(
            path: testFile.path,
            modDate: modDate,
            repoPath: "/test/repo"
        )

        XCTAssertEqual(status, .running, "Result event should indicate running state")
        XCTAssertEqual(eventType, "result", "Event type should be 'result'")
    }

    /// Test that a "summary" event indicates waiting state
    func testSummaryEventIndicatesWaiting() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let testFile = tempDir.appendingPathComponent("test-summary-\(UUID().uuidString).jsonl")

        // Write a JSONL file with a summary event
        let summaryEvent = """
        {"type":"summary","summary":"Session about code review"}
        """
        try summaryEvent.write(to: testFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: testFile) }

        let attrs = try FileManager.default.attributesOfItem(atPath: testFile.path)
        let modDate = attrs[.modificationDate] as! Date

        let discovery = ClaudeSessionDiscovery.shared
        let (status, eventType, _) = discovery.detectStatusFromJSONL(
            path: testFile.path,
            modDate: modDate,
            repoPath: "/test/repo"
        )

        XCTAssertEqual(status, .waiting, "Summary event should indicate waiting state")
        XCTAssertEqual(eventType, "summary", "Event type should be 'summary'")
    }

    /// Test that old files are detected as idle regardless of event type
    func testOldFileIsIdle() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let testFile = tempDir.appendingPathComponent("test-old-file-\(UUID().uuidString).jsonl")

        // Write a JSONL file with a user event
        let userEvent = """
        {"type":"user","message":{"content":"Hello"}}
        """
        try userEvent.write(to: testFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: testFile) }

        // Simulate an old file (6 minutes ago)
        let oldDate = Date().addingTimeInterval(-360)

        let discovery = ClaudeSessionDiscovery.shared
        let (status, _, _) = discovery.detectStatusFromJSONL(
            path: testFile.path,
            modDate: oldDate,
            repoPath: "/test/repo"
        )

        XCTAssertEqual(status, .idle, "Old file (>5 minutes) should be idle regardless of event type")
    }

    /// Test reading last event from a multi-line JSONL file
    func testReadLastEventFromMultiLineFile() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let testFile = tempDir.appendingPathComponent("test-multiline-\(UUID().uuidString).jsonl")

        // Write a JSONL file with multiple events
        let events = """
        {"type":"user","message":{"content":"First message"}}
        {"type":"assistant","message":{"content":"Response","stop_reason":"end_turn"}}
        {"type":"user","message":{"content":"Second message"}}
        {"type":"progress","data":"Thinking..."}
        """
        try events.write(to: testFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: testFile) }

        let discovery = ClaudeSessionDiscovery.shared
        let lastEvent = discovery.readLastJSONLEvent(testFile.path)

        XCTAssertNotNil(lastEvent, "Should read last event from file")
        XCTAssertEqual(lastEvent?["type"] as? String, "progress", "Last event should be 'progress'")
    }

    /// Test that the last valid event in sequence determines state
    func testLastEventDeterminesState() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let testFile = tempDir.appendingPathComponent("test-sequence-\(UUID().uuidString).jsonl")

        // Write a conversation sequence ending with assistant end_turn
        let events = """
        {"type":"user","message":{"content":"Help me"}}
        {"type":"assistant","message":{"content":"Sure!","stop_reason":"tool_use"}}
        {"type":"tool_result","content":"data"}
        {"type":"assistant","message":{"content":"Here's the answer.","stop_reason":"end_turn"}}
        """
        try events.write(to: testFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: testFile) }

        let attrs = try FileManager.default.attributesOfItem(atPath: testFile.path)
        let modDate = attrs[.modificationDate] as! Date

        let discovery = ClaudeSessionDiscovery.shared
        let (status, eventType, stopReason) = discovery.detectStatusFromJSONL(
            path: testFile.path,
            modDate: modDate,
            repoPath: "/test/repo"
        )

        XCTAssertEqual(status, .waiting, "Final assistant with end_turn should indicate waiting")
        XCTAssertEqual(eventType, "assistant", "Event type should be 'assistant'")
        XCTAssertEqual(stopReason, "end_turn", "Stop reason should be 'end_turn'")
    }

    /// Test streaming assistant (no stop_reason) with recent modification
    func testStreamingAssistantRecentIsRunning() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let testFile = tempDir.appendingPathComponent("test-streaming-\(UUID().uuidString).jsonl")

        // Write an assistant event without stop_reason (still streaming)
        let assistantEvent = """
        {"type":"assistant","message":{"content":"I'm still writing..."}}
        """
        try assistantEvent.write(to: testFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: testFile) }

        // Use current time (just created - recent)
        let attrs = try FileManager.default.attributesOfItem(atPath: testFile.path)
        let modDate = attrs[.modificationDate] as! Date

        let discovery = ClaudeSessionDiscovery.shared
        let (status, _, _) = discovery.detectStatusFromJSONL(
            path: testFile.path,
            modDate: modDate,
            repoPath: "/test/repo"
        )

        XCTAssertEqual(status, .running, "Recent streaming assistant (no stop_reason) should be running")
    }

    /// Test streaming assistant (no stop_reason) with older modification
    func testStreamingAssistantOlderIsWaiting() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let testFile = tempDir.appendingPathComponent("test-streaming-old-\(UUID().uuidString).jsonl")

        // Write an assistant event without stop_reason
        let assistantEvent = """
        {"type":"assistant","message":{"content":"I'm still writing..."}}
        """
        try assistantEvent.write(to: testFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: testFile) }

        // Simulate older modification (45 seconds ago - past 30s threshold but within 5 min)
        let olderDate = Date().addingTimeInterval(-45)

        let discovery = ClaudeSessionDiscovery.shared
        let (status, _, _) = discovery.detectStatusFromJSONL(
            path: testFile.path,
            modDate: olderDate,
            repoPath: "/test/repo"
        )

        XCTAssertEqual(status, .waiting, "Older streaming assistant (no stop_reason, >30s) should be waiting")
    }

    /// Test handling of empty file
    func testEmptyFileFallsBackToTimeBased() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let testFile = tempDir.appendingPathComponent("test-empty-\(UUID().uuidString).jsonl")

        // Create an empty file
        try "".write(to: testFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: testFile) }

        // Recent modification should fall back to time-based = running
        let recentDate = Date().addingTimeInterval(-10)

        let discovery = ClaudeSessionDiscovery.shared
        let (status, eventType, _) = discovery.detectStatusFromJSONL(
            path: testFile.path,
            modDate: recentDate,
            repoPath: "/test/repo"
        )

        XCTAssertEqual(status, .running, "Empty file with recent mod time should fall back to running")
        XCTAssertNil(eventType, "No event type for empty file")
    }

    /// Test handling of malformed JSON
    func testMalformedJsonFallsBackToTimeBased() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let testFile = tempDir.appendingPathComponent("test-malformed-\(UUID().uuidString).jsonl")

        // Write invalid JSON
        try "this is not valid json".write(to: testFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: testFile) }

        // Recent modification should fall back to time-based = running
        let recentDate = Date().addingTimeInterval(-10)

        let discovery = ClaudeSessionDiscovery.shared
        let (status, eventType, _) = discovery.detectStatusFromJSONL(
            path: testFile.path,
            modDate: recentDate,
            repoPath: "/test/repo"
        )

        XCTAssertEqual(status, .running, "Malformed JSON with recent mod time should fall back to running")
        XCTAssertNil(eventType, "No event type for malformed JSON")
    }

    // MARK: - DiscoveredSession JSONL Properties Tests

    func testDiscoveredSessionLastEventType() {
        let session = DiscoveredSession(
            id: "test-session",
            filePath: "/path/to/session.jsonl",
            repoPath: "/path/to/repo",
            title: "Test",
            status: .running,
            lastActivity: Date(),
            messageCount: 5,
            lastEventType: "progress",
            lastStopReason: nil
        )
        XCTAssertEqual(session.lastEventType, "progress")
        XCTAssertNil(session.lastStopReason)
    }

    func testDiscoveredSessionStopReason() {
        let session = DiscoveredSession(
            id: "test-session",
            filePath: "/path/to/session.jsonl",
            repoPath: "/path/to/repo",
            title: "Test",
            status: .waiting,
            lastActivity: Date(),
            messageCount: 5,
            lastEventType: "assistant",
            lastStopReason: "end_turn"
        )
        XCTAssertEqual(session.lastEventType, "assistant")
        XCTAssertEqual(session.lastStopReason, "end_turn")
    }
}
