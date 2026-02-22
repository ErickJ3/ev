#!/usr/bin/env bash
set -euo pipefail

REPO="ErickJ3/ev"
INSTALL_DIR="${EV_INSTALL_DIR:-$HOME/.local/bin}"

info() { printf '\033[1;34m%s\033[0m\n' "$*"; }
error() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

detect_platform() {
    local os arch
    os="$(uname -s)"
    arch="$(uname -m)"

    case "$os" in
        Linux)  os="linux" ;;
        FreeBSD) os="freebsd" ;;
        *) error "Unsupported OS: $os. Only Linux and FreeBSD are supported." ;;
    esac

    case "$arch" in
        x86_64|amd64) arch="x86_64" ;;
        aarch64|arm64) arch="aarch64" ;;
        *) error "Unsupported architecture: $arch. Only x86_64 and aarch64 are supported." ;;
    esac

    if [ "$os" = "freebsd" ] && [ "$arch" != "x86_64" ]; then
        error "FreeBSD is only supported on x86_64."
    fi

    ASSET_NAME="ev-${os}-${arch}"
}

get_latest_version() {
    local url="https://api.github.com/repos/${REPO}/releases/latest"
    if command -v curl >/dev/null 2>&1; then
        LATEST_TAG=$(curl -fsSL "$url" | grep '"tag_name"' | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')
    elif command -v wget >/dev/null 2>&1; then
        LATEST_TAG=$(wget -qO- "$url" | grep '"tag_name"' | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')
    else
        error "Neither curl nor wget found. Please install one of them."
    fi

    [ -z "$LATEST_TAG" ] && error "Could not determine latest release. Check https://github.com/${REPO}/releases"
}

download() {
    local url="https://github.com/${REPO}/releases/download/${LATEST_TAG}/${ASSET_NAME}"
    info "Downloading ev ${LATEST_TAG} (${ASSET_NAME})..."

    mkdir -p "$INSTALL_DIR"

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -o "${INSTALL_DIR}/ev" "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "${INSTALL_DIR}/ev" "$url"
    fi

    chmod +x "${INSTALL_DIR}/ev"
}

check_path() {
    case ":${PATH}:" in
        *":${INSTALL_DIR}:"*) ;;
        *)
            printf '\n'
            info "Add ${INSTALL_DIR} to your PATH:"
            printf '\n'
            printf '  # Add to your shell config (~/.bashrc, ~/.zshrc, etc.):\n'
            printf '  export PATH="%s:$PATH"\n' "$INSTALL_DIR"
            printf '\n'
            ;;
    esac
}

main() {
    info "Installing ev..."
    detect_platform
    get_latest_version
    download
    check_path
    info "ev ${LATEST_TAG} installed to ${INSTALL_DIR}/ev"
}

main
