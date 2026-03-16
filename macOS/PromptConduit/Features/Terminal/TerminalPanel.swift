import AppKit

/// Custom NSPanel for terminal sessions that intercepts image paste (Cmd+V)
/// When the clipboard contains an image, saves it to temp and inserts the path
/// Otherwise, passes the paste event through to Ghostty normally
class TerminalPanel: NSPanel {
    /// Callback when an image is pasted - receives the formatted path to insert
    var onImagePaste: ((String) -> Void)?

    /// Reference to the terminal view for direct text insertion
    weak var terminalView: GhosttyTerminalView?

    private let imageService = ImageAttachmentService.shared

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown,
           event.modifierFlags.contains(.command) {

            let key = event.charactersIgnoringModifiers?.lowercased()

            // Handle Cmd+C (copy) — Ghostty handles selection natively
            if key == "c" {
                if let terminal = terminalView ?? findTerminalView(in: contentView ?? NSView()) {
                    if let selectedText = terminal.getSelectedText() {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(selectedText, forType: .string)
                        return // Don't pass to terminal
                    }
                }
            }

            // Handle Cmd+V (paste) - check for image
            if key == "v" {
                if imageService.pasteboardContainsImage() {
                    handleImagePaste()
                    return // Don't pass to terminal
                }
            }
        }

        // Pass all other events through normally
        super.sendEvent(event)
    }

    /// Handles pasting an image from the clipboard
    private func handleImagePaste() {
        guard let savedURL = imageService.saveImageFromPasteboard() else {
            NSSound.beep()
            return
        }

        let formattedPath = imageService.formatPathForTerminal(savedURL)
        let textToInsert = " \(formattedPath) "

        if let terminal = terminalView {
            terminal.sendText(textToInsert)
        }

        onImagePaste?(textToInsert)
    }

    /// Finds and stores reference to the terminal view in the view hierarchy
    func findAndStoreTerminalView() {
        guard let contentView = self.contentView else { return }
        if let terminal = findTerminalView(in: contentView) {
            self.terminalView = terminal
        }
    }

    /// Recursively finds GhosttyTerminalView in view hierarchy
    private func findTerminalView(in view: NSView) -> GhosttyTerminalView? {
        if let terminal = view as? GhosttyTerminalView {
            return terminal
        }

        for subview in view.subviews {
            if let found = findTerminalView(in: subview) {
                return found
            }
        }

        return nil
    }
}

// MARK: - TerminalWindow

/// Custom NSWindow for multi-terminal grids that intercepts copy (Cmd+C), image paste (Cmd+V),
/// and broadcast toggle (Cmd+B). Supports broadcast mode for typing to all terminals at once.
class TerminalWindow: NSWindow {
    private let imageService = ImageAttachmentService.shared
    private let terminalManager = TerminalSessionManager.shared

    /// The group ID for broadcast mode. Set this when displaying a multi-terminal grid.
    var groupId: UUID?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            if event.modifierFlags.contains(.command) {
                let key = event.charactersIgnoringModifiers?.lowercased()

                // Handle Cmd+B (broadcast toggle)
                if key == "b" {
                    handleBroadcastToggle()
                    return
                }

                // Handle Cmd+C (copy) — single getSelectedText() call, no workarounds
                if key == "c" {
                    if handleCopy() {
                        return
                    }
                }

                // Handle Cmd+V (paste) - check for image, then check for broadcast
                if key == "v" {
                    if imageService.pasteboardContainsImage() {
                        handleImagePaste()
                        return
                    }
                    if let groupId = groupId, terminalManager.isBroadcastEnabled(for: groupId) {
                        if let text = NSPasteboard.general.string(forType: .string) {
                            terminalManager.broadcastToGroup(groupId, text: text)
                            return
                        }
                    }
                }
            } else {
                // Non-command key - check for broadcast mode
                if let groupId = groupId, terminalManager.isBroadcastEnabled(for: groupId) {
                    terminalManager.broadcastKeyEventToGroup(groupId, event: event)
                    return
                }
            }
        }

        super.sendEvent(event)
    }

    /// Handles Cmd+B to toggle broadcast mode
    private func handleBroadcastToggle() {
        guard let groupId = groupId else {
            NSSound.beep()
            return
        }
        terminalManager.toggleBroadcast(for: groupId)
    }

    /// Handles copying selected text from the focused terminal.
    /// Returns true if copy was handled.
    private func handleCopy() -> Bool {
        guard let terminal = findFocusedTerminal() else {
            return false
        }

        if let selectedText = terminal.getSelectedText() {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(selectedText, forType: .string)
            return true
        }

        return false
    }

    /// Handles pasting an image from the clipboard into the focused terminal
    private func handleImagePaste() {
        guard let terminal = findFocusedTerminal() else {
            NSSound.beep()
            return
        }

        guard let savedURL = imageService.saveImageFromPasteboard() else {
            NSSound.beep()
            return
        }

        let formattedPath = imageService.formatPathForTerminal(savedURL)
        let textToInsert = " \(formattedPath) "
        terminal.sendText(textToInsert)
    }

    /// Finds the focused GhosttyTerminalView in the window
    private func findFocusedTerminal() -> GhosttyTerminalView? {
        if let terminal = firstResponder as? GhosttyTerminalView {
            return terminal
        }

        // Check if first responder is inside a terminal view
        if let responderView = firstResponder as? NSView {
            var view: NSView? = responderView
            while let current = view {
                if let terminal = current as? GhosttyTerminalView {
                    return terminal
                }
                view = current.superview
            }
        }

        // Fallback: search content view hierarchy
        if let contentView = self.contentView {
            return findTerminalInHierarchy(contentView)
        }

        return nil
    }

    /// Recursively finds a GhosttyTerminalView in the hierarchy
    private func findTerminalInHierarchy(_ view: NSView) -> GhosttyTerminalView? {
        if let terminal = view as? GhosttyTerminalView {
            return terminal
        }

        for subview in view.subviews {
            if let found = findTerminalInHierarchy(subview) {
                return found
            }
        }

        return nil
    }
}

// MARK: - TerminalPanelDelegate

/// Delegate for TerminalPanel to handle close events
class TerminalPanelDelegate: NSObject, NSWindowDelegate {
    private let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
        super.init()
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if let panel = notification.object as? TerminalPanel {
            panel.findAndStoreTerminalView()
        }
    }
}
