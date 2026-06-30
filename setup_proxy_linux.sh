#!/usr/bin/env bash
# ============================================================
#  Linux 终端代理一键配置脚本（纯 bash，无需 Python）
#  支持: Clash / ClashX / v2rayN / v2rayU / sing-box
#  适用: Codex CLI / Claude Code / npm / git
#  用法:  source setup_proxy.sh     # 立即生效
#         bash setup_proxy.sh       # 写入配置但不立即生效（需重新开终端）
# ============================================================

set -u

# ─── 配置区 ──────────────────────────────────────────────────
DEFAULT_HTTP_PORT=7890
DEFAULT_SOCKS5_PORT=7891
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
# ───────────────────────────────────────────────────────────────

# 颜色输出
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()  { printf '  \033[0;36m%s\033[0m\n' "$1" >&2; }
ok()    { printf '  \033[0;32m✓ %s\033[0m\n' "$1" >&2; }
warn()  { printf '  \033[1;33m⚠ %s\033[0m\n' "$1" >&2; }
err()   { printf '  \033[0;31m✗ %s\033[0m\n' "$1" >&2; }
bold()  { printf '\033[1m%s\033[0m\n' "$1"; }

# ─── 端口检测 ────────────────────────────────────────────────

detect_clash_ports() {
    local port=0 socks_port=0
    local configs=(
        "$HOME/.config/clash/config.yaml"
        "$HOME/.config/mihomo/config.yaml"
        "$HOME/Library/Application Support/ClashX/config.yaml"
        "$HOME/Library/Application Support/ClashX Pro/config.yaml"
    )
    for cfg in "${configs[@]}"; do
        [[ -f "$cfg" ]] || continue
        # 优先读 mixed-port
        port=$(grep -E "^mixed-port:[[:space:]]*[0-9]+" "$cfg" 2>/dev/null | head -1 | grep -oE "[0-9]+" || echo "")
        [[ -n "$port" ]] && { info "检测到 Clash 混合端口: $port  ($cfg)"; echo "$port $port"; return; }
        # 其次读 port (HTTP)
        port=$(grep -E "^port:[[:space:]]*[0-9]+" "$cfg" 2>/dev/null | head -1 | grep -oE "[0-9]+" || echo "")
        if [[ -n "$port" ]]; then
            socks_port=$(grep -E "^socks-port:[[:space:]]*[0-9]+" "$cfg" 2>/dev/null | head -1 | grep -oE "[0-9]+" || echo "")
            [[ -n "$socks_port" ]] || socks_port=$((port+1))
            info "检测到 Clash HTTP 端口: $port  ($cfg)"
            echo "$port $socks_port"
            return
        fi
    done
    local scanned
    scanned=$(find_listening_port_near "$DEFAULT_HTTP_PORT" "Clash/Mihomo" || true)
    [[ -n "$scanned" ]] && { echo "$scanned $((scanned+1))"; return; }
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

proxy_port_from_env() {
    local proxy_value="${http_proxy:-${https_proxy:-${HTTP_PROXY:-${HTTPS_PROXY:-}}}}"
    [[ -n "$proxy_value" ]] || return 1
    local port
    port=$(printf '%s\n' "$proxy_value" | sed -nE 's#^[a-zA-Z0-9+.-]+://[^/:]+:([0-9]+).*#\1#p')
    [[ -n "$port" ]] || return 1
    echo "$port"
}

auto_detect() {
    # 优先检查 v2rayN。很多 v2rayN 混合端口 HTTP/SOCKS 共用 10808。
    local vp sp
    read -r vp sp <<< "$(detect_v2rayn_port)"
    if check_port "$vp"; then
        ok "v2rayN 端口 $vp 正在监听"
        echo "$vp $sp"
        return
    fi

    # 再尊重当前终端已经生效的代理端口，作为手动配置/旧会话 fallback。
    local envp
    if envp=$(proxy_port_from_env); then
        if check_port "$envp"; then
            ok "当前环境代理端口 $envp 正在监听"
            echo "$envp $envp"
            return
        fi
        info "当前环境代理端口 $envp 未监听，继续自动检测"
    fi

    # 再检查 Clash。
    local cp csp
    read -r cp csp <<< "$(detect_clash_ports)"
    if check_port "$cp"; then
        ok "Clash 端口 $cp 正在监听"
        echo "$cp $csp"
        return
    fi

    # 如果 v2rayN 配置给出了端口但没检测到监听，仍优先用它的配置值。
    if [[ -n "$vp" && "$vp" != "0" ]]; then
        warn "未检测到监听端口，使用 v2rayN 配置端口"
        echo "$vp $sp"
        return
    fi
    # 再检查 sing-box
    local sbp=$(detect_singbox_port)
    if check_port "$sbp"; then
        ok "sing-box 端口 $sbp 正在监听"
        echo "$sbp $((sbp+1))"
        return
    fi
    # 默认 clash 端口
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

# ─── RC 文件路径（Linux）────────────────────────────────────
get_rc_file() {
    case "${SHELL:-}" in
        */zsh)
            echo "$HOME/.zshrc"
            ;;
        */bash|"")
            echo "$HOME/.bashrc"
            ;;
        *)
            warn "未识别当前登录 shell: ${SHELL:-unknown}，默认写入 ~/.profile"
            echo "$HOME/.profile"
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
        # 删除旧块
        local tmp
        tmp=$(mktemp)
        local in_block=0
        while IFS= read -r line; do
            if [[ "$line" == "$PROXY_BLOCK_START"* ]]; then
                in_block=1
                continue
            fi
            if [[ "$line" == "$PROXY_BLOCK_END"* ]]; then
                in_block=0
                continue
            fi
            [[ $in_block -eq 0 ]] && echo "$line" >> "$tmp"
        done < "$rc"
        # 追加新块
        echo "" >> "$tmp"
        echo "$block" >> "$tmp"
        mv "$tmp" "$rc"
        ok "已更新 $rc"
    else
        echo "$block" > "$rc"
        ok "已创建 $rc"
    fi
}

# ─── npm / git ────────────────────────────────────────────────

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

remove_all() {
    local rc
    rc=$(get_rc_file)

    if [[ -f "$rc" ]]; then
        local tmp; tmp=$(mktemp)
        local in_block=0
        while IFS= read -r line; do
            if [[ "$line" == "$PROXY_BLOCK_START"* ]]; then in_block=1; continue; fi
            if [[ "$line" == "$PROXY_BLOCK_END"* ]]; then in_block=0; continue; fi
            [[ $in_block -eq 0 ]] && echo "$line" >> "$tmp"
        done < "$rc"
        mv "$tmp" "$rc"
        ok "已从 $rc 移除代理配置"
    fi
    command -v npm >/dev/null 2>&1 && { npm config delete proxy 2>/dev/null; npm config delete https-proxy 2>/dev/null; ok "npm 代理已清除"; }
    command -v git >/dev/null 2>&1 && { git config --global --unset http.proxy 2>/dev/null || true; git config --global --unset https.proxy 2>/dev/null || true; ok "git 代理已清除"; }
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
    bold "  Linux 代理一键配置 — Codex / Claude Code"
    bold "=============================================="
    echo "  1) 配置代理（自动检测端口）"
    echo "  2) 配置代理（手动指定端口）"
    echo "  3) 移除所有代理配置"
    echo "  4) 验证当前代理连通性"
    echo "  5) 全链路测试 (OpenAI + Anthropic)"
    echo "  6) 查看当前代理配置"
    echo "  7) 检测出口 IP (Claude + OpenAI cf-trace)"
    echo "  8) 清空当前会话环境变量"
    echo "  0) 退出"
    echo ""
}

main() {
    local rc
    rc=$(get_rc_file)
    info "代理配置将写入: $rc"

    while true; do
        print_menu
        read -rp "请选择 [0-8]: " choice
        case $choice in
            1)
                read -r hp sp <<< "$(auto_detect)"
                info "使用端口: HTTP=$hp, SOCKS5=$sp"
                write_zshrc "$hp" "$sp"
                configure_npm "$hp"
                read -rp "  是否同时配置 git 代理？[y/N] " cfg_git
                [[ "$cfg_git" == "y" ]] && configure_git "$hp"
                verify_proxy "$hp"
                set_env_current "$hp" "$sp"
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
                read -rp "  输入 SOCKS5 代理端口 [默认 $((hp+1))]: " s
                sp=${s:-$((hp+1))}
                write_zshrc "$hp" "$sp"
                configure_npm "$hp"
                read -rp "  是否同时配置 git 代理？[y/N] " cfg_git
                [[ "$cfg_git" == "y" ]] && configure_git "$hp"
                verify_proxy "$hp"
                set_env_current "$hp" "$sp"
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
                clean_current_env
                show_current_config
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
