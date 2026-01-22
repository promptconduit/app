import Foundation

/// Manages Claude Code hook installation for PromptConduit
/// Installs hooks that write events to ~/.promptconduit/hook-events
/// which are then monitored by HookNotificationService
///
/// Hooks are added to ~/.claude/settings.json (the user settings file).
/// We carefully preserve existing settings and only modify the hooks section.
/// Our hooks are marked with "PromptConduit-managed" so we can identify them.
class ClaudeCodeHookManager {
    static let shared = ClaudeCodeHookManager()

    /// Claude settings.json file path (user-level settings)
    /// We preserve existing content and only add/remove our marked hooks
    private let claudeSettingsPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude")
        .appendingPathComponent("settings.json")

    /// Hook events file path (where hooks write events)
    private let hookEventsPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".promptconduit")
        .appendingPathComponent("hook-events")

    /// Marker comment to identify PromptConduit hooks
    private let hookMarker = "PromptConduit-managed"

    /// Hook event names we manage
    private let managedHookEvents = ["SessionStart", "UserPromptSubmit", "Stop"]

    private init() {}

    // MARK: - Public Interface

    /// Check if hooks are currently installed
    func areHooksInstalled() -> Bool {
        guard let settings = readClaudeSettings() else { return false }
        guard let hooks = settings["hooks"] as? [String: Any] else { return false }

        // Check if all managed hooks exist with our marker
        for event in managedHookEvents {
            guard let eventHooks = hooks[event] as? [[String: Any]] else { return false }
            let hasOurHook = eventHooks.contains { hook in
                if let command = hook["command"] as? String {
                    return command.contains(hookMarker)
                }
                return false
            }
            if !hasOurHook { return false }
        }

        return true
    }

    /// Install hooks that write events to the hook-events file
    func installHooks() -> Result<Void, ClaudeHookError> {
        // Ensure directories exist
        let promptConduitDir = hookEventsPath.deletingLastPathComponent()
        let claudeDir = claudeSettingsPath.deletingLastPathComponent()

        do {
            try FileManager.default.createDirectory(at: promptConduitDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        } catch {
            return .failure(.fileSystemError("Failed to create directories: \(error.localizedDescription)"))
        }

        // Create hook-events file if needed
        if !FileManager.default.fileExists(atPath: hookEventsPath.path) {
            FileManager.default.createFile(atPath: hookEventsPath.path, contents: nil)
        }

        // Read existing settings or create new
        var settings = readClaudeSettings() ?? [:]
        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        // Add our hooks for each event
        for event in managedHookEvents {
            var eventHooks = hooks[event] as? [[String: Any]] ?? []

            // Remove any existing PromptConduit hooks (to update)
            eventHooks.removeAll { hook in
                if let command = hook["command"] as? String {
                    return command.contains(hookMarker)
                }
                return false
            }

            // Add our hook - a simple shell command that appends JSON to the events file
            let hookCommand = makeHookCommand(for: event)
            let newHook: [String: Any] = [
                "type": "command",
                "command": hookCommand
            ]
            eventHooks.append(newHook)

            hooks[event] = eventHooks
        }

        settings["hooks"] = hooks

        // Write back to file
        return writeClaudeSettings(settings)
    }

    /// Uninstall our hooks (removes only PromptConduit hooks)
    func uninstallHooks() -> Result<Void, ClaudeHookError> {
        guard var settings = readClaudeSettings() else {
            // No settings file, nothing to uninstall
            return .success(())
        }

        guard var hooks = settings["hooks"] as? [String: Any] else {
            // No hooks section, nothing to uninstall
            return .success(())
        }

        // Remove our hooks from each event
        for event in managedHookEvents {
            guard var eventHooks = hooks[event] as? [[String: Any]] else { continue }

            eventHooks.removeAll { hook in
                if let command = hook["command"] as? String {
                    return command.contains(hookMarker)
                }
                return false
            }

            if eventHooks.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = eventHooks
            }
        }

        if hooks.isEmpty {
            settings.removeValue(forKey: "hooks")
        } else {
            settings["hooks"] = hooks
        }

        return writeClaudeSettings(settings)
    }

    /// Get the path to the Claude settings.json file for display
    var settingsFilePath: String {
        claudeSettingsPath.path
    }

    // MARK: - Private Helpers

    /// Make the shell command for a specific hook event
    private func makeHookCommand(for event: String) -> String {
        // The command writes a JSON line to the hook-events file
        // Uses printf to avoid issues with echo on different shells
        // SESSION_ID is provided by Claude Code as an environment variable
        let eventsPath = hookEventsPath.path

        // Include marker in comment for identification
        return """
        /bin/sh -c 'printf "{\\\"event\\\":\\\"\(event)\\\",\\\"cwd\\\":\\\"%s\\\",\\\"session_id\\\":\\\"%s\\\",\\\"timestamp\\\":%d}\\n" "$PWD" "$SESSION_ID" "$(date +%s)" >> "\(eventsPath)"' # \(hookMarker)
        """
    }

    /// Read Claude settings.json
    private func readClaudeSettings() -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: claudeSettingsPath.path) else { return nil }

        do {
            let data = try Data(contentsOf: claudeSettingsPath)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            return json
        } catch {
            print("[ClaudeCodeHookManager] Failed to read settings: \(error)")
            return nil
        }
    }

    /// Write Claude settings.json (preserves existing settings)
    private func writeClaudeSettings(_ settings: [String: Any]) -> Result<Void, ClaudeHookError> {
        do {
            let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: claudeSettingsPath)
            return .success(())
        } catch {
            return .failure(.fileSystemError("Failed to write settings: \(error.localizedDescription)"))
        }
    }
}

// MARK: - Error Type

enum ClaudeHookError: LocalizedError {
    case fileSystemError(String)
    case parseError(String)
    case settingsNotFound

    var errorDescription: String? {
        switch self {
        case .fileSystemError(let message):
            return "File system error: \(message)"
        case .parseError(let message):
            return "Parse error: \(message)"
        case .settingsNotFound:
            return "Claude settings file not found"
        }
    }
}
