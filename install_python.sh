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

    # 方案2: 没有 Homebrew，先装 Homebrew
    warn "未检测到 Homebrew"
    printf '  是否先安装 Homebrew（推荐包管理器）？[Y/n] '
    read -r answer
    if [[ -z "$answer" || "$answer" =~ ^[Yy] ]]; then
        info "安装 Homebrew..."
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        if command -v brew &>/dev/null; then
            # 确保 brew 在 PATH 中（Apple Silicon）
            if [[ -f /opt/homebrew/bin/brew ]]; then
                eval "$(/opt/homebrew/bin/brew shellenv)"
            fi
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

# ---- 主流程 ----

main() {
    echo ""
    printf '\033[1m=== Python 3 安装脚本 ===\033[0m\n'
    echo ""

    # 已安装 → 直接退出
    if detect_python; then
        echo ""
        info "Python 已就绪，可直接运行:" 
        printf '    \033[0;36mbash setup_proxy.sh\033[0m   (纯 Shell 版)\n'
        printf '    \033[0;36mpython3 setup_proxy.py\033[0m  (Python 版)\n'
        return 0
    fi

    warn "未检测到 Python 3，开始安装..."
    echo ""

    local os_type
    os_type=$(uname -s)

    case "$os_type" in
        Darwin)
            install_mac
            ;;
        Linux)
            install_linux
            ;;
        *)
            err "不支持的系统: $os_type"
            info "请手动安装: https://www.python.org/downloads/"
            return 1
            ;;
    esac
}

main "$@"
