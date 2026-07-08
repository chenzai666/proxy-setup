#!/usr/bin/env bash
# Dispatch to the platform-specific Bash proxy setup script.

set -euo pipefail

_PROXY_SOURCED=0
[[ "${BASH_SOURCE[0]}" != "$0" ]] && _PROXY_SOURCED=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OS_NAME="$(uname -s 2>/dev/null || echo unknown)"

run_platform_script() {
    local script_name=$1
    shift || true
    local local_script="$SCRIPT_DIR/$script_name"

    if [[ ! -f "$local_script" ]]; then
        local bases=()
        if [[ -n "${PROXY_SETUP_REMOTE_BASE_URL:-}" ]]; then
            bases+=("${PROXY_SETUP_REMOTE_BASE_URL%/}")
        else
            bases+=(
                "https://raw.githubusercontent.com/chenzai666/proxy-setup/master"
            )
        fi

        if ! command -v curl >/dev/null 2>&1; then
            echo "Script not found: $local_script" >&2
            echo "curl is required to download $script_name." >&2
            exit 1
        fi

        local base url tmp
        tmp="${local_script}.tmp.$$"
        for base in "${bases[@]}"; do
            url="$base/$script_name"
            echo "Downloading platform script: $url" >&2
            if curl -fsSL "$url" -o "$tmp"; then
                mv "$tmp" "$local_script"
                chmod +x "$local_script" 2>/dev/null || true
                break
            fi
        done
        rm -f "$tmp"

        if [[ ! -f "$local_script" ]]; then
            echo "Script not found: $local_script" >&2
            echo "Please run: git clone https://github.com/chenzai666/proxy-setup.git" >&2
            exit 1
        fi
    fi

    if [[ "$_PROXY_SOURCED" == "1" ]]; then
        . "$local_script" "$@"
    else
        exec bash "$local_script" "$@"
    fi
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
