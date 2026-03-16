#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
GHOSTTY_DIR="$ROOT_DIR/ghostty"
FRAMEWORK_DIR="$ROOT_DIR/macOS/Frameworks"
CACHE_DIR="$HOME/.cache/promptconduit/ghosttykit"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# Check for Zig
check_zig() {
    if ! command -v zig &>/dev/null; then
        error "Zig is required but not found. Install it with: brew install zig"
    fi
    info "Zig version: $(zig version)"
}

# Initialize git submodules
init_submodules() {
    info "Initializing git submodules..."
    cd "$ROOT_DIR"
    git submodule update --init --recursive
}

# Compute SHA of the ghostty submodule commit
ghostty_sha() {
    cd "$ROOT_DIR"
    git submodule status ghostty | awk '{print $1}' | tr -d '+-'
}

# Build GhosttyKit.xcframework
build_ghosttykit() {
    local sha
    sha="$(ghostty_sha)"
    local cached="$CACHE_DIR/$sha/GhosttyKit.xcframework"

    if [ -d "$cached" ]; then
        info "Using cached GhosttyKit.xcframework (SHA: ${sha:0:12})"
    else
        info "Building GhosttyKit.xcframework (SHA: ${sha:0:12})..."
        cd "$GHOSTTY_DIR"

        zig build -Demit-xcframework=true -Dxcframework-target=universal

        mkdir -p "$CACHE_DIR/$sha"
        cp -R zig-out/GhosttyKit.xcframework "$CACHE_DIR/$sha/"
        info "Cached build at $CACHE_DIR/$sha/"
    fi

    # Copy to Frameworks directory
    mkdir -p "$FRAMEWORK_DIR"
    rm -rf "$FRAMEWORK_DIR/GhosttyKit.xcframework"
    cp -R "$CACHE_DIR/$sha/GhosttyKit.xcframework" "$FRAMEWORK_DIR/"
    info "Installed GhosttyKit.xcframework to $FRAMEWORK_DIR/"
}

# Copy the Ghostty C header for the bridging header
copy_header() {
    local header_src="$GHOSTTY_DIR/include/ghostty.h"
    local header_dst="$FRAMEWORK_DIR/ghostty.h"

    if [ ! -f "$header_src" ]; then
        # Try the xcframework location
        header_src="$FRAMEWORK_DIR/GhosttyKit.xcframework/macos-arm64_x86_64/GhosttyKit.framework/Headers/ghostty.h"
    fi

    if [ -f "$header_src" ]; then
        cp "$header_src" "$header_dst"
        info "Copied ghostty.h to $FRAMEWORK_DIR/"
    else
        warn "ghostty.h not found - bridging header may not work until framework is built"
    fi
}

# Main
main() {
    info "PromptConduit macOS App - Setup"
    info "================================"

    check_zig
    init_submodules
    build_ghosttykit
    copy_header

    info ""
    info "Setup complete! Next steps:"
    info "  cd macOS && xcodegen generate && xcodebuild -scheme PromptConduit -configuration Debug build"
}

main "$@"
