import SwiftUI
import SwiftTerm
import UniformTypeIdentifiers

// MARK: - Design Tokens

private enum CellTokens {
    static let backgroundPrimary = Color(red: 0.06, green: 0.09, blue: 0.16)
    static let backgroundHeader = Color(red: 0.12, green: 0.16, blue: 0.24)
    static let backgroundHeaderWaiting = Color(red: 0.3, green: 0.25, blue: 0.1)
    static let textPrimary = Color(red: 0.93, green: 0.94, blue: 0.96)
    static let textSecondary = Color(red: 0.58, green: 0.63, blue: 0.73)
    static let statusRunning = Color.green
    static let statusWaiting = Color.yellow
    static let statusTerminated = Color.red
    static let borderWaiting = Color.yellow
    static let borderFocused = Color(red: 0.0, green: 0.83, blue: 0.67)  // Cyan
}

/// A single terminal cell in the multi-terminal grid
struct TerminalCellView: View {
    let sessionId: UUID
    let repoName: String
    let workingDirectory: String
    let isFocused: Bool
    let onFocus: () -> Void
    let onTerminated: () -> Void
    let onTerminalReady: (LocalProcessTerminalView) -> Void
    var onClaudeReady: (() -> Void)? = nil

    @ObservedObject private var terminalManager = TerminalSessionManager.shared
    @State private var isTerminated = false
    @State private var isDragOver = false
    @State private var terminalView: LocalProcessTerminalView? = nil

    private let imageService = ImageAttachmentService.shared

    /// Get the current session from the manager
    private var session: TerminalSessionInfo? {
        terminalManager.session(for: sessionId)
    }

    /// Whether the session is waiting for input
    private var isWaiting: Bool {
        session?.isWaiting ?? false
    }

    var body: some View {
        VStack(spacing: 0) {
            // Mini header with status
            cellHeader

            // Terminal with drag & drop
            ZStack {
                EmbeddedTerminalView(
                    workingDirectory: workingDirectory,
                    onTerminated: {
                        isTerminated = true
                        onTerminated()
                    },
                    onTerminalReady: { terminal in
                        terminalView = terminal  // Store locally for drag & drop
                        onTerminalReady(terminal)
                    },
                    onOutputReceived: { text in
                        // Feed output to the terminal session manager for waiting state detection
                        terminalManager.processOutput(sessionId, text: text)
                    },
                    onClaudeReady: {
                        onClaudeReady?()
                    }
                )
                .background(CellTokens.backgroundPrimary)

                // Drag overlay
                if isDragOver {
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.cyan, lineWidth: 2)
                        .background(Color.cyan.opacity(0.1))
                }
            }
            .onDrop(of: [.image, .fileURL], isTargeted: $isDragOver) { providers in
                handleDrop(providers: providers)
            }
        }
        .background(CellTokens.backgroundPrimary)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(borderColor, lineWidth: borderWidth)
        )
        .cornerRadius(4)
        .onTapGesture {
            onFocus()
        }
    }

    // MARK: - Header

    private var cellHeader: some View {
        HStack(spacing: 8) {
            // Status indicator
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .overlay(
                    // Pulsing animation when waiting
                    Circle()
                        .stroke(statusColor.opacity(0.5), lineWidth: 2)
                        .scaleEffect(isWaiting ? 1.5 : 1.0)
                        .opacity(isWaiting ? 0 : 1)
                        .animation(
                            isWaiting ?
                                Animation.easeOut(duration: 1.0).repeatForever(autoreverses: false) :
                                .default,
                            value: isWaiting
                        )
                )

            // Repository name
            Text(repoName)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(CellTokens.textPrimary)
                .lineLimit(1)

            Spacer()

            // Status text
            Text(statusText)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(statusColor)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(headerBackgroundColor)
    }

    // MARK: - Status Helpers

    private var statusColor: SwiftUI.Color {
        if isTerminated {
            return CellTokens.statusTerminated
        } else if isWaiting {
            return CellTokens.statusWaiting
        } else {
            return CellTokens.statusRunning
        }
    }

    private var statusText: String {
        if isTerminated {
            return "Terminated"
        } else if isWaiting {
            return "Waiting"
        } else {
            return "Running"
        }
    }

    private var headerBackgroundColor: SwiftUI.Color {
        if isWaiting {
            return CellTokens.backgroundHeaderWaiting
        } else {
            return CellTokens.backgroundHeader
        }
    }

    private var borderColor: SwiftUI.Color {
        if isWaiting {
            return CellTokens.borderWaiting
        } else if isFocused {
            return CellTokens.borderFocused
        } else {
            return SwiftUI.Color.clear
        }
    }

    private var borderWidth: CGFloat {
        if isWaiting || isFocused {
            return 2
        } else {
            return 0
        }
    }

    // MARK: - Drag & Drop

    /// Handles file drop from drag & drop
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        var handled = false

        for provider in providers {
            // Try to load as file URL first
            if provider.hasItemConformingToTypeIdentifier("public.file-url") {
                provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                    if let data = item as? Data,
                       let url = URL(dataRepresentation: data, relativeTo: nil),
                       isImageFile(url) {
                        DispatchQueue.main.async {
                            attachImageFile(url)
                        }
                    }
                }
                handled = true
            }
            // Try to load as image data
            else if provider.hasItemConformingToTypeIdentifier("public.image") {
                provider.loadDataRepresentation(forTypeIdentifier: "public.image") { data, _ in
                    if let data = data {
                        DispatchQueue.main.async {
                            attachImageData(data)
                        }
                    }
                }
                handled = true
            }
        }

        return handled
    }

    /// Attaches an image file by copying it to temp storage
    private func attachImageFile(_ url: URL) {
        if let savedURL = imageService.copyImageFile(url) {
            insertIntoTerminal(savedURL.path)
        }
    }

    /// Attaches image data by saving to temp storage
    private func attachImageData(_ data: Data) {
        if let savedURL = imageService.saveImageData(data, fileExtension: "png") {
            insertIntoTerminal(savedURL.path)
        }
    }

    /// Inserts the image path into the terminal input
    private func insertIntoTerminal(_ path: String) {
        let textToInsert = "@\(path) "
        terminalView?.send(txt: textToInsert)
    }

    /// Checks if a URL points to an image file
    private func isImageFile(_ url: URL) -> Bool {
        let imageExtensions = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "tif", "heic"]
        return imageExtensions.contains(url.pathExtension.lowercased())
    }
}

// MARK: - Preview

#Preview {
    HStack(spacing: 4) {
        TerminalCellView(
            sessionId: UUID(),
            repoName: "my-project",
            workingDirectory: "/tmp",
            isFocused: false,
            onFocus: {},
            onTerminated: {},
            onTerminalReady: { _ in }
        )
        .frame(width: 400, height: 300)

        TerminalCellView(
            sessionId: UUID(),
            repoName: "another-project",
            workingDirectory: "/tmp",
            isFocused: true,
            onFocus: {},
            onTerminated: {},
            onTerminalReady: { _ in }
        )
        .frame(width: 400, height: 300)
    }
    .padding()
    .background(Color.black)
}
