#!/usr/bin/env bash
# ============================================================
#  Python 3 安装脚本（Mac / Linux）
#  proxy-setup 配套，确保 setup_proxy.py 可用
# ============================================================
set -euo pipefail

GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

ok()   { printf '  \033[0;32m✓ %s\033[0m\n' "$1"; }
info() { printf '  \033[0;36m%s\033[0m\n' "$1"; }
warn() { printf '  \033[1;33m⚠ %s\033[0m\n' "$1"; }
err()  { printf '  \033[0;31m✗ %s\033[0m\n' "$1"; }

# ---- 检测当前 Python ----

detect_python() {
    if command -v python3 &>/dev/null; then
        local ver
        ver=$(python3 --version 2>&1)
        ok "已安装: $ver  ($(command -v python3))"
        return 0
    elif command -v python &>/dev/null; then
        local ver
        ver=$(python --version 2>&1)
        ok "已安装: $ver  ($(command -v python))"
        return 0
    fi
    return 1
}

# ---- Homebrew 安装（国内镜像优先）----

install_homebrew() {
    # 国内镜像源（按优先级排序）
    local mirrors=(
        "https://mirrors.ustc.edu.cn/brew-install.sh          中科大"
        "https://mirrors.tuna.tsinghua.edu.cn/homebrew/install.sh  清华"
        "https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh  GitHub官方"
    )

    for entry in "${mirrors[@]}"; do
        local url="${entry%% *}"
        local name="${entry#* }"
        name="${name##* }"
        info "尝试 $name 镜像..."
        if curl -fsSL --connect-timeout 5 --max-time 30 "$url" | /bin/bash -s -- 2>/dev/null; then
            ok "Homebrew 安装成功 ($name)"
            # 确保 brew 在 PATH 中（Apple Silicon / Intel）
            for bp in /opt/homebrew/bin/brew /usr/local/bin/brew; do
                if [[ -f "$bp" ]]; then
                    eval "$("$bp" shellenv)"
                    break
                fi
            done
            return 0
        fi
        warn "$name 不可达，尝试下一个..."
    done

    err "所有镜像均无法连接，请手动安装 Homebrew"
    info "官方: https://brew.sh"
    info "Gitee 国内: https://gitee.com/cunkai/HomebrewCN"
    return 1
}

# ---- Mac 安装 ----

install_mac() {
    info "macOS 检测中..."

    # 方案1: Homebrew
    if command -v brew &>/dev/null; then
        info "通过 Homebrew 安装 Python 3..."
        brew install python@3.13 2>/dev/null || brew install python3
        if command -v python3 &>/dev/null; then
            ok "Python 3 安装成功"
            python3 --version
            return 0
        fi
        err "Homebrew 安装失败"
        return 1
    fi

    # 方案2: 没有 Homebrew，先装 Homebrew（国内镜像优先）
    warn "未检测到 Homebrew"
    printf '  是否先安装 Homebrew（推荐包管理器）？[Y/n] '
    read -r answer
    if [[ -z "$answer" || "$answer" =~ ^[Yy] ]]; then
        install_homebrew
        if command -v brew &>/dev/null; then
            brew install python@3.13 2>/dev/null || brew install python3
            ok "Python 3 安装成功"
            python3 --version
            return 0
        fi
    fi

    # 方案3: 手动指引
    warn "请手动安装 Python: https://www.python.org/downloads/"
    return 1
}

# ---- Linux 安装 ----

install_linux() {
    info "Linux 检测中..."

    if command -v apt-get &>/dev/null; then
        info "apt-get 安装 Python 3..."
        sudo apt-get update -qq && sudo apt-get install -y python3 python3-venv python3-pip
    elif command -v yum &>/dev/null; then
        info "yum 安装 Python 3..."
        sudo yum install -y python3 python3-pip
    elif command -v dnf &>/dev/null; then
        info "dnf 安装 Python 3..."
        sudo dnf install -y python3 python3-pip
    elif command -v pacman &>/dev/null; then
        info "pacman 安装 Python 3..."
        sudo pacman -S --noconfirm python python-pip
    elif command -v apk &>/dev/null; then
        info "apk 安装 Python 3..."
        sudo apk add python3 py3-pip
    else
        err "未识别的 Linux 发行版，请手动安装 python3"
        return 1
    fi

    if command -v python3 &>/dev/null; then
        ok "Python 3 安装成功"
        python3 --version
        return 0
    fi
    err "安装失败"
    return 1
}

# ---- 检测并运行 setup_proxy ----

find_and_run_setup() {
    echo ""
    info "检测同目录下的代理配置脚本..."

    local script_dir
    script_dir="$(cd "$(dirname "$0")" && pwd)"

    local found=""
    if [[ -f "$script_dir/setup_proxy.sh" ]]; then
        found="$script_dir/setup_proxy.sh"
    elif [[ -f "$script_dir/../setup_proxy.sh" ]]; then
        found="$script_dir/../setup_proxy.sh"
    elif [[ -f "$HOME/Downloads/setup_proxy.sh" ]]; then
        found="$HOME/Downloads/setup_proxy.sh"
    elif [[ -f "$HOME/Downloads/proxy-setup/setup_proxy.sh" ]]; then
        found="$HOME/Downloads/proxy-setup/setup_proxy.sh"
    elif [[ -f "$HOME/Downloads/proxy-setup-master/setup_proxy.sh" ]]; then
        found="$HOME/Downloads/proxy-setup-master/setup_proxy.sh"
    elif [[ -f "$HOME/Downloads/proxy-setup-main/setup_proxy.sh" ]]; then
        found="$HOME/Downloads/proxy-setup-main/setup_proxy.sh"
    fi

    if [[ -n "$found" ]]; then
        ok "找到: $found"
        printf '  是否运行代理配置脚本？[Y/n] '
        read -r answer
        if [[ -z "$answer" || "$answer" =~ ^[Yy] ]]; then
            bash "$found"
            return $?
        fi
    else
        warn "未找到 setup_proxy.sh"
        info "你可以手动下载:"
        info "  git clone https://github.com/chenzai666/proxy-setup.git"
        info "  cd proxy-setup && bash setup_proxy.sh"
    fi
}

# ---- 主流程 ----

main() {
    echo ""
    printf '\033[1m=== Python 3 安装脚本 ===\033[0m\n'
    echo ""

    # 已安装 → 提示并检测 setup 脚本
    if detect_python; then
        find_and_run_setup
        return 0
    fi

    warn "未检测到 Python 3，开始安装..."
    echo ""

    local os_type
    os_type=$(uname -s)

    case "$os_type" in
        Darwin)
            install_mac || return 1
            find_and_run_setup
            ;;
        Linux)
            install_linux || return 1
            find_and_run_setup
            ;;
        *)
            err "不支持的系统: $os_type"
            info "请手动安装: https://www.python.org/downloads/"
            return 1
            ;;
    esac
}

main "$@"
