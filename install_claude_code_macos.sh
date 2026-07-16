#!/usr/bin/env bash
# Install Claude Code on macOS and make the `claude` command available.

set -euo pipefail

INSTALL_URL="${CLAUDE_CODE_INSTALL_URL:-https://claude.ai/install.sh}"
BIN_DIR="${CLAUDE_CODE_BIN_DIR:-$HOME/.local/bin}"
RC_FILE="${CLAUDE_CODE_RC_FILE:-}"
SKIP_INSTALL="${CLAUDE_CODE_SKIP_INSTALL:-0}"

PATH_BLOCK_START="# >>> claude-code path >>>"
PATH_BLOCK_END="# <<< claude-code path <<<"

info() { printf '  \033[0;36m%s\033[0m\n' "$1" >&2; }
ok() { printf '  \033[0;32m[OK] %s\033[0m\n' "$1" >&2; }
warn() { printf '  \033[1;33m[WARN] %s\033[0m\n' "$1" >&2; }
err() { printf '  \033[0;31m[ERR] %s\033[0m\n' "$1" >&2; }

get_progress_interval_seconds() {
    local raw=${CLAUDE_CODE_PROGRESS_SECONDS:-} value

    case "$raw" in
        '') printf '60\n' ;;
        *[!0-9]*) printf '60\n' ;;
        *)
            value=$((10#$raw))
            if ((value < 2)); then
                printf '2\n'
            else
                printf '%s\n' "$value"
            fi
            ;;
    esac
}

format_duration() {
    local seconds=$1 hours minutes

    hours=$((seconds / 3600))
    minutes=$(((seconds % 3600) / 60))
    seconds=$((seconds % 60))

    if ((hours > 0)); then
        printf '%sh %sm %ss\n' "$hours" "$minutes" "$seconds"
    elif ((minutes > 0)); then
        printf '%sm %ss\n' "$minutes" "$seconds"
    else
        printf '%ss\n' "$seconds"
    fi
}

render_progress_status() {
    local elapsed=$1 message
    message="Claude Code installer is still running... elapsed $(format_duration "$elapsed")"

    if [[ -t 2 ]]; then
        printf '\r\033[K  %s' "$message" >&2
    else
        info "$message"
    fi
}

clear_progress_status() {
    if [[ -t 2 ]]; then
        printf '\r\033[K' >&2
    fi
}

usage() {
    cat <<'EOF'
Usage:
  bash install_claude_code_macos.sh

Environment variables:
  CLAUDE_CODE_SKIP_INSTALL=1     Only repair the claude command and PATH.
  CLAUDE_CODE_RC_FILE=PATH       Shell config file to update.
                                 Default: ~/.zshrc for zsh, ~/.bash_profile for bash.
  CLAUDE_CODE_BIN_DIR=PATH       Directory for the claude symlink.
                                 Default: ~/.local/bin
  CLAUDE_CODE_INSTALL_URL=URL    Override the official installer URL.
  CLAUDE_CODE_PROGRESS_SECONDS=N Progress heartbeat interval. Default: 60 (min: 2).
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

path_line_for_rc() {
    local rc=$1
    local escaped_bin=${BIN_DIR//\\/\\\\}
    escaped_bin=${escaped_bin//\"/\\\"}

    if [[ "$rc" == *.fish || "$rc" == */config.fish ]]; then
        if [[ "$BIN_DIR" == "$HOME/.local/bin" ]]; then
            printf '%s\n' 'set -gx PATH "$HOME/.local/bin" $PATH'
        else
            printf 'set -gx PATH "%s" $PATH\n' "$escaped_bin"
        fi
        return
    fi

    if [[ "$BIN_DIR" == "$HOME/.local/bin" ]]; then
        printf '%s\n' 'export PATH="$HOME/.local/bin:$PATH"'
    else
        printf 'export PATH="%s:$PATH"\n' "$escaped_bin"
    fi
}

path_already_configured() {
    local rc=$1
    grep -Fq "$BIN_DIR" "$rc" && return 0
    [[ "$BIN_DIR" == "$HOME/.local/bin" ]] && grep -Fq '$HOME/.local/bin' "$rc"
}

has_proxy_env() {
    [[ -n "${http_proxy:-${https_proxy:-${HTTP_PROXY:-${HTTPS_PROXY:-}}}}" ]]
}

configure_proxy() {
    if has_proxy_env; then
        ok "Using current proxy environment for installer"
        return
    fi

    warn "No proxy environment found. If direct download fails, run setup_proxy_macos.sh and source your shell rc first."
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

    local tmp interval started pid elapsed next_update exit_code
    tmp="$(mktemp "/tmp/claude-code-install.XXXXXX.sh")"
    trap 'rm -f "$tmp"' EXIT

    info "Downloading Claude Code installer..."
    curl -fsSL "$INSTALL_URL" -o "$tmp"

    info "Running Claude Code installer..."
    interval="$(get_progress_interval_seconds)"
    started=$SECONDS
    next_update=$interval
    bash "$tmp" &
    pid=$!
    info "Claude Code installer started (PID $pid). Status will update in place every ${interval}s."

    while kill -0 "$pid" 2>/dev/null; do
        sleep 1
        elapsed=$((SECONDS - started))
        if ((elapsed >= next_update)) && kill -0 "$pid" 2>/dev/null; then
            render_progress_status "$elapsed"
            next_update=$((next_update + interval))
        fi
    done

    clear_progress_status
    if wait "$pid"; then
        ok "Claude Code installer finished in $(format_duration "$((SECONDS - started))")"
    else
        exit_code=$?
        err "Claude Code installer exited with code $exit_code after $(format_duration "$((SECONDS - started))")"
        rm -f "$tmp"
        trap - EXIT
        return "$exit_code"
    fi

    rm -f "$tmp"
    trap - EXIT
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

find_existing_claude_binary() {
    collect_candidates

    local candidate
    for candidate in "${CANDIDATES[@]}"; do
        if valid_claude "$candidate"; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    return 1
}

find_claude_binary() {
    local existing
    if existing="$(find_existing_claude_binary)"; then
        printf '%s\n' "$existing"
        return 0
    fi

    collect_candidates
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

    if path_already_configured "$rc"; then
        ok "PATH already includes $BIN_DIR in $rc"
        return
    fi

    {
        printf '\n%s\n' "$PATH_BLOCK_START"
        path_line_for_rc "$rc"
        printf '%s\n' "$PATH_BLOCK_END"
    } >> "$rc"

    ok "Updated PATH in $rc"
}

verify_install() {
    export PATH="$BIN_DIR:$PATH"
    hash -r 2>/dev/null || true

    local resolved version
    resolved="$(command -v claude 2>/dev/null || true)"
    if [[ -z "$resolved" ]]; then
        err "claude is still not on PATH."
        exit 1
    fi

    if ! version="$(claude --version 2>&1)"; then
        err "Unable to read Claude Code version: $version"
        exit 1
    fi

    ok "claude command: $resolved"
    printf '%s\n' "$version"
}

main() {
    if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
        usage
        exit 0
    fi

    require_macos
    if [[ "$SKIP_INSTALL" != "1" && "$SKIP_INSTALL" != "true" ]]; then
        local existing version
        if existing="$(find_existing_claude_binary)"; then
            version="$("$existing" --version 2>&1)"
            ok "Claude Code is already installed. Version: $version"
            return
        fi
    fi

    configure_proxy
    run_installer

    local claude_bin
    claude_bin="$(find_claude_binary)"
    ensure_symlink "$claude_bin"
    ensure_path
    local claude_version
    claude_version="$(verify_install)"

    printf '\n'
    ok "Claude Code is ready. Version: $claude_version"
    info "For a new terminal, PATH will load automatically."
    info "For this terminal, run: source \"$(select_rc_file)\""
}

main "$@"
