import AppKit
import Foundation

/// Locates and reveals the local PromptConduit data folder (`~/.promptconduit/`),
/// where the CLI and the app write their on-disk artifacts:
///
///   - `hook-events` / `app-events` — lightweight session traces (used by the
///     menu-bar app to track when sessions start/stop)
///   - `events.ndjson`              — the full JSON payloads the CLI sends to the
///     platform, recorded locally before/at send time
///   - `errors.log` / `status.json` — send failures, dropped events, and rolling
///     sent/failed/dropped counters
///
/// These files are produced by the CLI (and the app's installed hooks); this
/// type only locates and reveals them in Finder.
enum PromptConduitDataFolder {
    /// `~/.promptconduit/`
    static var directoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".promptconduit")
    }

    /// `~/.promptconduit/events.ndjson` — the full-payload event log.
    static var eventLogURL: URL {
        directoryURL.appendingPathComponent("events.ndjson")
    }

    /// Reveals the data folder in Finder. When the event log already exists we
    /// open the folder with it selected, so the user lands directly on the
    /// payloads; otherwise we just open the folder. The directory is created
    /// first (best-effort) so the reveal never silently no-ops before the first
    /// event is captured.
    static func reveal() {
        let fm = FileManager.default
        try? fm.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        if fm.fileExists(atPath: eventLogURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([eventLogURL])
        } else {
            NSWorkspace.shared.open(directoryURL)
        }
    }
}
