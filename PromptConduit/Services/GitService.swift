import Foundation

/// Service for extracting git repository information from local directories
class GitService {
    static let shared = GitService()

    private init() {}

    /// Extracts the GitHub URL from a local git repository
    /// - Parameter directory: The path to check for a git repository
    /// - Returns: The GitHub web URL if found, nil otherwise
    func getGitHubURL(for directory: String) -> URL? {
        guard let remoteURL = getRemoteOriginURL(for: directory) else {
            return nil
        }

        return convertToGitHubWebURL(remoteURL)
    }

    /// Gets the remote origin URL from a git repository
    /// - Parameter directory: The path to the git repository
    /// - Returns: The remote origin URL string, or nil if not found
    func getRemoteOriginURL(for directory: String) -> String? {
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["remote", "get-url", "origin"]
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                return nil
            }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            return output?.isEmpty == false ? output : nil
        } catch {
            return nil
        }
    }

    /// Converts a git remote URL to a GitHub web URL
    /// - Parameter remoteURL: The git remote URL (SSH or HTTPS)
    /// - Returns: The GitHub web URL, or nil if not a GitHub repository
    func convertToGitHubWebURL(_ remoteURL: String) -> URL? {
        var urlString = remoteURL

        // Handle SSH URL format: git@github.com:owner/repo.git
        if urlString.hasPrefix("git@github.com:") {
            urlString = urlString.replacingOccurrences(of: "git@github.com:", with: "https://github.com/")
        }

        // Handle other SSH formats: ssh://git@github.com/owner/repo.git
        if urlString.hasPrefix("ssh://git@github.com/") {
            urlString = urlString.replacingOccurrences(of: "ssh://git@github.com/", with: "https://github.com/")
        }

        // Remove .git suffix if present
        if urlString.hasSuffix(".git") {
            urlString = String(urlString.dropLast(4))
        }

        // Verify it's a GitHub URL
        guard urlString.contains("github.com") else {
            return nil
        }

        return URL(string: urlString)
    }

    /// Checks if a directory is inside a git repository
    /// - Parameter directory: The path to check
    /// - Returns: True if the directory is inside a git repository
    func isGitRepository(_ directory: String) -> Bool {
        let process = Process()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["rev-parse", "--git-dir"]
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
