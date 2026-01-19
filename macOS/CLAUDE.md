# PromptConduit macOS App

Native Swift/SwiftUI menu bar application for managing Claude Code sessions.

## Build & Run

```bash
cd app/macOS

# Build
xcodebuild -scheme PromptConduit -configuration Debug build

# Run the built app
open ~/Library/Developer/Xcode/DerivedData/PromptConduit-*/Build/Products/Debug/PromptConduit.app

# Run tests
xcodebuild test -scheme PromptConduit -destination 'platform=macOS'
```

**Important:** Swift code changes require a full rebuild and app restart. Hot reload is not supported.

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
│   └── Dashboard/
│       ├── SessionDashboardView.swift    # Main dashboard with 4 tabs
│       └── SaveSkillSheet.swift          # Save pattern as skill UI
├── Services/
│   ├── ClaudeSessionDiscovery.swift      # Session file monitoring
│   ├── TranscriptIndexService.swift      # Semantic search indexing
│   ├── PatternDetectionService.swift     # Pattern detection
│   ├── PatternSkillService.swift         # Pattern → skill conversion
│   └── SlashCommandsService.swift        # Skill loading/management
└── Core/
    └── PTY/                              # Terminal emulation
```
