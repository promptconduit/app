import Foundation

/// Parses and processes Claude CLI output
class OutputParser {
    // ANSI escape code pattern
    private static let ansiPattern = try! NSRegularExpression(
        pattern: "\\x1B(?:[@-Z\\\\-_]|\\[[0-?]*[ -/]*[@-~])",
        options: []
    )

    // MARK: - ANSI Stripping

    /// Removes ANSI escape codes from text
    static func stripANSI(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return ansiPattern.stringByReplacingMatches(
            in: text,
            options: [],
            range: range,
            withTemplate: ""
        )
    }

    // MARK: - Pattern Detection

    /// Detects if the output indicates Claude is waiting for input
    static func isWaitingForInput(_ text: String) -> Bool {
        let cleanText = stripANSI(text)
        let patterns = [
            "❯",           // Prompt indicator
            "> ",          // Simple prompt
            "Continue?",   // Continue prompt
            "(y/n)",       // Yes/No prompt
        ]
        return patterns.contains { cleanText.contains($0) }
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
