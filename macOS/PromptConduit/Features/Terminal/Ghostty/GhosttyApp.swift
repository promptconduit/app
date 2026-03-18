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

        // Build runtime config with callbacks.
        // Pattern follows ghostty/macos/Sources/Ghostty/Ghostty.App.swift.
        var runtimeCfg = ghostty_runtime_config_s(
            userdata: Unmanaged.passUnretained(self).toOpaque(),
            supports_selection_clipboard: false,
            wakeup_cb: { userdata in
                guard let userdata = userdata else { return }
                DispatchQueue.main.async {
                    let app = Unmanaged<GhosttyApp>.fromOpaque(userdata).takeUnretainedValue()
                    app.tick()
                }
            },
            action_cb: { app, target, action in
                guard let app = app else { return false }
                return GhosttyApp.handleAction(app, target: target, action: action)
            },
            read_clipboard_cb: { userdata, kind, state in
                GhosttyApp.readClipboard(userdata, kind: kind, state: state)
            },
            confirm_read_clipboard_cb: nil,
            write_clipboard_cb: { userdata, kind, content, len, confirm in
                GhosttyApp.writeClipboard(userdata, kind: kind, content: content, len: len)
            },
            close_surface_cb: nil
        )

        app = ghostty_app_new(&runtimeCfg, cfg)
        ghostty_config_free(cfg)

        if app == nil {
            print("[GhosttyApp] ghostty_app_new failed")
        } else {
            print("[GhosttyApp] Initialized successfully")
        }
    }

    /// Shut down the ghostty app. Typically only called on app termination.
    func stop() {
        guard let app = app else { return }
        ghostty_app_free(app)
        self.app = nil
    }

    // MARK: - Tick

    /// Drive the ghostty event loop. Called from the wakeup callback.
    func tick() {
        guard let app = app else { return }
        ghostty_app_tick(app)
    }

    // MARK: - Action Callback

    /// Handle actions from ghostty. Returns true if handled.
    private static func handleAction(_ app: ghostty_app_t, target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        // Surface-level actions (child exit, title change, etc.) are dispatched
        // to individual GhosttyTerminalView instances via their stored userdata.
        // We handle child exit here since we need to notify the view.
        switch action.tag {
        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            // Find the surface view from the target and notify termination
            if let surfaceUserdata = ghostty_surface_userdata(target) {
                let view = Unmanaged<GhosttyTerminalView>.fromOpaque(surfaceUserdata).takeUnretainedValue()
                DispatchQueue.main.async {
                    view.handleProcessTerminated()
                }
            }
            return true

        default:
            return false
        }
    }

    // MARK: - Clipboard

    private static func readClipboard(_ userdata: UnsafeMutableRawPointer?, kind: ghostty_clipboard_e, state: UnsafeMutableRawPointer?) -> Bool {
        // userdata is the surface's userdata (our GhosttyTerminalView)
        guard let userdata = userdata else { return false }
        let view = Unmanaged<GhosttyTerminalView>.fromOpaque(userdata).takeUnretainedValue()
        guard let surface = view.surface else { return false }

        let pasteboard = NSPasteboard.general
        let str = pasteboard.string(forType: .string) ?? ""
        str.withCString { cstr in
            ghostty_surface_complete_clipboard_request(surface, cstr, state, false)
        }
        return true
    }

    private static func writeClipboard(_ userdata: UnsafeMutableRawPointer?, kind: ghostty_clipboard_e, content: UnsafePointer<ghostty_clipboard_content_s>?, len: Int) {
        guard let content = content, len > 0 else { return }
        // Get the first content item's string
        let item = content[0]
        guard let strPtr = item.data else { return }
        let str = String(cString: strPtr)

        DispatchQueue.main.async {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(str, forType: .string)
        }
    }
}

/// Helper to extract surface userdata from an action target.
/// Returns nil if the target is not a surface.
private func ghostty_surface_userdata(_ target: ghostty_target_s) -> UnsafeMutableRawPointer? {
    // The target union contains a surface pointer when the tag indicates surface
    // We need to check the target tag and extract the surface's userdata
    // This depends on the ghostty API structure
    return nil // TODO: implement once we can verify the target struct layout
}
