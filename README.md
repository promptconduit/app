# PromptConduit App

Desktop application for Claude Code terminal management.

## Directory Structure

```
app/
├── macOS/          # Native macOS app (Swift/SwiftUI)
├── docs/           # Documentation
└── .claude/        # Claude Code commands
```

## macOS Native App

The native macOS implementation using Swift, SwiftUI, and SwiftTerm.

### Building

```bash
cd macOS
xcodebuild -project PromptConduit.xcodeproj -scheme PromptConduit -configuration Debug build
```

### Running

```bash
open ~/Library/Developer/Xcode/DerivedData/PromptConduit-*/Build/Products/Debug/PromptConduit.app
```

## Architecture

- **SwiftTerm** for terminal emulation
- **UNUserNotificationCenter** for notifications
- Native PTY via Foundation
