# Proxy Setup

Windows / Mac / Linux 代理一键配置工具，自动检测 v2rayN / Clash / sing-box 端口，支持 Codex CLI 和 Claude Code。

## 远程执行（无需下载）

> 适用于 `setup_proxy.sh` / `setup_proxy.ps1` 等自包含脚本。

**Mac / Linux:**

```bash
curl -sSL https://raw.githubusercontent.com/chenzai666/proxy-setup/master/setup_proxy.sh | bash
```

```bash
# 或 Python 版
curl -sSL https://raw.githubusercontent.com/chenzai666/proxy-setup/master/setup_proxy.py | python3
```

**Windows (PowerShell):**

```powershell
[Console]::OutputEncoding = [Text.Encoding]::UTF8; irm https://cdn.jsdelivr.net/gh/chenzai666/proxy-setup@master/setup_proxy.ps1 | iex
```

> 如果执行策略受限：
> ```powershell
> powershell -ExecutionPolicy Bypass -Command "[Console]::OutputEncoding=[Text.Encoding]::UTF8; irm https://cdn.jsdelivr.net/gh/chenzai666/proxy-setup@master/setup_proxy.ps1 | iex"
> ```
>
> 注：使用 jsdelivr CDN 而非 GitHub Raw（GitHub 会缓存 UTF-8 BOM 导致解析失败），前置 `[Console]::OutputEncoding` 确保中文正常显示。

---

## 下载执行

> 适合需要先查看脚本内容再执行的场景。

### 下载 ZIP

**Windows (PowerShell):**

```powershell
Invoke-WebRequest -Uri "https://github.com/chenzai666/proxy-setup/archive/refs/heads/master.zip" -OutFile "$env:USERPROFILE\Downloads\proxy-setup.zip"
Expand-Archive -Path "$env:USERPROFILE\Downloads\proxy-setup.zip" -DestinationPath "$env:USERPROFILE\Downloads\proxy-setup" -Force
cd "$env:USERPROFILE\Downloads\proxy-setup\proxy-setup-master"
.\install_python.bat
```

**Mac / Linux (curl):**

```bash
curl -L -o ~/Downloads/proxy-setup.tar.gz "https://github.com/chenzai666/proxy-setup/archive/refs/heads/master.tar.gz"
mkdir -p ~/Downloads/proxy-setup
tar -xzf ~/Downloads/proxy-setup.tar.gz -C ~/Downloads/proxy-setup --strip-components=1
cd ~/Downloads/proxy-setup
bash setup_proxy.sh
```

**Mac / Linux (wget):**

```bash
wget -O ~/Downloads/proxy-setup.tar.gz "https://github.com/chenzai666/proxy-setup/archive/refs/heads/master.tar.gz"
mkdir -p ~/Downloads/proxy-setup
tar -xzf ~/Downloads/proxy-setup.tar.gz -C ~/Downloads/proxy-setup --strip-components=1
cd ~/Downloads/proxy-setup
bash setup_proxy.sh
```

---

### 或 Git Clone

```bash
git clone https://github.com/chenzai666/proxy-setup.git
cd proxy-setup
bash setup_proxy.sh
```

---

### 纯 PowerShell（无需 Python，Windows）

```powershell
powershell -ExecutionPolicy Bypass -File setup_proxy.ps1
```

---

### 纯 bash（无需 Python，Mac / Linux）

```bash
bash setup_proxy.sh
```

如果要用 Python 版（先装 Python）：

```bash
bash install_python.sh
```

> `install_python.sh` 自动适配 Homebrew（含中科大/清华国内镜像）、apt、yum、dnf、pacman。安装后自动检测并运行 `setup_proxy.py`。

---

## 文件说明

| 文件 | 类型 | 需要 Python | 平台 |
|------|------|:----------:|------|
| `setup_proxy.sh` | Shell | 否 | Mac / Linux |
| `setup_proxy.py` | Python | 是 | 全平台 |
| `setup_proxy.ps1` | PowerShell | 否 | Windows |
| `install_python.sh` | Shell | 否 | Mac / Linux |
| `install_python.bat` | Batch | 否 | Windows |

## 菜单功能

1. 配置代理（自动检测端口）
2. 配置代理（手动指定端口）
3. 移除所有代理配置
4. 验证当前代理连通性
5. 全链路测试 (OpenAI + Anthropic)
6. 查看当前代理配置
0. 退出
