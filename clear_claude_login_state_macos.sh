#!/usr/bin/env bash
set -euo pipefail

# Clear Claude Desktop login/session state and cache for the current macOS user.
# This does not uninstall Claude.app.
#
# Usage:
#   bash Clear-ClaudeLoginState-macOS.sh
#   DRY_RUN=1 bash Clear-ClaudeLoginState-macOS.sh
#   INCLUDE_CLAUDE_CLI=1 bash Clear-ClaudeLoginState-macOS.sh
#   INCLUDE_BROWSER_SITE_DATA=1 bash Clear-ClaudeLoginState-macOS.sh

dry_run="${DRY_RUN:-0}"
include_claude_cli="${INCLUDE_CLAUDE_CLI:-0}"
include_browser_site_data="${INCLUDE_BROWSER_SITE_DATA:-0}"

home_dir="${HOME:?HOME is not set}"

say() {
  printf '%s\n' "$*"
}

remove_path() {
  local path="$1"

  case "$path" in
    "$home_dir"/*) ;;
    *)
      say "Skipped path outside HOME: $path"
      return
      ;;
  esac

  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    return
  fi

  if [ "$dry_run" = "1" ]; then
    say "Would remove: $path"
  else
    rm -rf "$path"
    say "Removed: $path"
  fi
}

say "Stopping Claude..."
if [ "$dry_run" = "1" ]; then
  say "Would run: osascript -e 'quit app \"Claude\"'"
  say "Would run: pkill -x Claude"
else
  osascript -e 'quit app "Claude"' >/dev/null 2>&1 || true
  sleep 2
  pkill -x Claude >/dev/null 2>&1 || true
  pkill -f '/Claude.app/' >/dev/null 2>&1 || true
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

for target in "${targets[@]}"; do
  remove_path "$target"
done

say "Removing additional Claude/Anthropic matches in common Library folders..."

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
  done < <(find "$root" -maxdepth 1 \( -iname '*claude*' -o -iname '*anthropic*' \) 2>/dev/null)
done

if [ "$include_claude_cli" = "1" ]; then
  say "Removing Claude CLI/config directory..."
  remove_path "$home_dir/.claude"
fi

if [ "$include_browser_site_data" = "1" ]; then
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

  say "Browser cookies are best removed from the browser UI by deleting site data for claude.ai."
fi

say ""
say "Done."
say "Reopen Claude. If it asks you to sign in, local login state was cleared."
say "If signing in still shows account_banned/account on hold, that is server-side account status."
