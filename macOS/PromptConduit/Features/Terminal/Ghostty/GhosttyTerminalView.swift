import AppKit
import QuartzCore

/// An NSView that wraps a single ghostty terminal surface with Metal-accelerated rendering.
class GhosttyTerminalView: NSView {

    /// The ghostty surface handle (created when the process is started).
    private(set) var surface: ghostty_surface_t?

    /// Callback invoked when terminal output is received (for Claude readiness detection).
    /// Note: Requires the promptconduit/ghostty fork patch for output monitoring.
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
            ghostty_surface_free(surface)
        }
    }

    // MARK: - Process Launch

    /// Start a process in the terminal.
    /// - Parameters:
    ///   - command: Shell command string passed to ghostty as the surface command.
    ///   - workingDirectory: Working directory for the process.
    ///   - environmentVars: Environment variables as ["KEY": "VALUE"] dictionary.
    func startProcess(
        command: String,
        workingDirectory: String,
        environmentVars: [String: String] = [:]
    ) {
        guard surface == nil else {
            print("[GhosttyTerminalView] Process already started")
            return
        }

        guard let app = GhosttyApp.shared.app else {
            print("[GhosttyTerminalView] GhosttyApp not initialized")
            return
        }

        // Build a surface config following the pattern from
        // ghostty/macos/Sources/Ghostty/Surface View/SurfaceView.swift
        var config = ghostty_surface_config_new()
        config.userdata = Unmanaged.passUnretained(self).toOpaque()

        // Set macOS platform with this view as the NSView
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform = ghostty_platform_u(
            macos: ghostty_platform_macos_s(
                nsview: Unmanaged.passUnretained(self).toOpaque()
            )
        )
        config.scale_factor = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        config.font_size = 13

        // Use withCString closures to keep string pointers alive during surface creation.
        // This matches the nested-closure pattern from Ghostty's SurfaceConfiguration.withCValue.
        let surfaceResult: ghostty_surface_t? = workingDirectory.withCString { cWorkDir in
            config.working_directory = cWorkDir

            return command.withCString { cCmd in
                config.command = cCmd

                // Convert environment dictionary to ghostty_env_var_s array
                let keys = Array(environmentVars.keys)
                let values = Array(environmentVars.values)

                return keys.withCStrings { keyCStrings in
                    return values.withCStrings { valueCStrings in
                        var envVars = [ghostty_env_var_s]()
                        envVars.reserveCapacity(environmentVars.count)
                        for i in 0..<environmentVars.count {
                            envVars.append(ghostty_env_var_s(
                                key: keyCStrings[i],
                                value: valueCStrings[i]
                            ))
                        }

                        return envVars.withUnsafeMutableBufferPointer { buffer in
                            config.env_vars = buffer.baseAddress
                            config.env_var_count = environmentVars.count
                            return ghostty_surface_new(app, &config)
                        }
                    }
                }
            }
        }

        guard let newSurface = surfaceResult else {
            print("[GhosttyTerminalView] Failed to create surface")
            return
        }

        surface = newSurface

        // Set up output monitoring callback (promptconduit/ghostty fork — not in upstream).
        // This hooks into the PTY read loop to feed output to Claude readiness detection.
        let ud = Unmanaged.passUnretained(self).toOpaque()
        ghostty_surface_set_output_callback(newSurface, { data, len, userdata in
            guard let data = data, let userdata = userdata else { return }
            let view = Unmanaged<GhosttyTerminalView>.fromOpaque(userdata).takeUnretainedValue()

            let buffer = UnsafeBufferPointer(start: data, count: len)
            if let text = String(bytes: buffer, encoding: .utf8) {
                DispatchQueue.main.async {
                    view.handleOutputReceived(text)
                }
            }
        }, ud)

        print("[GhosttyTerminalView] Process started")
    }

    // MARK: - Text Input

    /// Send text to the terminal as if it was typed.
    /// Uses ghostty_surface_text which bypasses key bindings (appropriate for programmatic input).
    func sendText(_ text: String) {
        guard let surface = surface else { return }
        let len = text.utf8CString.count
        if len == 0 { return }

        text.withCString { ptr in
            ghostty_surface_text(surface, ptr, UInt(len - 1))
        }
    }

    /// Send raw bytes to the terminal (e.g., control characters like CR).
    func sendBytes(_ bytes: [UInt8]) {
        guard let surface = surface else { return }
        // Convert bytes to a string and use ghostty_surface_text
        if let str = String(bytes: bytes, encoding: .utf8) {
            sendText(str)
        }
    }

    // MARK: - Key Forwarding (for broadcast mode)

    /// Forward a key event to this terminal surface.
    /// Used by broadcast mode to send keystrokes to all terminals.
    func forwardKeyEvent(_ event: NSEvent) {
        guard let surface = surface else { return }
        Ghostty.sendKeyEvent(to: surface, event: event, action: event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS)
    }

    // MARK: - Selection

    /// Get the currently selected text, if any.
    func getSelectedText() -> String? {
        guard let surface = surface else { return nil }
        guard ghostty_surface_has_selection(surface) else { return nil }

        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }

        guard let ptr = text.text, text.text_len > 0 else { return nil }
        let str = String(cString: ptr)
        return str.isEmpty ? nil : str
    }

    // MARK: - Layout

    override func layout() {
        super.layout()

        guard let surface = surface else { return }

        let scale = UInt32(window?.backingScaleFactor ?? 2.0)
        ghostty_surface_set_size(
            surface,
            UInt32(bounds.width),
            UInt32(bounds.height)
        )
        ghostty_surface_set_content_scale(
            surface,
            Double(scale),
            Double(scale)
        )
    }

    // MARK: - First Responder

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        if let surface = surface {
            ghostty_surface_set_focus(surface, true)
        }
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        if let surface = surface {
            ghostty_surface_set_focus(surface, false)
        }
        return super.resignFirstResponder()
    }

    // MARK: - Keyboard Events

    override func keyDown(with event: NSEvent) {
        guard let surface = surface else { return }
        Ghostty.sendKeyEvent(to: surface, event: event, action: event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS)
    }

    override func keyUp(with event: NSEvent) {
        guard let surface = surface else { return }
        Ghostty.sendKeyEvent(to: surface, event: event, action: GHOSTTY_ACTION_RELEASE)
    }

    override func flagsChanged(with event: NSEvent) {
        guard let surface = surface else { return }
        Ghostty.sendKeyEvent(to: surface, event: event, action: GHOSTTY_ACTION_PRESS)
    }

    // MARK: - Mouse Events

    override func mouseDown(with event: NSEvent) {
        guard let surface = surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        let mods = Ghostty.ghosttyMods(event.modifierFlags)
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, mods)
    }

    override func mouseUp(with event: NSEvent) {
        guard let surface = surface else { return }
        let mods = Ghostty.ghosttyMods(event.modifierFlags)
        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, mods)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let surface = surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        let mods = Ghostty.ghosttyMods(event.modifierFlags)
        ghostty_surface_mouse_pos(surface, point.x, point.y, mods)
    }

    override func mouseMoved(with event: NSEvent) {
        guard let surface = surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        let mods = Ghostty.ghosttyMods(event.modifierFlags)
        ghostty_surface_mouse_pos(surface, point.x, point.y, mods)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface = surface else { return }
        var scrollMods = ghostty_input_scroll_mods_t()
        scrollMods.precise = event.hasPreciseScrollingDeltas
        scrollMods.momentum = event.momentumPhase != []
        ghostty_surface_mouse_scroll(surface, event.scrollingDeltaX, event.scrollingDeltaY, scrollMods)
    }

    // MARK: - Process Termination (called from GhosttyApp action callback)

    /// Called when the child process exits. Invoked from the action callback.
    func handleProcessTerminated() {
        onProcessTerminated?()
    }

    // MARK: - Output Monitoring

    /// Handles output received from the PTY (via fork patch callback).
    private func handleOutputReceived(_ text: String) {
        outputBuffer += text
        if outputBuffer.count > maxBufferSize {
            outputBuffer = String(outputBuffer.suffix(maxBufferSize))
        }

        if !isClaudeReady {
            checkClaudeReady()
        }

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

// MARK: - Input Helpers

/// Namespace for Ghostty input helpers.
/// Pattern follows cmux's GhosttyTerminalView key handling.
enum Ghostty {
    /// Translate NSEvent modifier flags to ghostty mods.
    static func ghosttyMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods: UInt32 = GHOSTTY_MODS_NONE.rawValue

        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }

        return ghostty_input_mods_e(mods)
    }

    /// Send a key event to a ghostty surface from an NSEvent.
    /// The text pointer must remain valid during the ghostty_surface_key call,
    /// so we use withCString to ensure lifetime safety (matching cmux's pattern).
    @discardableResult
    static func sendKeyEvent(to surface: ghostty_surface_t, event: NSEvent, action: ghostty_input_action_e) -> Bool {
        var key = ghostty_input_key_s()
        key.action = action
        key.keycode = UInt32(event.keyCode)
        key.mods = ghosttyMods(event.modifierFlags)
        key.consumed_mods = GHOSTTY_MODS_NONE
        key.composing = false
        key.unshifted_codepoint = 0

        let text = event.charactersIgnoringModifiers ?? event.characters ?? ""
        if text.isEmpty {
            key.text = nil
            return ghostty_surface_key(surface, key)
        } else {
            // Text pointer must be valid during ghostty_surface_key — keep inside withCString
            return text.withCString { ptr in
                key.text = ptr
                return ghostty_surface_key(surface, key)
            }
        }
    }
}
