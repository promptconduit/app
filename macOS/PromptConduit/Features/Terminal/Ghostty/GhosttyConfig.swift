import Foundation

/// Builds a ghostty configuration suitable for embedding Claude Code terminals.
/// Loads the user's ghostty config files (if any) and finalizes the config.
enum GhosttyConfig {

    /// Creates a ghostty config by loading user config files.
    /// Returns nil if config creation fails.
    static func makeDefault() -> ghostty_config_t? {
        guard let config = ghostty_config_new() else {
            return nil
        }

        // Load user's ghostty config from default locations
        // (~/.config/ghostty/config, etc.)
        ghostty_config_load_default_files(config)

        // Finalize the config
        ghostty_config_finalize(config)

        return config
    }
}
