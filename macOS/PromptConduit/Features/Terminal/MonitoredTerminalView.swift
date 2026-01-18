import SwiftTerm
import AppKit
import QuartzCore

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

    // MARK: - Selection State

    /// Whether user is actively selecting text (mouse is down)
    private var isSelecting = false

    /// Buffer for data received while user is selecting
    private var selectionPendingData: [ArraySlice<UInt8>] = []

    /// Timer to flush pending data after selection timeout
    private var selectionFlushTimer: Timer?

    /// Maximum time to buffer data while selecting (seconds)
    private let selectionTimeout: TimeInterval = 2.0

    // MARK: - Custom Selection Tracking (workaround for SwiftTerm bugs)

    /// Start position of our tracked selection (in terminal coordinates)
    private(set) var trackedSelectionStart: Position?

    /// End position of our tracked selection (in terminal coordinates)
    private(set) var trackedSelectionEnd: Position?

    /// Returns the text from our tracked selection coordinates
    /// This works around SwiftTerm's buggy getSelection() that returns empty
    func getTrackedSelectionText() -> String? {
        guard let start = trackedSelectionStart, let end = trackedSelectionEnd else {
            return nil
        }

        let terminal = getTerminal()
        let (minPos, maxPos) = orderPositions(start, end)

        terminalLog("DEBUG getTrackedSelectionText - (\(minPos.col), \(minPos.row)) to (\(maxPos.col), \(maxPos.row))")

        let text = terminal.getText(start: minPos, end: maxPos)
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)

        return trimmedText.isEmpty ? nil : trimmedText
    }

    /// Clears the tracked selection
    func clearTrackedSelection() {
        trackedSelectionStart = nil
        trackedSelectionEnd = nil
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        terminalLog("INIT - Terminal view created (frame)")
        setupContextMenu()
        setupMouseMonitoring()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        terminalLog("INIT - Terminal view created (coder)")
        setupContextMenu()
        setupMouseMonitoring()
    }

    deinit {
        selectionFlushTimer?.invalidate()
        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    // MARK: - Mouse Event Handling (Custom Selection)

    /// Local event monitor for mouse events (needed because SwiftTerm's mouseUp/draw aren't open)
    private var mouseMonitor: Any?

    /// Selection highlight layer
    private var selectionLayer: CALayer?

    /// Setup mouse monitoring for custom selection tracking
    private func setupMouseMonitoring() {
        // Setup layer-backed view for custom selection drawing
        wantsLayer = true

        // Create selection highlight layer
        let layer = CALayer()
        layer.backgroundColor = NSColor.selectedTextBackgroundColor.withAlphaComponent(0.4).cgColor
        layer.isHidden = true
        self.layer?.addSublayer(layer)
        selectionLayer = layer

        // Monitor mouse events locally
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self = self else { return event }
            guard let window = self.window, event.window == window else { return event }

            let locationInWindow = event.locationInWindow
            let locationInView = self.convert(locationInWindow, from: nil)

            // Only handle if click is within our bounds
            guard self.bounds.contains(locationInView) else { return event }

            switch event.type {
            case .leftMouseDown:
                self.handleCustomMouseDown(locationInView: locationInView, event: event)
            case .leftMouseDragged:
                self.handleCustomMouseDragged(locationInView: locationInView)
            case .leftMouseUp:
                self.handleCustomMouseUp(locationInView: locationInView)
            default:
                break
            }

            return event
        }
    }

    /// Handle mouse down for custom selection
    private func handleCustomMouseDown(locationInView: CGPoint, event: NSEvent) {
        terminalLog("DEBUG handleCustomMouseDown - clickCount: \(event.clickCount)")
        terminalLog("DEBUG handleCustomMouseDown - frame: \(frame), bounds: \(bounds)")
        terminalLog("DEBUG handleCustomMouseDown - terminal cols: \(getTerminal().cols), rows: \(getTerminal().rows)")

        // Clear SwiftTerm's selection to prevent its (offset) visual rendering
        selectNone()

        // Track our own selection with correct coordinates
        trackedSelectionStart = convertPointToTerminalPosition(locationInView)
        trackedSelectionEnd = trackedSelectionStart
        isSelecting = true

        terminalLog("DEBUG handleCustomMouseDown - trackedSelectionStart: col=\(trackedSelectionStart?.col ?? -1), row=\(trackedSelectionStart?.row ?? -1)")

        // Update selection layer
        updateSelectionLayer()

        startSelectionTimer()
    }

    /// Handle mouse dragged for custom selection
    private func handleCustomMouseDragged(locationInView: CGPoint) {
        guard isSelecting else { return }

        trackedSelectionEnd = convertPointToTerminalPosition(locationInView)

        terminalLog("DEBUG handleCustomMouseDragged - trackedSelectionEnd: col=\(trackedSelectionEnd?.col ?? -1), row=\(trackedSelectionEnd?.row ?? -1)")

        // Update selection layer
        updateSelectionLayer()

        resetSelectionTimer()
    }

    /// Handle mouse up for custom selection
    private func handleCustomMouseUp(locationInView: CGPoint) {
        terminalLog("DEBUG handleCustomMouseUp - isSelecting: \(isSelecting)")

        if isSelecting {
            trackedSelectionEnd = convertPointToTerminalPosition(locationInView)
            terminalLog("DEBUG handleCustomMouseUp - final trackedSelectionEnd: col=\(trackedSelectionEnd?.col ?? -1), row=\(trackedSelectionEnd?.row ?? -1)")
        }

        // End selection mode after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.endSelection()
        }
    }

    /// Updates the selection highlight layer to show current selection
    private func updateSelectionLayer() {
        guard let start = trackedSelectionStart, let end = trackedSelectionEnd else {
            selectionLayer?.isHidden = true
            return
        }

        // Don't show if start and end are the same (no actual selection)
        if start.col == end.col && start.row == end.row {
            selectionLayer?.isHidden = true
            return
        }

        let terminal = getTerminal()
        let (minPos, maxPos) = orderPositions(start, end)

        // Get cell dimensions from font metrics
        let cellWidth = font.maximumAdvancement.width
        let cellHeight = ceil(font.ascender - font.descender + font.leading)

        // Convert buffer positions back to visible positions
        let visibleStartRow = max(0, minPos.row - terminal.buffer.yDisp)
        let visibleEndRow = max(0, maxPos.row - terminal.buffer.yDisp)

        // For now, draw a single rectangle covering the selection
        // (For multi-row selections, we'd need multiple layers or a custom drawing approach)
        let startCol = minPos.col
        let endCol = maxPos.col

        // Calculate rectangle position
        // Y is flipped: row 0 is at the top of the view
        let x = CGFloat(startCol) * cellWidth
        let topY = bounds.height - CGFloat(visibleStartRow + 1) * cellHeight
        let bottomY = bounds.height - CGFloat(visibleEndRow + 1) * cellHeight
        let width: CGFloat
        let height: CGFloat

        if visibleStartRow == visibleEndRow {
            // Single row selection
            width = CGFloat(endCol - startCol + 1) * cellWidth
            height = cellHeight

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            selectionLayer?.frame = NSRect(x: x, y: topY, width: width, height: height)
            selectionLayer?.isHidden = false
            CATransaction.commit()
        } else {
            // Multi-row selection - draw full width for simplicity
            // For proper multi-row selection, we'd need multiple layers
            let fullWidth = CGFloat(terminal.cols) * cellWidth
            height = topY - bottomY + cellHeight

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            selectionLayer?.frame = NSRect(x: 0, y: bottomY, width: fullWidth, height: height)
            selectionLayer?.isHidden = false
            CATransaction.commit()
        }
    }

    /// Converts a point in view coordinates to terminal grid position
    /// This is our own implementation since SwiftTerm's calculateMouseHit is internal
    private func convertPointToTerminalPosition(_ point: CGPoint) -> Position {
        let terminal = getTerminal()

        // Get cell dimensions from font metrics (same as SwiftTerm uses internally)
        // SwiftTerm uses: ascent + descent + leading for height, and advance width for width
        let fontMetrics = self.font
        let cellHeight = ceil(fontMetrics.ascender - fontMetrics.descender + fontMetrics.leading)
        let cellWidth = fontMetrics.maximumAdvancement.width

        // Convert point to terminal coordinates
        // Note: NSView has origin at bottom-left, so we need to flip Y
        let col = Int(point.x / cellWidth)
        let row = Int((bounds.height - point.y) / cellHeight)

        // Clamp to valid range
        let clampedCol = max(0, min(col, terminal.cols - 1))
        let clampedRow = max(0, min(row, terminal.rows - 1))

        // Add buffer scroll offset for the actual buffer position
        let bufferRow = clampedRow + terminal.buffer.yDisp

        terminalLog("DEBUG convertPointToTerminalPosition - point: \(point), cellSize: \(cellWidth)x\(cellHeight)")
        terminalLog("DEBUG convertPointToTerminalPosition - raw: col=\(col), row=\(row), bufferRow=\(bufferRow)")
        terminalLog("DEBUG convertPointToTerminalPosition - frame: \(frame), bounds: \(bounds)")
        terminalLog("DEBUG convertPointToTerminalPosition - font metrics: ascender=\(fontMetrics.ascender), descender=\(fontMetrics.descender), leading=\(fontMetrics.leading)")

        return Position(col: clampedCol, row: bufferRow)
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

        menu.addItem(NSMenuItem.separator())

        // Test option: Select All & Copy (to verify selectAll works)
        let selectAllCopyItem = NSMenuItem(title: "Select All & Copy", action: #selector(selectAllAndCopy(_:)), keyEquivalent: "")
        selectAllCopyItem.target = self  // Must set target for custom actions
        menu.addItem(selectAllCopyItem)

        self.menu = menu
    }

    // MARK: - Copy & Selection Support

    /// Copies the selected terminal text to the clipboard
    /// Works around SwiftTerm bug where getSelection() returns empty even when selection is active
    @objc override func copy(_ sender: Any?) {
        terminalLog("DEBUG copy() - selectionActive: \(selectionActive)")
        terminalLog("DEBUG copy() - trackedSelectionStart: col=\(trackedSelectionStart?.col ?? -1), row=\(trackedSelectionStart?.row ?? -1)")
        terminalLog("DEBUG copy() - trackedSelectionEnd: col=\(trackedSelectionEnd?.col ?? -1), row=\(trackedSelectionEnd?.row ?? -1)")

        // First try the normal getSelection()
        if let text = getSelection(), !text.isEmpty {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            terminalLog("DEBUG copy() - copied \(text.count) chars via getSelection()")
            return
        }

        // Workaround #1: Use our tracked selection coordinates
        // This works around SwiftTerm's buggy getSelection() that returns empty
        if let start = trackedSelectionStart, let end = trackedSelectionEnd {
            let terminal = getTerminal()

            // Determine min/max positions (selection could be made in either direction)
            let (minPos, maxPos) = orderPositions(start, end)

            terminalLog("DEBUG copy() - using tracked selection: (\(minPos.col), \(minPos.row)) to (\(maxPos.col), \(maxPos.row))")

            let directText = terminal.getText(start: minPos, end: maxPos)
            let trimmedText = directText.trimmingCharacters(in: .whitespacesAndNewlines)

            if !trimmedText.isEmpty {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(trimmedText, forType: .string)
                terminalLog("DEBUG copy() - copied \(trimmedText.count) chars via tracked selection")
                return
            } else {
                terminalLog("DEBUG copy() - tracked selection returned empty text")
            }
        }

        // Workaround #2: Fall back to copying visible terminal content using getText()
        if selectionActive {
            let terminal = getTerminal()
            let startPos = Position(col: 0, row: 0)
            let endPos = Position(col: terminal.cols - 1, row: terminal.rows - 1)
            let directText = terminal.getText(start: startPos, end: endPos)
            let trimmedText = directText.trimmingCharacters(in: .whitespacesAndNewlines)

            if !trimmedText.isEmpty {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(trimmedText, forType: .string)
                terminalLog("DEBUG copy() - copied \(trimmedText.count) chars via getText() workaround (all visible)")
                return
            }
        }

        // Last resort: call parent implementation
        super.copy(sender)
        terminalLog("DEBUG copy() - called super.copy()")
    }

    /// Orders two positions so that minPos comes before maxPos (for text extraction)
    private func orderPositions(_ p1: Position, _ p2: Position) -> (min: Position, max: Position) {
        // Compare by row first, then by column
        if p1.row < p2.row || (p1.row == p2.row && p1.col <= p2.col) {
            return (p1, p2)
        } else {
            return (p2, p1)
        }
    }

    /// Select all text and copy - for testing
    @objc func selectAllAndCopy(_ sender: Any?) {
        let terminal = getTerminal()
        terminalLog("DEBUG selectAllAndCopy - terminal cols: \(terminal.cols), rows: \(terminal.rows)")
        terminalLog("DEBUG selectAllAndCopy - buffer yDisp: \(terminal.buffer.yDisp)")

        terminalLog("DEBUG selectAllAndCopy - before selectAll, selectionActive: \(selectionActive)")
        selectAll()
        terminalLog("DEBUG selectAllAndCopy - after selectAll, selectionActive: \(selectionActive)")

        // Try using getText directly with known coordinates
        let startPos = Position(col: 0, row: 0)
        let endPos = Position(col: terminal.cols - 1, row: terminal.rows - 1)
        let directText = terminal.getText(start: startPos, end: endPos)
        terminalLog("DEBUG selectAllAndCopy - terminal.getText(0,0 to \(terminal.cols-1),\(terminal.rows-1)): '\(directText.prefix(100))...' (length: \(directText.count))")

        let selection = getSelection()
        terminalLog("DEBUG selectAllAndCopy - getSelection(): '\(selection ?? "nil")' (length: \(selection?.count ?? -1))")

        // Use direct getText result if getSelection fails
        let textToCopy = (selection?.isEmpty == false) ? selection! : directText
        let trimmedText = textToCopy.trimmingCharacters(in: .whitespacesAndNewlines)

        if !trimmedText.isEmpty {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(trimmedText, forType: .string)
            terminalLog("DEBUG selectAllAndCopy - copied \(trimmedText.count) chars")
        } else {
            terminalLog("DEBUG selectAllAndCopy - no text to copy")
        }
    }

    /// Validates menu items - enables Copy only when there's a selection
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) {
            terminalLog("DEBUG validateUserInterfaceItem - selectionActive: \(selectionActive)")
            let selection = getSelection()
            terminalLog("DEBUG validateUserInterfaceItem - getSelection(): '\(selection ?? "nil")'")
            // Use selectionActive as the primary check since it's more reliable
            return selectionActive
        }
        // Always enable "Select All & Copy" for testing
        if item.action == #selector(selectAllAndCopy(_:)) {
            terminalLog("DEBUG validateUserInterfaceItem - selectAllAndCopy: always enabled")
            return true
        }
        return super.validateUserInterfaceItem(item)
    }

    // Note: Removed custom performKeyEquivalent override for Cmd+C
    // Let the standard menu system and SwiftTerm handle copy natively

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
