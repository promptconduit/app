import Foundation
import Combine

/// Represents a Claude slash command
struct SlashCommand: Identifiable, Hashable {
    let id: String
    let name: String
    let description: String?
    let allowedTools: String?
    let argumentHint: String?
    let prompt: String
    let filePath: String

    init(name: String, description: String?, allowedTools: String?, argumentHint: String?, prompt: String, filePath: String) {
        self.id = name
        self.name = name
        self.description = description
        self.allowedTools = allowedTools
        self.argumentHint = argumentHint
        self.prompt = prompt
        self.filePath = filePath
    }
}

/// Service for managing Claude slash commands
class SlashCommandsService: ObservableObject {
    static let shared = SlashCommandsService()

    @Published private(set) var commands: [SlashCommand] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?

    private init() {
        reload()
    }

    // MARK: - Loading

    func reload() {
        isLoading = true
        error = nil

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let loadedCommands = self?.loadCommands() ?? []

            DispatchQueue.main.async {
                self?.commands = loadedCommands
                self?.isLoading = false
            }
        }
    }

    private func loadCommands() -> [SlashCommand] {
        var allCommands: [SlashCommand] = []

        // Load from user-level commands
        let userCommandsPath = SettingsService.claudeCommandsPath
        allCommands.append(contentsOf: loadCommandsFromDirectory(userCommandsPath))

        return allCommands.sorted { $0.name < $1.name }
    }

    private func loadCommandsFromDirectory(_ path: String) -> [SlashCommand] {
        let fileManager = FileManager.default
        var commands: [SlashCommand] = []

        guard fileManager.fileExists(atPath: path) else {
            return []
        }

        do {
            let contents = try fileManager.contentsOfDirectory(atPath: path)

            for filename in contents where filename.hasSuffix(".md") {
                let filePath = (path as NSString).appendingPathComponent(filename)
                if let command = parseCommandFile(at: filePath) {
                    commands.append(command)
                }
            }
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.error = "Failed to read commands: \(error.localizedDescription)"
            }
        }

        return commands
    }

    private func parseCommandFile(at path: String) -> SlashCommand? {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }

        let filename = (path as NSString).lastPathComponent
        let name = (filename as NSString).deletingPathExtension

        // Parse frontmatter
        var description: String?
        var allowedTools: String?
        var argumentHint: String?
        var prompt = content

        if content.hasPrefix("---") {
            let parts = content.components(separatedBy: "---")
            if parts.count >= 3 {
                let frontmatter = parts[1]
                prompt = parts.dropFirst(2).joined(separator: "---").trimmingCharacters(in: .whitespacesAndNewlines)

                // Parse YAML-like frontmatter
                for line in frontmatter.components(separatedBy: .newlines) {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("description:") {
                        description = trimmed.replacingOccurrences(of: "description:", with: "").trimmingCharacters(in: .whitespaces)
                    } else if trimmed.hasPrefix("allowed-tools:") {
                        allowedTools = trimmed.replacingOccurrences(of: "allowed-tools:", with: "").trimmingCharacters(in: .whitespaces)
                    } else if trimmed.hasPrefix("argument-hint:") {
                        argumentHint = trimmed.replacingOccurrences(of: "argument-hint:", with: "").trimmingCharacters(in: .whitespaces)
                    }
                }
            }
        }

        return SlashCommand(
            name: name,
            description: description,
            allowedTools: allowedTools,
            argumentHint: argumentHint,
            prompt: prompt,
            filePath: path
        )
    }

    // MARK: - Creating Commands

    func createCommand(name: String, description: String?, prompt: String, allowedTools: String?) {
        let commandsPath = SettingsService.claudeCommandsPath
        let filePath = (commandsPath as NSString).appendingPathComponent("\(name).md")

        // Build content
        var content = "---\n"
        if let desc = description {
            content += "description: \(desc)\n"
        }
        if let tools = allowedTools {
            content += "allowed-tools: \(tools)\n"
        }
        content += "---\n\n"
        content += prompt

        do {
            // Ensure directory exists
            try SettingsService.shared.createDirectoryIfNeeded(commandsPath)

            // Write file
            try content.write(toFile: filePath, atomically: true, encoding: .utf8)

            // Reload commands
            reload()
        } catch {
            self.error = "Failed to create command: \(error.localizedDescription)"
        }
    }

    // MARK: - Deleting Commands

    func deleteCommand(_ command: SlashCommand) {
        do {
            try FileManager.default.removeItem(atPath: command.filePath)
            reload()
        } catch {
            self.error = "Failed to delete command: \(error.localizedDescription)"
        }
    }
}
