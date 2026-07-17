#!/usr/bin/env bash
# Dispatch to the platform-specific Bash proxy setup script.

_PROXY_SOURCED=0
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
    _PROXY_SOURCED=1
else
    set -euo pipefail
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OS_NAME="$(uname -s 2>/dev/null || echo unknown)"
RAW_REMOTE_BASE_URL="https://raw.githubusercontent.com/chenzai666/proxy-setup/master"
CDN_REMOTE_BASE_URL="https://cdn.jsdelivr.net/gh/chenzai666/proxy-setup@master"
LEGACY_REMOTE_BASE_URL=""

is_truthy() {
    case "${1:-}" in
        1|true|TRUE|yes|YES|y|Y) return 0 ;;
        *) return 1 ;;
    esac
}

is_temp_script_dir() {
    case "$SCRIPT_DIR" in
        /tmp|/tmp/*|/private/tmp|/private/tmp/*|/var/folders/*) return 0 ;;
        *) return 1 ;;
    esac
}

should_refresh_platform_script() {
    local local_script=$1
    [[ ! -f "$local_script" ]] && return 0
    [[ -n "$LEGACY_REMOTE_BASE_URL" ]] && return 0
    is_truthy "${PROXY_SETUP_FORCE_DOWNLOAD:-}" && return 0
    is_temp_script_dir && return 0
    return 1
}

remote_base_url() {
    if [[ -n "$LEGACY_REMOTE_BASE_URL" ]]; then
        printf '%s\n' "$LEGACY_REMOTE_BASE_URL"
    elif is_truthy "${PROXY_SETUP_USE_CDN:-}"; then
        printf '%s\n' "$CDN_REMOTE_BASE_URL"
    else
        printf '%s\n' "$RAW_REMOTE_BASE_URL"
    fi
}

if [[ -n "${PROXY_SETUP_REMOTE_BASE_URL:-}" ]]; then
    case "${PROXY_SETUP_REMOTE_BASE_URL%/}" in
        "$RAW_REMOTE_BASE_URL"|"$CDN_REMOTE_BASE_URL")
            LEGACY_REMOTE_BASE_URL="${PROXY_SETUP_REMOTE_BASE_URL%/}"
            ;;
        *)
            echo "PROXY_SETUP_REMOTE_BASE_URL only accepts the built-in GitHub or jsDelivr URL." >&2
            if [[ "$_PROXY_SOURCED" == "1" ]]; then
                # Do not terminate the caller's interactive shell when this file is sourced.
                return 0
            fi
            exit 2
            ;;
    esac
fi

run_platform_script() {
    local script_name=$1
    shift || true
    local local_script="$SCRIPT_DIR/$script_name"

    if should_refresh_platform_script "$local_script"; then
        local bases=("$(remote_base_url)")

        if ! command -v curl >/dev/null 2>&1; then
            echo "Script not found: $local_script" >&2
            echo "curl is required to download $script_name." >&2
            exit 1
        fi

        local base url tmp downloaded=0
        tmp="$(mktemp "${TMPDIR:-/tmp}/proxy-setup-${script_name}.XXXXXX")" || {
            echo "Failed to create temporary file." >&2
            exit 1
        }
        for base in "${bases[@]}"; do
            url="$base/$script_name"
            echo "Downloading platform script: $url" >&2
            if curl -fsSL "$url" -o "$tmp"; then
                downloaded=1
                mv "$tmp" "$local_script"
                chmod +x "$local_script" 2>/dev/null || true
                break
            fi
        done
        rm -f "$tmp"

        if [[ "$downloaded" != "1" ]]; then
            echo "Failed to download $script_name." >&2
            echo "Please retry later or run: git clone https://github.com/chenzai666/proxy-setup.git" >&2
            exit 1
        fi
    fi

    if [[ ! -f "$local_script" ]]; then
        echo "Script not found: $local_script" >&2
        echo "Please run: git clone https://github.com/chenzai666/proxy-setup.git" >&2
        exit 1
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
