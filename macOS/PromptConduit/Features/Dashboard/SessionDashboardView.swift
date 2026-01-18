import SwiftUI

// MARK: - Design Tokens

private enum DashboardTokens {
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

    // Status colors (Tokyo Night theme)
    static let statusRunning = Color(red: 0.62, green: 0.81, blue: 0.42)   // Green
    static let statusWaiting = Color(red: 0.88, green: 0.69, blue: 0.41)   // Yellow/Orange
    static let statusIdle = Color(red: 0.34, green: 0.37, blue: 0.53)      // Gray
    static let statusError = Color(red: 0.97, green: 0.47, blue: 0.47)     // Red
}

// MARK: - Session Dashboard View

struct SessionDashboardView: View {
    @StateObject private var discovery = ClaudeSessionDiscovery.shared
    @State private var selectedSession: DiscoveredSession?
    @State private var searchText: String = ""

    let onResumeSession: (DiscoveredSession) -> Void
    let onClose: () -> Void

    private var filteredGroups: [RepoSessionGroup] {
        if searchText.isEmpty {
            return discovery.repoGroups
        }

        return discovery.repoGroups.compactMap { group in
            let filteredSessions = group.sessions.filter {
                $0.title.localizedCaseInsensitiveContains(searchText) ||
                $0.repoName.localizedCaseInsensitiveContains(searchText)
            }

            if filteredSessions.isEmpty && !group.displayName.localizedCaseInsensitiveContains(searchText) {
                return nil
            }

            var filtered = group
            if !filteredSessions.isEmpty {
                filtered.sessions = filteredSessions
            }
            return filtered
        }
    }

    var body: some View {
        ZStack {
            DashboardTokens.backgroundPrimary.ignoresSafeArea()

            HSplitView {
                // Left sidebar - Session tree
                sessionSidebar
                    .frame(minWidth: 280, maxWidth: 400)

                // Right panel - Session detail
                if let session = selectedSession {
                    sessionDetail(session)
                } else {
                    emptyState
                }
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .onAppear {
            discovery.startMonitoring()
        }
        .onDisappear {
            discovery.stopMonitoring()
        }
    }

    // MARK: - Sidebar

    private var sessionSidebar: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Sessions")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(DashboardTokens.textPrimary)

                Spacer()

                // Refresh button
                Button(action: { discovery.refresh() }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(DashboardTokens.accentCyan)
                        .rotationEffect(.degrees(discovery.isLoading ? 360 : 0))
                        .animation(discovery.isLoading ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: discovery.isLoading)
                }
                .buttonStyle(.plain)
                .help("Refresh sessions")
            }
            .padding(16)

            // Search
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(DashboardTokens.textMuted)

                TextField("Search sessions...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(DashboardTokens.textPrimary)

                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(DashboardTokens.textMuted)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            .background(DashboardTokens.backgroundCard)
            .cornerRadius(8)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)

            Divider()
                .background(DashboardTokens.borderColor)

            // Session tree
            if filteredGroups.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 32))
                        .foregroundColor(DashboardTokens.textMuted)

                    Text(searchText.isEmpty ? "No sessions found" : "No matching sessions")
                        .font(.system(size: 14))
                        .foregroundColor(DashboardTokens.textMuted)

                    if searchText.isEmpty {
                        Text("Start a Claude Code session to see it here")
                            .font(.system(size: 12))
                            .foregroundColor(DashboardTokens.textMuted)
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(filteredGroups) { group in
                            RepoGroupRow(
                                group: group,
                                selectedSessionId: selectedSession?.id,
                                onToggle: { discovery.toggleExpanded(group.id) },
                                onSelectSession: { session in
                                    withAnimation(.easeInOut(duration: 0.15)) {
                                        selectedSession = session
                                    }
                                }
                            )
                        }
                    }
                    .padding(8)
                }
            }

            // Last refresh indicator
            if let lastRefresh = discovery.lastRefresh {
                HStack {
                    Circle()
                        .fill(DashboardTokens.statusRunning)
                        .frame(width: 6, height: 6)
                    Text("Updated \(lastRefresh, formatter: timeFormatter)")
                        .font(.system(size: 10))
                        .foregroundColor(DashboardTokens.textMuted)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
        .background(DashboardTokens.backgroundSecondary)
    }

    // MARK: - Session Detail

    private func sessionDetail(_ session: DiscoveredSession) -> some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        SessionStatusIndicator(status: session.status, size: 12)

                        Text(session.title)
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(DashboardTokens.textPrimary)
                            .lineLimit(1)
                    }

                    HStack(spacing: 12) {
                        Label(session.repoName, systemImage: "folder")
                            .font(.system(size: 12))
                            .foregroundColor(DashboardTokens.textSecondary)

                        Text("•")
                            .foregroundColor(DashboardTokens.textMuted)

                        Text("\(session.messageCount) messages")
                            .font(.system(size: 12))
                            .foregroundColor(DashboardTokens.textMuted)

                        Text("•")
                            .foregroundColor(DashboardTokens.textMuted)

                        Text(session.relativeTime)
                            .font(.system(size: 12))
                            .foregroundColor(DashboardTokens.textMuted)
                    }
                }

                Spacer()

                // Resume button
                Button(action: { onResumeSession(session) }) {
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill")
                        Text("Resume")
                    }
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(DashboardTokens.accentCyan)
                    .foregroundColor(DashboardTokens.backgroundPrimary)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }
            .padding(20)
            .background(DashboardTokens.backgroundSecondary)

            Divider()
                .background(DashboardTokens.borderColor)

            // Session info
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Status card
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Status")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(DashboardTokens.textSecondary)

                        HStack(spacing: 16) {
                            statusCard(
                                icon: session.status.icon,
                                title: session.status.label,
                                subtitle: statusDescription(for: session.status),
                                color: statusColor(for: session.status)
                            )
                        }
                    }

                    // Details card
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Details")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(DashboardTokens.textSecondary)

                        VStack(alignment: .leading, spacing: 8) {
                            detailRow(label: "Session ID", value: session.id)
                            detailRow(label: "Repository", value: session.repoPath)
                            detailRow(label: "File", value: session.filePath)
                            detailRow(label: "Last Activity", value: formatDate(session.lastActivity))
                        }
                        .padding(16)
                        .background(DashboardTokens.backgroundCard)
                        .cornerRadius(10)
                    }

                    // Actions
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Actions")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(DashboardTokens.textSecondary)

                        HStack(spacing: 12) {
                            actionButton(icon: "folder", title: "Open in Finder") {
                                NSWorkspace.shared.selectFile(session.filePath, inFileViewerRootedAtPath: "")
                            }

                            actionButton(icon: "doc.on.doc", title: "Copy Session ID") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(session.id, forType: .string)
                            }
                        }
                    }
                }
                .padding(20)
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.left.circle")
                .font(.system(size: 40))
                .foregroundColor(DashboardTokens.textMuted)

            Text("Select a session")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(DashboardTokens.textSecondary)

            Text("Choose a session from the sidebar to view details and resume.")
                .font(.system(size: 13))
                .foregroundColor(DashboardTokens.textMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helper Views

    private func statusCard(icon: String, title: String, subtitle: String, color: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundColor(color)
                .frame(width: 40, height: 40)
                .background(color.opacity(0.15))
                .cornerRadius(10)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(DashboardTokens.textPrimary)

                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(DashboardTokens.textMuted)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DashboardTokens.backgroundCard)
        .cornerRadius(10)
    }

    private func detailRow(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DashboardTokens.textMuted)

            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(DashboardTokens.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func actionButton(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                Text(title)
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(DashboardTokens.backgroundCard)
            .foregroundColor(DashboardTokens.textPrimary)
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(DashboardTokens.borderColor, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private func statusColor(for status: ClaudeSessionStatus) -> Color {
        switch status {
        case .running: return DashboardTokens.statusRunning
        case .waiting: return DashboardTokens.statusWaiting
        case .idle: return DashboardTokens.statusIdle
        case .error: return DashboardTokens.statusError
        }
    }

    private func statusDescription(for status: ClaudeSessionStatus) -> String {
        switch status {
        case .running: return "Session is actively being used"
        case .waiting: return "Session is waiting for input"
        case .idle: return "Session has not been used recently"
        case .error: return "Session has an error"
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private var timeFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter
    }
}

// MARK: - Repo Group Row

struct RepoGroupRow: View {
    let group: RepoSessionGroup
    let selectedSessionId: String?
    let onToggle: () -> Void
    let onSelectSession: (DiscoveredSession) -> Void

    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 0) {
            // Group header
            Button(action: onToggle) {
                HStack(spacing: 10) {
                    // Expand/collapse arrow
                    Image(systemName: group.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(DashboardTokens.textMuted)
                        .frame(width: 12)

                    // Status indicator
                    SessionStatusIndicator(status: group.aggregateStatus, size: 10)

                    // Repo name
                    Text(group.displayName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DashboardTokens.textPrimary)
                        .lineLimit(1)

                    Spacer()

                    // Session count
                    Text("\(group.sessionCount)")
                        .font(.system(size: 11))
                        .foregroundColor(DashboardTokens.textMuted)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(DashboardTokens.backgroundCard)
                        .cornerRadius(4)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(isHovered ? DashboardTokens.backgroundCardHover : Color.clear)
                .cornerRadius(6)
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }

            // Sessions (if expanded)
            if group.isExpanded {
                VStack(spacing: 2) {
                    ForEach(group.sessions) { session in
                        SessionRow(
                            session: session,
                            isSelected: selectedSessionId == session.id,
                            onSelect: { onSelectSession(session) }
                        )
                    }
                }
                .padding(.leading, 24)
            }
        }
    }
}

// MARK: - Session Row

struct SessionRow: View {
    let session: DiscoveredSession
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                // Status indicator
                SessionStatusIndicator(status: session.status, size: 8)

                // Session title
                Text(session.title)
                    .font(.system(size: 12))
                    .foregroundColor(isSelected ? DashboardTokens.textPrimary : DashboardTokens.textSecondary)
                    .lineLimit(1)

                Spacer()

                // Time
                Text(session.relativeTime)
                    .font(.system(size: 10))
                    .foregroundColor(DashboardTokens.textMuted)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                isSelected ? DashboardTokens.accentCyan.opacity(0.15) :
                    (isHovered ? DashboardTokens.backgroundCardHover : Color.clear)
            )
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Status Indicator

struct SessionStatusIndicator: View {
    let status: ClaudeSessionStatus
    let size: CGFloat

    var body: some View {
        Circle()
            .fill(statusColor)
            .frame(width: size, height: size)
            .overlay(
                Circle()
                    .stroke(statusColor.opacity(0.3), lineWidth: size * 0.2)
            )
    }

    private var statusColor: Color {
        switch status {
        case .running: return DashboardTokens.statusRunning
        case .waiting: return DashboardTokens.statusWaiting
        case .idle: return DashboardTokens.statusIdle
        case .error: return DashboardTokens.statusError
        }
    }
}
