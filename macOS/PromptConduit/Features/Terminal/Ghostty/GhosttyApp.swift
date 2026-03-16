import Foundation
import AppKit

/// Singleton managing the ghostty_app_t lifecycle.
/// All GhosttyTerminalView surfaces share a single app instance.
final class GhosttyApp {
    static let shared = GhosttyApp()

    /// The underlying ghostty app handle. `nil` until `start()` succeeds.
    private(set) var app: ghostty_app_t?

    /// Whether the app has been initialized
    var isRunning: Bool { app != nil }

    private init() {}

    // MARK: - Lifecycle

    /// Initialize the ghostty app with default configuration.
    /// Safe to call multiple times — only the first call creates the app.
    func start() {
        guard app == nil else { return }

        let config = GhosttyConfig.makeDefault()
        guard let cfg = config else {
            print("[GhosttyApp] Failed to create config")
            return
        }

        // Build runtime config with callbacks
        var runtimeCfg = ghostty_runtime_config_s()
        runtimeCfg.userdata = Unmanaged.passUnretained(self).toOpaque()
        runtimeCfg.wakeup_cb = { ud in
            DispatchQueue.main.async {
                guard let ud = ud else { return }
                let app = Unmanaged<GhosttyApp>.fromOpaque(ud).takeUnretainedValue()
                app.handleWakeup()
            }
        }
        runtimeCfg.action_cb = { ud, target, action in
            // Handle app-level actions (close, clipboard, etc.)
            guard let ud = ud else { return }
            let app = Unmanaged<GhosttyApp>.fromOpaque(ud).takeUnretainedValue()
            app.handleAction(target: target, action: action)
        }
        runtimeCfg.read_clipboard_cb = { ud, kind, state in
            GhosttyApp.handleReadClipboard(userdata: ud, kind: kind, state: state)
        }
        runtimeCfg.write_clipboard_cb = { ud, str, kind, confirm in
            GhosttyApp.handleWriteClipboard(userdata: ud, string: str, kind: kind, confirm: confirm)
        }

        app = ghostty_app_init(cfg, &runtimeCfg)
        ghostty_config_deinit(cfg)

        if app == nil {
            print("[GhosttyApp] ghostty_app_init failed")
        } else {
            print("[GhosttyApp] Initialized successfully")
        }
    }

    /// Shut down the ghostty app. Typically only called on app termination.
    func stop() {
        guard let app = app else { return }
        ghostty_app_deinit(app)
        self.app = nil
        print("[GhosttyApp] Deinitialized")
    }

    // MARK: - Tick

    /// Drive the ghostty event loop. Called from the wakeup callback.
    func tick() {
        guard let app = app else { return }
        _ = ghostty_app_tick(app)
    }

    // MARK: - Callbacks

    private func handleWakeup() {
        tick()
    }

    private func handleAction(target: ghostty_target_s, action: ghostty_action_u) {
        // Surface-level actions (close, title change, etc.) are handled
        // by the individual GhosttyTerminalView instances via their own callbacks.
        // App-level actions can be handled here if needed.
    }

    // MARK: - Clipboard

    private static func handleReadClipboard(userdata: UnsafeMutableRawPointer?, kind: ghostty_clipboard_e, state: UnsafeMutableRawPointer?) {
        DispatchQueue.main.async {
            let pasteboard = NSPasteboard.general
            // Always respond — returning nothing can cause ghostty to hang
            let str = pasteboard.string(forType: .string) ?? ""

            str.withCString { cstr in
                ghostty_app_set_clipboard(state, cstr, kind)
            }
        }
    }

    private static func handleWriteClipboard(userdata: UnsafeMutableRawPointer?, string: UnsafePointer<CChar>?, kind: ghostty_clipboard_e, confirm: Bool) {
        guard let string = string else { return }
        let str = String(cString: string)

        DispatchQueue.main.async {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(str, forType: .string)
        }
    }
}
