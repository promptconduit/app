import Foundation
import Combine

/// Log helper for TerminalOutputMonitor debugging
private func monitorLog(_ message: String) {
    let logPath = "/tmp/promptconduit-terminal.log"
    let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
    let line = "[Monitor \(timestamp)] \(message)\n"

    if let handle = FileHandle(forWritingAtPath: logPath) {
        handle.seekToEndOfFile()
        if let data = line.data(using: .utf8) {
            handle.write(data)
        }
        handle.closeFile()
    }
    print("[Monitor] \(message)")
}

/// Monitors terminal output to detect when Claude is waiting for user input
class TerminalOutputMonitor: ObservableObject {
    /// Current waiting state
    @Published private(set) var isWaiting: Bool = false

    /// Callback when waiting state changes
    var onWaitingStateChanged: ((Bool) -> Void)?

    /// Buffer to hold recent terminal output for pattern detection
    private var buffer: String = ""
    private let maxBufferSize = 1000

    /// Debounce timer to prevent flickering
    private var debounceTimer: Timer?
    private let debounceInterval: TimeInterval = 0.5

    /// Suppression window to prevent output-based waiting detection after UserPromptSubmit
    private var suppressWaitingUntil: Date?

    /// Suppression window to prevent ALL output-based detection after any hook event
    /// When hooks fire, they take priority over output parsing
    private var suppressAllUntil: Date?

    /// Track the last detected state to avoid redundant notifications
    private var lastNotifiedState: Bool = false

    /// Timer for periodic state checking (fallback for terminals without output streaming)
    private var periodicCheckTimer: Timer?

    // MARK: - Initialization

    init(onWaitingStateChanged: ((Bool) -> Void)? = nil) {
        self.onWaitingStateChanged = onWaitingStateChanged
    }

    deinit {
        stopMonitoring()
    }

    // MARK: - Public Interface

    /// Process new output from the terminal
    /// Call this method whenever new text appears in the terminal
    func processOutput(_ text: String) {
        monitorLog("processOutput called with \(text.count) chars")

        // Append to buffer
        buffer += text

        // Trim buffer if too large (keep most recent content)
        if buffer.count > maxBufferSize {
            buffer = String(buffer.suffix(maxBufferSize))
        }

        monitorLog("Buffer size: \(buffer.count), debouncing state check")
        // Debounce the state check
        debounceStateCheck()
    }

    /// Clear the output buffer and reset state
    func reset() {
        buffer = ""
        isWaiting = false
        lastNotifiedState = false
        debounceTimer?.invalidate()
        debounceTimer = nil
    }

    /// Clear just the output buffer (preserves state)
    /// Called when UserPromptSubmit fires to prevent old patterns from persisting
    func clearBuffer() {
        buffer = ""
        monitorLog("Buffer cleared on UserPromptSubmit")
    }

    /// Start periodic monitoring (for terminals where we can't capture output directly)
    func startPeriodicMonitoring(interval: TimeInterval = 1.0) {
        stopPeriodicMonitoring()
        periodicCheckTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.checkWaitingState()
        }
    }

    /// Stop periodic monitoring
    func stopPeriodicMonitoring() {
        periodicCheckTimer?.invalidate()
        periodicCheckTimer = nil
    }

    /// Stop all monitoring
    func stopMonitoring() {
        debounceTimer?.invalidate()
        debounceTimer = nil
        stopPeriodicMonitoring()
    }

    /// Manually trigger a state check
    func checkWaitingState() {
        monitorLog("checkWaitingState called, buffer tail: '\(String(buffer.suffix(50)).replacingOccurrences(of: "\n", with: "\\n"))'")
        let detected = OutputParser.isWaitingForInput(buffer)
        monitorLog("OutputParser.isWaitingForInput returned: \(detected)")
        updateWaitingState(detected)
    }

    /// Force set the waiting state (useful for external signals)
    func setWaiting(_ waiting: Bool) {
        updateWaitingState(waiting)
    }

    /// Notify that user has provided input (clears waiting state)
    func userProvidedInput() {
        // Clear the buffer of old content since user is now typing
        if buffer.count > 100 {
            buffer = String(buffer.suffix(100))
        }
        updateWaitingState(false)
    }

    /// Suppress output-based waiting detection for a duration
    /// Used after UserPromptSubmit hook to prevent false positives from echoed prompts
    func suppressWaitingDetection(for duration: TimeInterval) {
        suppressWaitingUntil = Date().addingTimeInterval(duration)
        monitorLog("Suppressing waiting detection for \(duration)s until \(suppressWaitingUntil!)")
    }

    /// Suppress ALL output-based state detection for a duration
    /// Used after hook events to ensure hooks take priority over output parsing
    func suppressAllDetection(for duration: TimeInterval) {
        suppressAllUntil = Date().addingTimeInterval(duration)
        monitorLog("Suppressing ALL output detection for \(duration)s until \(suppressAllUntil!)")
    }

    // MARK: - Private Methods

    private func debounceStateCheck() {
        debounceTimer?.invalidate()
        debounceTimer = Timer.scheduledTimer(withTimeInterval: debounceInterval, repeats: false) { [weak self] _ in
            self?.checkWaitingState()
        }
    }

    private func updateWaitingState(_ newState: Bool) {
        monitorLog("updateWaitingState called: newState=\(newState), lastNotifiedState=\(lastNotifiedState)")

        // If within ALL detection suppression window, ignore all output-based state changes
        // This ensures hook events take priority over output parsing
        if let suppressAllUntil = suppressAllUntil, Date() < suppressAllUntil {
            monitorLog("Ignoring output-based state change due to hook suppression window (until \(suppressAllUntil))")
            return
        }

        // If trying to set waiting=true but within waiting suppression window, ignore
        // This prevents false positives from echoed prompts after UserPromptSubmit
        if newState == true, let suppressWaitingUntil = suppressWaitingUntil, Date() < suppressWaitingUntil {
            monitorLog("Ignoring waiting=true due to suppression window (until \(suppressWaitingUntil))")
            return
        }

        // Only notify on actual changes
        guard newState != lastNotifiedState else {
            monitorLog("State unchanged, skipping notification")
            return
        }

        lastNotifiedState = newState
        monitorLog("State CHANGED to \(newState), notifying...")

        DispatchQueue.main.async { [weak self] in
            self?.isWaiting = newState
            monitorLog("Calling onWaitingStateChanged callback with \(newState)")
            self?.onWaitingStateChanged?(newState)
        }
    }
}

// MARK: - Claude-Specific Patterns

extension TerminalOutputMonitor {
    /// Additional Claude-specific waiting patterns
    static let claudeWaitingPatterns: [String] = [
        "❯",                           // Claude's primary prompt
        "❯ ",                          // Prompt with space
        "> ",                          // Generic prompt
        "Continue?",                   // Continue prompt
        "(y/n)",                       // Yes/No prompt
        "Press Enter",                 // Press Enter prompt
        "Waiting for",                 // Generic waiting indicator
        "Do you want to",              // Action confirmation
        "Would you like to",           // Polite confirmation
        "Please confirm",              // Confirmation request
        "[Y/n]",                       // Alternative yes/no
        "[y/N]",                       // Alternative yes/no (default no)
    ]

    /// Check if the buffer ends with any waiting pattern
    func endsWithWaitingPattern() -> Bool {
        let cleanBuffer = OutputParser.stripANSI(buffer)
        let trimmed = cleanBuffer.trimmingCharacters(in: .whitespacesAndNewlines)

        for pattern in Self.claudeWaitingPatterns {
            if trimmed.hasSuffix(pattern) || trimmed.contains(pattern) {
                return true
            }
        }

        return false
    }
}
