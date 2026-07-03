#!/usr/bin/env bash
# Install Claude Code on macOS and make the `claude` command available.

set -euo pipefail

INSTALL_URL="${CLAUDE_CODE_INSTALL_URL:-https://claude.ai/install.sh}"
BIN_DIR="${CLAUDE_CODE_BIN_DIR:-$HOME/.local/bin}"
RC_FILE="${CLAUDE_CODE_RC_FILE:-}"
SKIP_INSTALL="${CLAUDE_CODE_SKIP_INSTALL:-0}"
PROXY_URL="${CLAUDE_CODE_PROXY:-}"

if [[ "$BIN_DIR" == "$HOME/.local/bin" ]]; then
    PATH_LINE='export PATH="$HOME/.local/bin:$PATH"'
else
    PATH_LINE="export PATH=\"$BIN_DIR:\$PATH\""
fi
PATH_BLOCK_START="# >>> claude-code path >>>"
PATH_BLOCK_END="# <<< claude-code path <<<"
PROXY_CONFIG_BLOCK_START="# >>> proxy-config start <<<"
PROXY_CONFIG_BLOCK_END="# >>> proxy-config end <<<"

info() { printf '  \033[0;36m%s\033[0m\n' "$1" >&2; }
ok() { printf '  \033[0;32m[OK] %s\033[0m\n' "$1" >&2; }
warn() { printf '  \033[1;33m[WARN] %s\033[0m\n' "$1" >&2; }
err() { printf '  \033[0;31m[ERR] %s\033[0m\n' "$1" >&2; }

usage() {
    cat <<'EOF'
Usage:
  bash install_claude_code_macos.sh

Environment variables:
  CLAUDE_CODE_SKIP_INSTALL=1     Only repair the claude command and PATH.
  CLAUDE_CODE_PROXY=URL          Optional manual proxy override.
                                 Normally, run setup_proxy_macos.sh first;
                                 this installer reuses its proxy-config block.
  CLAUDE_CODE_RC_FILE=PATH       Shell config file to update.
                                 Default: ~/.zshrc for zsh, ~/.bash_profile for bash.
  CLAUDE_CODE_BIN_DIR=PATH       Directory for the claude symlink.
                                 Default: ~/.local/bin
  CLAUDE_CODE_INSTALL_URL=URL    Override the official installer URL.
EOF
}

require_macos() {
    local os_name
    os_name="$(uname -s 2>/dev/null || echo unknown)"
    if [[ "$os_name" != "Darwin" ]]; then
        err "This script is for macOS only. Current OS: $os_name"
        exit 1
    fi
}

select_rc_file() {
    if [[ -n "$RC_FILE" ]]; then
        printf '%s\n' "$RC_FILE"
        return
    fi

    case "${SHELL:-}" in
        */zsh) printf '%s\n' "$HOME/.zshrc" ;;
        */bash) printf '%s\n' "$HOME/.bash_profile" ;;
        *) printf '%s\n' "$HOME/.zshrc" ;;
    esac
}

export_proxy_var() {
    local key=$1 value=$2
    case "$key" in
        http_proxy|https_proxy|all_proxy|HTTP_PROXY|HTTPS_PROXY|ALL_PROXY|no_proxy|NO_PROXY)
            export "$key=$value"
            ;;
    esac
}

load_proxy_from_rc() {
    local rc=$1
    [[ -f "$rc" ]] || return 1

    local line in_block=0 loaded=0 key value
    while IFS= read -r line; do
        if [[ "$line" == "$PROXY_CONFIG_BLOCK_START"* ]]; then
            in_block=1
            continue
        fi
        if [[ "$line" == "$PROXY_CONFIG_BLOCK_END"* ]]; then
            break
        fi
        [[ "$in_block" -eq 1 ]] || continue

        if [[ "$line" =~ ^export[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)=\"(.*)\"$ ]]; then
            key="${BASH_REMATCH[1]}"
            value="${BASH_REMATCH[2]}"
            export_proxy_var "$key" "$value"
            loaded=1
        fi
    done < "$rc"

    [[ "$loaded" -eq 1 ]]
}

has_proxy_env() {
    [[ -n "${http_proxy:-${https_proxy:-${HTTP_PROXY:-${HTTPS_PROXY:-}}}}" ]]
}

configure_proxy() {
    if [[ -n "$PROXY_URL" ]]; then
        export http_proxy="$PROXY_URL"
        export https_proxy="$PROXY_URL"
        export HTTP_PROXY="$PROXY_URL"
        export HTTPS_PROXY="$PROXY_URL"
        ok "Using manual proxy override for installer: $PROXY_URL"
        return
    fi

    if has_proxy_env; then
        ok "Using existing proxy environment for installer"
        return
    fi

    local rc
    rc="$(select_rc_file)"
    if load_proxy_from_rc "$rc"; then
        ok "Loaded proxy environment from $rc"
        return
    fi

    warn "No proxy environment found. If direct download fails, run setup_proxy_macos.sh first."
}

run_installer() {
    if [[ "$SKIP_INSTALL" == "1" || "$SKIP_INSTALL" == "true" ]]; then
        warn "Skipping installer because CLAUDE_CODE_SKIP_INSTALL=$SKIP_INSTALL"
        return
    fi

    command -v curl >/dev/null 2>&1 || {
        err "curl is required but was not found."
        exit 1
    }

    local tmp
    tmp="$(mktemp "/tmp/claude-code-install.XXXXXX.sh")"
    trap 'rm -f "$tmp"' EXIT

    info "Downloading Claude Code installer..."
    curl -fsSL "$INSTALL_URL" -o "$tmp"

    info "Running Claude Code installer..."
    bash "$tmp"
}

valid_claude() {
    local candidate=$1
    [[ -n "$candidate" && -f "$candidate" && -x "$candidate" ]] || return 1
    "$candidate" --version >/dev/null 2>&1
}

append_candidate() {
    local candidate=$1
    [[ -n "$candidate" ]] || return 0
    CANDIDATES+=("$candidate")
}

collect_candidates() {
    CANDIDATES=()

    append_candidate "$(command -v claude 2>/dev/null || true)"
    append_candidate "$BIN_DIR/claude"
    append_candidate "/opt/homebrew/bin/claude"
    append_candidate "/usr/local/bin/claude"

    shopt -s nullglob
    local p
    for p in "$HOME"/Library/Application\ Support/Claude/claude-code/*/claude.app/Contents/MacOS/claude; do
        append_candidate "$p"
    done
    for p in "$HOME"/Library/Application\ Support/Claude/claude-code-vm/*/claude; do
        append_candidate "$p"
    done
    shopt -u nullglob
}

find_claude_binary() {
    collect_candidates

    local candidate
    for candidate in "${CANDIDATES[@]}"; do
        if valid_claude "$candidate"; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    err "Could not find a working Claude Code executable."
    err "Tried:"
    for candidate in "${CANDIDATES[@]}"; do
        [[ -n "$candidate" ]] && printf '  - %s\n' "$candidate" >&2
    done
    exit 1
}

ensure_symlink() {
    local target=$1
    local link="$BIN_DIR/claude"

    mkdir -p "$BIN_DIR"

    if [[ "$target" == "$link" ]]; then
        ok "claude already exists at $link"
        return
    fi

    if [[ -L "$link" || -e "$link" ]]; then
        rm -f "$link"
    fi

    ln -sf "$target" "$link"
    ok "Linked claude -> $target"
}

ensure_path() {
    local rc
    rc="$(select_rc_file)"
    mkdir -p "$(dirname "$rc")"
    touch "$rc"

    if grep -Fq "$BIN_DIR" "$rc" || grep -Fq '$HOME/.local/bin' "$rc"; then
        ok "PATH already includes $BIN_DIR in $rc"
        return
    fi

    {
        printf '\n%s\n' "$PATH_BLOCK_START"
        printf '%s\n' "$PATH_LINE"
        printf '%s\n' "$PATH_BLOCK_END"
    } >> "$rc"

    ok "Updated PATH in $rc"
}

verify_install() {
    export PATH="$BIN_DIR:$PATH"
    hash -r 2>/dev/null || true

    local resolved
    resolved="$(command -v claude 2>/dev/null || true)"
    if [[ -z "$resolved" ]]; then
        err "claude is still not on PATH."
        exit 1
    fi

    ok "claude command: $resolved"
    claude --version
}

main() {
    if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
        usage
        exit 0
    fi

    require_macos
    configure_proxy
    run_installer

    local claude_bin
    claude_bin="$(find_claude_binary)"
    ensure_symlink "$claude_bin"
    ensure_path
    verify_install

    printf '\n'
    ok "Claude Code is ready."
    info "For a new terminal, PATH will load automatically."
    info "For this terminal, run: source \"$(select_rc_file)\""
}

main "$@"
