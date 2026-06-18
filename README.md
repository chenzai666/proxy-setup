# Proxy Setup

Windows / Mac / Linux 代理一键配置工具，自动检测 v2rayN / Clash / sing-box 端口，支持 Codex CLI 和 Claude Code。

## 远程执行（无需下载）

> 适用于 `setup_proxy.sh` / `setup_proxy.ps1` 等自包含脚本。

**Mac / Linux:**

```bash
curl -sSL https://raw.githubusercontent.com/chenzai666/proxy-setup/master/setup_proxy.sh -o /tmp/sp.sh && bash /tmp/sp.sh && rm /tmp/sp.sh
```

> 注：不能直接 `curl | bash`，管道会抢占 stdin 导致 `read` 无法交互。

```bash
# 或 Python 版（需先下载，管道执行会因 input() 报错）
curl -sSL https://raw.githubusercontent.com/chenzai666/proxy-setup/master/setup_proxy.py -o /tmp/sp.py && python3 /tmp/sp.py && rm /tmp/sp.py
```

**Windows (PowerShell):**

```powershell
$w=New-Object Net.WebClient;$w.Encoding=[Text.Encoding]::UTF8;iex($w.DownloadString('https://raw.githubusercontent.com/chenzai666/proxy-setup/master/setup_proxy.ps1'))
```

> `WebClient` + `iex` 方式直接在内存执行，无 BOM/编码问题，干净可靠。
>
> 如果 GitHub 不通，用国内镜像：
> ```powershell
> $w=New-Object Net.WebClient;$w.Encoding=[Text.Encoding]::UTF8;iex($w.DownloadString('https://gh-proxy.com/https://raw.githubusercontent.com/chenzai666/proxy-setup/master/setup_proxy.ps1'))
> ```

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

**Mac / Linux:**

```bash
git clone https://github.com/chenzai666/proxy-setup.git
cd proxy-setup
bash setup_proxy.sh
```

**Windows (命令提示符):**

```
git clone https://github.com/chenzai666/proxy-setup.git
cd proxy-setup
install_python.bat
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

### 纯 Batch（无需 Python，Windows）

```cmd
install_python.bat
```

> `install_python.bat` 自动在常见路径查找 `setup_proxy.py`，未找到会提示手动输入；检测到 Python 未安装时通过 winget 自动安装 Python 3.13。

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
