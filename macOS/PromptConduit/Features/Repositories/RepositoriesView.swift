import SwiftUI
import AppKit

// MARK: - Design Tokens

private enum RepoTokens {
    static let backgroundPrimary = Color(red: 0.06, green: 0.09, blue: 0.16)
    static let backgroundSecondary = Color(red: 0.10, green: 0.13, blue: 0.20)
    static let backgroundCard = Color(red: 0.13, green: 0.16, blue: 0.24)
    static let backgroundCardHover = Color(red: 0.16, green: 0.20, blue: 0.28)
    static let accentCyan = Color(red: 0.0, green: 0.83, blue: 0.67)
    static let accentPurple = Color(red: 0.58, green: 0.44, blue: 0.86)
    static let textPrimary = Color(red: 0.93, green: 0.94, blue: 0.96)
    static let textSecondary = Color(red: 0.58, green: 0.63, blue: 0.73)
    static let textMuted = Color(red: 0.4, green: 0.45, blue: 0.55)
    static let borderColor = Color(red: 0.20, green: 0.24, blue: 0.32)
    static let successGreen = Color(red: 0.3, green: 0.85, blue: 0.5)
}

// MARK: - Repositories View

struct RepositoriesView: View {
    let onSelectRepo: (RecentRepository) -> Void
    let onResumeSession: (SessionHistory) -> Void
    let onNewSession: (String) -> Void
    let onAddRepo: () -> Void
    let onClose: () -> Void

    @ObservedObject private var settings = SettingsService.shared
    @State private var selectedRepo: RecentRepository?
    @State private var searchText: String = ""

    private var filteredRepos: [RecentRepository] {
        if searchText.isEmpty {
            return settings.recentRepositories
        }
        return settings.recentRepositories.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.path.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        ZStack {
            RepoTokens.backgroundPrimary.ignoresSafeArea()

            HSplitView {
                // Left sidebar - Repository list
                repositoryList
                    .frame(minWidth: 280, maxWidth: 350)

                // Right panel - Selected repo details
                if let repo = selectedRepo {
                    repositoryDetail(repo)
                } else {
                    emptyState
                }
            }
        }
        .frame(minWidth: 800, minHeight: 500)
        .onAppear {
            // Auto-select first repo
            if selectedRepo == nil {
                selectedRepo = settings.recentRepositories.first
            }
        }
    }

    // MARK: - Repository List

    private var repositoryList: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Repositories")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(RepoTokens.textPrimary)

                Spacer()

                Button(action: onAddRepo) {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(RepoTokens.accentCyan)
                }
                .buttonStyle(.plain)
                .help("Add Repository")
            }
            .padding(16)

            // Search
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(RepoTokens.textMuted)

                TextField("Search repositories...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(RepoTokens.textPrimary)

                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(RepoTokens.textMuted)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            .background(RepoTokens.backgroundCard)
            .cornerRadius(8)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)

            Divider()
                .background(RepoTokens.borderColor)

            // Repository list
            if filteredRepos.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "folder.badge.questionmark")
                        .font(.system(size: 32))
                        .foregroundColor(RepoTokens.textMuted)

                    Text(searchText.isEmpty ? "No repositories yet" : "No matching repositories")
                        .font(.system(size: 14))
                        .foregroundColor(RepoTokens.textMuted)

                    if searchText.isEmpty {
                        Button("Add Repository") {
                            onAddRepo()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(RepoTokens.accentCyan)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(filteredRepos) { repo in
                            RepoListItem(
                                repo: repo,
                                sessionCount: settings.sessionsForRepository(path: repo.path).count,
                                isSelected: selectedRepo?.path == repo.path
                            ) {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    selectedRepo = repo
                                }
                            }
                        }
                    }
                    .padding(8)
                }
            }
        }
        .background(RepoTokens.backgroundSecondary)
    }

    // MARK: - Repository Detail

    private func repositoryDetail(_ repo: RecentRepository) -> some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(repo.name)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(RepoTokens.textPrimary)

                    Text(shortenPath(repo.path))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(RepoTokens.textMuted)
                }

                Spacer()

                // Action buttons
                HStack(spacing: 12) {
                    Button(action: { openInFinder(repo.path) }) {
                        Image(systemName: "folder")
                            .font(.system(size: 14))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(RepoTokens.textSecondary)
                    .help("Open in Finder")

                    Button(action: { onNewSession(repo.path) }) {
                        HStack(spacing: 6) {
                            Image(systemName: "plus")
                            Text("New Session")
                        }
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(RepoTokens.accentCyan)
                        .foregroundColor(RepoTokens.backgroundPrimary)
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(20)
            .background(RepoTokens.backgroundSecondary)

            Divider()
                .background(RepoTokens.borderColor)

            // Sessions list
            let sessions = settings.sessionsForRepository(path: repo.path)

            if sessions.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 40))
                        .foregroundColor(RepoTokens.textMuted)

                    Text("No sessions yet")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(RepoTokens.textSecondary)

                    Text("Start a new session to begin working with Claude in this repository.")
                        .font(.system(size: 13))
                        .foregroundColor(RepoTokens.textMuted)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 300)

                    Button(action: { onNewSession(repo.path) }) {
                        HStack(spacing: 6) {
                            Image(systemName: "play.fill")
                            Text("Start Session")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(RepoTokens.accentCyan)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Session History")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(RepoTokens.textSecondary)
                        .padding(.horizontal, 20)
                        .padding(.top, 16)

                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(sessions) { session in
                                SessionListItem(session: session) {
                                    onResumeSession(session)
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 20)
                    }
                }
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.left.circle")
                .font(.system(size: 40))
                .foregroundColor(RepoTokens.textMuted)

            Text("Select a repository")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(RepoTokens.textSecondary)

            Text("Choose a repository from the list to view its session history.")
                .font(.system(size: 13))
                .foregroundColor(RepoTokens.textMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    private func shortenPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    private func openInFinder(_ path: String) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }
}

// MARK: - Repo List Item

struct RepoListItem: View {
    let repo: RecentRepository
    let sessionCount: Int
    let isSelected: Bool
    let onTap: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // Icon
                Image(systemName: "folder.fill")
                    .font(.system(size: 16))
                    .foregroundColor(isSelected ? RepoTokens.accentCyan : RepoTokens.textSecondary)
                    .frame(width: 24)

                // Info
                VStack(alignment: .leading, spacing: 2) {
                    Text(repo.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(RepoTokens.textPrimary)
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        Text("\(sessionCount) session\(sessionCount == 1 ? "" : "s")")
                            .font(.system(size: 11))
                            .foregroundColor(RepoTokens.textMuted)
                    }
                }

                Spacer()

                if isSelected {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(RepoTokens.accentCyan)
                }
            }
            .padding(10)
            .background(
                isSelected ? RepoTokens.accentCyan.opacity(0.15) :
                    (isHovered ? RepoTokens.backgroundCardHover : Color.clear)
            )
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - Session List Item

struct SessionListItem: View {
    let session: SessionHistory
    let onResume: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 16) {
            // Status icon
            Image(systemName: session.status.icon)
                .font(.system(size: 14))
                .foregroundColor(statusColor)
                .frame(width: 20)

            // Content
            VStack(alignment: .leading, spacing: 4) {
                Text(session.shortPrompt)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(RepoTokens.textPrimary)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    Text(session.detailedTime)
                        .font(.system(size: 11))
                        .foregroundColor(RepoTokens.textMuted)

                    Text("•")
                        .foregroundColor(RepoTokens.textMuted)

                    Text("\(session.messageCount) messages")
                        .font(.system(size: 11))
                        .foregroundColor(RepoTokens.textMuted)
                }
            }

            Spacer()

            // Resume button
            Button(action: onResume) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                    Text("Resume")
                        .font(.system(size: 12, weight: .medium))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(isHovered ? RepoTokens.accentCyan : RepoTokens.backgroundSecondary)
                .foregroundColor(isHovered ? RepoTokens.backgroundPrimary : RepoTokens.textPrimary)
                .cornerRadius(6)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(isHovered ? RepoTokens.backgroundCardHover : RepoTokens.backgroundCard)
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(RepoTokens.borderColor, lineWidth: 1)
        )
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private var statusColor: Color {
        switch session.status {
        case .completed: return RepoTokens.successGreen
        case .failed: return Color(red: 0.95, green: 0.35, blue: 0.35)
        case .interrupted: return Color(red: 0.95, green: 0.75, blue: 0.3)
        }
    }
}
