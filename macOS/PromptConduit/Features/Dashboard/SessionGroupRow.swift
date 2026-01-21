import SwiftUI

// MARK: - Session Group Row

/// Sidebar row for displaying a session group
struct SessionGroupRow: View {
    let group: SessionGroup
    let isSelected: Bool
    let isHighlighted: Bool
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                // Status indicator
                SessionGroupStatusIndicator(status: group.status, size: 10)

                // Group info
                VStack(alignment: .leading, spacing: 2) {
                    // Group name or prompt preview
                    Text(group.displayName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(isSelected ? TokyoNight.textPrimary : TokyoNight.textSecondary)
                        .lineLimit(1)

                    // Metadata row
                    HStack(spacing: 6) {
                        // Repo count with icon
                        HStack(spacing: 3) {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 9))
                            Text("\(group.repoCount)")
                                .font(.system(size: 10))
                        }
                        .foregroundColor(TokyoNight.textMuted)

                        Text("•")
                            .font(.system(size: 8))
                            .foregroundColor(TokyoNight.textMuted)

                        // Relative time
                        Text(group.relativeTime)
                            .font(.system(size: 10))
                            .foregroundColor(TokyoNight.textMuted)
                    }
                }

                Spacer()

                // Status label for active sessions
                if group.status == .waiting {
                    Text("Waiting")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(TokyoNight.statusWaiting)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(TokyoNight.statusWaiting.opacity(0.15))
                        .cornerRadius(4)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                isSelected ? TokyoNight.accentCyan.opacity(0.15) :
                    (isHovered ? TokyoNight.backgroundCardHover : Color.clear)
            )
            .cornerRadius(8)
            .overlay(
                // Highlight effect for deep linking
                RoundedRectangle(cornerRadius: 8)
                    .stroke(TokyoNight.statusWaiting, lineWidth: 2)
                    .opacity(isHighlighted ? 1 : 0)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Expanded Session Group Row

/// Expandable session group row showing individual repos
struct ExpandableSessionGroupRow: View {
    let group: SessionGroup
    let isSelected: Bool
    let isExpanded: Bool
    let isHighlighted: Bool
    let onSelect: () -> Void
    let onToggleExpand: () -> Void

    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 0) {
            // Main group row
            Button(action: onSelect) {
                HStack(spacing: 10) {
                    // Expand/collapse button
                    Button(action: onToggleExpand) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(TokyoNight.textMuted)
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.plain)

                    // Status indicator
                    SessionGroupStatusIndicator(status: group.status, size: 10)

                    // Group info
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.displayName)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(isSelected ? TokyoNight.textPrimary : TokyoNight.textSecondary)
                            .lineLimit(1)

                        HStack(spacing: 6) {
                            Text("\(group.repoCount) repos")
                                .font(.system(size: 10))
                                .foregroundColor(TokyoNight.textMuted)

                            Text("•")
                                .font(.system(size: 8))
                                .foregroundColor(TokyoNight.textMuted)

                            Text(group.relativeTime)
                                .font(.system(size: 10))
                                .foregroundColor(TokyoNight.textMuted)
                        }
                    }

                    Spacer()

                    // Status badge
                    statusBadge
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    isSelected ? TokyoNight.accentCyan.opacity(0.15) :
                        (isHovered ? TokyoNight.backgroundCardHover : Color.clear)
                )
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(TokyoNight.statusWaiting, lineWidth: 2)
                        .opacity(isHighlighted ? 1 : 0)
                )
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }

            // Expanded repo list
            if isExpanded {
                VStack(spacing: 2) {
                    ForEach(group.repoPaths, id: \.self) { repoPath in
                        RepoPathRow(
                            repoPath: repoPath,
                            claudeSessionId: group.claudeSessionIds[repoPath]
                        )
                    }
                }
                .padding(.leading, 36)
                .padding(.trailing, 12)
                .padding(.bottom, 8)
            }
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch group.status {
        case .active:
            Text("Running")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(TokyoNight.statusRunning)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(TokyoNight.statusRunning.opacity(0.15))
                .cornerRadius(4)
        case .waiting:
            Text("Waiting")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(TokyoNight.statusWaiting)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(TokyoNight.statusWaiting.opacity(0.15))
                .cornerRadius(4)
        case .completed:
            Text("Done")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(TokyoNight.statusIdle)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(TokyoNight.statusIdle.opacity(0.15))
                .cornerRadius(4)
        case .archived:
            EmptyView()
        }
    }
}

// MARK: - Repo Path Row

/// Row showing an individual repo within an expanded group
struct RepoPathRow: View {
    let repoPath: String
    let claudeSessionId: String?

    @State private var isHovered = false

    private var repoName: String {
        URL(fileURLWithPath: repoPath).lastPathComponent
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.fill")
                .font(.system(size: 10))
                .foregroundColor(TokyoNight.textMuted)

            Text(repoName)
                .font(.system(size: 11))
                .foregroundColor(TokyoNight.textSecondary)
                .lineLimit(1)

            Spacer()

            if claudeSessionId != nil {
                Circle()
                    .fill(TokyoNight.statusRunning)
                    .frame(width: 6, height: 6)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(isHovered ? TokyoNight.backgroundCardHover : Color.clear)
        .cornerRadius(4)
        .onHover { isHovered = $0 }
        .help(repoPath)
    }
}

// MARK: - Session Group Card (Alternative larger view)

/// Card-style view for session groups, used in grid layouts
struct SessionGroupCard: View {
    let group: SessionGroup
    let isSelected: Bool
    let onSelect: () -> Void
    let onRelaunch: (() -> Void)?

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 12) {
                // Header
                HStack {
                    SessionGroupStatusIndicator(status: group.status, size: 12)

                    Text(group.displayName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(TokyoNight.textPrimary)
                        .lineLimit(1)

                    Spacer()

                    if let onRelaunch = onRelaunch, !group.isActive {
                        Button(action: onRelaunch) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 12))
                                .foregroundColor(TokyoNight.accentCyan)
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Prompt preview
                if !group.prompt.isEmpty {
                    Text(group.promptPreview)
                        .font(.system(size: 12))
                        .foregroundColor(TokyoNight.textSecondary)
                        .lineLimit(2)
                }

                // Footer
                HStack(spacing: 12) {
                    // Repo count
                    HStack(spacing: 4) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 10))
                        Text("\(group.repoCount) repos")
                            .font(.system(size: 11))
                    }
                    .foregroundColor(TokyoNight.textMuted)

                    Spacer()

                    // Time
                    Text(group.relativeTime)
                        .font(.system(size: 11))
                        .foregroundColor(TokyoNight.textMuted)
                }
            }
            .padding(16)
            .background(
                isSelected ? TokyoNight.accentCyan.opacity(0.15) :
                    (isHovered ? TokyoNight.backgroundCardHover : TokyoNight.backgroundCard)
            )
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? TokyoNight.accentCyan : TokyoNight.borderColor, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
