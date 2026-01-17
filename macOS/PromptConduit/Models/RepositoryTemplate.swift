import Foundation

/// A saved collection of repositories that can be launched together
struct RepositoryTemplate: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var repositoryPaths: [String]
    var defaultLayout: GridLayout
    var createdAt: Date
    var lastUsed: Date

    /// Number of repositories in this template
    var repositoryCount: Int {
        repositoryPaths.count
    }

    /// Extract display names from repository paths
    var displayNames: [String] {
        repositoryPaths.map { path in
            URL(fileURLWithPath: path).lastPathComponent
        }
    }

    /// Check if all repository paths still exist
    var allPathsExist: Bool {
        repositoryPaths.allSatisfy { path in
            FileManager.default.fileExists(atPath: path)
        }
    }

    /// Get paths that no longer exist
    var missingPaths: [String] {
        repositoryPaths.filter { path in
            !FileManager.default.fileExists(atPath: path)
        }
    }

    init(
        id: UUID = UUID(),
        name: String,
        repositoryPaths: [String],
        defaultLayout: GridLayout = .auto,
        createdAt: Date = Date(),
        lastUsed: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.repositoryPaths = repositoryPaths
        self.defaultLayout = defaultLayout
        self.createdAt = createdAt
        self.lastUsed = lastUsed
    }

    /// Create a template with a new last used date
    func withUpdatedLastUsed() -> RepositoryTemplate {
        var updated = self
        updated.lastUsed = Date()
        return updated
    }

    /// Add a repository path if not already present
    mutating func addRepository(path: String) {
        guard !repositoryPaths.contains(path) else { return }
        guard repositoryPaths.count < 8 else { return }  // Max 8 repos
        repositoryPaths.append(path)
    }

    /// Remove a repository path
    mutating func removeRepository(path: String) {
        repositoryPaths.removeAll { $0 == path }
    }

    /// Remove repositories that no longer exist on disk
    mutating func removeMissingPaths() {
        repositoryPaths = repositoryPaths.filter { path in
            FileManager.default.fileExists(atPath: path)
        }
    }
}

// MARK: - Comparable for sorting

extension RepositoryTemplate: Comparable {
    static func < (lhs: RepositoryTemplate, rhs: RepositoryTemplate) -> Bool {
        lhs.lastUsed > rhs.lastUsed  // Most recently used first
    }
}
