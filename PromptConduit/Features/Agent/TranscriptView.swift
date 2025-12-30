import SwiftUI

/// Displays the conversation transcript with clean terminal-like output
struct TranscriptView: View {
    let entries: [TranscriptEntry]
    let rawOutput: String

    @State private var showRawOutput = false

    var body: some View {
        VStack(spacing: 0) {
            // Toggle for output mode
            HStack {
                Spacer()
                Toggle("Show Raw Output", isOn: $showRawOutput)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // Content area
            if showRawOutput {
                RawTerminalView(output: rawOutput)
            } else {
                CleanOutputView(output: rawOutput)
            }
        }
    }
}

// MARK: - Clean Output View (Stripped ANSI)

struct CleanOutputView: View {
    let output: String

    private var cleanedOutput: String {
        OutputParser.stripANSI(output)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var outputLines: [OutputLine] {
        cleanedOutput
            .components(separatedBy: .newlines)
            .enumerated()
            .map { OutputLine(id: $0.offset, text: $0.element) }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(outputLines) { line in
                        OutputLineView(line: line)
                            .id(line.id)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(NSColor.textBackgroundColor))
            .onChange(of: outputLines.count) { _ in
                if let lastLine = outputLines.last {
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo(lastLine.id, anchor: .bottom)
                    }
                }
            }
        }
    }
}

struct OutputLine: Identifiable {
    let id: Int
    let text: String
}

struct OutputLineView: View {
    let line: OutputLine

    var body: some View {
        Group {
            if isPromptLine {
                HStack(spacing: 4) {
                    Text("›")
                        .font(.system(.body, design: .monospaced))
                        .fontWeight(.bold)
                        .foregroundColor(.accentColor)
                    Text(promptText)
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.primary)
                }
            } else if isClaudeHeader {
                Text(line.text)
                    .font(.system(.body, design: .monospaced))
                    .fontWeight(.semibold)
                    .foregroundColor(.purple)
            } else if isToolLine {
                HStack(spacing: 4) {
                    Image(systemName: "wrench.fill")
                        .font(.caption)
                        .foregroundColor(.orange)
                    Text(line.text)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            } else if isSeparatorLine {
                Divider()
                    .padding(.vertical, 4)
            } else if !line.text.trimmingCharacters(in: .whitespaces).isEmpty {
                Text(line.text)
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.primary)
                    .textSelection(.enabled)
            }
        }
    }

    private var isPromptLine: Bool {
        let trimmed = line.text.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix(">") || trimmed.hasPrefix("❯")
    }

    private var promptText: String {
        let trimmed = line.text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("> ") {
            return String(trimmed.dropFirst(2))
        } else if trimmed.hasPrefix("❯ ") {
            return String(trimmed.dropFirst(2))
        }
        return trimmed
    }

    private var isClaudeHeader: Bool {
        line.text.contains("Claude Code") || line.text.contains("Welcome")
    }

    private var isToolLine: Bool {
        line.text.contains("[Tool:") || line.text.contains("Reading") ||
        line.text.contains("Writing") || line.text.contains("Editing")
    }

    private var isSeparatorLine: Bool {
        let trimmed = line.text.trimmingCharacters(in: .whitespaces)
        return trimmed.allSatisfy { $0 == "─" || $0 == "-" || $0 == "═" } && trimmed.count > 10
    }
}

// MARK: - Raw Terminal View

struct RawTerminalView: View {
    let output: String

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(output)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.green)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .id("rawOutput")
            }
            .background(Color.black)
            .onChange(of: output.count) { _ in
                withAnimation {
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
            .buttonStyle(.borderedProminent)
            .disabled(text.isEmpty || !isEnabled)
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
    }
}

// MARK: - Preview

#Preview {
    TranscriptView(
        entries: [],
        rawOutput: """
        ╭─── Claude Code v2.0.75 ──────────────────────────────╮
        │             Welcome back Scott Havird!               │
        │                    * ▝▜█████▛▘ *                     │
        │  Opus 4.5 · Claude Max · scott@example.com           │
        ╰──────────────────────────────────────────────────────╯

        > What would you like me to help with today?

        [Tool: Read] src/app/layout.tsx
        I've read the file. Here's what I found...
        """
    )
}
