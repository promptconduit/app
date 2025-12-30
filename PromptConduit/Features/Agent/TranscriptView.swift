import SwiftUI

/// Displays the conversation transcript
struct TranscriptView: View {
    let entries: [TranscriptEntry]
    let rawOutput: String

    @State private var showRawOutput = false

    var body: some View {
        VStack(spacing: 0) {
            // Toggle for raw output
            HStack {
                Spacer()
                Toggle("Show Raw Output", isOn: $showRawOutput)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .padding(.horizontal)
            .padding(.vertical, 4)
            .background(Color(NSColor.controlBackgroundColor))

            // Content
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if showRawOutput {
                            RawOutputView(output: rawOutput)
                        } else {
                            ForEach(entries) { entry in
                                TranscriptEntryView(entry: entry)
                                    .id(entry.id)
                            }
                        }
                    }
                    .padding()
                }
                .onChange(of: entries.count) { _ in
                    // Scroll to bottom on new entry
                    if let lastEntry = entries.last {
                        withAnimation {
                            proxy.scrollTo(lastEntry.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Entry View

struct TranscriptEntryView: View {
    let entry: TranscriptEntry

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Icon
            entryIcon
                .frame(width: 24)

            // Content
            VStack(alignment: .leading, spacing: 4) {
                Text(entryLabel)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text(entry.content)
                    .font(.body)
                    .textSelection(.enabled)
                    .padding(8)
                    .background(entryBackground)
                    .cornerRadius(8)
            }
        }
    }

    @ViewBuilder
    private var entryIcon: some View {
        switch entry.type {
        case .user:
            Image(systemName: "person.fill")
                .foregroundColor(.blue)
        case .assistant:
            Image(systemName: "cpu")
                .foregroundColor(.purple)
        case .tool:
            Image(systemName: "wrench.fill")
                .foregroundColor(.orange)
        case .system:
            Image(systemName: "gear")
                .foregroundColor(.gray)
        }
    }

    private var entryLabel: String {
        let time = entry.timestamp.formatted(date: .omitted, time: .shortened)
        switch entry.type {
        case .user: return "You • \(time)"
        case .assistant: return "Claude • \(time)"
        case .tool: return "Tool • \(time)"
        case .system: return "System • \(time)"
        }
    }

    private var entryBackground: Color {
        switch entry.type {
        case .user:
            return Color.blue.opacity(0.1)
        case .assistant:
            return Color.purple.opacity(0.1)
        case .tool:
            return Color.orange.opacity(0.1)
        case .system:
            return Color.gray.opacity(0.1)
        }
    }
}

// MARK: - Raw Output View

struct RawOutputView: View {
    let output: String

    var body: some View {
        Text(output)
            .font(.system(.body, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color(NSColor.textBackgroundColor))
            .cornerRadius(8)
    }
}

// MARK: - Input Bar

struct AgentInputBar: View {
    @Binding var text: String
    let isEnabled: Bool
    let onSend: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            TextField("Enter message...", text: $text)
                .textFieldStyle(.roundedBorder)
                .disabled(!isEnabled)
                .onSubmit {
                    if !text.isEmpty && isEnabled {
                        onSend()
                    }
                }

            Button(action: onSend) {
                Image(systemName: "paperplane.fill")
            }
            .disabled(text.isEmpty || !isEnabled)
            .keyboardShortcut(.return, modifiers: [])
        }
        .padding()
    }
}

// MARK: - Preview

#Preview {
    TranscriptView(
        entries: [
            TranscriptEntry(type: .user("Add google analytics to this website")),
            TranscriptEntry(type: .assistant("I'll help you add Google Analytics. First, let me check your project structure...")),
            TranscriptEntry(type: .tool("Read", "src/app/layout.tsx")),
            TranscriptEntry(type: .assistant("I found your layout file. I'll add the Google Analytics script.")),
        ],
        rawOutput: "Sample raw output..."
    )
}
