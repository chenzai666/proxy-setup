#!/usr/bin/env bash
# Dispatch to the platform-specific Bash proxy setup script.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OS_NAME="$(uname -s 2>/dev/null || echo unknown)"
REMOTE_BASE_URL="${PROXY_SETUP_REMOTE_BASE_URL:-https://raw.githubusercontent.com/chenzai666/proxy-setup/master}"

run_platform_script() {
    local script_name=$1
    local local_script="$SCRIPT_DIR/$script_name"

    if [[ -f "$local_script" ]]; then
        exec bash "$local_script" "$@"
    fi

    local tmp_script
    tmp_script="$(mktemp "/tmp/${script_name}.XXXXXX")"
    trap 'rm -f "$tmp_script"' EXIT

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$REMOTE_BASE_URL/$script_name" -o "$tmp_script"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$tmp_script" "$REMOTE_BASE_URL/$script_name"
    else
        echo "Neither curl nor wget is available to download $script_name" >&2
        exit 1
    fi

    bash "$tmp_script" "$@"
}

case "$OS_NAME" in
    Darwin)
        run_platform_script "setup_proxy_macos.sh" "$@"
        ;;
    Linux)
        run_platform_script "setup_proxy_linux.sh" "$@"
        ;;
    *)
        echo "Unsupported OS for setup_proxy.sh: $OS_NAME" >&2
        echo "Use setup_proxy.ps1 on Windows, or run setup_proxy.py manually." >&2
        exit 1
        ;;
esac
