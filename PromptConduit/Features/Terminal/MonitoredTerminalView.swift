import SwiftTerm
import AppKit

/// A LocalProcessTerminalView subclass that captures output for monitoring
/// Used to detect when Claude is ready and when it's waiting for input
class MonitoredTerminalView: LocalProcessTerminalView {
    /// Callback invoked whenever data is received from the process
    var onDataReceived: ((String) -> Void)?

    /// Buffer for detecting Claude ready state
    private var outputBuffer = ""
    private let maxBufferSize = 2000

    /// Whether Claude has shown its prompt (ready for input)
    private(set) var isClaudeReady = false

    /// Callback when Claude becomes ready
    var onClaudeReady: (() -> Void)?

    /// Patterns that indicate Claude is ready for input
    /// Claude Code shows "Try" suggestions when ready for input
    private let readyPatterns = [
        "> Try \"",     // Claude Code suggestion prompt (main indicator it's ready)
        "❯",           // Claude's primary prompt (terminal mode)
        "❯ ",          // Prompt with space
    ]

    override init(frame: CGRect) {
        super.init(frame: frame)
        print("[MonitoredTerminal] INIT - Terminal view created")
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        print("[MonitoredTerminal] INIT (coder) - Terminal view created")
    }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        // Call parent to feed data to terminal
        super.dataReceived(slice: slice)

        // Convert to string and notify
        if let text = String(bytes: slice, encoding: .utf8) {
            // Update buffer
            outputBuffer += text
            if outputBuffer.count > maxBufferSize {
                outputBuffer = String(outputBuffer.suffix(maxBufferSize))
            }

            // Debug: Log output received
            let cleanText = stripANSI(text)
            if !cleanText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                print("[MonitoredTerminal] Output received (\(text.count) bytes): \(cleanText.prefix(100))...")
            }

            // Check for Claude ready state
            if !isClaudeReady {
                checkClaudeReady()
            }

            // Notify callback
            onDataReceived?(text)
        }
    }

    /// Check if Claude has shown its ready prompt
    private func checkClaudeReady() {
        // Strip ANSI codes for pattern matching
        let cleanOutput = stripANSI(outputBuffer)

        // Debug: check the last 200 chars of clean output
        let tail = String(cleanOutput.suffix(200))
        if tail.contains("Try") {
            print("[MonitoredTerminal] FOUND 'Try' in tail: \(tail.prefix(100))")
        }

        for pattern in readyPatterns {
            if cleanOutput.contains(pattern) {
                print("[MonitoredTerminal] Claude ready! Detected pattern: '\(pattern)'")
                isClaudeReady = true
                DispatchQueue.main.async { [weak self] in
                    print("[MonitoredTerminal] Calling onClaudeReady callback")
                    self?.onClaudeReady?()
                }
                break
            }
        }
    }

    /// Strip ANSI escape sequences from text
    private func stripANSI(_ text: String) -> String {
        // Pattern matches ANSI escape sequences
        let pattern = "\\x1B\\[[0-9;]*[A-Za-z]|\\x1B\\][^\\x07]*\\x07"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
    }

    /// Reset the ready state (useful when starting new sessions)
    func resetReadyState() {
        isClaudeReady = false
        outputBuffer = ""
    }
}
