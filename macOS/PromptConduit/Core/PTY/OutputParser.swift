import Foundation

/// Log helper for OutputParser debugging
private func parserLog(_ message: String) {
    let logPath = "/tmp/promptconduit-terminal.log"
    let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
    let line = "[Parser \(timestamp)] \(message)\n"

    if let handle = FileHandle(forWritingAtPath: logPath) {
        handle.seekToEndOfFile()
        if let data = line.data(using: .utf8) {
            handle.write(data)
        }
        handle.closeFile()
    }
}

/// Parses and processes Claude CLI output
class OutputParser {
    // Multiple ANSI escape patterns to catch all variations
    private static let ansiPatterns: [NSRegularExpression] = {
        let patterns = [
            // Standard ANSI escape sequences (ESC [ ... m)
            "\\x1B\\[[0-9;]*m",
            // ANSI cursor and screen control
            "\\x1B\\[[0-9;]*[A-Za-z]",
            // More general ANSI pattern
            "\\x1B(?:[@-Z\\\\-_]|\\[[0-?]*[ -/]*[@-~])",
            // OSC sequences (title bar, etc)
            "\\x1B\\][^\\x07\\x1B]*(?:\\x07|\\x1B\\\\)",
            // Catch sequences that lost ESC prefix (common in some terminals)
            "\\[\\?[0-9;]*[a-z]",
            "\\[[0-9;]+m",
            // DEC special sequences
            "\\x1B[78]",
            "\\x1B\\([AB0-2]",
            // RGB color codes that may leak through (38;2;R;G;Bm format)
            "[0-9]+;[0-9]+;[0-9]+;[0-9]+;[0-9]+m",
            // Partial SGR sequences
            "[0-9;]+m",
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0, options: []) }
    }()

    // MARK: - ANSI Stripping

    /// Removes ANSI escape codes from text
    static func stripANSI(_ text: String) -> String {
        var result = text

        // Apply all patterns
        for pattern in ansiPatterns {
            let range = NSRange(result.startIndex..., in: result)
            result = pattern.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: ""
            )
        }

        // Also remove common control characters
        result = result.replacingOccurrences(of: "\u{1B}", with: "") // ESC
        result = result.replacingOccurrences(of: "\u{9B}", with: "") // CSI

        // Remove any remaining bracket sequences that look like ANSI codes
        if let bracketPattern = try? NSRegularExpression(pattern: "\\[[0-9;?]*[a-zA-Z]", options: []) {
            let range = NSRange(result.startIndex..., in: result)
            result = bracketPattern.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: ""
            )
        }

        return result
    }

    // MARK: - Pattern Detection

    /// Detects if the output indicates Claude is waiting for input
    /// For Claude Code TUI, patterns may appear anywhere in the buffer, not just at the end
    static func isWaitingForInput(_ text: String) -> Bool {
        let cleanText = stripANSI(text).trimmingCharacters(in: .whitespacesAndNewlines)

        // Debug: Log what we're checking
        parserLog("isWaitingForInput - cleanText length: \(cleanText.count)")

        // Check last 500 chars for Claude Code TUI patterns
        let recentText = String(cleanText.suffix(500))
        parserLog("isWaitingForInput - recentText (500 chars): '\(recentText.replacingOccurrences(of: "\n", with: "\\n").prefix(150))...'")

        // First check for "busy" indicators - Claude is NOT waiting if these are present
        let busyPatterns = [
            "Thinking...",
            "Loading...",
            "Schlepping",     // Claude's quirky loading message
            "· Reading",      // Tool in progress
            "· Writing",      // Tool in progress
            "· Editing",      // Tool in progress
            "⏳",             // Loading spinner
            // Tool/MCP execution indicators
            "⎿",              // Tool result box (closing)
            "├",              // Tool result box (middle)
            "╭",              // Tool result box (top corner)
            "╰",              // Tool result box (bottom corner)
            "Calling",        // MCP tool calls
            "mcp__",          // MCP tool prefix in output
            "Running:",       // Running command indicator
            "Executing",      // Execution indicator
            "· Bash",         // Bash tool in progress
            "· Glob",         // Glob tool in progress
            "· Grep",         // Grep tool in progress
            "· Task",         // Task tool in progress
        ]

        for pattern in busyPatterns {
            if recentText.contains(pattern) {
                parserLog("DETECTED busy pattern: '\(pattern)' - NOT waiting")
                return false
            }
        }

        // Get the last few lines for stricter pattern matching
        // This prevents old prompt patterns from triggering false "waiting" detection
        let lines = recentText.components(separatedBy: "\n")
        let lastLines = lines.suffix(5).joined(separator: "\n")
        parserLog("isWaitingForInput - checking last 5 lines: '\(lastLines.replacingOccurrences(of: "\n", with: "\\n").prefix(100))...'")

        // Claude Code TUI patterns that indicate ready for input
        // Use regex to be more flexible with whitespace variations
        let emptyPromptRegex = try? NSRegularExpression(pattern: "\\n>\\s*\\n", options: [])
        if let regex = emptyPromptRegex {
            let range = NSRange(lastLines.startIndex..., in: lastLines)
            if regex.firstMatch(in: lastLines, options: [], range: range) != nil {
                parserLog("DETECTED empty prompt line with regex - WAITING for input")
                return true
            }
        }

        // Check for specific ready patterns - ONLY in the last few lines
        let readyPatterns = [
            "> Try \"",        // Claude's suggestion prompt
            "❯ ",              // Claude's terminal prompt
            "❯",               // Claude's terminal prompt (no space)
        ]

        for pattern in readyPatterns {
            if lastLines.contains(pattern) {
                parserLog("DETECTED ready pattern: '\(pattern)' in last lines - WAITING for input")
                return true
            }
        }

        // Claude Code TUI welcome/idle screen patterns
        // These indicate Claude is on the welcome screen waiting for input
        let welcomeScreenPatterns = [
            "(shift+tab to cycle)",    // Status bar navigation hint
            "shift+tab to cycle",      // Without parentheses
            "/status for info",        // Help hint in status area
            "Tips:",                   // Tips section on welcome screen
            "What can I help",         // Welcome message
            "to get started",          // Welcome message continuation
        ]

        for pattern in welcomeScreenPatterns {
            if recentText.contains(pattern) {
                parserLog("DETECTED welcome screen pattern: '\(pattern)' - WAITING for input")
                return true
            }
        }

        // Interactive prompts that indicate waiting - check in last lines
        let interactivePatterns = [
            "Continue?",       // Continue prompt
            "(y/n)",           // Yes/No prompt
            "(Y/n)",           // Default yes
            "(y/N)",           // Default no
            "[Y/n]",           // Bracket style
            "[y/N]",           // Bracket style
            "Press Enter",     // Enter prompt
            "Do you want",     // Confirmation
            "Would you like",  // Confirmation
            "confirm",         // Confirmation requests
        ]

        for pattern in interactivePatterns {
            if lastLines.contains(pattern) {
                parserLog("DETECTED interactive pattern: '\(pattern)' in last lines - WAITING for input")
                return true
            }
        }

        parserLog("No pattern matched, returning false")
        return false
    }

    /// Detects tool usage in output
    static func detectToolUse(_ text: String) -> ToolUse? {
        let cleanText = stripANSI(text)

        // Common tool patterns in Claude output
        if cleanText.contains("[Tool:") {
            // Extract tool name and target
            let pattern = "\\[Tool:\\s*(\\w+)\\]\\s*(.+)"
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: cleanText, range: NSRange(cleanText.startIndex..., in: cleanText)),
               let toolRange = Range(match.range(at: 1), in: cleanText),
               let targetRange = Range(match.range(at: 2), in: cleanText) {
                return ToolUse(
                    name: String(cleanText[toolRange]),
                    target: String(cleanText[targetRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
        }

        // Alternative detection for Read, Edit, Write, Bash tools
        let toolPatterns: [(String, String)] = [
            ("Read", "Reading file:"),
            ("Edit", "Editing file:"),
            ("Write", "Writing file:"),
            ("Bash", "Running command:"),
            ("Glob", "Searching for:"),
            ("Grep", "Searching in:"),
        ]

        for (tool, prefix) in toolPatterns {
            if cleanText.contains(prefix) {
                if let range = cleanText.range(of: prefix) {
                    let target = String(cleanText[range.upperBound...])
                        .components(separatedBy: .newlines)
                        .first ?? ""
                    return ToolUse(name: tool, target: target.trimmingCharacters(in: .whitespaces))
                }
            }
        }

        return nil
    }

    /// Detects if Claude has completed its response
    static func isComplete(_ text: String) -> Bool {
        let cleanText = stripANSI(text)
        // Look for end-of-response indicators
        return cleanText.hasSuffix("❯ ") || cleanText.contains("Task completed")
    }

    /// Parses the output into structured blocks
    static func parseBlocks(_ text: String) -> [OutputBlock] {
        let cleanText = stripANSI(text)
        var blocks: [OutputBlock] = []
        var currentBlock = ""
        var currentType: OutputBlock.BlockType = .text

        for line in cleanText.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Detect block type changes
            if trimmed.hasPrefix("```") {
                if currentType == .code {
                    // End of code block
                    blocks.append(OutputBlock(type: .code, content: currentBlock))
                    currentBlock = ""
                    currentType = .text
                } else {
                    // Start of code block
                    if !currentBlock.isEmpty {
                        blocks.append(OutputBlock(type: currentType, content: currentBlock))
                    }
                    currentBlock = ""
                    currentType = .code
                }
            } else if trimmed.hasPrefix("[Tool:") {
                // Tool block
                if !currentBlock.isEmpty {
                    blocks.append(OutputBlock(type: currentType, content: currentBlock))
                }
                blocks.append(OutputBlock(type: .tool, content: trimmed))
                currentBlock = ""
                currentType = .text
            } else {
                currentBlock += line + "\n"
            }
        }

        // Add remaining content
        if !currentBlock.isEmpty {
            blocks.append(OutputBlock(type: currentType, content: currentBlock.trimmingCharacters(in: .newlines)))
        }

        return blocks
    }
}

// MARK: - Claude State Detection

/// Represents the detected state of Claude Code CLI
enum ClaudeState {
    case waiting   // Ready for input (prompt visible, not processing)
    case running   // Processing (busy patterns visible)
    case unknown   // Can't determine state

    var isWaiting: Bool { self == .waiting }
    var isRunning: Bool { self == .running }
}

extension OutputParser {
    /// Detects the current state of Claude from terminal output
    /// This provides a more nuanced view than the binary isWaitingForInput
    static func detectState(_ text: String) -> ClaudeState {
        let cleanText = stripANSI(text).trimmingCharacters(in: .whitespacesAndNewlines)

        // Need some content to make a determination
        guard cleanText.count > 10 else { return .unknown }

        // Check last 500 chars for patterns
        let recentText = String(cleanText.suffix(500))
        let lines = recentText.components(separatedBy: "\n")
        let lastLines = lines.suffix(5).joined(separator: "\n")

        // Check for "busy" indicators first - these mean Claude is running
        // Use specific prefixes to avoid false matches with normal text
        let busyPatterns = [
            "Thinking...",
            "Loading...",
            "Schlepping",        // Claude's quirky loading message
            "· Reading",         // Tool in progress
            "· Writing",         // Tool in progress
            "· Editing",         // Tool in progress
            "· Bash",            // Bash tool in progress
            "· Glob",            // Glob tool in progress
            "· Grep",            // Grep tool in progress
            "· Task",            // Task tool in progress
            "⏳",                // Loading spinner
            "⎿",                 // Tool result box (closing)
            "├",                 // Tool result box (middle)
            "╭",                 // Tool result box (top corner)
            "╰",                 // Tool result box (bottom corner)
            "Calling",           // MCP tool calls
            "mcp__",             // MCP tool prefix in output
            "Running:",          // Running command indicator
            "Executing",         // Execution indicator
        ]

        for pattern in busyPatterns {
            if recentText.contains(pattern) {
                parserLog("detectState: RUNNING (found busy pattern '\(pattern)')")
                return .running
            }
        }

        // Check for waiting patterns in last few lines
        let waitingPatterns = [
            "> Try \"",
            "Continue?",
            "(y/n)",
            "(Y/n)",
            "(y/N)",
            "[Y/n]",
            "[y/N]",
            "Press Enter",
            "Do you want",
            "Would you like",
            "confirm",
        ]

        for pattern in waitingPatterns {
            if lastLines.contains(pattern) {
                parserLog("detectState: WAITING (found pattern '\(pattern)')")
                return .waiting
            }
        }

        // Claude Code TUI welcome/idle screen patterns
        let welcomeScreenPatterns = [
            "(shift+tab to cycle)",
            "shift+tab to cycle",
            "/status for info",
            "Tips:",
            "What can I help",
            "to get started",
        ]

        for pattern in welcomeScreenPatterns {
            if recentText.contains(pattern) {
                parserLog("detectState: WAITING (found welcome screen pattern '\(pattern)')")
                return .waiting
            }
        }

        // If we see the empty prompt line pattern, it's waiting
        let emptyPromptRegex = try? NSRegularExpression(pattern: "\\n>\\s*\\n", options: [])
        if let regex = emptyPromptRegex {
            let range = NSRange(lastLines.startIndex..., in: lastLines)
            if regex.firstMatch(in: lastLines, options: [], range: range) != nil {
                parserLog("detectState: WAITING (found empty prompt line)")
                return .waiting
            }
        }

        parserLog("detectState: UNKNOWN (no definitive pattern matched)")
        return .unknown
    }
}

// MARK: - Supporting Types

struct ToolUse {
    let name: String
    let target: String
}

struct OutputBlock: Identifiable {
    let id = UUID()
    let type: BlockType
    let content: String

    enum BlockType {
        case text
        case code
        case tool
    }
}
