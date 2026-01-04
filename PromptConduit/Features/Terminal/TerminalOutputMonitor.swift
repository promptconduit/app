import Foundation
import Combine

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
        // Append to buffer
        buffer += text

        // Trim buffer if too large (keep most recent content)
        if buffer.count > maxBufferSize {
            buffer = String(buffer.suffix(maxBufferSize))
        }

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
        let detected = OutputParser.isWaitingForInput(buffer)
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

    // MARK: - Private Methods

    private func debounceStateCheck() {
        debounceTimer?.invalidate()
        debounceTimer = Timer.scheduledTimer(withTimeInterval: debounceInterval, repeats: false) { [weak self] _ in
            self?.checkWaitingState()
        }
    }

    private func updateWaitingState(_ newState: Bool) {
        // Only notify on actual changes
        guard newState != lastNotifiedState else { return }

        lastNotifiedState = newState

        DispatchQueue.main.async { [weak self] in
            self?.isWaiting = newState
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
