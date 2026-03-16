import AppKit
import QuartzCore

/// An NSView that wraps a single ghostty terminal surface with Metal-accelerated rendering.
/// Replaces SwiftTerm's LocalProcessTerminalView and MonitoredTerminalView.
class GhosttyTerminalView: NSView {

    /// The ghostty surface handle (created when the process is started).
    private(set) var surface: ghostty_surface_t?

    /// File descriptor for the surface's PTY — used for sendText/sendBytes.
    private var ptyFD: Int32 = -1

    /// Retained self pointer passed to ghostty callbacks. Released in deinit.
    private var retainedSelf: Unmanaged<GhosttyTerminalView>?

    /// Callback invoked when terminal output is received (for Claude readiness detection).
    var onDataReceived: ((String) -> Void)?

    /// Callback when Claude is ready for input.
    var onClaudeReady: (() -> Void)?

    /// Callback when the process terminates.
    var onProcessTerminated: (() -> Void)?

    /// Whether Claude has shown its prompt (ready for input).
    private(set) var isClaudeReady = false

    /// Buffer for detecting Claude ready state.
    private var outputBuffer = ""
    private let maxBufferSize = 2000

    /// Patterns indicating Claude is ready for input.
    private let readyPatterns = [
        "Try \"",
        "\u{276F} Try",
        "> Try",
        "\u{276F}",
    ]

    // MARK: - Initialization

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true
        layer?.backgroundColor = NSColor(red: 0.06, green: 0.09, blue: 0.16, alpha: 1.0).cgColor

        // Ensure GhosttyApp is started
        GhosttyApp.shared.start()
    }

    deinit {
        if let surface = surface {
            ghostty_surface_deinit(surface)
        }
        // Release the retained self reference used by ghostty callbacks
        retainedSelf?.release()
    }

    // MARK: - Process Launch

    /// Start a process in the terminal.
    /// - Parameters:
    ///   - shellCommand: Pre-built shell command string to execute via /bin/zsh -l -c.
    ///   - environment: Environment variables as "KEY=VALUE" strings.
    func startProcess(
        shellCommand: String,
        environment: [String]
    ) {
        guard let app = GhosttyApp.shared.app else {
            print("[GhosttyTerminalView] GhosttyApp not initialized")
            return
        }

        // Build the surface configuration
        // Use passRetained so ghostty callbacks can safely reference this view.
        // The matching release happens in deinit.
        let retained = Unmanaged.passRetained(self)
        retainedSelf = retained

        var surfaceConfig = ghostty_surface_config_s()
        surfaceConfig.userdata = retained.toOpaque()

        // Set up the Metal layer for GPU rendering
        let metalLayer = CAMetalLayer()
        metalLayer.contentsScale = window?.backingScaleFactor ?? 2.0
        metalLayer.frame = bounds
        self.layer = metalLayer

        // Set command and environment in surface config
        shellCommand.withCString { cmd in
            surfaceConfig.command = cmd

            // Pass environment variables to the surface
            let cEnvStrings = environment.map { strdup($0) }
            cEnvStrings.withUnsafeBufferPointer { envBuf in
                surfaceConfig.env = envBuf.baseAddress
                surfaceConfig.env_len = UInt32(envBuf.count)

                // Create the surface
                surface = ghostty_surface_new(app, &surfaceConfig)
            }
            // Free the strdup'd strings
            for ptr in cEnvStrings { free(ptr) }
        }

        guard let surface = surface else {
            print("[GhosttyTerminalView] Failed to create surface")
            return
        }

        // Get the PTY file descriptor for writing
        ptyFD = ghostty_surface_pty_fd(surface)

        // Set up output monitoring callback (requires our fork patch)
        let ud = retained.toOpaque()
        ghostty_surface_set_output_callback(surface, { data, len, userdata in
            guard let data = data, let userdata = userdata else { return }
            let view = Unmanaged<GhosttyTerminalView>.fromOpaque(userdata).takeUnretainedValue()

            let buffer = UnsafeBufferPointer(start: data, count: len)
            if let text = String(bytes: buffer, encoding: .utf8) {
                DispatchQueue.main.async {
                    view.handleOutputReceived(text)
                }
            }
        }, ud)

        // Set up termination callback
        ghostty_surface_set_termination_callback(surface, { userdata in
            guard let userdata = userdata else { return }
            let view = Unmanaged<GhosttyTerminalView>.fromOpaque(userdata).takeUnretainedValue()
            DispatchQueue.main.async {
                view.onProcessTerminated?()
            }
        }, ud)

        print("[GhosttyTerminalView] Process started: \(command)")
    }

    // MARK: - Text Input

    /// Send text to the terminal's PTY.
    func sendText(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        sendBytes(Array(data))
    }

    /// Send raw bytes to the terminal's PTY.
    func sendBytes(_ bytes: [UInt8]) {
        guard ptyFD >= 0 else { return }
        bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            _ = write(ptyFD, base, buffer.count)
        }
    }

    // MARK: - Key Forwarding (for broadcast mode)

    /// Forward a key event to this terminal surface.
    /// Used by broadcast mode to send keystrokes to all terminals.
    func forwardKeyEvent(_ event: NSEvent) {
        guard let surface = surface else { return }
        ghostty_surface_key(surface, event)
    }

    // MARK: - Selection

    /// Get the currently selected text, if any.
    func getSelectedText() -> String? {
        guard let surface = surface else { return nil }
        guard let cstr = ghostty_surface_selection(surface) else { return nil }
        let text = String(cString: cstr)
        ghostty_free(cstr)
        return text.isEmpty ? nil : text
    }

    // MARK: - Layout

    override func layout() {
        super.layout()

        guard let surface = surface else { return }

        // Update Metal layer frame
        if let metalLayer = layer as? CAMetalLayer {
            metalLayer.frame = bounds
            metalLayer.drawableSize = CGSize(
                width: bounds.width * (window?.backingScaleFactor ?? 2.0),
                height: bounds.height * (window?.backingScaleFactor ?? 2.0)
            )
        }

        // Notify ghostty of the size change
        ghostty_surface_set_size(
            surface,
            UInt32(bounds.width),
            UInt32(bounds.height),
            UInt32(window?.backingScaleFactor ?? 2)
        )
    }

    // MARK: - First Responder

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        guard let surface = surface else { return super.becomeFirstResponder() }
        ghostty_surface_set_focus(surface, true)
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        guard let surface = surface else { return super.resignFirstResponder() }
        ghostty_surface_set_focus(surface, false)
        return super.resignFirstResponder()
    }

    // MARK: - Mouse & Keyboard Events

    override func keyDown(with event: NSEvent) {
        guard let surface = surface else { return }
        ghostty_surface_key(surface, event)
    }

    override func keyUp(with event: NSEvent) {
        guard let surface = surface else { return }
        ghostty_surface_key(surface, event)
    }

    override func flagsChanged(with event: NSEvent) {
        guard let surface = surface else { return }
        ghostty_surface_key(surface, event)
    }

    override func mouseDown(with event: NSEvent) {
        guard let surface = surface else { return }
        ghostty_surface_mouse_button(surface, event)
    }

    override func mouseUp(with event: NSEvent) {
        guard let surface = surface else { return }
        ghostty_surface_mouse_button(surface, event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let surface = surface else { return }
        ghostty_surface_mouse_pos(surface, event)
    }

    override func mouseMoved(with event: NSEvent) {
        guard let surface = surface else { return }
        ghostty_surface_mouse_pos(surface, event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface = surface else { return }
        ghostty_surface_mouse_scroll(surface, event)
    }

    // MARK: - Output Monitoring

    /// Handles output received from the PTY (via fork patch callback).
    private func handleOutputReceived(_ text: String) {
        // Update buffer
        outputBuffer += text
        if outputBuffer.count > maxBufferSize {
            outputBuffer = String(outputBuffer.suffix(maxBufferSize))
        }

        // Check for Claude ready state
        if !isClaudeReady {
            checkClaudeReady()
        }

        // Notify callback
        onDataReceived?(text)
    }

    /// Check if Claude has shown its ready prompt.
    private func checkClaudeReady() {
        let cleanOutput = stripANSI(outputBuffer)

        for pattern in readyPatterns {
            if cleanOutput.contains(pattern) {
                isClaudeReady = true
                onClaudeReady?()
                break
            }
        }
    }

    /// Cached regex for stripping ANSI escape sequences.
    private static let ansiRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: "\\x1B\\[[0-9;]*[A-Za-z]|\\x1B\\][^\\x07]*\\x07")
    }()

    /// Strip ANSI escape sequences from text.
    private func stripANSI(_ text: String) -> String {
        guard let regex = Self.ansiRegex else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }

    /// Reset the ready state (useful when starting new sessions).
    func resetReadyState() {
        isClaudeReady = false
        outputBuffer = ""
    }
}
