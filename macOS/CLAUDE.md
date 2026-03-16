# PromptConduit macOS App

Native Swift/SwiftUI menu bar application for managing Claude Code sessions.

## Prerequisites

- **Zig** — required to build GhosttyKit (the terminal emulator framework)
  ```bash
  brew install zig
  ```

## Build & Run

```bash
cd app

# First-time setup: build GhosttyKit.xcframework from the ghostty submodule
./scripts/setup.sh

# Generate Xcode project and build
cd macOS
xcodegen generate
xcodebuild -scheme PromptConduit -configuration Debug build

# Run the built app
open ~/Library/Developer/Xcode/DerivedData/PromptConduit-*/Build/Products/Debug/PromptConduit.app

# Run tests
xcodebuild test -scheme PromptConduit -destination 'platform=macOS'
```

**Important:** Swift code changes require a full rebuild and app restart. Hot reload is not supported.

### Ghostty Submodule

The app uses [Ghostty](https://github.com/ghostty-org/ghostty) (via our fork at `promptconduit/ghostty`) for GPU-accelerated terminal emulation. The submodule lives at `app/ghostty/` and is built into `GhosttyKit.xcframework` by `scripts/setup.sh`.

- The xcframework is cached at `~/.cache/promptconduit/ghosttykit/` keyed by commit SHA
- `macOS/Frameworks/` is gitignored (built artifact)
- The bridging header at `PromptConduit/PromptConduit-Bridging-Header.h` imports `ghostty.h`

## Sessions Dashboard (Cmd+Shift+D)

The dashboard provides four tabs:

| Tab | Description |
|-----|-------------|
| **Sessions** | Browse Claude Code sessions grouped by repository |
| **Semantic** | Natural language search across all transcripts using embeddings |
| **Patterns** | Detect repeated prompts across sessions, save as reusable skills |
| **Skills** | Browse, edit, and delete Claude Code skills (slash commands) |

### Skills Management

Skills are loaded from two locations:
- **Global:** `~/.claude/commands/` - Available in all projects
- **Project:** `[repo]/.claude/commands/` - Project-specific, can be committed to git

Skills are markdown files with YAML frontmatter:
```markdown
---
description: What this skill does
allowed-tools: tool1,tool2
argument-hint: <argument description>
---

The prompt content goes here.
```

## Project Structure

```
PromptConduit/
├── Features/
│   ├── Dashboard/
│   │   ├── SessionDashboardView.swift    # Main dashboard with 4 tabs
│   │   └── SaveSkillSheet.swift          # Save pattern as skill UI
│   └── Terminal/
│       ├── Ghostty/
│       │   ├── GhosttyApp.swift          # Singleton ghostty_app_t manager
│       │   ├── GhosttyConfig.swift       # Terminal configuration
│       │   └── GhosttyTerminalView.swift # NSView wrapping ghostty_surface_t
│       ├── EmbeddedTerminalView.swift    # SwiftUI NSViewRepresentable wrapper
│       ├── TerminalPanel.swift           # NSPanel/NSWindow with copy/paste
│       ├── MultiTerminalGridView.swift   # Multi-terminal grid layout
│       └── TerminalCellView.swift        # Individual grid cell
├── Services/
│   ├── ClaudeSessionDiscovery.swift      # Session file monitoring
│   ├── TerminalSessionManager.swift      # Terminal session lifecycle
│   ├── TranscriptIndexService.swift      # Semantic search indexing
│   ├── PatternDetectionService.swift     # Pattern detection
│   ├── PatternSkillService.swift         # Pattern → skill conversion
│   └── SlashCommandsService.swift        # Skill loading/management
└── Models/
    └── MultiSessionGroup.swift           # Multi-session group model
```
