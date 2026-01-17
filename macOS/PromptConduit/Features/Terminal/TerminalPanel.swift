import AppKit
import SwiftTerm

/// Custom NSPanel for terminal sessions that intercepts image paste (Cmd+V)
/// When the clipboard contains an image, saves it to temp and inserts the path
/// Otherwise, passes the paste event through to SwiftTerm normally
class TerminalPanel: NSPanel {
    /// Callback when an image is pasted - receives the formatted path to insert
    var onImagePaste: ((String) -> Void)?

    /// Reference to the terminal view for direct text insertion
    weak var terminalView: LocalProcessTerminalView?

    private let imageService = ImageAttachmentService.shared

    override func sendEvent(_ event: NSEvent) {
        // Check for Cmd+C (copy)
        if event.type == .keyDown,
           event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "c" {
            handleCopy()
            return // Don't pass to terminal (we handled it)
        }

        // Check for Cmd+V (paste)
        if event.type == .keyDown,
           event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "v" {

            // Check if pasteboard contains an image
            if imageService.pasteboardContainsImage() {
                handleImagePaste()
                return // Don't pass to terminal
            }
        }

        // Pass all other events through normally
        super.sendEvent(event)
    }

    /// Handles copying selected text from the terminal
    private func handleCopy() {
        guard let terminal = terminalView else {
            // Try to find terminal view if not cached
            findAndStoreTerminalView()
            guard let terminal = terminalView else {
                NSSound.beep()
                return
            }
            performCopy(from: terminal)
            return
        }
        performCopy(from: terminal)
    }

    /// Performs the actual copy operation
    private func performCopy(from terminal: LocalProcessTerminalView) {
        guard let selectedText = terminal.getSelection(), !selectedText.isEmpty else {
            NSSound.beep()
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(selectedText, forType: .string)
    }

    /// Handles pasting an image from the clipboard
    private func handleImagePaste() {
        // Save image from pasteboard
        guard let savedURL = imageService.saveImageFromPasteboard() else {
            // No image found, play error sound
            NSSound.beep()
            return
        }

        // Format path for terminal
        let formattedPath = imageService.formatPathForTerminal(savedURL)
        let textToInsert = " \(formattedPath) "

        // Insert directly into terminal if available
        if let terminal = terminalView {
            terminal.send(txt: textToInsert)
        }

        // Also notify via callback
        onImagePaste?(textToInsert)
    }

    /// Finds and stores reference to the terminal view in the view hierarchy
    func findAndStoreTerminalView() {
        guard let contentView = self.contentView else { return }
        if let terminal = findTerminalView(in: contentView) {
            self.terminalView = terminal
        }
    }

    /// Recursively finds LocalProcessTerminalView in view hierarchy
    private func findTerminalView(in view: NSView) -> LocalProcessTerminalView? {
        if let terminal = view as? LocalProcessTerminalView {
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

/// Custom NSWindow for multi-terminal grids that intercepts copy (Cmd+C) and image paste (Cmd+V)
/// Similar to TerminalPanel but for regular windows with multiple terminals
class TerminalWindow: NSWindow {
    private let imageService = ImageAttachmentService.shared

    override func sendEvent(_ event: NSEvent) {
        // Check for Cmd+C (copy)
        if event.type == .keyDown,
           event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "c" {
            if handleCopy() {
                return // Don't pass to terminal (we handled it)
            }
        }

        // Check for Cmd+V (paste)
        if event.type == .keyDown,
           event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "v" {

            // Check if pasteboard contains an image
            if imageService.pasteboardContainsImage() {
                handleImagePaste()
                return // Don't pass to terminal
            }
        }

        // Pass all other events through normally
        super.sendEvent(event)
    }

    /// Handles copying selected text from the focused terminal
    /// Returns true if copy was handled, false otherwise
    private func handleCopy() -> Bool {
        // Find the focused terminal view (first responder in hierarchy)
        guard let terminal = findFocusedTerminal() else {
            NSSound.beep()
            return false
        }

        guard let selectedText = terminal.getSelection(), !selectedText.isEmpty else {
            NSSound.beep()
            return false
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(selectedText, forType: .string)
        return true
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
        terminal.send(txt: textToInsert)
    }

    /// Finds the focused LocalProcessTerminalView in the window
    /// Checks first responder and its hierarchy
    private func findFocusedTerminal() -> LocalProcessTerminalView? {
        // Check if first responder is a terminal
        if let terminal = firstResponder as? LocalProcessTerminalView {
            return terminal
        }

        // Check if first responder is inside a terminal view
        if let responderView = firstResponder as? NSView {
            var view: NSView? = responderView
            while let current = view {
                if let terminal = current as? LocalProcessTerminalView {
                    return terminal
                }
                view = current.superview
            }
        }

        // Fallback: search content view hierarchy for any terminal with selection
        if let contentView = self.contentView {
            return findTerminalWithSelection(in: contentView)
        }

        return nil
    }

    /// Recursively finds a LocalProcessTerminalView that has a selection
    private func findTerminalWithSelection(in view: NSView) -> LocalProcessTerminalView? {
        if let terminal = view as? LocalProcessTerminalView,
           let selection = terminal.getSelection(),
           !selection.isEmpty {
            return terminal
        }

        for subview in view.subviews {
            if let found = findTerminalWithSelection(in: subview) {
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
        // When panel becomes key, find and store terminal view reference
        if let panel = notification.object as? TerminalPanel {
            panel.findAndStoreTerminalView()
        }
    }
}
