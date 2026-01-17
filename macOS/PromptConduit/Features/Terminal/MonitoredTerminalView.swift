import SwiftTerm
import AppKit

/// File-based logger for debugging terminal output capture
private func terminalLog(_ message: String) {
    let logPath = "/tmp/promptconduit-terminal.log"
    let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
    let line = "[\(timestamp)] \(message)\n"

    // Create file if it doesn't exist
    if !FileManager.default.fileExists(atPath: logPath) {
        FileManager.default.createFile(atPath: logPath, contents: nil)
    }

    // Append to file
    if let handle = FileHandle(forWritingAtPath: logPath) {
        handle.seekToEndOfFile()
        if let data = line.data(using: .utf8) {
            handle.write(data)
        }
        handle.closeFile()
    }

    // Also print to console
    print("[TerminalDebug] \(message)")
}

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

    // MARK: - Selection Preservation

    /// Whether user is actively selecting text (mouse is down)
    private var isSelecting = false

    /// Buffer for data received while user is selecting
    private var selectionPendingData: [ArraySlice<UInt8>] = []

    /// Timer to flush pending data after selection timeout
    private var selectionFlushTimer: Timer?

    /// Maximum time to buffer data while selecting (seconds)
    private let selectionTimeout: TimeInterval = 2.0

    /// Event monitors for tracking mouse state
    private var mouseDownMonitor: Any?
    private var mouseUpMonitor: Any?
    private var mouseDragMonitor: Any?

    override init(frame: CGRect) {
        super.init(frame: frame)
        terminalLog("INIT - Terminal view created (frame)")
        setupContextMenu()
        setupMouseMonitors()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        terminalLog("INIT - Terminal view created (coder)")
        setupContextMenu()
        setupMouseMonitors()
    }

    deinit {
        removeMouseMonitors()
        selectionFlushTimer?.invalidate()
    }

    // MARK: - Mouse Event Monitoring

    /// Sets up event monitors to track mouse state for selection preservation
    private func setupMouseMonitors() {
        // Monitor mouse down events
        mouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.handleMouseDown(event)
            return event
        }

        // Monitor mouse drag events
        mouseDragMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDragged) { [weak self] event in
            self?.handleMouseDragged(event)
            return event
        }

        // Monitor mouse up events
        mouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            self?.handleMouseUp(event)
            return event
        }
    }

    /// Removes event monitors
    private func removeMouseMonitors() {
        if let monitor = mouseDownMonitor {
            NSEvent.removeMonitor(monitor)
            mouseDownMonitor = nil
        }
        if let monitor = mouseUpMonitor {
            NSEvent.removeMonitor(monitor)
            mouseUpMonitor = nil
        }
        if let monitor = mouseDragMonitor {
            NSEvent.removeMonitor(monitor)
            mouseDragMonitor = nil
        }
    }

    /// Checks if the event is within this terminal view
    private func isEventInView(_ event: NSEvent) -> Bool {
        guard let window = self.window, event.window == window else { return false }
        let locationInWindow = event.locationInWindow
        let locationInView = convert(locationInWindow, from: nil)
        return bounds.contains(locationInView)
    }

    private func handleMouseDown(_ event: NSEvent) {
        guard isEventInView(event) else { return }
        isSelecting = true
        startSelectionTimer()
    }

    private func handleMouseDragged(_ event: NSEvent) {
        guard isEventInView(event) else { return }
        if isSelecting {
            resetSelectionTimer()
        }
    }

    private func handleMouseUp(_ event: NSEvent) {
        guard isSelecting else { return }
        // Small delay to allow the selection to finalize before processing pending data
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.endSelection()
        }
    }

    /// Starts a timer to auto-flush pending data if selection takes too long
    private func startSelectionTimer() {
        selectionFlushTimer?.invalidate()
        selectionFlushTimer = Timer.scheduledTimer(withTimeInterval: selectionTimeout, repeats: false) { [weak self] _ in
            self?.endSelection()
        }
    }

    /// Resets the selection timer
    private func resetSelectionTimer() {
        if isSelecting {
            startSelectionTimer()
        }
    }

    /// Ends selection mode and processes any buffered data
    private func endSelection() {
        selectionFlushTimer?.invalidate()
        selectionFlushTimer = nil
        isSelecting = false

        // Process any buffered data
        flushPendingData()
    }

    /// Flushes pending data that was buffered during selection
    private func flushPendingData() {
        guard !selectionPendingData.isEmpty else { return }

        terminalLog("Flushing \(selectionPendingData.count) pending data chunks after selection")

        let dataToProcess = selectionPendingData
        selectionPendingData.removeAll()

        for slice in dataToProcess {
            processReceivedData(slice: slice)
        }
    }

    // MARK: - Context Menu

    /// Sets up the right-click context menu with Copy and Select All options
    private func setupContextMenu() {
        let menu = NSMenu()

        let copyItem = NSMenuItem(title: "Copy", action: #selector(copy(_:)), keyEquivalent: "c")
        copyItem.keyEquivalentModifierMask = .command
        menu.addItem(copyItem)

        let selectAllItem = NSMenuItem(title: "Select All", action: #selector(selectAll(_:)), keyEquivalent: "a")
        selectAllItem.keyEquivalentModifierMask = .command
        menu.addItem(selectAllItem)

        self.menu = menu
    }

    // MARK: - Copy & Selection Support

    /// Copies the selected terminal text to the clipboard
    @objc override func copy(_ sender: Any?) {
        guard let selectedText = getSelection(), !selectedText.isEmpty else {
            NSSound.beep()
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(selectedText, forType: .string)
        terminalLog("Copied \(selectedText.count) characters to clipboard")
    }

    /// Validates menu items - enables Copy only when there's a selection
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) {
            if let selectedText = getSelection() {
                return !selectedText.isEmpty
            }
            return false
        }
        return super.validateUserInterfaceItem(item)
    }

    /// Handle keyboard shortcuts for copy (Cmd+C)
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Handle Cmd+C for copy
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "c" {
            copy(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        terminalLog("dataReceived called with \(slice.count) bytes, isSelecting: \(isSelecting)")

        // If user is selecting text, buffer the data to prevent selection from being cleared
        if isSelecting {
            terminalLog("Buffering data while user is selecting")
            selectionPendingData.append(slice)
            return
        }

        processReceivedData(slice: slice)
    }

    /// Processes received data (either immediately or after buffering during selection)
    private func processReceivedData(slice: ArraySlice<UInt8>) {
        // Call parent to feed data to terminal
        super.dataReceived(slice: slice)

        // Convert to string and notify
        if let text = String(bytes: slice, encoding: .utf8) {
            terminalLog("Converted to text: \(text.prefix(50).replacingOccurrences(of: "\n", with: "\\n"))...")

            // Update buffer
            outputBuffer += text
            if outputBuffer.count > maxBufferSize {
                outputBuffer = String(outputBuffer.suffix(maxBufferSize))
            }

            // Debug: Log output received
            let cleanText = stripANSI(text)
            if !cleanText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                terminalLog("Output received (\(text.count) bytes): \(cleanText.prefix(100))...")
            }

            // Check for Claude ready state
            if !isClaudeReady {
                checkClaudeReady()
            }

            // Notify callback
            terminalLog("Calling onDataReceived callback: \(onDataReceived != nil)")
            onDataReceived?(text)
        } else {
            terminalLog("Failed to convert bytes to UTF-8 string")
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
