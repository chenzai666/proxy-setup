#!/usr/bin/env bash
set -euo pipefail

# Merge surviving Claude Code local work records into the current macOS account.
# Source credentials and account metadata are never imported.

source_input=""
destination_input="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
backup_root_input="${CLAUDE_MIGRATION_BACKUP_ROOT:-$HOME/.claude-migration-backups}"
dry_run=0
assume_yes=0
allow_logged_out=0

home_dir="${HOME:?HOME is not set}"
home_dir="$(cd "$home_dir" 2>/dev/null && pwd -P)" || {
  printf '%s\n' "HOME does not exist: $HOME" >&2
  exit 1
}

say()  { printf '%s\n' "$*"; }
info() { printf '  \033[0;36m%s\033[0m\n' "$*" >&2; }
ok()   { printf '  \033[0;32m[OK] %s\033[0m\n' "$*" >&2; }
warn() { printf '  \033[1;33m[WARN] %s\033[0m\n' "$*" >&2; }
err()  { printf '  \033[0;31m[ERR] %s\033[0m\n' "$*" >&2; }

usage() {
  cat <<'EOF'
用法：
  bash migrate_claude_code_account_macos.sh [选项]

选项：
  --source PATH          旧数据目录。可以是 .claude 目录，或包含 .claude 的备份目录。
                         未指定时自动选择 ~/.claude-cleanup-backups 下最新备份。
  --destination PATH     当前账号 Claude 配置目录，默认 ~/.claude。
  --backup-root PATH     当前数据的回滚备份目录，默认 ~/.claude-migration-backups。
  --dry-run              只检查和显示迁移计划，不写入任何文件。
  --yes                  跳过确认提示。
  --allow-logged-out     未检测到当前账号凭据时仍允许迁移。
  -h, --help             显示帮助。

迁移内容：
  projects、sessions、history.jsonl、commands、agents、skills、plugins、
  backups、session-env、shell-snapshots、todos、plans，以及缺失的用户设置。

永不迁移：
  .credentials.json、cache、telemetry，以及旧账号 oauthAccount/userID。
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --source)
      [ "$#" -ge 2 ] || { err "--source 缺少路径"; exit 2; }
      source_input="$2"
      shift 2
      ;;
    --destination)
      [ "$#" -ge 2 ] || { err "--destination 缺少路径"; exit 2; }
      destination_input="$2"
      shift 2
      ;;
    --backup-root)
      [ "$#" -ge 2 ] || { err "--backup-root 缺少路径"; exit 2; }
      backup_root_input="$2"
      shift 2
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    --yes|-y)
      assume_yes=1
      shift
      ;;
    --allow-logged-out)
      allow_logged_out=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      err "未知参数: $1"
      usage
      exit 2
      ;;
  esac
done

normalize_existing_dir() {
  local path=$1
  [ -d "$path" ] || return 1
  (cd "$path" 2>/dev/null && pwd -P)
}

normalize_future_path() {
  local path=$1 dir base suffix=""
  case "$path" in
    /*) ;;
    *) path="$PWD/$path" ;;
  esac
  dir=$(dirname "$path")
  base=$(basename "$path")
  while [ ! -d "$dir" ] && [ "$dir" != "/" ]; do
    suffix="$(basename "$dir")/${suffix}"
    dir=$(dirname "$dir")
  done
  [ -d "$dir" ] || return 1
  dir="$(cd "$dir" 2>/dev/null && pwd -P)"
  printf '%s/%s%s\n' "$dir" "$suffix" "$base"
}

path_mtime() {
  stat -f '%m' "$1" 2>/dev/null || stat -c '%Y' "$1" 2>/dev/null || printf '0\n'
}

find_latest_cleanup_backup() {
  local root="$home_dir/.claude-cleanup-backups" candidate latest="" latest_time=0 current_time
  [ -d "$root" ] || return 1
  shopt -s nullglob
  local candidates=("$root"/*)
  shopt -u nullglob
  for candidate in "${candidates[@]}"; do
    [ -d "$candidate/.claude" ] || continue
    current_time=$(path_mtime "$candidate")
    if [ "$current_time" -gt "$latest_time" ]; then
      latest="$candidate"
      latest_time=$current_time
    fi
  done
  [ -n "$latest" ] || return 1
  printf '%s\n' "$latest"
}

if [ -z "$source_input" ]; then
  if source_input="$(find_latest_cleanup_backup)"; then
    info "自动选择最新清理备份: $source_input"
  else
    err "未找到可自动使用的备份，请通过 --source 指定旧 .claude 或备份目录。"
    exit 1
  fi
fi

source_path="$(normalize_existing_dir "$source_input")" || {
  err "源目录不存在: $source_input"
  exit 1
}

source_config=""
source_root_json=""
if [ -d "$source_path/.claude" ]; then
  source_config="$(normalize_existing_dir "$source_path/.claude")"
  [ -f "$source_path/.claude.json" ] && source_root_json="$source_path/.claude.json"
elif [ "$(basename "$source_path")" = ".claude" ] || [ -d "$source_path/projects" ] || [ -f "$source_path/history.jsonl" ]; then
  source_config="$source_path"
  source_parent=$(dirname "$source_path")
  [ -f "$source_parent/.claude.json" ] && source_root_json="$source_parent/.claude.json"
else
  err "源目录不包含可识别的 Claude Code 数据: $source_path"
  exit 1
fi

destination="$(normalize_future_path "$destination_input")" || {
  err "无法解析目标目录: $destination_input"
  exit 1
}
backup_root="$(normalize_future_path "$backup_root_input")" || {
  err "无法解析备份目录: $backup_root_input"
  exit 1
}

case "$destination" in
  "$home_dir"/*) ;;
  *) err "目标目录必须位于当前用户 HOME 内: $destination"; exit 1 ;;
esac
[ "$destination" != "$home_dir" ] || { err "目标目录不能是 HOME 本身"; exit 1; }
case "$backup_root" in
  "$home_dir"/*) ;;
  *) err "备份目录必须位于当前用户 HOME 内: $backup_root"; exit 1 ;;
esac

if [ "$source_config" = "$destination" ]; then
  err "源目录和目标目录相同，已停止迁移。"
  exit 1
fi
case "$source_config/" in
  "$destination"/*) err "源目录不能位于目标目录内部。"; exit 1 ;;
esac
case "$backup_root/" in
  "$destination"/*) err "回滚备份目录不能位于目标目录内部。"; exit 1 ;;
esac
case "$destination/" in
  "$backup_root"/*) err "目标目录不能位于回滚备份目录内部。"; exit 1 ;;
esac
[ "$backup_root" != "$destination" ] || { err "目标目录和回滚备份目录不能相同。"; exit 1; }

merge_dirs=(projects sessions commands agents skills plugins backups session-env shell-snapshots todos plans)
copy_if_missing_files=(settings.json settings.local.json config.json CLAUDE.md)

has_importable=0
for name in "${merge_dirs[@]}"; do
  [ -e "$source_config/$name" ] && has_importable=1
done
for name in "${copy_if_missing_files[@]}" history.jsonl; do
  [ -e "$source_config/$name" ] && has_importable=1
done
[ "$has_importable" -eq 1 ] || {
  err "源目录没有 projects、history、sessions 或可迁移的用户配置。"
  exit 1
}

count_files() {
  local path=$1
  if [ -d "$path" ]; then
    find "$path" -type f 2>/dev/null | wc -l | tr -d ' '
  else
    printf '0\n'
  fi
}

source_project_files=$(count_files "$source_config/projects")
destination_project_files=$(count_files "$destination/projects")

current_login_found=0
if [ -f "$destination/.credentials.json" ] ||
   [ -n "${ANTHROPIC_API_KEY:-}" ] ||
   [ -n "${ANTHROPIC_AUTH_TOKEN:-}" ] ||
   [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  current_login_found=1
elif command -v security >/dev/null 2>&1; then
  for service in "Claude Code-credentials" "Claude Code OAuth" "claude-code"; do
    if security find-generic-password -s "$service" >/dev/null 2>&1; then
      current_login_found=1
      break
    fi
  done
fi

say ""
say "Claude Code 旧数据迁移计划"
say "  源数据:       $source_config"
say "  当前账号目录: $destination"
say "  回滚备份目录: $backup_root"
say "  源项目文件数: $source_project_files"
say "  当前项目文件: $destination_project_files"
say "  当前登录凭据: $([ "$current_login_found" -eq 1 ] && printf '已检测到，将保留' || printf '未检测到')"
say ""
say "源账号凭据、cache、telemetry、oauthAccount 和 userID 不会导入。"
say "同名文件冲突时保留当前账号版本；旧数据只补充缺失内容。"

if [ "$current_login_found" -ne 1 ] && [ "$allow_logged_out" -ne 1 ]; then
  err "未检测到当前新账号登录凭据。请先登录新账号，或明确使用 --allow-logged-out。"
  exit 1
fi

if [ "$dry_run" -eq 1 ]; then
  say ""
  ok "预演完成，没有停止进程、复制或修改任何文件。"
  exit 0
fi

if [ "$assume_yes" -ne 1 ]; then
  printf '确认开始迁移？[y/N] '
  IFS= read -r answer
  case "$answer" in
    y|Y|yes|YES) ;;
    *) warn "已取消，未修改任何文件。"; exit 0 ;;
  esac
fi

destination_parent=$(dirname "$destination")
destination_name=$(basename "$destination")
mkdir -p "$destination_parent" "$backup_root"
chmod 700 "$backup_root" 2>/dev/null || true

stage="$destination_parent/.${destination_name}.migration-stage.$$"
root_stage="$destination_parent/.claude-root-migration-stage.$$.json"
timestamp="$(date '+%Y%m%d-%H%M%S')"
rollback_dir="$backup_root/$timestamp"
if [ -e "$rollback_dir" ]; then
  rollback_dir="$backup_root/$timestamp-$$"
fi

[ ! -e "$stage" ] || { err "临时目录已存在: $stage"; exit 1; }
mkdir -p "$stage"
chmod 700 "$stage" 2>/dev/null || true

cleanup_temps() {
  rm -rf "$stage" 2>/dev/null || true
  rm -f "$root_stage" 2>/dev/null || true
}
trap cleanup_temps EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

info "停止 Claude Code，避免迁移过程中继续写入会话..."
pkill -x claude >/dev/null 2>&1 || true
pkill -f '@anthropic-ai/claude-code' >/dev/null 2>&1 || true

if [ -d "$destination" ]; then
  info "复制当前账号数据到 staging..."
  cp -pR "$destination/." "$stage/"
fi

merge_directory_no_clobber() {
  local source_dir=$1 target_dir=$2
  [ -d "$source_dir" ] || return 0
  mkdir -p "$target_dir"
  cp -pRn "$source_dir/." "$target_dir/"
}

info "合并旧项目、会话和扩展配置..."
for name in "${merge_dirs[@]}"; do
  merge_directory_no_clobber "$source_config/$name" "$stage/$name"
done

for name in "${copy_if_missing_files[@]}"; do
  if [ -f "$source_config/$name" ] && [ ! -e "$stage/$name" ]; then
    cp -p "$source_config/$name" "$stage/$name"
  fi
done

if [ -f "$source_config/history.jsonl" ]; then
  if [ -f "$stage/history.jsonl" ]; then
    history_tmp="$stage/.history-merge.$$"
    awk 'NF && !seen[$0]++ { print }' "$stage/history.jsonl" "$source_config/history.jsonl" > "$history_tmp"
    mv "$history_tmp" "$stage/history.jsonl"
  else
    cp -p "$source_config/history.jsonl" "$stage/history.jsonl"
  fi
fi

# Source authentication and volatile cache never reach the new account because
# only the allowlisted directories/files above are merged. Existing target
# credentials and cache remain untouched in staging.

destination_root_json="$home_dir/.claude.json"
root_merge_ready=0
if [ -n "$source_root_json" ] && command -v osascript >/dev/null 2>&1; then
  info "合并 .claude.json 中的 projects/mcpServers 登记（不导入账号字段）..."
  if osascript -l JavaScript - "$source_root_json" "$destination_root_json" "$root_stage" <<'JXA'
ObjC.import('Foundation');

function readJson(path) {
  const fm = $.NSFileManager.defaultManager;
  if (!fm.fileExistsAtPath(path)) return {};
  const text = $.NSString.stringWithContentsOfFileEncodingError(
    path, $.NSUTF8StringEncoding, null
  );
  return JSON.parse(ObjC.unwrap(text));
}

function mergeMap(source, destination, key) {
  const sourceMap = source[key];
  if (!sourceMap || typeof sourceMap !== 'object' || Array.isArray(sourceMap)) return;
  if (!destination[key] || typeof destination[key] !== 'object' || Array.isArray(destination[key])) {
    destination[key] = {};
  }
  Object.keys(sourceMap).forEach(function (name) {
    if (!(name in destination[key])) {
      destination[key][name] = sourceMap[name];
    } else if (sourceMap[name] && destination[key][name] &&
               typeof sourceMap[name] === 'object' &&
               typeof destination[key][name] === 'object' &&
               !Array.isArray(sourceMap[name]) && !Array.isArray(destination[key][name])) {
      destination[key][name] = Object.assign({}, sourceMap[name], destination[key][name]);
    }
  });
}

function run(argv) {
  const source = readJson(argv[0]);
  const destination = readJson(argv[1]);
  mergeMap(source, destination, 'projects');
  mergeMap(source, destination, 'mcpServers');
  // Account-bound source fields (oauthAccount, userID, machineID) are intentionally ignored.
  const output = $(JSON.stringify(destination, null, 2) + '\n');
  const written = output.writeToFileAtomicallyEncodingError(
    argv[2], true, $.NSUTF8StringEncoding, null
  );
  if (!written) throw new Error('Failed to write merged JSON');
}
JXA
  then
    chmod 600 "$root_stage" 2>/dev/null || true
    root_merge_ready=1
  else
    warn ".claude.json 项目登记合并失败；会话文件仍可迁移，但旧项目首次打开时可能需要重新授权。"
    rm -f "$root_stage"
  fi
elif [ -n "$source_root_json" ]; then
  warn "系统没有 osascript，跳过 .claude.json 项目登记合并。"
fi

stage_project_files=$(count_files "$stage/projects")
imported_project_files=$((stage_project_files - destination_project_files))
if [ "$imported_project_files" -lt 0 ]; then imported_project_files=0; fi

mkdir -p "$rollback_dir"
chmod 700 "$rollback_dir" 2>/dev/null || true

destination_moved=0
destination_installed=0
root_moved=0
root_installed=0

rollback_failed_commit() {
  local failure_message=$1
  err "$failure_message，正在自动回滚..."
  if [ "$destination_installed" -eq 1 ]; then
    rm -rf "$destination"
  fi
  if [ "$destination_moved" -eq 1 ] && [ -d "$rollback_dir/current-claude" ]; then
    mv "$rollback_dir/current-claude" "$destination"
  fi
  if [ "$root_installed" -eq 1 ]; then
    rm -f "$destination_root_json"
  fi
  if [ "$root_moved" -eq 1 ] && [ -f "$rollback_dir/current-claude.json" ]; then
    mv "$rollback_dir/current-claude.json" "$destination_root_json"
  fi
  exit 1
}

info "原子切换到合并后的数据目录..."
if [ -d "$destination" ]; then
  mv "$destination" "$rollback_dir/current-claude" || rollback_failed_commit "无法备份当前 Claude 目录"
  destination_moved=1
fi
if ! mv "$stage" "$destination"; then
  rollback_failed_commit "无法安装合并后的 Claude 目录"
fi
destination_installed=1

if [ "$root_merge_ready" -eq 1 ]; then
  if [ -f "$destination_root_json" ]; then
    mv "$destination_root_json" "$rollback_dir/current-claude.json" || rollback_failed_commit "无法备份当前 .claude.json"
    root_moved=1
  fi
  if ! mv "$root_stage" "$destination_root_json"; then
    rollback_failed_commit "无法安装合并后的 .claude.json"
  fi
  root_installed=1
fi

chmod 700 "$destination" "$rollback_dir" 2>/dev/null || true
if ! cat > "$rollback_dir/MIGRATION_INFO.txt" <<EOF
迁移时间: $(date '+%Y-%m-%d %H:%M:%S')
源目录: $source_config
目标目录: $destination
迁移前项目文件数: $destination_project_files
源项目文件数: $source_project_files
新增项目文件数: $imported_project_files

current-claude/ 是迁移前当前账号的完整 Claude 配置快照，可能包含当前账号凭据。
确认迁移无误后，请妥善保管或删除该回滚目录。
EOF
then
  warn "迁移已完成，但无法写入回滚说明。"
else
  chmod 600 "$rollback_dir/MIGRATION_INFO.txt" 2>/dev/null || true
fi

trap - EXIT INT TERM
cleanup_temps

say ""
ok "迁移完成"
say "  新增项目文件: $imported_project_files"
say "  当前项目文件: $stage_project_files"
say "  回滚快照:     $rollback_dir"
say ""
say "旧账号凭据没有导入；当前新账号凭据已保留。"
say "重新运行 Claude Code 后，可使用 /resume 检查旧会话，或进入原项目目录继续工作。"
say "注意：已经被 rm -rf 删除且没有备份的对话、云端 Cowork/Chat 数据无法由本脚本恢复。"
