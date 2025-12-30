import SwiftUI

// MARK: - Design Tokens (matching promptconduit.dev)

private enum DesignTokens {
    // Background colors
    static let backgroundPrimary = Color(red: 0.06, green: 0.09, blue: 0.16)      // #0f172a
    static let backgroundSecondary = Color(red: 0.12, green: 0.16, blue: 0.24)    // #1e293b
    static let backgroundCard = Color(red: 0.15, green: 0.19, blue: 0.27)         // #262f3d

    // Accent colors
    static let accentCyan = Color(red: 0.0, green: 0.83, blue: 0.67)              // #00d4aa
    static let accentPurple = Color(red: 0.58, green: 0.44, blue: 0.86)           // #9470db
    static let accentOrange = Color(red: 0.96, green: 0.62, blue: 0.26)           // #f59e42
    static let accentYellow = Color(red: 0.98, green: 0.84, blue: 0.37)           // #fad65f

    // Text colors
    static let textPrimary = Color(red: 0.93, green: 0.94, blue: 0.96)            // #eef0f5
    static let textSecondary = Color(red: 0.58, green: 0.63, blue: 0.73)          // #94a3b8
    static let textMuted = Color(red: 0.4, green: 0.45, blue: 0.55)               // #66738c

    // Message-specific colors
    static let userBorder = accentCyan
    static let assistantBorder = accentPurple
    static let systemBorder = accentOrange
    static let toolBorder = accentYellow
}

/// Displays the conversation transcript with beautiful dark theme
struct TranscriptView: View {
    let entries: [TranscriptEntry]
    let rawOutput: String

    @State private var showRawOutput = false

    var body: some View {
        ZStack {
            DesignTokens.backgroundPrimary.ignoresSafeArea()

            VStack(spacing: 0) {
                // Toggle for output mode
                HStack {
                    Spacer()
                    Toggle("Show Raw Output", isOn: $showRawOutput)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .foregroundColor(DesignTokens.textSecondary)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(DesignTokens.backgroundSecondary)

                Divider()
                    .background(DesignTokens.textMuted.opacity(0.3))

                // Content area
                if showRawOutput {
                    RawTerminalView(output: rawOutput)
                } else {
                    MessageListView(entries: entries)
                }
            }
        }
    }
}

// MARK: - Message List View

struct MessageListView: View {
    let entries: [TranscriptEntry]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(entries) { entry in
                        MessageCardView(entry: entry)
                            .id(entry.id)
                    }
                }
                .padding()
            }
            .background(DesignTokens.backgroundPrimary)
            .onChange(of: entries.count) {
                if let lastEntry = entries.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(lastEntry.id, anchor: .bottom)
                    }
                }
            }
        }
    }
}

// MARK: - Message Card View

struct MessageCardView: View {
    let entry: TranscriptEntry

    private var messageType: MessageType {
        switch entry.type {
        case .user: return .user
        case .assistant: return .assistant
        case .tool: return .tool
        case .system: return .system
        }
    }

    private var borderColor: Color {
        switch messageType {
        case .user: return DesignTokens.userBorder
        case .assistant: return DesignTokens.assistantBorder
        case .tool: return DesignTokens.toolBorder
        case .system: return DesignTokens.systemBorder
        }
    }

    private var labelText: String {
        switch messageType {
        case .user: return "USER"
        case .assistant: return "ASSISTANT"
        case .tool: return "TOOL"
        case .system: return "SYSTEM"
        }
    }

    private var alignment: HorizontalAlignment {
        messageType == .user ? .trailing : .leading
    }

    private var maxWidth: CGFloat {
        messageType == .user ? .infinity : 600
    }

    var body: some View {
        HStack {
            if messageType == .user {
                Spacer(minLength: 60)
            }

            VStack(alignment: .leading, spacing: 8) {
                // Header with label and timestamp
                HStack(spacing: 8) {
                    Text(labelText)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(borderColor)

                    if case .tool(let name, _) = entry.type {
                        ToolBadge(name: name)
                    }

                    Spacer()

                    Text(formatTimestamp(entry.timestamp))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(DesignTokens.textMuted)
                }

                // Content
                contentView
            }
            .padding(12)
            .frame(maxWidth: maxWidth, alignment: .leading)
            .background(DesignTokens.backgroundCard)
            .overlay(
                Rectangle()
                    .fill(borderColor)
                    .frame(width: 3),
                alignment: .leading
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))

            if messageType != .user {
                Spacer(minLength: 60)
            }
        }
    }

    @ViewBuilder
    private var contentView: some View {
        switch entry.type {
        case .user(let text), .assistant(let text), .system(let text):
            Text(text)
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(DesignTokens.textPrimary)
                .textSelection(.enabled)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
        case .tool(_, let target):
            if !target.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("TARGET")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(DesignTokens.textMuted)
                    Text(target)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(DesignTokens.textSecondary)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func formatTimestamp(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Tool Badge

struct ToolBadge: View {
    let name: String

    private var badgeColor: Color {
        switch name.lowercased() {
        case "read": return Color(red: 0.2, green: 0.6, blue: 0.9)
        case "write", "edit": return Color(red: 0.9, green: 0.5, blue: 0.2)
        case "bash": return Color(red: 0.6, green: 0.8, blue: 0.4)
        case "glob", "grep": return Color(red: 0.7, green: 0.5, blue: 0.9)
        default: return DesignTokens.accentYellow
        }
    }

    var body: some View {
        Text(name)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundColor(DesignTokens.backgroundPrimary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(badgeColor)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

// MARK: - Message Type

private enum MessageType {
    case user
    case assistant
    case tool
    case system
}

// MARK: - Raw Terminal View

struct RawTerminalView: View {
    let output: String

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(output)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Color.green.opacity(0.9))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .id("rawOutput")
            }
            .background(Color.black)
            .onChange(of: output.count) {
                withAnimation(.easeOut(duration: 0.1)) {
                    proxy.scrollTo("rawOutput", anchor: .bottom)
                }
            }
        }
    }
}

// MARK: - Input Bar

struct AgentInputBar: View {
    @Binding var text: String
    let isEnabled: Bool
    let isRunning: Bool
    let onSend: () -> Void
    let onInterruptAndSend: () -> Void

    private var canSend: Bool {
        !text.isEmpty && isEnabled
    }

    private var showInterruptMode: Bool {
        isRunning && !text.isEmpty
    }

    var body: some View {
        HStack(spacing: 12) {
            // Text input
            TextField(isRunning ? "Type to interrupt Claude..." : "Enter message...", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(DesignTokens.textPrimary)
                .padding(10)
                .background(DesignTokens.backgroundCard)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(
                            showInterruptMode ? DesignTokens.accentOrange.opacity(0.5) : DesignTokens.textMuted.opacity(0.3),
                            lineWidth: 1
                        )
                )
                .disabled(!isEnabled)
                .onSubmit {
                    if canSend {
                        if isRunning {
                            onInterruptAndSend()
                        } else {
                            onSend()
                        }
                    }
                }

            // Send / Interrupt & Send button
            Button(action: {
                if isRunning {
                    onInterruptAndSend()
                } else {
                    onSend()
                }
            }) {
                if showInterruptMode {
                    // Interrupt & Send mode
                    HStack(spacing: 6) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 11))
                        Text("Send")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundColor(DesignTokens.backgroundPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(DesignTokens.accentOrange)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    // Normal send mode
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 14))
                        .foregroundColor(DesignTokens.backgroundPrimary)
                        .padding(10)
                        .background(canSend ? DesignTokens.accentCyan : DesignTokens.textMuted)
                        .clipShape(Circle())
                }
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .help(showInterruptMode ? "Interrupt Claude and send your message" : "Send message")
            .animation(.easeInOut(duration: 0.15), value: showInterruptMode)
        }
        .padding()
        .background(DesignTokens.backgroundSecondary)
    }
}

// MARK: - Preview

#Preview {
    TranscriptView(
        entries: [
            TranscriptEntry(type: .system("Session started")),
            TranscriptEntry(type: .user("Can you make this game top down please")),
            TranscriptEntry(type: .assistant("I'll help you convert the game to a top-down perspective. Let me first read the current game files to understand the structure.")),
            TranscriptEntry(type: .tool("Read", "src/game/main.ts")),
            TranscriptEntry(type: .tool("Edit", "src/game/player.ts")),
            TranscriptEntry(type: .assistant("I've updated the game to use a top-down perspective. The main changes were:\n\n1. Changed the camera angle\n2. Updated player movement\n3. Adjusted collision detection")),
        ],
        rawOutput: "Raw output here..."
    )
    .frame(width: 700, height: 500)
}
