import SwiftUI

/// Sheet view for saving a detected pattern as a Claude Code skill
struct SaveSkillSheet: View {
    let pattern: DetectedPattern
    @Binding var isPresented: Bool
    var onSave: ((String) -> Void)?  // Called with saved path on success

    // MARK: - State

    @State private var skillName: String = ""
    @State private var description: String = ""
    @State private var saveLocation: SkillSaveLocation = .global
    @State private var showOverwriteAlert = false
    @State private var errorMessage: String?
    @State private var isSaving = false

    private let skillService = PatternSkillService()

    // MARK: - Computed Properties

    /// Primary repo path from pattern (for project-level save)
    private var primaryRepoPath: String? {
        skillService.primaryRepoPath(from: pattern)
    }

    /// Resolved file path where skill will be saved
    private var resolvedPath: String {
        skillService.skillPath(
            name: skillName.isEmpty ? "skill-name" : skillService.sanitizeSkillName(skillName),
            location: saveLocation,
            projectPath: primaryRepoPath
        )
    }

    /// Display-friendly path (with ~ for home directory)
    private var displayPath: String {
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        return resolvedPath.replacingOccurrences(of: homePath, with: "~")
    }

    /// Preview of the markdown that will be generated
    private var previewMarkdown: String {
        skillService.generateSkillMarkdown(
            pattern: pattern,
            name: skillName,
            description: description
        )
    }

    /// Whether the save button should be enabled
    private var canSave: Bool {
        !skillName.isEmpty && !isSaving
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Image(systemName: "square.and.arrow.down")
                    .foregroundColor(.accentColor)
                Text("Save as Skill")
                    .font(.headline)
                Spacer()
            }

            Divider()

            // Pattern preview
            GroupBox {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Pattern")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(pattern.preview)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(2)
                }
            }

            // Name input
            VStack(alignment: .leading, spacing: 4) {
                Text("Skill Name")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("my-skill-name", text: $skillName)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: skillName) { _, newValue in
                        // Auto-sanitize on change
                        let sanitized = skillService.sanitizeSkillName(newValue)
                        if sanitized != newValue && !newValue.isEmpty {
                            // Only update if different to avoid cursor jump
                            skillName = sanitized
                        }
                    }
                Text("Will be invoked as /\(skillName.isEmpty ? "skill-name" : skillName)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            // Description input
            VStack(alignment: .leading, spacing: 4) {
                Text("Description")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("What this skill does", text: $description)
                    .textFieldStyle(.roundedBorder)
            }

            // Location picker
            VStack(alignment: .leading, spacing: 4) {
                Text("Save Location")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Picker("", selection: $saveLocation) {
                    ForEach(SkillSaveLocation.allCases) { location in
                        Text(location.rawValue).tag(location)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Text(saveLocation.description)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            // Show resolved path
            HStack {
                Image(systemName: "folder")
                    .foregroundColor(.secondary)
                Text(displayPath)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            // Preview
            GroupBox {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Preview")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    ScrollView {
                        Text(previewMarkdown)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                }
            }

            // Error message
            if let error = errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }

            Divider()

            // Actions
            HStack {
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.escape)

                Spacer()

                Button(action: saveSkill) {
                    if isSaving {
                        ProgressView()
                            .scaleEffect(0.7)
                    } else {
                        Text("Save Skill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
                .keyboardShortcut(.return)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear(perform: populateDefaults)
        .alert("Skill Already Exists", isPresented: $showOverwriteAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Overwrite", role: .destructive) {
                performSave(overwrite: true)
            }
        } message: {
            Text("A skill named '\(skillName)' already exists at this location. Do you want to overwrite it?")
        }
    }

    // MARK: - Actions

    private func populateDefaults() {
        skillName = skillService.suggestSkillName(from: pattern)
        description = skillService.suggestDescription(from: pattern)
        saveLocation = skillService.suggestLocation(from: pattern)
    }

    private func saveSkill() {
        errorMessage = nil

        // Check if file exists
        if skillService.skillExists(name: skillName, location: saveLocation, projectPath: primaryRepoPath) {
            showOverwriteAlert = true
            return
        }

        performSave(overwrite: false)
    }

    private func performSave(overwrite: Bool) {
        isSaving = true
        errorMessage = nil

        let result = skillService.saveSkill(
            pattern: pattern,
            name: skillName,
            description: description,
            location: saveLocation,
            projectPath: primaryRepoPath,
            overwrite: overwrite
        )

        isSaving = false

        switch result {
        case .success(let path):
            onSave?(path)
            isPresented = false

        case .fileExists(let path):
            // Shouldn't happen with overwrite check, but handle anyway
            errorMessage = "File already exists: \(path)"

        case .directoryCreationFailed(let error):
            errorMessage = "Failed to create directory: \(error)"

        case .writeFailed(let error):
            errorMessage = "Failed to write file: \(error)"
        }
    }
}

// MARK: - Preview

#Preview {
    let mockMessage = IndexedMessage(
        id: 1,
        sessionId: "session-1",
        messageUuid: "uuid-1",
        messageType: "user",
        content: "Help me fix this authentication bug in the login flow",
        embedding: [],
        repoPath: "/Users/test/myproject",
        timestamp: Date()
    )

    let mockPattern = DetectedPattern(
        id: UUID(),
        representative: mockMessage,
        members: [
            PatternMember(id: 1, message: mockMessage, similarityToRepresentative: 1.0)
        ],
        score: PatternScore(
            count: 5,
            sessionDiversity: 3,
            repoDiversity: 1,
            avgSimilarity: 0.85,
            mostRecent: Date()
        )
    )

    return SaveSkillSheet(
        pattern: mockPattern,
        isPresented: .constant(true)
    )
}
