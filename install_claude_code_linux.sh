#!/usr/bin/env bash
# Install Claude Code on Linux and make the `claude` command available.

set -euo pipefail

INSTALL_URL="${CLAUDE_CODE_INSTALL_URL:-https://claude.ai/install.sh}"
BIN_DIR="${CLAUDE_CODE_BIN_DIR:-$HOME/.local/bin}"
RC_FILE="${CLAUDE_CODE_RC_FILE:-}"
SKIP_INSTALL="${CLAUDE_CODE_SKIP_INSTALL:-0}"
ALLOW_UNSAFE_SOURCE="${CLAUDE_CODE_ALLOW_UNSAFE_SOURCE:-0}"

PATH_BLOCK_START="# >>> claude-code path >>>"
PATH_BLOCK_END="# <<< claude-code path <<<"

info() { printf '  \033[0;36m%s\033[0m\n' "$1" >&2; }
ok()   { printf '  \033[0;32m[OK] %s\033[0m\n' "$1" >&2; }
warn() { printf '  \033[1;33m[WARN] %s\033[0m\n' "$1" >&2; }
err()  { printf '  \033[0;31m[ERR] %s\033[0m\n' "$1" >&2; }

usage() {
    cat <<'EOF'
Usage:
  bash install_claude_code_linux.sh [--allow-unsafe-source]

Environment variables:
  CLAUDE_CODE_SKIP_INSTALL=1     Only repair the claude command and PATH.
  CLAUDE_CODE_RC_FILE=PATH       Shell config file to update.
                                 Default: ~/.bashrc for bash, ~/.zshrc for zsh.
  CLAUDE_CODE_BIN_DIR=PATH       Directory for the claude symlink.
                                 Default: ~/.local/bin
  CLAUDE_CODE_INSTALL_URL=URL    Override the official installer URL.
  CLAUDE_CODE_ALLOW_UNSAFE_SOURCE=1  Permit a custom installer source after verification.
EOF
}

is_truthy() {
    case "${1:-}" in
        1|true|TRUE|yes|YES|y|Y) return 0 ;;
        *) return 1 ;;
    esac
}

assert_trusted_install_source() {
    local official_url="https://claude.ai/install.sh"
    [[ "$INSTALL_URL" == "$official_url" ]] && return 0
    if is_truthy "$ALLOW_UNSAFE_SOURCE"; then
        warn "Using explicitly authorized custom installer source: $INSTALL_URL"
        return 0
    fi
    err "Custom installer sources are disabled. Set CLAUDE_CODE_ALLOW_UNSAFE_SOURCE=1 only after verifying the source."
    return 1
}

require_linux() {
    local os_name
    os_name="$(uname -s 2>/dev/null || echo unknown)"
    if [[ "$os_name" != "Linux" ]]; then
        err "This script is for Linux only. Current OS: $os_name"
        exit 1
    fi
}

select_rc_file() {
    if [[ -n "$RC_FILE" ]]; then
        printf '%s\n' "$RC_FILE"
        return
    fi

    case "${SHELL:-}" in
        */zsh)  printf '%s\n' "$HOME/.zshrc" ;;
        */fish) printf '%s\n' "$HOME/.config/fish/config.fish" ;;
        *)      printf '%s\n' "$HOME/.bashrc" ;;
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

    warn "No proxy environment found. Set http_proxy/https_proxy before running if needed."
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

    assert_trusted_install_source || return 1

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
    append_candidate "/usr/local/bin/claude"
    append_candidate "/usr/bin/claude"

    # npm global bin is optional. Some minimal Linux systems do not have npm.
    local npm_prefix
    if command -v npm >/dev/null 2>&1; then
        npm_prefix="$(npm config get prefix 2>/dev/null || true)"
        if [[ -n "$npm_prefix" ]]; then
            append_candidate "$npm_prefix/bin/claude"
        fi
    fi

    # XDG / home-dir installs
    shopt -s nullglob
    local p
    for p in "$HOME"/.local/share/claude-code/*/claude; do
        append_candidate "$p"
    done
    for p in "$HOME"/.local/share/Claude/claude-code/*/claude; do
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
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            -h|--help) usage; exit 0 ;;
            --allow-unsafe-source) ALLOW_UNSAFE_SOURCE=1 ;;
            *) err "Unknown argument: $1"; usage; exit 2 ;;
        esac
        shift
    done

    require_linux
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
