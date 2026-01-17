import XCTest
@testable import PromptConduit

final class PTYSessionTests: XCTestCase {

    func testSessionCreation() {
        let session = PTYSession(workingDirectory: "/tmp")
        XCTAssertFalse(session.isRunning)
        XCTAssertTrue(session.output.isEmpty)
    }

    func testOutputParserStripANSI() {
        let input = "\u{1B}[32mGreen text\u{1B}[0m"
        let output = OutputParser.stripANSI(input)
        XCTAssertEqual(output, "Green text")
    }

    func testOutputParserDetectToolUse() {
        let input = "[Tool: Read] src/app/layout.tsx"
        let toolUse = OutputParser.detectToolUse(input)
        XCTAssertNotNil(toolUse)
        XCTAssertEqual(toolUse?.name, "Read")
    }

    func testAgentSessionCreation() {
        let session = AgentSession(
            prompt: "Test prompt",
            workingDirectory: "/tmp"
        )
        XCTAssertEqual(session.status, .idle)
        XCTAssertEqual(session.prompt, "Test prompt")
        XCTAssertTrue(session.transcript.isEmpty)
    }

    func testAgentManagerSingleton() {
        let manager1 = AgentManager.shared
        let manager2 = AgentManager.shared
        XCTAssertTrue(manager1 === manager2)
    }
}
