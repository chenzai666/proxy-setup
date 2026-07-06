#!/usr/bin/env bash
# Dispatch to the platform-specific Bash proxy setup script.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OS_NAME="$(uname -s 2>/dev/null || echo unknown)"
REMOTE_BASE_URL="${PROXY_SETUP_REMOTE_BASE_URL:-https://raw.githubusercontent.com/chenzai666/proxy-setup/master}"
TMP_PLATFORM_SCRIPT=""
trap '[[ -n "${TMP_PLATFORM_SCRIPT:-}" ]] && rm -f "$TMP_PLATFORM_SCRIPT"' EXIT

run_platform_script() {
    local script_name=$1
    local local_script="$SCRIPT_DIR/$script_name"

    if [[ -f "$local_script" ]]; then
        exec bash "$local_script" "$@"
    fi

    TMP_PLATFORM_SCRIPT="$(mktemp "/tmp/${script_name}.XXXXXX")"

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$REMOTE_BASE_URL/$script_name" -o "$TMP_PLATFORM_SCRIPT"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$TMP_PLATFORM_SCRIPT" "$REMOTE_BASE_URL/$script_name"
    else
        echo "Neither curl nor wget is available to download $script_name" >&2
        exit 1
    fi

    bash "$TMP_PLATFORM_SCRIPT" "$@"
}

case "$OS_NAME" in
    Darwin)
        run_platform_script "setup_proxy_macos.sh" "$@"
        ;;
    *)
        echo "Unsupported OS: $OS_NAME" >&2
        echo "Use setup_proxy.ps1 on Windows or setup_proxy_macos.sh on macOS." >&2
        exit 1
        ;;
esac
