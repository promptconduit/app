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
