import Foundation

/// Builds a ghostty configuration suitable for embedding Claude Code terminals.
enum GhosttyConfig {

    /// Creates a default ghostty config for embedded terminal use.
    /// Returns nil if config creation fails.
    static func makeDefault() -> ghostty_config_t? {
        guard let config = ghostty_config_new() else {
            return nil
        }

        // Font
        set(config, key: "font-family", value: "SF Mono")
        set(config, key: "font-size", value: "13")

        // Colors — dark theme matching the app's design tokens
        set(config, key: "background", value: "0f1729")       // rgb(0.06, 0.09, 0.16)
        set(config, key: "foreground", value: "edf0f5")       // rgb(0.93, 0.94, 0.96)

        // Terminal environment
        set(config, key: "term", value: "xterm-256color")

        // Window appearance
        set(config, key: "window-decoration", value: "false")
        set(config, key: "window-padding-x", value: "4")
        set(config, key: "window-padding-y", value: "4")
        set(config, key: "confirm-close-surface", value: "false")

        // Scrollback
        set(config, key: "scrollback-limit", value: "10000")

        // Mouse
        set(config, key: "mouse-hide-while-typing", value: "true")

        // Clipboard
        set(config, key: "clipboard-read", value: "allow")
        set(config, key: "clipboard-write", value: "allow")

        // Load finalized config
        ghostty_config_finalize(config)

        return config
    }

    /// Helper to set a config key-value pair.
    private static func set(_ config: ghostty_config_t, key: String, value: String) {
        key.withCString { k in
            value.withCString { v in
                ghostty_config_set(config, k, v)
            }
        }
    }
}
