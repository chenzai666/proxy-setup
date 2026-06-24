# proxy-setup

跨平台代理配置脚本，支持 v2rayN / Clash / sing-box 等工具，一键配置系统代理。

## 安装脚本

各平台使用对应的安装脚本，会自动检测并安装 Python（如未安装），然后运行代理配置。

| 平台 | 脚本 | 说明 |
|------|------|------|
| Windows | `install_python.bat` | 双击运行，自动安装 Python 3.13 后启动配置 |
| Windows | `install_python.ps1` | PowerShell 版本，支持更多自定义参数 |
| macOS/Linux | `install_python.sh` | Bash 脚本，自动安装 Python 并运行配置 |

### Windows 用户（ most common）

**推荐：双击 `install_python.bat`**

脚本会自动：
1. 在以下位置查找 `setup_proxy.py` / `setup_proxy.ps1`：
   - 当前 `.bat` 所在文件夹
   - 父目录（`.bat` 在子文件夹时）
   - `C:\Users\tt\WorkBuddy\Claw\`
   - `Downloads/proxy-setup/`  (常见 ZIP 解压路径)
   - 桌面 `proxy-setup/`
2. 如未找到，提示手动输入路径
3. 检测 Python，未安装则通过 winget 安装 Python 3.13
4. 运行对应的代理配置脚本

> 如果提示"Python not found"且 winget 不可用，请手动前往 https://www.python.org/downloads/ 安装（勾选 Add to PATH）

### 手动运行

已安装 Python 的情况下，可直接运行：

```bash
# Windows
python setup_proxy.py

# macOS/Linux
python3 setup_proxy.py
```

## 远程执行（无需下载）

> 适用于 `setup_proxy.sh` / `setup_proxy.ps1` 等自包含脚本。

**Windows (PowerShell):**

```powershell
$w=New-Object Net.WebClient;$w.Encoding=[Text.Encoding]::UTF8;iex($w.DownloadString('https://raw.githubusercontent.com/chenzai666/proxy-setup/master/setup_proxy.ps1'))
```

> `WebClient` + `iex` 在内存执行，无 BOM/编码问题。

**Windows 加速版（jsdelivr CDN，国内更快）：**

```powershell
$w=New-Object Net.WebClient;$w.Encoding=[Text.Encoding]::UTF8;iex($w.DownloadString('https://cdn.jsdelivr.net/gh/chenzai666/proxy-setup@master/setup_proxy.ps1'))
```

> 如果 CDN 未刷新，可先访问 `https://purge.jsdelivr.net/gh/chenzai666/proxy-setup@master/setup_proxy.ps1` 清缓存后再运行。

**Windows 固定版本（彻底避开 CDN 缓存漂移）：**

```powershell
$w=New-Object Net.WebClient;$w.Encoding=[Text.Encoding]::UTF8;iex($w.DownloadString('https://cdn.jsdelivr.net/gh/chenzai666/proxy-setup@e4cae12/setup_proxy.ps1'))
```

> `@e4cae12` 是包含 Claude / OpenAI 出口 IP 检测、macOS Bash/v2rayN 自动检测修复、Windows 当前会话代理清理的固定版本；固定 commit 不会自动更新。

**Mac / Linux:**

```bash
curl -sSL https://raw.githubusercontent.com/chenzai666/proxy-setup/master/setup_proxy.sh -o /tmp/sp.sh && bash /tmp/sp.sh && rm /tmp/sp.sh
```

> 注：不能直接 `curl | bash`，管道会抢占 stdin 导致 `read` 无法交互。

```bash
# 或 Python 版（需先下载，管道执行会因 input() 报错）
curl -sSL https://raw.githubusercontent.com/chenzai666/proxy-setup/master/setup_proxy.py -o /tmp/sp.py && python3 /tmp/sp.py && rm /tmp/sp.py
```

### 或 Git Clone

```bash
git clone https://github.com/chenzai666/proxy-setup.git
cd proxy-setup

# Windows（CMD）
install_python.bat

# macOS / Linux
bash setup_proxy.sh
```

## 代理配置说明

脚本支持配置以下工具的代理设置：
- v2rayN（Windows）
- Clash（全平台）
- sing-box（全平台）

配置完成后，系统代理会自动指向对应端口（默认 10808 / 7890）。

### Claude / OpenAI 出口 IP 检测

脚本支持通过 Cloudflare `cdn-cgi/trace` 检测访问 Claude、Anthropic API、ChatGPT、OpenAI API 时的真实出口 IP、地区代码和接入节点。

菜单入口：

- **Python 版** (`setup_proxy.py`)：菜单选项 `7`
- **Bash 版** (`setup_proxy.sh`)：菜单选项 `7`
- **PowerShell 版** (`setup_proxy.ps1`)：菜单选项 `8`

检测目标：

- `https://claude.ai/cdn-cgi/trace`
- `https://console.anthropic.com/cdn-cgi/trace`
- `https://api.anthropic.com/cdn-cgi/trace`
- `https://chatgpt.com/cdn-cgi/trace`
- `https://api.openai.com/cdn-cgi/trace`

重点看输出中的 `ip`、`loc`、`colo`、`warp` 字段。`loc=US` 代表该域名看到的出口地区是美国。

### 临时清空当前会话代理

如果当前终端残留了失效代理（例如 `127.0.0.1:7897`），会导致 `curl` / `npm` / `git` 优先走旧代理而失败。脚本支持只清空当前会话环境变量，不修改 profile、npm、git 的持久配置。

菜单入口：

- **Bash 版** (`setup_proxy.sh`)：菜单选项 `8`
- **PowerShell 版** (`setup_proxy.ps1`)：菜单选项 `9`
- **Python 版** (`setup_proxy.py`)：Windows 菜单选项 `9`（仅影响脚本进程本身）

手动清理命令：

```bash
unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY no_proxy NO_PROXY
```

```powershell
"http_proxy","https_proxy","all_proxy","HTTP_PROXY","HTTPS_PROXY","ALL_PROXY","no_proxy","NO_PROXY" | ForEach-Object { Remove-Item "Env:\$_" -ErrorAction SilentlyContinue }
```

### Windows 智能DNS 禁用

启用代理后，Windows 的「智能多宿主名称解析」(Smart Multi-Homed Name Resolution) 可能向所有网卡同时发送 DNS 查询，导致 DNS 泄漏。脚本支持**逐项独立切换**：

**Python 版** (`setup_proxy.py`)：菜单选项 `8`  → 管理子菜单
**PowerShell 版** (`setup_proxy.ps1`)：菜单选项 `7` → 管理子菜单

三项注册表策略：

| 选项 | 注册表键 | 作用 | 推荐 |
|------|----------|------|:--:|
| 智能多宿主 DNS 解析 | `DisableSmartNameResolution` | 禁止向所有网卡广播 DNS | ✅禁用 |
| 并行 A/AAAA 查询 | `DisableParallelAandAAAA` | 停止并行 IPv4/IPv6 查询 | ✅禁用 |
| mDNS/LLMNR 组播 | `EnableMulticast` | 关闭内网设备发现 | ⚠可选 |

菜单支持：
- **1/2/3** — 逐项独立开关
- **4) 一键禁用推荐项** — 关闭前两项，保留组播（兼顾安全与内网便利）
- **5) 全部恢复默认** — 删除所有策略键，恢复系统默认
- **6) 检测 DNS 泄漏** — 输出分项风险画像：检查 Windows DNS 策略、系统 DNS 服务器、直连公网 DNS、CDN 解析辅助对比和代理域名访问能力

> 需要**管理员权限**。

## 项目结构

```
proxy-setup/
├── install_python.bat   # Windows 一键安装启动器
├── install_python.ps1   # Windows PowerShell 版本
├── install_python.sh    # macOS/Linux Bash 版本
├── setup_proxy.py       # Python 代理配置主脚本
├── setup_proxy.sh       # macOS/Linux Bash 代理配置脚本
└── setup_proxy.ps1      # PowerShell 代理配置脚本
```

## 仓库地址

https://github.com/chenzai666/proxy-setup
