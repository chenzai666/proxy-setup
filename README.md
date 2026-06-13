# proxy-setup

终端代理一键配置脚本，让 Codex CLI、Claude Code、npm、git 走代理。

支持 v2rayN / Clash / sing-box 自动检测端口。

## 文件说明

| 文件 | 类型 | 依赖 | 平台 |
|------|------|------|------|
| `setup_proxy.py` | 代理配置 | Python 3 | Windows / Mac / Linux |
| `setup_proxy.sh` | 代理配置 | bash | Mac / Linux |
| `setup_proxy.ps1` | 代理配置 | 无（系统自带） | Windows |
| `install_python.bat` | 环境安装 | 无 | Windows |
| `install_python.sh` | 环境安装 | 无 | Mac / Linux |

## 功能

- 自动检测代理客户端端口（v2rayN guiNConfig.json / Clash config.yaml / sing-box config.json）
- 写入 shell 配置文件（`.zshrc` / `.bashrc` / PowerShell `$PROFILE`）
- Windows CMD 支持（注册表 AutoRun）
- 配置 npm & git 代理
- 代理连通性验证 + 出口 IP 展示（含地区识别）
- 全链路测试（OpenAI + Anthropic API）
- 查看/清空当前会话环境变量

## 快速开始

### 1. 下载

**PowerShell 一键下载：**

```powershell
Invoke-WebRequest -Uri "https://github.com/chenzai666/proxy-setup/archive/refs/heads/master.zip" -OutFile "$env:USERPROFILE\Downloads\proxy-setup.zip"
Expand-Archive -Path "$env:USERPROFILE\Downloads\proxy-setup.zip" -DestinationPath "$env:USERPROFILE\Downloads\proxy-setup" -Force
```

下载完成后进入目录：

```powershell
cd "$env:USERPROFILE\Downloads\proxy-setup\proxy-setup-master"
```

下载完成后运行：

```
.\install_python.bat
```

> 自动检测 Python，无则安装；装完后自动搜索并运行 `setup_proxy.py`。

**或 Git Clone：**

```bash
git clone https://github.com/chenzai666/proxy-setup.git
```

克隆完成后进入目录：

```bash
cd proxy-setup
```

```bash
bash setup_proxy.sh
```

### 2. 纯 PowerShell（无需 Python）

```powershell
powershell -ExecutionPolicy Bypass -File setup_proxy.ps1
```

### Mac / Linux

```bash
bash setup_proxy.sh
```

如果要用 Python 版：

```bash
bash install_python.sh
```

> `install_python.sh` 自动适配 Homebrew（含中科大/清华国内镜像）、apt、yum、dnf、pacman。

