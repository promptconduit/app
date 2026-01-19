import XCTest
@testable import PromptConduit

final class SlashCommandsServiceTests: XCTestCase {

    // MARK: - Skill Location Tests

    func testLocationGlobalForGlobalPath() {
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        let globalPath = "\(homePath)/.claude/commands/my-skill.md"

        let command = SlashCommand(
            name: "my-skill",
            description: "Test skill",
            allowedTools: nil,
            argumentHint: nil,
            prompt: "Test prompt",
            filePath: globalPath
        )

        XCTAssertEqual(command.location, .global, "Skill in ~/.claude/commands/ should be global")
    }

    func testLocationProjectForProjectPath() {
        let projectPath = "/Users/test/myproject/.claude/commands/deploy.md"

        let command = SlashCommand(
            name: "deploy",
            description: "Deploy skill",
            allowedTools: nil,
            argumentHint: nil,
            prompt: "Deploy the project",
            filePath: projectPath
        )

        XCTAssertEqual(command.location, .project, "Skill in [repo]/.claude/commands/ should be project")
    }

    // MARK: - Display Path Tests

    func testDisplayPathReplacesHomeWithTilde() {
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        let filePath = "\(homePath)/.claude/commands/test.md"

        let command = SlashCommand(
            name: "test",
            description: nil,
            allowedTools: nil,
            argumentHint: nil,
            prompt: "Test",
            filePath: filePath
        )

        XCTAssertTrue(command.displayPath.hasPrefix("~"), "Display path should start with ~")
        XCTAssertFalse(command.displayPath.contains(homePath), "Display path should not contain full home path")
        XCTAssertEqual(command.displayPath, "~/.claude/commands/test.md")
    }

    // MARK: - Project Path Extraction Tests

    func testProjectPathExtraction() {
        let filePath = "/Users/test/myproject/.claude/commands/deploy.md"

        let command = SlashCommand(
            name: "deploy",
            description: nil,
            allowedTools: nil,
            argumentHint: nil,
            prompt: "Deploy",
            filePath: filePath
        )

        XCTAssertEqual(command.projectPath, "/Users/test/myproject", "Should extract project path correctly")
    }

    func testProjectPathNilForGlobalSkill() {
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        let filePath = "\(homePath)/.claude/commands/global-skill.md"

        let command = SlashCommand(
            name: "global-skill",
            description: nil,
            allowedTools: nil,
            argumentHint: nil,
            prompt: "Global",
            filePath: filePath
        )

        XCTAssertNil(command.projectPath, "Global skill should have nil projectPath")
    }

    // MARK: - Project Name Tests

    func testProjectName() {
        let filePath = "/Users/test/myproject/.claude/commands/deploy.md"

        let command = SlashCommand(
            name: "deploy",
            description: nil,
            allowedTools: nil,
            argumentHint: nil,
            prompt: "Deploy",
            filePath: filePath
        )

        XCTAssertEqual(command.projectName, "myproject", "Should extract project name correctly")
    }

    func testProjectNameNilForGlobalSkill() {
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        let filePath = "\(homePath)/.claude/commands/global-skill.md"

        let command = SlashCommand(
            name: "global-skill",
            description: nil,
            allowedTools: nil,
            argumentHint: nil,
            prompt: "Global",
            filePath: filePath
        )

        XCTAssertNil(command.projectName, "Global skill should have nil projectName")
    }

    // MARK: - Nested Project Path Tests

    func testProjectPathWithNestedRepo() {
        let filePath = "/Users/test/work/projects/myapp/.claude/commands/build.md"

        let command = SlashCommand(
            name: "build",
            description: nil,
            allowedTools: nil,
            argumentHint: nil,
            prompt: "Build",
            filePath: filePath
        )

        XCTAssertEqual(command.projectPath, "/Users/test/work/projects/myapp")
        XCTAssertEqual(command.projectName, "myapp")
        XCTAssertEqual(command.location, .project)
    }

    // MARK: - SkillLocation Enum Tests

    func testSkillLocationRawValues() {
        XCTAssertEqual(SkillLocation.global.rawValue, "Global")
        XCTAssertEqual(SkillLocation.project.rawValue, "Project")
    }
}
