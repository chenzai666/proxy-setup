#!/usr/bin/env bash
set -euo pipefail

# Clear Claude Desktop or Claude Code login state and cache for the
# current macOS user. If no target is provided, the script asks whether to
# clean or migrate a previous Claude Code backup after signing in to a new
# account.
# Claude Code mode backs up projects, conversations, settings, and extensions.
# Settings are restored only with the explicit, sanitized migration option.
# This does not uninstall Claude.app.
#
# Usage:
#   bash clear_claude_login_state_macos.sh
#   DRY_RUN=1 bash clear_claude_login_state_macos.sh
#   TARGET=code bash clear_claude_login_state_macos.sh
#   bash clear_claude_login_state_macos.sh --target code
#   bash clear_claude_login_state_macos.sh --target migrate --yes
#   bash clear_claude_login_state_macos.sh --target migrate --include-settings --yes

dry_run="${DRY_RUN:-0}"
target="${TARGET:-}"
include_claude_cli="${INCLUDE_CLAUDE_CLI:-0}"
include_browser_site_data="${INCLUDE_BROWSER_SITE_DATA:-0}"
migration_source="${MIGRATION_SOURCE:-}"
assume_yes="${ASSUME_YES:-0}"
allow_logged_out="${ALLOW_LOGGED_OUT:-0}"
include_settings="${INCLUDE_SETTINGS:-0}"
cleanup_failures=()

home_dir="${HOME:?HOME is not set}"
home_dir="$(cd "$home_dir" 2>/dev/null && pwd -P)" || {
  printf '%s\n' "HOME does not exist: $HOME" >&2
  exit 1
}

say() {
  printf '%s\n' "$*"
}

record_cleanup_failure() {
  cleanup_failures+=("$1")
}

usage() {
  cat <<'EOF'
Usage:
  bash clear_claude_login_state_macos.sh [--target desktop|code|migrate] [options]

Targets:
  desktop   Clear only Claude Desktop app login state and cache.
  code      Clear only Claude Code credentials and cache; preserve conversations.
  migrate   Merge a previous Claude Code cleanup backup into the currently signed-in account.

Environment:
  TARGET=desktop|code
  DRY_RUN=1
  MIGRATION_SOURCE=PATH           Old .claude directory or cleanup backup directory.
  ASSUME_YES=1                    Skip migration confirmation.
  ALLOW_LOGGED_OUT=1              Permit migration without a detected current login.
  INCLUDE_SETTINGS=1              Merge sanitized settings during target=migrate.
  INCLUDE_BROWSER_SITE_DATA=1   Only applies to target=desktop.
  INCLUDE_CLAUDE_CLI=1          Deprecated alias for target=code.

Options:
  --include-settings              Merge sanitized settings.json and settings.local.json.
EOF
}

select_target() {
  while true; do
    say ""
    say "Select Claude operation:"
    say "  1) Claude Desktop only"
    say "  2) Clear Claude Code login state and cache"
    say "  3) Migrate old Claude Code data into the current new account"
    say ""
    printf 'Enter 1, 2, or 3: '
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
      3|migrate|Migrate|migration|m|M)
        target="migrate"
        return
        ;;
      *)
        say "Invalid choice. Please enter 1, 2, or 3."
        ;;
    esac
  done
}

remove_path() {
  local path="$1"
  local full_path

  full_path="$(normalize_path "$path")" || {
    say "Skipped unresolved path: $path"
    record_cleanup_failure "$path (unresolved)"
    return 0
  }

  case "$full_path" in
    "$home_dir"/*) ;;
    *)
      say "Skipped path outside HOME: $full_path"
      record_cleanup_failure "$full_path (outside HOME)"
      return 0
      ;;
  esac

  if [ ! -e "$full_path" ] && [ ! -L "$full_path" ]; then
    return
  fi

  if [ "$dry_run" = "1" ]; then
    say "Would remove: $full_path"
  else
    if rm -rf "$full_path" 2>/dev/null; then
      if [ -e "$full_path" ] || [ -L "$full_path" ]; then
        say "Warning: still present after cleanup: $full_path"
        record_cleanup_failure "$full_path"
      else
        say "Removed: $full_path"
      fi
    else
      say "Warning: could not remove $full_path (check permissions)"
      record_cleanup_failure "$full_path"
    fi
  fi
}

backup_claude_code_user_data() {
  local code_config_dir="$1"
  local backup_root stamp destination stage source relative parent copied=0
  local protected_names=(
    projects sessions backups commands agents skills plugins
    session-env shell-snapshots todos plans
    history.jsonl settings.json settings.local.json config.json CLAUDE.md
  )

  stamp="$(date '+%Y%m%d-%H%M%S')"
  backup_root="$(safe_user_profile_path "$home_dir/.claude-cleanup-backups")" || {
    say "Unsafe Claude Code cleanup backup directory was rejected."
    return 1
  }
  destination="$backup_root/$stamp"
  if [ -e "$destination" ]; then
    destination="$backup_root/$stamp-$$"
  fi

  for relative in "${protected_names[@]}"; do
    source="$code_config_dir/$relative"
    [ -e "$source" ] || [ -L "$source" ] || continue
    assert_no_migration_symlinks "$source" || return 1
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

  stage="$backup_root/.${stamp}.backup-stage.$$-$RANDOM"
  mkdir -p "$stage/.claude"
  chmod 700 "$backup_root" "$stage" "$stage/.claude" 2>/dev/null || true
  for relative in "${protected_names[@]}"; do
    source="$code_config_dir/$relative"
    [ -e "$source" ] || [ -L "$source" ] || continue
    parent="$(dirname "$stage/.claude/$relative")"
    mkdir -p "$parent"
    cp -pR "$source" "$stage/.claude/$relative"
  done
  if [ -e "$home_dir/.claude.json" ] || [ -L "$home_dir/.claude.json" ]; then
    source="$(safe_user_profile_path "$home_dir/.claude.json")" || {
      say "Unsafe .claude.json was rejected; backup was not created."
      return 1
    }
    cp -pR "$source" "$stage/.claude.json"
  fi
  date -u '+%Y-%m-%dT%H:%M:%SZ' > "$stage/BACKUP_COMPLETE"
  mv "$stage" "$destination"
  chmod 700 "$destination" "$destination/.claude" 2>/dev/null || true
  say "Backup created: $destination"
}

remove_claude_code_root_account_metadata() {
  local root_config temporary
  root_config="$(safe_user_profile_path "$home_dir/.claude.json")" || {
    say "Warning: .claude.json is unsafe; account metadata was not modified."
    return 1
  }
  [ -f "$root_config" ] || return 0
  if [ "$dry_run" = "1" ]; then
    say "Would remove account-specific fields from: $root_config"
    return 0
  fi
  if ! command -v osascript >/dev/null 2>&1; then
    say "Warning: osascript is unavailable; could not remove account-specific fields from .claude.json."
    return 1
  fi
  temporary="$root_config.cleanup-$$-$RANDOM.tmp"
  if osascript -l JavaScript - "$root_config" "$temporary" <<'JXA'
ObjC.import('Foundation');
function run(argv) {
  const text = $.NSString.stringWithContentsOfFileEncodingError(argv[0], $.NSUTF8StringEncoding, null);
  const config = JSON.parse(ObjC.unwrap(text));
  if (!config || typeof config !== 'object' || Array.isArray(config)) throw new Error('Root config is not a JSON object');
  ['oauthAccount', 'userID', 'machineID', 'mcpServers'].forEach(function (key) { delete config[key]; });
  const output = $(JSON.stringify(config, null, 2) + '\n');
  if (!output.writeToFileAtomicallyEncodingError(argv[1], true, $.NSUTF8StringEncoding, null)) throw new Error('Failed to write cleaned JSON');
}
JXA
  then
    mv "$temporary" "$root_config"
    say "Removed account-specific fields from .claude.json while preserving project and user settings."
    return 0
  fi
  rm -f "$temporary"
  say "Warning: could not remove account-specific fields from .claude.json."
  return 1
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

safe_user_profile_path() {
  local path="$1" normalized physical
  normalized="$(normalize_path "$path")" || return 1
  case "$normalized" in "$home_dir"/*) ;; *) return 1 ;; esac
  [ "$normalized" != "$home_dir" ] || return 1
  [ ! -L "$normalized" ] || return 1
  if [ -d "$normalized" ]; then
    physical="$(cd "$normalized" 2>/dev/null && pwd -P)" || return 1
    [ "$physical" = "$normalized" ] || return 1
  fi
  printf '%s\n' "$normalized"
}

get_claude_code_config_dir() {
  safe_user_profile_path "${CLAUDE_CONFIG_DIR:-$home_dir/.claude}"
}

stop_claude_code_processes() {
  if [ "$dry_run" = "1" ]; then
    say "Would run: pkill -x claude"
    say "Would stop @anthropic-ai/claude-code processes"
    return 0
  fi
  pkill -x claude >/dev/null 2>&1 || true
  pkill -f '@anthropic-ai/claude-code' >/dev/null 2>&1 || true
  if pgrep -x claude >/dev/null 2>&1 || pgrep -f '@anthropic-ai/claude-code' >/dev/null 2>&1; then
    say "Warning: Claude Code is still running."
    return 1
  fi
  return 0
}

clear_claude_code_keychain_service() {
  local service="$1" find_status
  if [ "$dry_run" = "1" ]; then
    say "Would remove keychain service: $service"
    return 0
  fi
  if ! command -v security >/dev/null 2>&1; then
    say "Warning: security is unavailable; could not verify keychain service: $service"
    record_cleanup_failure "Keychain service $service (security unavailable)"
    return 0
  fi
  if security find-generic-password -s "$service" >/dev/null 2>&1; then
    find_status=0
  else
    find_status=$?
  fi
  if [ "$find_status" -eq 44 ]; then return 0; fi
  if [ "$find_status" -ne 0 ]; then
    say "Warning: could not inspect keychain service: $service"
    record_cleanup_failure "Keychain service $service (cannot inspect)"
    return 0
  fi
  if ! security delete-generic-password -s "$service" >/dev/null 2>&1; then
    say "Warning: could not remove keychain service: $service"
    record_cleanup_failure "Keychain service $service"
    return 0
  fi
  if security find-generic-password -s "$service" >/dev/null 2>&1; then
    say "Warning: keychain service remains after cleanup: $service"
    record_cleanup_failure "Keychain service $service"
  fi
  return 0
}

migration_path_mtime() {
  if [ "$(uname -s)" = "Darwin" ]; then
    stat -f '%m' "$1" 2>/dev/null || printf '0\n'
  else
    stat -c '%Y' "$1" 2>/dev/null || printf '0\n'
  fi
}

find_latest_claude_code_cleanup_backup() {
  local backup_root candidate latest="" latest_time=0 current_time completed_latest="" completed_time=0
  backup_root="$(safe_user_profile_path "$home_dir/.claude-cleanup-backups")" || return 1
  [ -d "$backup_root" ] || return 1
  shopt -s nullglob
  local candidates=("$backup_root"/*)
  shopt -u nullglob
  for candidate in "${candidates[@]}"; do
    [ -d "$candidate/.claude" ] || continue
    current_time="$(migration_path_mtime "$candidate")"
    if [ -f "$candidate/BACKUP_COMPLETE" ] && [ "$current_time" -gt "$completed_time" ]; then
      completed_latest="$candidate"
      completed_time="$current_time"
    fi
    if [ "$current_time" -gt "$latest_time" ]; then
      latest="$candidate"
      latest_time="$current_time"
    fi
  done
  if [ -n "$completed_latest" ]; then
    printf '%s\n' "$completed_latest"
  elif [ -n "$latest" ]; then
    printf '%s\n' "$latest"
  else
    return 1
  fi
}

assert_no_migration_symlinks() {
  local path="$1" linked
  [ -e "$path" ] || [ -L "$path" ] || return 0
  if [ -L "$path" ]; then
    say "Unsafe symbolic link was rejected: $path"
    return 1
  fi
  [ -d "$path" ] || return 0
  linked="$(find "$path" -type l -print -quit 2>/dev/null)"
  if [ -n "$linked" ]; then
    say "Unsafe symbolic link was rejected: $linked"
    return 1
  fi
  return 0
}

migration_file_count() {
  if [ -d "$1" ]; then
    find "$1" -type f 2>/dev/null | wc -l | tr -d ' '
  else
    printf '0\n'
  fi
}

merge_migration_directory_no_clobber() {
  local source_dir="$1" target_dir="$2"
  [ -d "$source_dir" ] || return 0
  mkdir -p "$target_dir"
  cp -pRn "$source_dir/." "$target_dir/"
}

merge_migration_history() {
  local source_file="$1" target_file="$2" temporary
  [ -f "$source_file" ] || return 0
  if [ ! -f "$target_file" ]; then
    cp -p "$source_file" "$target_file"
    return 0
  fi
  temporary="$target_file.migration-$$-$RANDOM.tmp"
  awk 'NF && !seen[$0]++ { print }' "$target_file" "$source_file" > "$temporary"
  mv "$temporary" "$target_file"
}

merge_migration_settings() {
  local source_file="$1" target_file="$2" temporary
  [ -f "$source_file" ] || return 0
  if [ -e "$target_file" ] || [ -L "$target_file" ]; then
    assert_no_migration_symlinks "$target_file" || return 1
  fi
  if ! command -v osascript >/dev/null 2>&1; then
    say "Warning: osascript is unavailable; could not merge sanitized settings: $source_file"
    return 1
  fi
  temporary="$target_file.migration-$$-$RANDOM.tmp"
  if ! osascript -l JavaScript - "$source_file" "$target_file" "$temporary" <<'JXA'
ObjC.import('Foundation');
function readJson(path) {
  const fm = $.NSFileManager.defaultManager;
  if (!fm.fileExistsAtPath(path)) return {};
  const text = $.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null);
  const value = JSON.parse(ObjC.unwrap(text));
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('Settings must be a JSON object');
  return value;
}
function sensitiveKey(key) {
  return /^(mcpservers?|.*(token|secret|password|credential|authorization|cookie|api[_-]?key|auth|headers?).*)$/i.test(key);
}
function sanitize(value) {
  if (Array.isArray(value)) return value.map(sanitize);
  if (!value || typeof value !== 'object') return value;
  const result = {};
  Object.keys(value).forEach(function (key) {
    if (!sensitiveKey(key)) result[key] = sanitize(value[key]);
  });
  return result;
}
function mergeNoClobber(source, destination) {
  Object.keys(source).forEach(function (key) {
    if (!(key in destination)) destination[key] = source[key];
    else if (source[key] && destination[key] && typeof source[key] === 'object' && typeof destination[key] === 'object' && !Array.isArray(source[key]) && !Array.isArray(destination[key])) mergeNoClobber(source[key], destination[key]);
  });
  return destination;
}
function run(argv) {
  const source = sanitize(readJson(argv[0]));
  const destination = readJson(argv[1]);
  const output = $(JSON.stringify(mergeNoClobber(source, destination), null, 2) + '\n');
  if (!output.writeToFileAtomicallyEncodingError(argv[2], true, $.NSUTF8StringEncoding, null)) throw new Error('Failed to write merged settings');
}
JXA
  then
    rm -f "$temporary"
    say "Warning: could not merge sanitized settings: $source_file"
    return 1
  fi
  chmod 600 "$temporary" 2>/dev/null || true
  mv "$temporary" "$target_file"
}

restore_migration_directory() {
  local current_path="$1" rollback_path="$2"
  if [ -e "$current_path" ] || [ -L "$current_path" ]; then
    rm -rf "$current_path" || return 1
  fi
  [ ! -e "$current_path" ] && [ ! -L "$current_path" ] || return 1
  mv "$rollback_path" "$current_path" || return 1
  [ -d "$current_path" ]
}

restore_migration_file() {
  local current_path="$1" rollback_path="$2"
  if [ -e "$current_path" ] || [ -L "$current_path" ]; then
    rm -f "$current_path" || return 1
  fi
  [ ! -e "$current_path" ] && [ ! -L "$current_path" ] || return 1
  mv "$rollback_path" "$current_path" || return 1
  [ -f "$current_path" ]
}

migrate_claude_code_data() {
  local source_input="$migration_source" source_path source_config="" source_root_json="" source_parent
  local destination rollback_root candidate_root merge_dirs copy_if_missing_files settings_files name has_importable=0
  local current_login_found=0 source_project_files destination_project_files destination_parent destination_name
  local stage root_stage timestamp rollback_dir destination_root_json root_merge_ready=0 stage_project_files imported_project_files
  local destination_moved=0 destination_installed=0 root_moved=0 root_installed=0 settings_merged=0 answer

  destination="$(get_claude_code_config_dir)" || {
    say "Unsafe CLAUDE_CONFIG_DIR was rejected; migration skipped: ${CLAUDE_CONFIG_DIR:-$home_dir/.claude}"
    return 1
  }
  rollback_root="$(safe_user_profile_path "$home_dir/.claude-migration-backups")" || {
    say "Unsafe migration rollback directory was rejected."
    return 1
  }
  case "$rollback_root" in "$home_dir"/*) ;; *) say "Migration rollback directory must be inside HOME."; return 1 ;; esac
  [ "$rollback_root" != "$destination" ] || { say "Migration rollback directory cannot equal the Claude Code directory."; return 1; }
  case "$rollback_root/" in "$destination"/*) say "Migration rollback directory cannot be inside the Claude Code directory."; return 1 ;; esac
  case "$destination/" in "$rollback_root"/*) say "Claude Code directory cannot be inside the migration rollback directory."; return 1 ;; esac

  if [ -z "$source_input" ]; then
    source_input="$(find_latest_claude_code_cleanup_backup)" || {
      say "No Claude Code cleanup backup was found. Use --source to choose an old .claude or backup directory."
      return 1
    }
    say "Using latest cleanup backup: $source_input"
  fi
  # Check the original source path before normalize_path resolves a linked
  # parent directory and hides the symbolic-link entry point.
  assert_no_migration_symlinks "$source_input" || return 1
  source_path="$(normalize_path "$source_input")" || { say "Migration source does not exist: $source_input"; return 1; }
  if [ -d "$source_path/.claude" ]; then
    source_config="$(normalize_path "$source_path/.claude")"
    [ -f "$source_path/.claude.json" ] && source_root_json="$source_path/.claude.json"
  elif [ "$(basename "$source_path")" = ".claude" ] || [ -d "$source_path/projects" ] || [ -f "$source_path/history.jsonl" ]; then
    source_config="$source_path"
    source_parent="$(dirname "$source_path")"
    [ -f "$source_parent/.claude.json" ] && source_root_json="$source_parent/.claude.json"
  else
    say "Migration source has no recognizable Claude Code data: $source_path"
    return 1
  fi
  assert_no_migration_symlinks "$source_config" || return 1
  [ -z "$source_root_json" ] || assert_no_migration_symlinks "$source_root_json" || return 1
  [ "$source_config" != "$destination" ] || { say "Migration source cannot be the current Claude Code directory."; return 1; }
  case "$source_config/" in "$destination"/*) say "Migration source cannot be inside the current Claude Code directory."; return 1 ;; esac

  merge_dirs=(projects sessions commands agents skills plugins backups session-env shell-snapshots todos plans)
  settings_files=(settings.json settings.local.json)
  # Settings and MCP configuration can carry old credentials, headers, or
  # router endpoints. Only import project guidance, never runtime settings.
  copy_if_missing_files=(CLAUDE.md)
  for name in "${merge_dirs[@]}" "${copy_if_missing_files[@]}" history.jsonl; do
    [ -e "$source_config/$name" ] && has_importable=1
  done
  [ "$has_importable" -eq 1 ] || { say "Migration source contains no supported Claude Code work data."; return 1; }
  for name in "${merge_dirs[@]}" "${copy_if_missing_files[@]}" history.jsonl; do
    assert_no_migration_symlinks "$source_config/$name" || return 1
  done
  if [ "$include_settings" = "1" ]; then
    for name in "${settings_files[@]}"; do
      assert_no_migration_symlinks "$source_config/$name" || return 1
    done
  fi

  if [ -f "$destination/.credentials.json" ] || [ -n "${ANTHROPIC_API_KEY:-}" ] || [ -n "${ANTHROPIC_AUTH_TOKEN:-}" ] || [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
    current_login_found=1
  elif command -v security >/dev/null 2>&1; then
    for name in "Claude Code-credentials" "Claude Code" "Claude Code OAuth" "claude-code"; do
      if security find-generic-password -s "$name" >/dev/null 2>&1; then current_login_found=1; break; fi
    done
  fi
  source_project_files="$(migration_file_count "$source_config/projects")"
  destination_project_files="$(migration_file_count "$destination/projects")"
  say ""
  say "Claude Code data migration plan"
  say "  Source: $source_config"
  say "  Current account: $destination"
  say "  Rollback backup: $rollback_root"
  say "  Source project files: $source_project_files"
  say "  Current project files: $destination_project_files"
  say "  Current login: $([ "$current_login_found" -eq 1 ] && printf 'detected and preserved' || printf 'not detected')"
  say "Source credentials, cache, telemetry, oauthAccount, userID, and machineID are never imported."
  say "Current-account files win on conflict; old data fills only missing files."
  if [ "$include_settings" = "1" ]; then
    say "Sanitized settings.json and settings.local.json will be merged; config.json and MCP settings are never imported."
  else
    say "Settings were backed up but will not be migrated. Use --include-settings to opt in to a sanitized settings merge."
  fi
  if [ "$current_login_found" -ne 1 ] && [ "$allow_logged_out" != "1" ]; then
    say "No current-account login was detected. Sign in first or explicitly use --allow-logged-out."
    return 1
  fi
  if [ "$dry_run" = "1" ]; then
    say "Migration preview complete. No process was stopped and no file was modified."
    return 0
  fi
  if [ "$assume_yes" != "1" ]; then
    printf 'Migrate old local data into the current account? [y/N] '
    IFS= read -r answer
    case "$answer" in y|Y|yes|YES) ;; *) say "Migration cancelled."; return 0 ;; esac
  fi

  say "Stopping Claude Code..."
  if ! stop_claude_code_processes; then
    say "Migration was not started because Claude Code is still running."
    return 1
  fi
  destination_parent="$(dirname "$destination")"
  destination_name="$(basename "$destination")"
  mkdir -p "$destination_parent" "$rollback_root"
  chmod 700 "$rollback_root" 2>/dev/null || true
  stage="$destination_parent/.${destination_name}.migration-stage.$$-$RANDOM"
  root_stage="$destination_parent/.claude-root-migration-stage.$$-$RANDOM.json"
  timestamp="$(date '+%Y%m%d-%H%M%S')"
  rollback_dir="$rollback_root/$timestamp"
  [ ! -e "$rollback_dir" ] || rollback_dir="$rollback_root/$timestamp-$$-$RANDOM"
  mkdir -p "$stage"
  chmod 700 "$stage" 2>/dev/null || true

  cleanup_migration_temps() { rm -rf "$stage" 2>/dev/null || true; rm -f "$root_stage" 2>/dev/null || true; }
  rollback_failed_migration() {
    local rollback_failed=0
    say "Migration commit failed; restoring the current account data."
    if [ "$destination_installed" -eq 1 ] && [ -d "$rollback_dir/current-claude" ]; then
      restore_migration_directory "$destination" "$rollback_dir/current-claude" || rollback_failed=1
    elif [ "$destination_moved" -eq 1 ] && [ -d "$rollback_dir/current-claude" ]; then
      if [ -e "$destination" ] || [ -L "$destination" ] || ! mv "$rollback_dir/current-claude" "$destination" || [ ! -d "$destination" ]; then
        rollback_failed=1
      fi
    fi
    if [ "$root_installed" -eq 1 ] && [ -f "$rollback_dir/current-claude.json" ]; then
      restore_migration_file "$destination_root_json" "$rollback_dir/current-claude.json" || rollback_failed=1
    elif [ "$root_moved" -eq 1 ] && [ -f "$rollback_dir/current-claude.json" ]; then
      if [ -e "$destination_root_json" ] || [ -L "$destination_root_json" ] || ! mv "$rollback_dir/current-claude.json" "$destination_root_json" || [ ! -f "$destination_root_json" ]; then
        rollback_failed=1
      fi
    fi
    if [ "$rollback_failed" -eq 1 ]; then
      say "Automatic rollback was incomplete. Original data remains under: $rollback_dir"
    fi
    return 1
  }
  trap cleanup_migration_temps EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  if [ -d "$destination" ]; then cp -pR "$destination/." "$stage/"; fi
  for name in "${merge_dirs[@]}"; do merge_migration_directory_no_clobber "$source_config/$name" "$stage/$name"; done
  for name in "${copy_if_missing_files[@]}"; do
    [ -f "$source_config/$name" ] && [ ! -e "$stage/$name" ] && cp -p "$source_config/$name" "$stage/$name"
  done
  merge_migration_history "$source_config/history.jsonl" "$stage/history.jsonl"
  if [ "$include_settings" = "1" ]; then
    for name in "${settings_files[@]}"; do
      [ -f "$source_config/$name" ] || continue
      merge_migration_settings "$source_config/$name" "$stage/$name" || return 1
      settings_merged=$((settings_merged + 1))
    done
  fi

  destination_root_json="$(safe_user_profile_path "$home_dir/.claude.json")" || {
    say "Unsafe .claude.json path was rejected."
    return 1
  }
  if [ -n "$source_root_json" ] && command -v osascript >/dev/null 2>&1; then
    if osascript -l JavaScript - "$source_root_json" "$destination_root_json" "$root_stage" <<'JXA'
ObjC.import('Foundation');
function readJson(path) {
  const fm = $.NSFileManager.defaultManager;
  if (!fm.fileExistsAtPath(path)) return {};
  const text = $.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null);
  return JSON.parse(ObjC.unwrap(text));
}
function mergeMap(source, destination, key) {
  const sourceMap = source[key];
  if (!sourceMap || typeof sourceMap !== 'object' || Array.isArray(sourceMap)) return;
  if (!destination[key] || typeof destination[key] !== 'object' || Array.isArray(destination[key])) destination[key] = {};
  Object.keys(sourceMap).forEach(function (name) {
    if (!(name in destination[key])) destination[key][name] = sourceMap[name];
    else if (sourceMap[name] && destination[key][name] && typeof sourceMap[name] === 'object' && typeof destination[key][name] === 'object' && !Array.isArray(sourceMap[name]) && !Array.isArray(destination[key][name])) destination[key][name] = Object.assign({}, sourceMap[name], destination[key][name]);
  });
}
function run(argv) {
  const source = readJson(argv[0]);
  const destination = readJson(argv[1]);
  mergeMap(source, destination, 'projects');
  const output = $(JSON.stringify(destination, null, 2) + '\n');
  if (!output.writeToFileAtomicallyEncodingError(argv[2], true, $.NSUTF8StringEncoding, null)) throw new Error('Failed to write merged JSON');
}
JXA
    then
      chmod 600 "$root_stage" 2>/dev/null || true
      root_merge_ready=1
    else
      say "Warning: .claude.json project registry merge was skipped."
      rm -f "$root_stage"
    fi
  elif [ -n "$source_root_json" ]; then
    say "Warning: osascript is unavailable; .claude.json project registry merge was skipped."
  fi

  stage_project_files="$(migration_file_count "$stage/projects")"
  imported_project_files=$((stage_project_files - destination_project_files))
  [ "$imported_project_files" -ge 0 ] || imported_project_files=0
  mkdir -p "$rollback_dir"
  chmod 700 "$rollback_dir" 2>/dev/null || true
  if [ -d "$destination" ]; then mv "$destination" "$rollback_dir/current-claude" || rollback_failed_migration || return 1; destination_moved=1; fi
  mv "$stage" "$destination" || { rollback_failed_migration; return 1; }
  destination_installed=1
  if [ "$root_merge_ready" -eq 1 ]; then
    if [ -f "$destination_root_json" ]; then mv "$destination_root_json" "$rollback_dir/current-claude.json" || { rollback_failed_migration; return 1; }; root_moved=1; fi
    mv "$root_stage" "$destination_root_json" || { rollback_failed_migration; return 1; }
    root_installed=1
  fi
  if ! cat > "$rollback_dir/MIGRATION_INFO.txt" <<EOF
Migration time: $(date '+%Y-%m-%d %H:%M:%S')
Source: $source_config
Current-account rollback: $rollback_dir
Imported project files: $imported_project_files
Sanitized settings files merged: $settings_merged
EOF
  then
    say "Warning: migration succeeded, but the rollback note could not be written."
  else
    chmod 600 "$rollback_dir/MIGRATION_INFO.txt" 2>/dev/null || true
  fi
  trap - EXIT INT TERM
  cleanup_migration_temps
  say "Migration complete. Imported project files: $imported_project_files"
  if [ "$include_settings" = "1" ]; then say "Sanitized settings files merged: $settings_merged"; fi
  say "Rollback snapshot: $rollback_dir"
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
    --migrate|--migrate-code-data)
      target="migrate"
      shift
      ;;
    --source)
      if [ "$#" -lt 2 ]; then
        usage
        exit 2
      fi
      migration_source="$2"
      shift 2
      ;;
    --yes|-y)
      assume_yes="1"
      shift
      ;;
    --allow-logged-out)
      allow_logged_out="1"
      shift
      ;;
    --include-settings)
      include_settings="1"
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
    migrate|Migrate|migration|m|M|3)
      target="migrate"
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

if [ "$include_settings" = "1" ] && [ "$target" != "migrate" ]; then
  say "--include-settings only applies to target=migrate."
  exit 2
fi

if [ "$target" = "migrate" ]; then
  migrate_claude_code_data
  exit $?
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
  if ! code_config_dir="$(get_claude_code_config_dir)"; then
    say "Unsafe CLAUDE_CONFIG_DIR was rejected; no files were cleaned: ${CLAUDE_CONFIG_DIR:-$home_dir/.claude}"
    exit 1
  fi
  say "Stopping Claude Code..."
  if ! stop_claude_code_processes; then
    say "Cleanup was not started because Claude Code is still running."
    exit 1
  fi

  backup_claude_code_user_data "$code_config_dir"
  say "Backing up Claude Code projects, conversations, settings, extensions, and .claude.json."
  if ! remove_claude_code_root_account_metadata; then
    say "Warning: credentials and cache will still be cleared, but .claude.json account metadata could not be removed."
    record_cleanup_failure ".claude.json account metadata"
  fi
  say "After signing in to the new account, run this same script again and choose option 3 to merge the backup."
  say "Removing Claude Code credentials, cache, and account/runtime configuration..."
  remove_path "$code_config_dir/.credentials.json"
  remove_path "$code_config_dir/cache"
  remove_path "$code_config_dir/settings.json"
  remove_path "$code_config_dir/settings.local.json"
  remove_path "$code_config_dir/config.json"

  keychain_services=(
    "Claude Code-credentials"
    "Claude Code"
    "claude-code"
    "Claude Code OAuth"
  )

  for service in "${keychain_services[@]}"; do
    clear_claude_code_keychain_service "$service"
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

if [ "${#cleanup_failures[@]}" -gt 0 ]; then
  say ""
  say "Cleanup was incomplete. Remaining or unverified targets:"
  for failure in "${cleanup_failures[@]}"; do say "  $failure"; done
  exit 1
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
