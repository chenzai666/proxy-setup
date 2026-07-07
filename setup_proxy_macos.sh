#!/usr/bin/env bash
# ============================================================
#  macOS 终端代理一键配置脚本（纯 bash，无需 Python）
#  支持: Clash / ClashX / v2rayN / v2rayU / sing-box
#  适用: Codex CLI / Claude Code / npm / git
#  用法:  source setup_proxy.sh     # 立即生效
#         bash setup_proxy.sh       # 写入配置但不立即生效（需重新开终端）
# ============================================================

set -u

# ─── 配置区 ──────────────────────────────────────────────────
DEFAULT_HTTP_PORT=7897
DEFAULT_SOCKS5_PORT=7897
PORT_SCAN_RADIUS="${PORT_SCAN_RADIUS:-10}"
HOST="127.0.0.1"
NO_PROXY="localhost,127.0.0.1,::1"
ANTHROPIC_BASE_URL=""   # 中转地址，留空则不写入

CF_TRACE_TARGETS=(
    "Claude Web|https://claude.ai/cdn-cgi/trace"
    "Claude Console|https://console.anthropic.com/cdn-cgi/trace"
    "Anthropic API|https://api.anthropic.com/cdn-cgi/trace"
    "ChatGPT Web|https://chatgpt.com/cdn-cgi/trace"
    "OpenAI API|https://api.openai.com/cdn-cgi/trace"
)

PROXY_BLOCK_START="# >>> proxy-config start <<<"
PROXY_BLOCK_END="# >>> proxy-config end <<<"
CLAUDE_GEO_BLOCK_START="# >>> claude-geo start <<<"
CLAUDE_GEO_BLOCK_END="# >>> claude-geo end <<<"
# ───────────────────────────────────────────────────────────────

# 颜色输出
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()  { printf '  \033[0;36m%s\033[0m\n' "$1" >&2; }
ok()    { printf '  \033[0;32m✓ %s\033[0m\n' "$1" >&2; }
warn()  { printf '  \033[1;33m⚠ %s\033[0m\n' "$1" >&2; }
err()   { printf '  \033[0;31m✗ %s\033[0m\n' "$1" >&2; }
bold()  { printf '\033[1m%s\033[0m\n' "$1"; }

require_platform() {
    local os_name
    os_name="$(uname -s 2>/dev/null || echo unknown)"
    if [[ "$os_name" != "Darwin" ]]; then
        err "setup_proxy_macos.sh must run on macOS (Darwin), current OS: $os_name"
        err "Use setup_proxy.ps1 on Windows."
        exit 1
    fi
}

require_platform

# ─── 端口检测 ────────────────────────────────────────────────

detect_clash_ports() {
    local port=0 socks_port=0
    local configs=(
        "$HOME/.config/clash/config.yaml"
        "$HOME/.config/mihomo/config.yaml"
        "$HOME/Library/Application Support/ClashX/config.yaml"
        "$HOME/Library/Application Support/ClashX Pro/config.yaml"
        "$HOME/Library/Application Support/Clash Verge/config.yaml"
        "$HOME/Library/Application Support/Clash Verge Rev/config.yaml"
        "$HOME/Library/Application Support/clash-verge-rev/config.yaml"
        "$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/config.yaml"
    )
    local extra_dirs=(
        "$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev"
        "$HOME/Library/Application Support/clash-verge-rev"
        "$HOME/Library/Application Support/Clash Verge"
        "$HOME/Library/Application Support/Clash Verge Rev"
        "$HOME/Library/Application Support/Mihomo Party"
    )
    local dir cfg
    for dir in "${extra_dirs[@]}"; do
        [[ -d "$dir" ]] || continue
        while IFS= read -r cfg; do
            configs+=("$cfg")
        done < <(find "$dir" -maxdepth 2 -type f \( -name '*.yaml' -o -name '*.yml' \) 2>/dev/null)
    done
    for cfg in "${configs[@]}"; do
        [[ -f "$cfg" ]] || continue
        # 优先读 mixed-port
        port=$(grep -E "^[[:space:]]*mixed-port:[[:space:]]*[0-9]+" "$cfg" 2>/dev/null | head -1 | grep -oE "[0-9]+" || echo "")
        [[ -n "$port" ]] && { info "检测到 Clash 混合端口: $port  ($cfg)"; echo "$port $port"; return; }
        # 其次读 port (HTTP)
        port=$(grep -E "^[[:space:]]*port:[[:space:]]*[0-9]+" "$cfg" 2>/dev/null | head -1 | grep -oE "[0-9]+" || echo "")
        if [[ -n "$port" ]]; then
            socks_port=$(grep -E "^[[:space:]]*socks-port:[[:space:]]*[0-9]+" "$cfg" 2>/dev/null | head -1 | grep -oE "[0-9]+" || echo "")
            [[ -n "$socks_port" ]] || socks_port=$((port+1))
            info "检测到 Clash HTTP 端口: $port  ($cfg)"
            echo "$port $socks_port"
            return
        fi
    done
    local scanned
    scanned=$(find_listening_port_near "$DEFAULT_HTTP_PORT" "Clash/Mihomo" || true)
    [[ -n "$scanned" ]] && { echo "$scanned $scanned"; return; }
    echo "$DEFAULT_HTTP_PORT $DEFAULT_SOCKS5_PORT"
}

detect_clash_port() {
    local hp sp
    read -r hp sp <<< "$(detect_clash_ports)"
    echo "$hp"
}

detect_v2rayn_port() {
    local http_port=10808 socks_port=10808
    local configs=(
        "$HOME/.config/v2rayN/guiNConfig.json"
        "$HOME/Library/Application Support/v2rayN/guiNConfig.json"
        "$HOME/v2rayN/guiNConfig.json"
    )
    for cfg in "${configs[@]}"; do
        [[ -f "$cfg" ]] || continue
        # 纯 bash/grep/sed 解析 JSON，不依赖 python3
        local raw_http raw_socks
        raw_http=$(grep -o '"httpPort"[[:space:]]*:[[:space:]]*[0-9]*' "$cfg" 2>/dev/null | grep -oE '[0-9]+$' | head -1)
        raw_socks=$(grep -o '"socksPort"[[:space:]]*:[[:space:]]*[0-9]*' "$cfg" 2>/dev/null | grep -oE '[0-9]+$' | head -1)
        [[ -n "$raw_http"  ]] && http_port=$raw_http
        [[ -n "$raw_socks" ]] && socks_port=$raw_socks || socks_port=$http_port
        info "检测到 v2rayN 端口: HTTP=$http_port, SOCKS=$socks_port  ($cfg)"
        echo "$http_port $socks_port"
        return
    done
    # 没有配置文件，嗅探端口（混合端口模式下 HTTP+SOCKS 共用一个端口）
    for base_port in 10808 1080; do
        p=$(find_listening_port_near "$base_port" "v2rayN" || true)
        if [[ -n "$p" ]]; then
            echo "$p $p"
            return
        fi
    done
    echo "10808 10808"
}

detect_singbox_port() {
    local port=$DEFAULT_HTTP_PORT
    local configs=(
        "$HOME/.config/sing-box/config.json"
        "$HOME/.config/sing-box/config.yaml"
    )
    for cfg in "${configs[@]}"; do
        [[ -f "$cfg" ]] || continue
        port=$(grep -oE '"listen_port"[[:space:]]*:[[:space:]]*[0-9]+' "$cfg" 2>/dev/null | grep -oE "[0-9]+" | head -1 || echo "")
        [[ -n "$port" ]] && { info "检测到 sing-box 端口: $port  ($cfg)"; echo "$port"; return; }
    done
    echo "$port"
}

check_port() {
    local port=$1
    lsof -iTCP:"$port" -sTCP:LISTEN -n -P >/dev/null 2>&1
}

port_scan_candidates() {
    local base=$1
    local offset p radius="${PORT_SCAN_RADIUS:-10}"
    for ((offset=0; offset<=radius; offset++)); do
        for p in $((base-offset)) $((base+offset)); do
            [[ "$p" -ge 1 && "$p" -le 65535 ]] || continue
            printf '%s\n' "$p"
        done
    done | awk '!seen[$0]++'
}

find_listening_port_near() {
    local base=$1 label=$2 p
    while IFS= read -r p; do
        if check_port "$p"; then
            info "端口扫描: $label 在 $p 监听（基准 $base ±${PORT_SCAN_RADIUS:-10}）"
            echo "$p"
            return 0
        fi
    done < <(port_scan_candidates "$base")
    return 1
}

auto_detect() {
    local cp csp
    read -r cp csp <<< "$(detect_clash_ports)"
    local vp sp
    read -r vp sp <<< "$(detect_v2rayn_port)"
    local sbp
    sbp=$(detect_singbox_port)

    local candidates=(
        "v2rayN:$vp:$sp"
        "Clash/Mihomo:$cp:$csp"
        "sing-box:$sbp:$((sbp+1))"
    )
    local candidate name hp socks found
    for candidate in "${candidates[@]}"; do
        IFS=: read -r name hp socks <<< "$candidate"
        found=$(find_listening_port_near "$hp" "$name" 2>/dev/null || true)
        if [[ -n "$found" ]]; then
            info "自动检测: $name 端口 $found 正在监听"
            echo "$found $(( found + socks - hp ))"
            return
        fi
    done

    warn "未检测到监听端口，使用默认值"
    echo "$DEFAULT_HTTP_PORT $DEFAULT_SOCKS5_PORT"
}

# ─── 写入 ~/.zshrc ────────────────────────────────────────────

build_proxy_block() {
    local hp=$1 sp=$2
    local lines=("$PROXY_BLOCK_START")
    lines+=("export http_proxy=\"http://$HOST:$hp\"")
    lines+=("export https_proxy=\"http://$HOST:$hp\"")
    lines+=("export all_proxy=\"socks5://$HOST:$sp\"")
    lines+=("export HTTP_PROXY=\"http://$HOST:$hp\"")
    lines+=("export HTTPS_PROXY=\"http://$HOST:$hp\"")
    lines+=("export ALL_PROXY=\"socks5://$HOST:$sp\"")
    lines+=("export no_proxy=\"$NO_PROXY\"")
    lines+=("export NO_PROXY=\"$NO_PROXY\"")
    [[ -n "$ANTHROPIC_BASE_URL" ]] && lines+=("export ANTHROPIC_BASE_URL=\"$ANTHROPIC_BASE_URL\"")
    lines+=("$PROXY_BLOCK_END")
    printf '%s\n' "${lines[@]}"
}

# ─── RC 文件路径（macOS）────────────────────────────────────
get_rc_file() {
    if [[ -n "${PROXY_SETUP_RC_FILE:-}" ]]; then
        echo "$PROXY_SETUP_RC_FILE"
        return
    fi

    case "${SHELL:-}" in
        */zsh|"")
            echo "$HOME/.zshrc"
            ;;
        */bash)
            if [[ -x /bin/zsh || -x /usr/bin/zsh ]]; then
                info "检测到 macOS zsh 可用，默认写入 ~/.zshrc；如需 bash，请设置 PROXY_SETUP_RC_FILE=$HOME/.bash_profile"
                echo "$HOME/.zshrc"
            else
                echo "$HOME/.bash_profile"
            fi
            ;;
        *)
            warn "未识别当前登录 shell: ${SHELL:-unknown}，默认写入 ~/.zshrc"
            echo "$HOME/.zshrc"
            ;;
    esac
}

write_zshrc() {
    local hp=$1 sp=$2
    local rc
    rc=$(get_rc_file)

    local block
    block=$(build_proxy_block "$hp" "$sp")

    if [[ -f "$rc" ]]; then
        cp "$rc" "${rc}.proxy-bak" 2>/dev/null || true
        local tmp
        tmp=$(mktemp) || { err "创建临时文件失败"; return 1; }
        chmod --reference="$rc" "$tmp" 2>/dev/null || chmod 644 "$tmp"
        local in_block=0
        while IFS= read -r line; do
            if [[ "$line" == "$PROXY_BLOCK_START"* ]]; then
                in_block=1; continue
            fi
            if [[ "$line" == "$PROXY_BLOCK_END"* ]]; then
                in_block=0; continue
            fi
            [[ $in_block -eq 0 ]] && printf '%s\n' "$line" >> "$tmp"
        done < "$rc"
        # 去除末尾多余空行，追加新块（避免多次运行积累空行）
        local tmp2
        tmp2=$(mktemp) || { rm -f "$tmp"; err "创建临时文件失败"; return 1; }
        awk 'NF{f=NR} {a[NR]=$0} END{for(i=1;i<=f;i++) print a[i]}' "$tmp" > "$tmp2" && mv "$tmp2" "$tmp"
        printf '\n' >> "$tmp"
        printf '%s\n' "$block" >> "$tmp"
        mv "$tmp" "$rc"
        ok "已更新 $rc"
    else
        printf '%s\n' "$block" > "$rc"
        ok "已创建 $rc"
    fi
}

# ─── npm / git ────────────────────────────────────────────────

claude_geo_dir() {
    printf '%s/.proxy-setup' "$HOME"
}

claude_geo_launcher_path() {
    printf '%s/claude-geo' "$(claude_geo_dir)"
}

install_claude_geo_launcher() {
    local hp=$1 sp=$2
    local dir launcher rc body tmp in_block
    dir="$(claude_geo_dir)"
    launcher="$(claude_geo_launcher_path)"
    rc="$(get_rc_file)"
    mkdir -p "$dir"

    body=$(cat <<'CLAUDE_GEO_SCRIPT'
#!/usr/bin/env bash
set -u
PROXY_HOST="127.0.0.1"
HTTP_PORT=__HTTP_PORT__
SOCKS_PORT=__SOCKS_PORT__
NO_PROXY_VALUE="${NO_PROXY:-${no_proxy:-localhost,127.0.0.1,::1}}"
IPINFO_TOKEN="${IPINFO_TOKEN:-}"
CLAUDE_COMMAND="claude"
PRINT_ONLY=0
CLAUDE_ARGS=()

while [ "$#" -gt 0 ]; do
    case "$1" in
        --proxy-host) PROXY_HOST="$2"; shift 2 ;;
        --http-port)  HTTP_PORT="$2";  shift 2 ;;
        --socks-port) SOCKS_PORT="$2"; shift 2 ;;
        --claude-command) CLAUDE_COMMAND="$2"; shift 2 ;;
        --print-only) PRINT_ONLY=1; shift ;;
        --) shift; CLAUDE_ARGS=("$@"); break ;;
        *) CLAUDE_ARGS+=("$1"); shift ;;
    esac
done
HTTP_PROXY_URL="http://${PROXY_HOST}:${HTTP_PORT}"
SOCKS_PROXY_URL="socks5://${PROXY_HOST}:${SOCKS_PORT}"

json_value() {
    local key="$1"
    sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1
}

fetch_json() {
    curl -fsS --proxy "$HTTP_PROXY_URL" --connect-timeout 5 --max-time 12 "$1" 2>/dev/null || true
}

emit_profile() {
    local provider="$1" json="$2"
    local ip country region city timezone isp success
    case "$provider" in
        ipapi)
            ip="$(printf '%s' "$json" | json_value ip)"
            country="$(printf '%s' "$json" | json_value country_code)"
            region="$(printf '%s' "$json" | json_value region)"
            city="$(printf '%s' "$json" | json_value city)"
            timezone="$(printf '%s' "$json" | json_value timezone)"
            isp="$(printf '%s' "$json" | json_value org)"
            ;;
        ipinfo)
            ip="$(printf '%s' "$json" | json_value ip)"
            country="$(printf '%s' "$json" | json_value country)"
            region="$(printf '%s' "$json" | json_value region)"
            city="$(printf '%s' "$json" | json_value city)"
            timezone="$(printf '%s' "$json" | json_value timezone)"
            isp="$(printf '%s' "$json" | json_value org)"
            ;;
        *)
            success="$(printf '%s' "$json" | sed -n 's/.*"success"[[:space:]]*:[[:space:]]*\(true\|false\).*/\1/p' | head -1)"
            [ "$success" = "true" ] || return 1
            ip="$(printf '%s' "$json" | json_value ip)"
            country="$(printf '%s' "$json" | json_value country_code)"
            region="$(printf '%s' "$json" | json_value region)"
            city="$(printf '%s' "$json" | json_value city)"
            timezone="$(printf '%s' "$json" | json_value timezone)"
            isp="$(printf '%s' "$json" | json_value isp)"
            ;;
    esac
    [ -n "$ip" ] && [ -n "$country" ] && [ -n "$timezone" ] || return 1
    printf 'ok=true\nprovider=%s\nip=%s\ncountryCode=%s\nregion=%s\ncity=%s\ntimezone=%s\nisp=%s\n' "$provider" "$ip" "$country" "$region" "$city" "$timezone" "$isp"
}

profile_value() {
    local key="$1"
    awk -F= -v k="$key" '$1 == k { print substr($0, length(k) + 2); exit }'
}

fetch_exit_profile() {
    local json
    json="$(fetch_json "https://ipapi.co/json/")"
    emit_profile ipapi "$json" && return 0
    if [ -n "$IPINFO_TOKEN" ]; then
        json="$(fetch_json "https://ipinfo.io/json?token=${IPINFO_TOKEN}")"
    else
        json="$(fetch_json "https://ipinfo.io/json")"
    fi
    emit_profile ipinfo "$json" && return 0
    json="$(fetch_json "https://ipwho.is/")"
    emit_profile ipwhois "$json" && return 0
    printf 'ok=false\nerror=all providers failed\n'
}

locale_bundle() {
    local country_code timezone language base posix_locale
    country_code="$(printf '%s' "${1:-}" | tr '[:lower:]' '[:upper:]')"
    timezone="${2:-}"
    case "$country_code" in
        CN) language="zh-CN" ;; HK) language="zh-HK" ;; MO) language="zh-MO" ;; TW) language="zh-TW" ;;
        US) language="en-US" ;; GB) language="en-GB" ;; CA) language="en-CA" ;; AU) language="en-AU" ;; NZ) language="en-NZ" ;; SG) language="en-SG" ;;
        JP) language="ja-JP" ;; KR) language="ko-KR" ;; DE) language="de-DE" ;; FR) language="fr-FR" ;; IT) language="it-IT" ;; ES) language="es-ES" ;; NL) language="nl-NL" ;;
        BR) language="pt-BR" ;; PT) language="pt-PT" ;; RU) language="ru-RU" ;; IN) language="en-IN" ;; ID) language="id-ID" ;; TH) language="th-TH" ;; VN) language="vi-VN" ;; PH) language="en-PH" ;; MY) language="ms-MY" ;;
        *) language="en-US" ;;
    esac
    base="${language%%-*}"
    posix_locale="$(printf '%s.UTF-8' "$(printf '%s' "$language" | tr '-' '_')")"
    printf 'language=%s\nposixLocale=%s\nacceptLanguage=%s,%s;q=0.9\ntimezone=%s\n' "$language" "$posix_locale" "$language" "$base" "$timezone"
}

PROFILE_TEXT="$(fetch_exit_profile)"
PROFILE_OK="$(printf '%s\n' "$PROFILE_TEXT" | profile_value ok)"
if [ "$PROFILE_OK" != "true" ]; then
    printf '无法检测代理出口画像: %s\n' "$(printf '%s\n' "$PROFILE_TEXT" | profile_value error)" >&2
    exit 1
fi
EXIT_IP="$(printf '%s\n' "$PROFILE_TEXT" | profile_value ip)"
EXIT_COUNTRY="$(printf '%s\n' "$PROFILE_TEXT" | profile_value countryCode)"
EXIT_REGION="$(printf '%s\n' "$PROFILE_TEXT" | profile_value region)"
EXIT_CITY="$(printf '%s\n' "$PROFILE_TEXT" | profile_value city)"
EXIT_TIMEZONE="$(printf '%s\n' "$PROFILE_TEXT" | profile_value timezone)"
BUNDLE="$(locale_bundle "$EXIT_COUNTRY" "$EXIT_TIMEZONE")"
LANGUAGE_TAG="$(printf '%s\n' "$BUNDLE" | profile_value language)"
POSIX_LOCALE="$(printf '%s\n' "$BUNDLE" | profile_value posixLocale)"
ACCEPT_LANGUAGE="$(printf '%s\n' "$BUNDLE" | profile_value acceptLanguage)"

printf 'Claude Code geo profile:\n'
printf '  Exit: %s %s/%s/%s %s\n' "$EXIT_IP" "$EXIT_COUNTRY" "$EXIT_REGION" "$EXIT_CITY" "$EXIT_TIMEZONE"
printf '  Locale: %s (%s)\n' "$LANGUAGE_TAG" "$POSIX_LOCALE"

export HTTP_PROXY="$HTTP_PROXY_URL" HTTPS_PROXY="$HTTP_PROXY_URL" ALL_PROXY="$SOCKS_PROXY_URL" NO_PROXY="$NO_PROXY_VALUE"
export http_proxy="$HTTP_PROXY_URL" https_proxy="$HTTP_PROXY_URL" all_proxy="$SOCKS_PROXY_URL" no_proxy="$NO_PROXY_VALUE"
export TZ="$EXIT_TIMEZONE" LANG="$POSIX_LOCALE" LC_ALL="$POSIX_LOCALE" LC_MESSAGES="$POSIX_LOCALE" LANGUAGE="$LANGUAGE_TAG" ACCEPT_LANGUAGE="$ACCEPT_LANGUAGE"

if [ "$PRINT_ONLY" = "1" ]; then
    env | grep -E '^(HTTP_PROXY|HTTPS_PROXY|ALL_PROXY|NO_PROXY|TZ|LANG|LC_ALL|LC_MESSAGES|LANGUAGE|ACCEPT_LANGUAGE)=' | sort
    exit 0
fi
exec "$CLAUDE_COMMAND" "${CLAUDE_ARGS[@]}"
CLAUDE_GEO_SCRIPT
)
    body="${body//__HTTP_PORT__/$hp}"
    body="${body//__SOCKS_PORT__/$sp}"
    printf '%s\n' "$body" > "$launcher"
    chmod +x "$launcher"
    ok "已写入 Claude Code 画像启动器: $launcher"

    tmp=$(mktemp) || { err "创建临时文件失败"; return 1; }
    if [[ -f "$rc" ]]; then
        in_block=0
        while IFS= read -r line; do
            if [[ "$line" == "$CLAUDE_GEO_BLOCK_START"* ]]; then in_block=1; continue; fi
            if [[ "$line" == "$CLAUDE_GEO_BLOCK_END"* ]]; then in_block=0; continue; fi
            [[ $in_block -eq 0 ]] && printf '%s\n' "$line" >> "$tmp"
        done < "$rc"
    fi
    {
        printf '\n%s\n' "$CLAUDE_GEO_BLOCK_START"
        printf 'claude-geo() { "%s" "$@"; }\n' "$launcher"
        printf 'alias cgeo=claude-geo\n'
        printf '%s\n' "$CLAUDE_GEO_BLOCK_END"
    } >> "$tmp"
    mv "$tmp" "$rc"
    ok "已安装 shell 命令: claude-geo (别名 cgeo)"
    info "以后从新终端运行 claude-geo，即可按当前代理出口自动匹配 TZ/LANG 后启动 Claude Code"
}

remove_claude_geo_launcher() {
    local rc tmp in_block launcher
    rc="$(get_rc_file)"
    if [[ -f "$rc" ]]; then
        tmp=$(mktemp) || { err "创建临时文件失败"; return 1; }
        in_block=0
        while IFS= read -r line; do
            if [[ "$line" == "$CLAUDE_GEO_BLOCK_START"* ]]; then in_block=1; continue; fi
            if [[ "$line" == "$CLAUDE_GEO_BLOCK_END"* ]]; then in_block=0; continue; fi
            [[ $in_block -eq 0 ]] && printf '%s\n' "$line" >> "$tmp"
        done < "$rc"
        mv "$tmp" "$rc"
        ok "已从 $rc 移除 claude-geo 命令"
    fi
    launcher="$(claude_geo_launcher_path)"
    if [[ -f "$launcher" ]]; then
        rm -f "$launcher"
        ok "已删除 $launcher"
    fi
}

configure_npm() {
    local hp=$1
    if command -v npm >/dev/null 2>&1; then
        npm config set proxy "http://$HOST:$hp" 2>/dev/null
        npm config set https-proxy "http://$HOST:$hp" 2>/dev/null
        ok "npm 代理已设置: http://$HOST:$hp"
    else
        warn "未找到 npm，跳过"
    fi
}

configure_git() {
    local hp=$1
    if command -v git >/dev/null 2>&1; then
        git config --global http.proxy "http://$HOST:$hp" 2>/dev/null
        git config --global https.proxy "http://$HOST:$hp" 2>/dev/null
        ok "git 代理已设置: http://$HOST:$hp"
    else
        warn "未找到 git，跳过"
    fi
}

configure_pip() {
    local hp=$1
    local pip_cmd
    pip_cmd=$(command -v pip3 2>/dev/null || command -v pip 2>/dev/null || echo "")
    if [[ -n "$pip_cmd" ]]; then
        "$pip_cmd" config set global.proxy "http://$HOST:$hp" 2>/dev/null
        ok "pip 代理已设置: http://$HOST:$hp"
    else
        warn "未找到 pip，跳过"
    fi
}

remove_all() {
    local rc
    rc=$(get_rc_file)

    if [[ -f "$rc" ]]; then
        local tmp; tmp=$(mktemp) || { err "创建临时文件失败"; return 1; }
        chmod --reference="$rc" "$tmp" 2>/dev/null || chmod 644 "$tmp"
        local in_block=0
        while IFS= read -r line; do
            if [[ "$line" == "$PROXY_BLOCK_START"* ]]; then in_block=1; continue; fi
            if [[ "$line" == "$PROXY_BLOCK_END"* ]]; then in_block=0; continue; fi
            [[ $in_block -eq 0 ]] && printf '%s\n' "$line" >> "$tmp"
        done < "$rc"
        mv "$tmp" "$rc"
        ok "已从 $rc 移除代理配置"
    fi
    remove_claude_geo_launcher
    command -v npm >/dev/null 2>&1 && { npm config delete proxy 2>/dev/null; npm config delete https-proxy 2>/dev/null; ok "npm 代理已清除"; }
    command -v git >/dev/null 2>&1 && { git config --global --unset http.proxy 2>/dev/null || true; git config --global --unset https.proxy 2>/dev/null || true; ok "git 代理已清除"; }
    local pip_cmd
    pip_cmd=$(command -v pip3 2>/dev/null || command -v pip 2>/dev/null || echo "")
    [[ -n "$pip_cmd" ]] && { "$pip_cmd" config unset global.proxy 2>/dev/null || true; ok "pip 代理已清除"; }
}

clean_current_env() {
    local vars=(http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY no_proxy NO_PROXY ANTHROPIC_BASE_URL)
    for v in "${vars[@]}"; do
        unset "$v" 2>/dev/null
    done
    ok "当前会话代理环境变量已清空"
}

verify_proxy() {
    local hp=$1
    info "验证代理连通性 (curl -x http://$HOST:$hp https://api.openai.com) ..."
    if command -v curl >/dev/null 2>&1; then
        local code="000" exitcode=1 output=""
        if output=$(curl -s -o /dev/null -w "%{http_code}" --proxy "http://$HOST:$hp" --connect-timeout 8 --max-time 15 "https://api.openai.com" 2>/dev/null); then
            exitcode=0
        else
            exitcode=$?
        fi
        code="${output:-000}"
        if [[ "$exitcode" == "0" ]]; then
            ok "代理可用 (HTTP $code)"
            local exit_data exit_ip exit_region
            exit_data=$(curl -s --proxy "http://$HOST:$hp" --connect-timeout 5 --max-time 8 \
                "http://ip-api.com/json?fields=country,city,regionName,isp,query" 2>/dev/null || echo "")
            if [[ -n "$exit_data" && "$exit_data" == "{"* ]]; then
                exit_ip=$(echo "$exit_data" | grep -o '"query":"[^"]*"' | head -1 | sed 's/"query":"\(.*\)"/\1/')
                local country city region isp
                country=$(echo "$exit_data" | grep -o '"country":"[^"]*"' | head -1 | sed 's/"country":"\(.*\)"/\1/')
                region=$(echo "$exit_data" | grep -o '"regionName":"[^"]*"' | head -1 | sed 's/"regionName":"\(.*\)"/\1/')
                city=$(echo "$exit_data" | grep -o '"city":"[^"]*"' | head -1 | sed 's/"city":"\(.*\)"/\1/')
                isp=$(echo "$exit_data" | grep -o '"isp":"[^"]*"' | head -1 | sed 's/"isp":"\(.*\)"/\1/')
                exit_region="$country"
                [[ -n "$region" ]] && exit_region="$exit_region, $region"
                [[ -n "$city" ]] && exit_region="$exit_region, $city"
                [[ -n "$isp" ]] && exit_region="$exit_region [$isp]"
            fi
            if [[ -n "$exit_ip" ]]; then
                if [[ -n "$exit_region" ]]; then
                    ok "出口 IP: $exit_ip  ($exit_region)"
                else
                    ok "出口 IP: $exit_ip"
                fi
            else
                # 兜底：纯 IP 服务
                exit_ip=$(curl -s --proxy "http://$HOST:$hp" --connect-timeout 5 --max-time 8 "https://ifconfig.me" 2>/dev/null || \
                          curl -s --proxy "http://$HOST:$hp" --connect-timeout 5 --max-time 8 "https://api.ipify.org" 2>/dev/null || \
                          curl -s --proxy "http://$HOST:$hp" --connect-timeout 5 --max-time 8 "https://ip.sb" 2>/dev/null || echo "")
                if [[ -n "$exit_ip" && "$exit_ip" != *"{"* && "$exit_ip" != *"<"* ]]; then
                    ok "出口 IP: $exit_ip"
                else
                    info "无法获取出口 IP（不影响使用）"
                fi
            fi
            # 验证 Anthropic API（Claude Code 核心需求）
            local a_code
            a_code=$(curl -s -o /dev/null -w "%{http_code}" --proxy "http://$HOST:$hp" \
                --connect-timeout 8 --max-time 15 "https://api.anthropic.com/v1/models" 2>/dev/null || echo "000")
            case "$a_code" in
                200|401|403) ok "Anthropic API 可达 (HTTP $a_code)" ;;
                000)         warn "Anthropic API 连接失败，Claude Code 可能无法正常使用" ;;
                *)           warn "Anthropic API 返回 $a_code，请检查节点" ;;
            esac
        elif [[ "${code:-000}" == "000" ]]; then
            warn "代理连接失败（curl exitcode=${exitcode:-1}），请确认客户端已启动且端口 $hp 正确"
        else
            warn "代理返回状态码: ${code:-000}（exitcode=${exitcode:-1}），请检查节点是否可用"
        fi
    else
        warn "未找到 curl，跳过验证"
    fi
}

curl_status() {
    local hp=$1 url=$2
    local out exitcode code time_total
    if out=$(curl -s -o /dev/null -w "%{http_code}|%{time_total}" --proxy "http://$HOST:$hp" --connect-timeout 8 --max-time 15 "$url" 2>/dev/null); then
        exitcode=0
    else
        exitcode=$?
    fi
    code=$(echo "${out:-000|0}" | cut -d'|' -f1)
    time_total=$(echo "${out:-000|0}" | cut -d'|' -f2)
    [[ -n "$code" ]] || code="000"
    [[ -n "$time_total" ]] || time_total="0"
    echo "$exitcode|$code|$time_total"
}

full_connectivity_test() {
    local hp=$1
    bold ""
    bold "  全面连通性测试 (端口 $hp)"
    printf "  %s\n" "──────────────────────────────────────────────────"
    printf "  %-20s %-10s %-10s %s\n" "服务" "状态" "耗时" "对应工具"
    printf "  %s\n" "──────────────────────────────────────────────────"

    local all_ok=true
    # OpenAI
    local o_out o_exit o_code o_time
    o_out=$(curl_status "$hp" "https://api.openai.com")
    o_exit=$(echo "$o_out" | cut -d'|' -f1)
    o_code=$(echo "$o_out" | cut -d'|' -f2)
    o_time=$(echo "$o_out" | cut -d'|' -f3)
    local o_ms
    o_ms=$(awk "BEGIN {printf \"%.0f\", $o_time * 1000}" 2>/dev/null || echo "0")

    if [[ "$o_exit" == "0" && "$o_code" != "000" ]]; then
        local tag
        case "$o_code" in 200|401|403|405|421|404) tag="连通" ;; *) tag="$o_code" ;; esac
        printf "  %-20s \033[32m%-10s\033[0m %-8sms Codex\n" "OpenAI API" "[$tag]" "$o_ms"
    else
        all_ok=false
        printf "  %-20s \033[31m%-10s\033[0m %-8sms Codex\n" "OpenAI API" "[失败]" "$o_ms"
    fi

    # Anthropic
    local a_out a_exit a_code a_time
    a_out=$(curl_status "$hp" "https://api.anthropic.com/v1/models")
    a_exit=$(echo "$a_out" | cut -d'|' -f1)
    a_code=$(echo "$a_out" | cut -d'|' -f2)
    a_time=$(echo "$a_out" | cut -d'|' -f3)
    local a_ms
    a_ms=$(awk "BEGIN {printf \"%.0f\", $a_time * 1000}" 2>/dev/null || echo "0")

    if [[ "$a_exit" == "0" && "$a_code" != "000" ]]; then
        local tag
        case "$a_code" in 200|401|403|405|421|404) tag="连通" ;; *) tag="$a_code" ;; esac
        printf "  %-20s \033[32m%-10s\033[0m %-8sms Claude Code\n" "Anthropic API" "[$tag]" "$a_ms"
    else
        all_ok=false
        printf "  %-20s \033[31m%-10s\033[0m %-8sms Claude Code\n" "Anthropic API" "[失败]" "$a_ms"
    fi

    printf "  %s\n" "──────────────────────────────────────────────────"
    if $all_ok; then
        ok "OpenAI & Anthropic 均连通，Codex / Claude Code 可用"
    else
        warn "部分 API 不通，检查对应目标是否被节点屏蔽"
    fi

    # 用 Cloudflare trace 检测出口 IP（Claude + OpenAI）
    printf "  %s\n" "──────────────────────────────────────────────────"
    check_cf_trace_exit_ips "$hp" "false"
}

check_cf_trace_exit_ips() {
    local hp=$1
    local show_raw=${2:-true}
    bold "  出口 IP 检测（通过 Cloudflare trace）:"
    for svc_url in "${CF_TRACE_TARGETS[@]}"; do
        local svc="${svc_url%%|*}"
        local trace_url="${svc_url#*|}"
        local trace_out ip loc colo warp
        trace_out=$(curl -s --proxy "http://$HOST:$hp" --connect-timeout 8 --max-time 12 "$trace_url" 2>/dev/null || echo "")
        if [[ -n "$trace_out" && "$trace_out" == *"="* ]]; then
            ip=$(echo "$trace_out" | grep -E "^ip=" | head -1 | cut -d'=' -f2)
            loc=$(echo "$trace_out" | grep -E "^loc=" | head -1 | cut -d'=' -f2)
            colo=$(echo "$trace_out" | grep -E "^colo=" | head -1 | cut -d'=' -f2)
            warp=$(echo "$trace_out" | grep -E "^warp=" | head -1 | cut -d'=' -f2)
            local parts=("$svc 出口 IP: $ip")
            [[ -n "$loc" ]] && parts+=("地区: $loc")
            [[ -n "$colo" ]] && parts+=("接入: $colo")
            [[ -n "$warp" && "$warp" != "off" ]] && parts+=("WARP: $warp")
            local joined="${parts[0]}"
            local i
            for ((i = 1; i < ${#parts[@]}; i++)); do
                joined+=" | ${parts[$i]}"
            done
            ok "$joined"

            if [[ "$show_raw" == "true" ]]; then
                echo ""
                echo "  --- $svc trace 原始输出 ---"
                echo "$trace_out" | while IFS= read -r line; do
                    echo "  $line"
                done
                printf "  %s\n" "──────────────────────────────────────────────────────"
            fi
        else
            warn "  $svc: 无法访问 $trace_url"
        fi
    done
}

set_env_current() {
    local hp=$1 sp=$2
    export http_proxy="http://$HOST:$hp"
    export https_proxy="http://$HOST:$hp"
    export all_proxy="socks5://$HOST:$sp"
    export HTTP_PROXY="http://$HOST:$hp"
    export HTTPS_PROXY="http://$HOST:$hp"
    export ALL_PROXY="socks5://$HOST:$sp"
    export no_proxy="$NO_PROXY"
    export NO_PROXY="$NO_PROXY"
    [[ -n "$ANTHROPIC_BASE_URL" ]] && export ANTHROPIC_BASE_URL="$ANTHROPIC_BASE_URL"
    ok "当前终端会话代理环境变量已设置"
}

show_current_config() {
    bold ""
    bold "  当前环境代理配置:"
    printf "  %s\n" "─────────────────────────────────────────────────"
    local keys=("http_proxy:HTTP 代理" "https_proxy:HTTPS 代理" "all_proxy:SOCKS5 代理" "no_proxy:不走代理")
    for kp in "${keys[@]}"; do
        local k="${kp%%:*}" label="${kp##*:}"
        local v="${!k:-}"
        if [[ -n "$v" ]]; then
            printf "  %-12s  \033[32m%s\033[0m\n" "$label" "$v"
        else
            printf "  %-12s  \033[31m未设置\033[0m\n" "$label"
        fi
    done
    if [[ -n "${ANTHROPIC_BASE_URL:-}" ]]; then
        printf "  %-12s  \033[32m%s\033[0m\n" "Anthropic" "${ANTHROPIC_BASE_URL}"
    fi
    printf "  %s\n" "─────────────────────────────────────────────────"
    ok "代理环境变量已生效"
}

# ─── 菜单 ────────────────────────────────────────────────────

print_menu() {
    bold "=============================================="
    bold "  macOS 代理一键配置 — Codex / Claude Code"
    bold "=============================================="
    echo "  1) 配置代理（自动检测端口）"
    echo "  2) 配置代理（手动指定端口）"
    echo "  3) 移除所有代理配置"
    echo "  4) 验证当前代理连通性"
    echo "  5) 全链路测试 (OpenAI + Anthropic)"
    echo "  6) 查看当前代理配置"
    echo "  7) 检测出口 IP (Claude + OpenAI cf-trace)"
    echo "  8) 清空当前会话环境变量"
    echo "  9) 安装/更新 Claude Code 画像一致启动器 (claude-geo)"
    echo "  0) 退出"
    echo ""
}

main() {
    local rc
    rc=$(get_rc_file)
    info "代理配置将写入: $rc"

    while true; do
        print_menu
        read -rp "请选择 [0-9]: " choice
        case $choice in
            1)
                read -r hp sp <<< "$(auto_detect)"
                info "使用端口: HTTP=$hp, SOCKS5=$sp"
                write_zshrc "$hp" "$sp"
                configure_npm "$hp"
                configure_pip "$hp"
                read -rp "  是否同时配置 git 代理？[y/N] " cfg_git
                [[ "$cfg_git" == "y" ]] && configure_git "$hp"
                verify_proxy "$hp"
                set_env_current "$hp" "$sp"
                install_claude_geo_launcher "$hp" "$sp"
                show_current_config
                echo ""
                bold "=== 配置完成 ==="
                warn "http_proxy 环境变量不代理 DNS 查询，存在 DNS 泄漏风险"
                info "防泄漏：v2rayN 开启 TUN 模式 / 浏览器设 SOCKS5 并关闭系统 DNS"
                echo ""
                bold "  请运行以下命令使环境变量立即生效（当前终端）："
                printf '    \033[0;36msource %s\033[0m\n' "$rc"
                echo "  或重新打开终端后自动生效。"
                ;;
            2)
                read -rp "  输入 HTTP 代理端口 [默认 $DEFAULT_HTTP_PORT]: " h
                hp=${h:-$DEFAULT_HTTP_PORT}
                read -rp "  输入 SOCKS5 代理端口 [默认 $hp]: " s
                sp=${s:-$hp}
                write_zshrc "$hp" "$sp"
                configure_npm "$hp"
                configure_pip "$hp"
                read -rp "  是否同时配置 git 代理？[y/N] " cfg_git
                [[ "$cfg_git" == "y" ]] && configure_git "$hp"
                verify_proxy "$hp"
                set_env_current "$hp" "$sp"
                install_claude_geo_launcher "$hp" "$sp"
                show_current_config
                echo ""
                bold "=== 配置完成 ==="
                warn "http_proxy 环境变量不代理 DNS 查询，存在 DNS 泄漏风险"
                info "防泄漏：v2rayN 开启 TUN 模式 / 浏览器设 SOCKS5 并关闭系统 DNS"
                echo ""
                bold "  请运行: source $rc"
                ;;
            3)
                remove_all
                bold "=== 代理配置已全部清除 ==="
                ;;
            4)
                read -r hp _ <<< "$(auto_detect)"
                verify_proxy "$hp"
                ;;
            5)
                read -r hp _ <<< "$(auto_detect)"
                full_connectivity_test "$hp"
                ;;
            6)
                show_current_config
                ;;
            7)
                read -r hp _ <<< "$(auto_detect)"
                bold ""
                bold "  正在通过代理端口 $hp 检测出口 IP ..."
                printf "  %s\n" "──────────────────────────────────────────────────────"
                check_cf_trace_exit_ips "$hp" "true"
                ok "检测完成"
                ;;
            8)
                if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
                    clean_current_env
                    show_current_config
                else
                    warn "此功能仅在 source 模式下有效"
                    info "请改用: source $(get_rc_file)"
                fi
                ;;
            9)
                read -r hp sp <<< "$(auto_detect)"
                info "使用端口: HTTP=$hp, SOCKS5=$sp"
                install_claude_geo_launcher "$hp" "$sp"
                ;;
            0)
                echo "退出"
                break
                ;;
            *)
                warn "无效选项"
                ;;
        esac
        echo ""
    done
}

main "$@"
