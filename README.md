# PromptConduit App

Desktop application for Claude Code terminal management.

## Directory Structure

```
app/
├── macOS/          # Native macOS app (Swift/SwiftUI) - Reference implementation
├── tauri/          # Cross-platform app (Rust + React) - macOS, Windows, Linux
├── docs/           # Documentation
└── .claude/        # Claude Code commands
```

## macOS Native App

The original native macOS implementation using Swift, SwiftUI, and SwiftTerm.

### Building

```bash
cd macOS
xcodebuild -project PromptConduit.xcodeproj -scheme PromptConduit -configuration Debug build
```

### Running

```bash
open ~/Library/Developer/Xcode/DerivedData/PromptConduit-*/Build/Products/Debug/PromptConduit.app
```

## Tauri Cross-Platform App

Cross-platform implementation supporting macOS, Windows, and Linux using Tauri (Rust + React).

### Prerequisites

- [Rust](https://rustup.rs/) (latest stable)
- [Node.js](https://nodejs.org/) (v18+)
- Platform-specific requirements:
  - **macOS**: Xcode Command Line Tools
  - **Windows**: Visual Studio Build Tools, WebView2
  - **Linux**: webkit2gtk, build-essential

### Development

```bash
cd tauri
npm install
npm run tauri dev
```

### Building for Production

```bash
cd tauri
npm run tauri build
```

The built application will be in `tauri/src-tauri/target/release/bundle/`.

## Architecture

### macOS Native
- **SwiftTerm** for terminal emulation
- **UNUserNotificationCenter** for notifications
- Native PTY via Foundation

### Tauri Cross-Platform
- **portable-pty** (Rust) for cross-platform PTY
- **xterm.js** for terminal UI
- **tauri-plugin-notification** for native notifications
- React + TypeScript frontend
