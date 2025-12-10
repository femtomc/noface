#!/bin/bash
# noface installer
#
# Usage: curl -fsSL https://raw.githubusercontent.com/femtomc/noface/main/install.sh | bash
#
# This script installs noface and its dependencies:
# - beads (issue tracker)
# - claude (implementation agent)
# - codex (review agent)
# - gh (GitHub CLI)
# - jq (JSON processor)

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Detect OS
OS="$(uname -s)"
ARCH="$(uname -m)"

log_info "Installing noface on $OS ($ARCH)"
echo ""

# Check for Zig
check_zig() {
    if command -v zig &> /dev/null; then
        log_success "zig found: $(zig version)"
        return 0
    else
        log_warn "zig not found"
        return 1
    fi
}

# Install Zig
install_zig() {
    log_info "Installing Zig..."

    case "$OS" in
        Darwin)
            if command -v brew &> /dev/null; then
                brew install zig
            else
                log_error "Homebrew not found. Install from: https://ziglang.org/download/"
                exit 1
            fi
            ;;
        Linux)
            # Try package managers
            if command -v apt-get &> /dev/null; then
                sudo apt-get update && sudo apt-get install -y zig
            elif command -v dnf &> /dev/null; then
                sudo dnf install -y zig
            elif command -v pacman &> /dev/null; then
                sudo pacman -S zig
            else
                log_error "No supported package manager found. Install from: https://ziglang.org/download/"
                exit 1
            fi
            ;;
        *)
            log_error "Unsupported OS: $OS. Install Zig manually from: https://ziglang.org/download/"
            exit 1
            ;;
    esac

    log_success "Zig installed"
}

# Check for beads
check_beads() {
    if command -v bd &> /dev/null; then
        log_success "beads (bd) found"
        return 0
    else
        log_warn "beads (bd) not found"
        return 1
    fi
}

# Install beads
install_beads() {
    log_info "Installing beads..."
    curl -fsSL https://raw.githubusercontent.com/steveyegge/beads/main/scripts/install.sh | bash
    log_success "beads installed"
}

# Check for Claude CLI
check_claude() {
    if command -v claude &> /dev/null; then
        log_success "claude found"
        return 0
    else
        log_warn "claude not found"
        return 1
    fi
}

# Install Claude CLI
install_claude() {
    log_info "Installing Claude CLI..."

    case "$OS" in
        Darwin)
            if command -v brew &> /dev/null; then
                brew install claude
            else
                npm install -g @anthropic-ai/claude-code
            fi
            ;;
        Linux)
            npm install -g @anthropic-ai/claude-code
            ;;
        *)
            log_error "Unsupported OS. Install Claude CLI from: https://github.com/anthropics/claude-code"
            exit 1
            ;;
    esac

    log_success "Claude CLI installed"
}

# Check for Codex CLI
check_codex() {
    if command -v codex &> /dev/null; then
        log_success "codex found"
        return 0
    else
        log_warn "codex not found"
        return 1
    fi
}

# Install Codex CLI
install_codex() {
    log_info "Installing Codex CLI..."

    case "$OS" in
        Darwin)
            if command -v brew &> /dev/null; then
                brew install codex
            else
                npm install -g @openai/codex
            fi
            ;;
        Linux)
            npm install -g @openai/codex
            ;;
        *)
            log_error "Unsupported OS. Install Codex from: https://github.com/openai/codex"
            exit 1
            ;;
    esac

    log_success "Codex CLI installed"
}

# Check for GitHub CLI
check_gh() {
    if command -v gh &> /dev/null; then
        log_success "gh found"
        return 0
    else
        log_warn "gh not found"
        return 1
    fi
}

# Install GitHub CLI
install_gh() {
    log_info "Installing GitHub CLI..."

    case "$OS" in
        Darwin)
            brew install gh
            ;;
        Linux)
            if command -v apt-get &> /dev/null; then
                curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
                echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
                sudo apt-get update && sudo apt-get install gh
            elif command -v dnf &> /dev/null; then
                sudo dnf install gh
            else
                log_error "Install gh from: https://cli.github.com/"
                exit 1
            fi
            ;;
        *)
            log_error "Install gh from: https://cli.github.com/"
            exit 1
            ;;
    esac

    log_success "GitHub CLI installed"
}

# Check for jq
check_jq() {
    if command -v jq &> /dev/null; then
        log_success "jq found"
        return 0
    else
        log_warn "jq not found"
        return 1
    fi
}

# Install jq
install_jq() {
    log_info "Installing jq..."

    case "$OS" in
        Darwin)
            brew install jq
            ;;
        Linux)
            if command -v apt-get &> /dev/null; then
                sudo apt-get install -y jq
            elif command -v dnf &> /dev/null; then
                sudo dnf install -y jq
            elif command -v pacman &> /dev/null; then
                sudo pacman -S jq
            fi
            ;;
        *)
            log_error "Install jq from: https://stedolan.github.io/jq/"
            exit 1
            ;;
    esac

    log_success "jq installed"
}

# Install noface itself
install_noface() {
    log_info "Installing noface..."

    INSTALL_DIR="${HOME}/.local/bin"
    mkdir -p "$INSTALL_DIR"

    # Clone and build
    TEMP_DIR=$(mktemp -d)
    cd "$TEMP_DIR"

    git clone --depth 1 https://github.com/femtomc/noface.git
    cd noface

    zig build -Doptimize=ReleaseFast

    cp zig-out/bin/noface "$INSTALL_DIR/"

    # Clean up
    cd /
    rm -rf "$TEMP_DIR"

    # Add to PATH if needed
    if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
        log_warn "Add $INSTALL_DIR to your PATH:"
        echo ""
        echo "  export PATH=\"\$PATH:$INSTALL_DIR\""
        echo ""
    fi

    log_success "noface installed to $INSTALL_DIR/noface"
}

# Main installation flow
echo "============================================"
echo "         noface installer"
echo "============================================"
echo ""

# Check and install dependencies
log_info "Checking dependencies..."
echo ""

check_zig || install_zig
check_beads || install_beads
check_claude || install_claude
check_codex || install_codex
check_gh || install_gh
check_jq || install_jq

echo ""

# Install noface
install_noface

echo ""
echo "============================================"
log_success "noface installation complete!"
echo "============================================"
echo ""
echo "Quick start:"
echo "  1. cd into your project directory"
echo "  2. Run: bd init (if not already initialized)"
echo "  3. Run: noface --help"
echo ""
echo "Configuration:"
echo "  Create .noface.toml in your project root."
echo "  See: https://github.com/femtomc/noface"
echo ""
