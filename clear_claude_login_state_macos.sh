#!/usr/bin/env bash
set -euo pipefail

# Clear Claude Desktop or Claude Code login state and cache for the
# current macOS user. If no target is provided, the script asks which one to
# clean.
# Claude Code mode preserves projects, conversations, settings, and extensions.
# This does not uninstall Claude.app.
#
# Usage:
#   bash clear_claude_login_state_macos.sh
#   DRY_RUN=1 bash clear_claude_login_state_macos.sh
#   TARGET=code bash clear_claude_login_state_macos.sh
#   bash clear_claude_login_state_macos.sh --target code

dry_run="${DRY_RUN:-0}"
target="${TARGET:-}"
include_claude_cli="${INCLUDE_CLAUDE_CLI:-0}"
include_browser_site_data="${INCLUDE_BROWSER_SITE_DATA:-0}"

home_dir="${HOME:?HOME is not set}"
home_dir="$(cd "$home_dir" 2>/dev/null && pwd -P)" || {
  printf '%s\n' "HOME does not exist: $HOME" >&2
  exit 1
}

say() {
  printf '%s\n' "$*"
}

usage() {
  cat <<'EOF'
Usage:
  bash clear_claude_login_state_macos.sh [--target desktop|code] [--dry-run]

Targets:
  desktop   Clear only Claude Desktop app login state and cache.
  code      Clear only Claude Code credentials and cache; preserve conversations.

Environment:
  TARGET=desktop|code
  DRY_RUN=1
  INCLUDE_BROWSER_SITE_DATA=1   Only applies to target=desktop.
  INCLUDE_CLAUDE_CLI=1          Deprecated alias for target=code.
EOF
}

select_target() {
  while true; do
    say ""
    say "Select cleanup target:"
    say "  1) Claude Desktop only"
    say "  2) Claude Code only"
    say ""
    printf 'Enter 1 or 2: '
    IFS= read -r choice

    case "$choice" in
      1|desktop|Desktop|d|D)
        target="desktop"
        return
        ;;
      2|code|Code|claude-code|ClaudeCode|c|C)
        target="code"
        return
        ;;
      *)
        say "Invalid choice. Please enter 1 or 2."
        ;;
    esac
  done
}

remove_path() {
  local path="$1"
  local full_path

  full_path="$(normalize_path "$path")" || {
    say "Skipped unresolved path: $path"
    return
  }

  case "$full_path" in
    "$home_dir"/*) ;;
    *)
      say "Skipped path outside HOME: $full_path"
      return
      ;;
  esac

  if [ ! -e "$full_path" ] && [ ! -L "$full_path" ]; then
    return
  fi

  if [ "$dry_run" = "1" ]; then
    say "Would remove: $full_path"
  else
    if rm -rf "$full_path" 2>/dev/null; then
      say "Removed: $full_path"
    else
      say "Warning: could not remove $full_path (check permissions)"
    fi
  fi
}

backup_claude_code_user_data() {
  local code_config_dir="$1"
  local backup_root="$home_dir/.claude-cleanup-backups"
  local stamp destination source relative parent copied=0
  local protected_names=(
    projects sessions backups commands agents skills plugins
    history.jsonl settings.json settings.local.json config.json CLAUDE.md
  )

  stamp="$(date '+%Y%m%d-%H%M%S')"
  destination="$backup_root/$stamp"
  if [ -e "$destination" ]; then
    destination="$backup_root/$stamp-$$"
  fi

  for relative in "${protected_names[@]}"; do
    [ -e "$code_config_dir/$relative" ] || [ -L "$code_config_dir/$relative" ] || continue
    copied=1
  done
  if [ -e "$home_dir/.claude.json" ] || [ -L "$home_dir/.claude.json" ]; then
    copied=1
  fi

  if [ "$copied" -eq 0 ]; then
    say "No Claude Code project history or user configuration needed backup."
    return 0
  fi

  if [ "$dry_run" = "1" ]; then
    say "Would back up protected Claude Code data to: $destination"
    return 0
  fi

  mkdir -p "$destination/.claude"
  chmod 700 "$backup_root" "$destination" "$destination/.claude" 2>/dev/null || true
  for relative in "${protected_names[@]}"; do
    source="$code_config_dir/$relative"
    [ -e "$source" ] || [ -L "$source" ] || continue
    parent="$(dirname "$destination/.claude/$relative")"
    mkdir -p "$parent"
    cp -pR "$source" "$destination/.claude/$relative"
  done
  if [ -e "$home_dir/.claude.json" ] || [ -L "$home_dir/.claude.json" ]; then
    cp -pR "$home_dir/.claude.json" "$destination/.claude.json"
  fi
  say "Backup created: $destination"
}

normalize_path() {
  local path="$1"
  local dir base

  if [ -z "$path" ]; then
    return 1
  fi

  case "$path" in
    /*) ;;
    *) path="$PWD/$path" ;;
  esac

  dir=$(dirname "$path")
  base=$(basename "$path")

  while [ ! -d "$dir" ] && [ "$dir" != "/" ]; do
    base="$(basename "$dir")/$base"
    dir=$(dirname "$dir")
  done

  if [ ! -d "$dir" ]; then
    return 1
  fi

  (cd "$dir" 2>/dev/null && printf '%s/%s\n' "$(pwd -P)" "$base")
}

if [ "$include_claude_cli" = "1" ]; then
  target="code"
  say "INCLUDE_CLAUDE_CLI=1 is deprecated; using TARGET=code."
fi

while [ "$#" -gt 0 ]; do
  case "$1" in
    --target)
      if [ "$#" -lt 2 ]; then
        usage
        exit 2
      fi
      target="$2"
      shift 2
      ;;
    --desktop)
      target="desktop"
      shift
      ;;
    --code|--claude-code)
      target="code"
      shift
      ;;
    --dry-run)
      dry_run="1"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      say "Unknown argument: $1"
      usage
      exit 2
      ;;
  esac
done

if [ -z "$target" ]; then
  select_target
else
  case "$target" in
    desktop|Desktop|d|D|1)
      target="desktop"
      ;;
    code|Code|claude-code|ClaudeCode|c|C|2)
      target="code"
      ;;
    *)
      say "Invalid target: $target"
      usage
      exit 2
      ;;
  esac
fi

if [ "$target" = "code" ] && [ "$include_browser_site_data" = "1" ]; then
  say "INCLUDE_BROWSER_SITE_DATA=1 only applies to TARGET=desktop and will be ignored."
fi

say "Cleanup target: $target"

if [ "$target" = "desktop" ]; then
  say "Stopping Claude Desktop..."
  if [ "$dry_run" = "1" ]; then
    say "Would run: osascript -e 'quit app \"Claude\"'"
    say "Would run: pkill -x Claude"
  else
    osascript -e 'quit app "Claude"' >/dev/null 2>&1 || true
    sleep 2
    pkill -x Claude >/dev/null 2>&1 || true
    pkill -f 'MacOS/Claude' >/dev/null 2>&1 || true
  fi

  say "Removing Claude Desktop app data and cache..."

  targets=(
    "$home_dir/Library/Application Support/Claude"
    "$home_dir/Library/Caches/Claude"
    "$home_dir/Library/Logs/Claude"
    "$home_dir/Library/Saved Application State/com.anthropic.claude.savedState"
    "$home_dir/Library/Preferences/com.anthropic.claude.plist"
    "$home_dir/Library/HTTPStorages/Claude"
    "$home_dir/Library/HTTPStorages/com.anthropic.claude"
    "$home_dir/Library/Cookies/com.anthropic.claude.binarycookies"
    "$home_dir/Library/WebKit/com.anthropic.claude"
    "$home_dir/Library/Containers/com.anthropic.claude"
    "$home_dir/Library/Group Containers/group.com.anthropic.claude"
  )

  for path in "${targets[@]}"; do
    remove_path "$path"
  done

  say "Removing additional Claude Desktop matches in common Library folders..."

  common_roots=(
    "$home_dir/Library/Application Support"
    "$home_dir/Library/Caches"
    "$home_dir/Library/Logs"
    "$home_dir/Library/Preferences"
    "$home_dir/Library/HTTPStorages"
    "$home_dir/Library/WebKit"
    "$home_dir/Library/Containers"
    "$home_dir/Library/Group Containers"
  )

  for root in "${common_roots[@]}"; do
    [ -d "$root" ] || continue
    while IFS= read -r match; do
      remove_path "$match"
    done < <(find "$root" -maxdepth 1 \( -iname 'Claude' -o -iname 'com.anthropic.claude*' -o -iname 'group.com.anthropic.claude*' \) 2>/dev/null)
  done
fi

if [ "$target" = "code" ]; then
  if ! code_config_dir="$(normalize_path "${CLAUDE_CONFIG_DIR:-$home_dir/.claude}")"; then
    code_config_dir=""
  fi
  case "$code_config_dir" in
    "$home_dir"/*) ;;
    *)
      say "Unsafe CLAUDE_CONFIG_DIR was rejected; file cleanup will be skipped: ${CLAUDE_CONFIG_DIR:-$home_dir/.claude}"
      code_config_dir=""
      ;;
  esac
  say "Stopping Claude Code..."
  if [ "$dry_run" = "1" ]; then
    say "Would run: pkill -x claude"
    say "Would stop @anthropic-ai/claude-code processes"
  else
    pkill -x claude >/dev/null 2>&1 || true
    pkill -f '@anthropic-ai/claude-code' >/dev/null 2>&1 || true
  fi

  if [ -n "$code_config_dir" ]; then
    backup_claude_code_user_data "$code_config_dir"
    say "Preserving Claude Code projects, conversations, settings, extensions, and .claude.json."
    say "Removing Claude Code credentials and cache..."
    remove_path "$code_config_dir/.credentials.json"
    remove_path "$code_config_dir/cache"
  fi

  keychain_services=(
    "Claude Code-credentials"
    "Claude Code"
    "claude-code"
    "Claude Code OAuth"
  )

  for service in "${keychain_services[@]}"; do
    if [ "$dry_run" = "1" ]; then
      say "Would remove keychain service: $service"
    else
      security delete-generic-password -s "$service" >/dev/null 2>&1 || true
    fi
  done
fi

if [ "$target" = "desktop" ] && [ "$include_browser_site_data" = "1" ]; then
  say "Removing named claude.ai browser IndexedDB folders..."
  browser_roots=(
    "$home_dir/Library/Application Support/Google/Chrome"
    "$home_dir/Library/Application Support/BraveSoftware/Brave-Browser"
    "$home_dir/Library/Application Support/Microsoft Edge"
  )

  for browser_root in "${browser_roots[@]}"; do
    [ -d "$browser_root" ] || continue
    while IFS= read -r profile; do
      remove_path "$profile/IndexedDB/https_claude.ai_0.indexeddb.leveldb"
      remove_path "$profile/IndexedDB/https_claude.ai_0.indexeddb.blob"
    done < <(find "$browser_root" -maxdepth 1 -type d \( -name 'Default' -o -name 'Profile *' \) 2>/dev/null)
  done

  say "Removing Firefox claude.ai storage..."
  while IFS= read -r ff_profile; do
    remove_path "$ff_profile/storage/default/https+++claude.ai"
    remove_path "$ff_profile/storage/default/https+++claude.ai^firstPartyDomain=claude.ai"
  done < <(find "$home_dir/Library/Application Support/Firefox/Profiles" -maxdepth 1 -type d 2>/dev/null)

  say "Browser cookies are best removed from the browser UI by deleting site data for claude.ai."
fi

if [ "$dry_run" = "1" ]; then
  say ""
  say "Preview complete. No files or credentials were removed."
  exit 0
fi

say ""
say "Done."
if [ "$target" = "desktop" ]; then
  say "Reopen Claude Desktop. If it asks you to sign in, local desktop login state was cleared."
  say "If signing in still shows account_banned/account on hold, that is server-side account status."
else
  say "Run Claude Code again. If it asks you to sign in, local Claude Code login state was cleared."
  say "If it still authenticates, check ANTHROPIC_API_KEY, ANTHROPIC_AUTH_TOKEN, or CLAUDE_CODE_OAUTH_TOKEN."
fi
