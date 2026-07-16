# proxy-setup

Windows / macOS 代理配置脚本，支持 v2rayN / Clash / sing-box 等工具，一键配置系统代理。

## 安装脚本

各平台使用对应的入口脚本。Windows 入口优先运行 PowerShell 主脚本（包含 `claude-geo`），仅在缺少 PowerShell 主脚本时回退到 Python 版；macOS 入口优先运行 Bash 版，只有在仅找到 Python 版时才检测/安装 Python。

| 平台 | 脚本 | 说明 |
|------|------|------|
| Windows | `install_python.bat` | 双击运行，优先启动 PowerShell 主脚本；必要时自动安装 Python 3.13 后回退运行 Python 版 |
| macOS | `install_python.sh` | Bash 启动器，优先运行 `setup_proxy.sh` / `setup_proxy_macos.sh`，仅 Python 回退时安装 Python |

### Windows 用户（most common）

**推荐：双击 `install_python.bat`**

脚本会自动：
1. 在以下位置查找 `setup_proxy.py` / `setup_proxy.ps1`：
   - 当前 `.bat` 所在文件夹
   - 父目录（`.bat` 在子文件夹时）
   - `Downloads/proxy-setup/`（常见 ZIP 解压路径）
   - 桌面 `proxy-setup/`
2. 如未找到，提示手动输入路径
3. 优先运行 PowerShell 主脚本（含 `claude-geo` 菜单）
4. 如果只有 Python 版，则检测 Python，未安装时通过 winget 安装 Python 3.13 后运行

> 如果提示"Python not found"且 winget 不可用，请手动前往 https://www.python.org/downloads/ 安装（勾选 Add to PATH）

### 手动运行

已安装 Python 的情况下，可直接运行：

```bash
# Windows
python setup_proxy.py

# macOS
python3 setup_proxy.py
```

> Python 版保留为跨平台/回退入口；Windows 上需要 `claude-geo` 时请优先使用 PowerShell 版 `setup_proxy.ps1` 或双击 `install_python.bat`。

## 远程执行（无需下载）

> 适用于 Windows PowerShell/CMD 入口，以及 macOS Bash 分发入口。

**Windows (PowerShell):**

```powershell
$w=New-Object Net.WebClient;$w.Encoding=[Text.Encoding]::UTF8;iex($w.DownloadString('https://raw.githubusercontent.com/chenzai666/proxy-setup/master/setup_proxy.ps1'))
```

> `WebClient` + `iex` 在内存执行，无 BOM/编码问题。
> Windows 版会自动设置 `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`，用于保证写入的 PowerShell profile 能在新窗口加载；无需管理员权限。

**Windows (CMD):**

```bat
curl -fsSL https://raw.githubusercontent.com/chenzai666/proxy-setup/master/setup_proxy.cmd -o %TEMP%\setup_proxy.cmd && %TEMP%\setup_proxy.cmd && del %TEMP%\setup_proxy.cmd
```

> CMD 版本是启动器：优先运行同目录的 `setup_proxy.ps1`，远程执行时会自动下载并调用 PowerShell 版，不依赖 Python。

**Windows (CMD) 加速版（jsdelivr CDN）：**

```bat
set PROXY_SETUP_REMOTE_URL=https://cdn.jsdelivr.net/gh/chenzai666/proxy-setup@master/setup_proxy.ps1
curl -fsSL https://cdn.jsdelivr.net/gh/chenzai666/proxy-setup@master/setup_proxy_cmd.txt -o %TEMP%\setup_proxy.cmd && %TEMP%\setup_proxy.cmd && del %TEMP%\setup_proxy.cmd
```

> jsdelivr 会拦截 `.cmd` 文件并返回 403，所以 CMD 加速版下载同内容的 `setup_proxy_cmd.txt` 并保存为 `.cmd` 运行。CDN 可能有缓存延迟；需要立即使用最新版本时，请优先用上面的 raw.githubusercontent 命令。

**Windows 加速版（jsdelivr CDN）：**

```powershell
$w=New-Object Net.WebClient;$w.Encoding=[Text.Encoding]::UTF8;iex($w.DownloadString('https://cdn.jsdelivr.net/gh/chenzai666/proxy-setup@master/setup_proxy.ps1'))
```

**macOS（自动识别平台）:**

```bash
curl -sSL https://raw.githubusercontent.com/chenzai666/proxy-setup/master/setup_proxy.sh -o /tmp/sp.sh && bash /tmp/sp.sh && rm /tmp/sp.sh
```

> 注：不能直接 `curl | bash`，管道会抢占 stdin 导致 `read` 无法交互。
> 分发入口会自动下载 macOS 专用脚本；在 `/tmp` 等远程临时目录运行时会刷新该脚本，避免复用旧缓存文件。

**macOS 加速版（jsdelivr CDN）：**

```bash
curl -fsSL https://cdn.jsdelivr.net/gh/chenzai666/proxy-setup@master/setup_proxy.sh -o /tmp/sp.sh && PROXY_SETUP_REMOTE_BASE_URL=https://cdn.jsdelivr.net/gh/chenzai666/proxy-setup@master bash /tmp/sp.sh; rm -f /tmp/sp.sh
```

**macOS 专用：**

```bash
curl -sSL https://raw.githubusercontent.com/chenzai666/proxy-setup/master/setup_proxy_macos.sh -o /tmp/sp.sh && bash /tmp/sp.sh && rm /tmp/sp.sh
```

**macOS 专用加速版（jsdelivr CDN）：**

```bash
curl -4 --retry 3 --retry-delay 2 --connect-timeout 8 --max-time 30 -fsSL https://cdn.jsdelivr.net/gh/chenzai666/proxy-setup@master/setup_proxy_macos.sh -o /tmp/sp.sh && bash /tmp/sp.sh; rm -f /tmp/sp.sh
```

macOS 版本默认写入 `~/.zshrc`，如需写入 bash 配置可先设置 `PROXY_SETUP_RC_FILE=$HOME/.bash_profile`；不会因为用 `bash /tmp/sp.sh` 执行就误写到 `~/.bashrc`。

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

# macOS
bash setup_proxy.sh
```

## 代理配置说明

脚本支持配置以下工具的代理设置：
- v2rayN（Windows）
- Clash/Mihomo（Windows、macOS）
- sing-box（Windows、macOS）

### 自动检测代理端口

两个平台的自动检测优先级一致：**v2rayN → Clash/Mihomo → sing-box**。

每个客户端的默认 HTTP 端口上下各扫 **±10 个端口**，确保在非默认端口运行时也能正确识别。
如果没有检测到任何监听端口，脚本会按优先级使用第一个候选默认值，也就是 v2rayN 的 `10808/10808`；Clash/Mihomo 自身的默认候选仍是 `7897/7897`。

sing-box 自动检测只接受 `mixed` 入站，或同时存在的 `http` 与 `socks` 入站；不会再把第一个 `listen_port` 或相邻端口猜作另一种协议。只有单一协议入站时，请使用手动配置并确认 HTTP 和 SOCKS5 端口。

### 代理配置项

脚本配置的代理范围包括：
- Shell 环境变量（`HTTP_PROXY` / `HTTPS_PROXY` / `ALL_PROXY` 及小写别名）写入 shell rc 文件
- `git` 全局代理
- `pip` 全局代理（`~/.config/pip/pip.conf` / `%APPDATA%\pip\pip.ini`）

脚本默认不写 Windows 用户级环境变量。Claude Code 如需继承这些代理变量，请从已经加载 profile 的 PowerShell/CMD 窗口启动。

写入 shell 配置和当前会话时，脚本会保留已有的 `NO_PROXY` / `no_proxy` 条目，并补充 `localhost`、`127.0.0.1`、`::1`；合并时会忽略大小写去重，不再覆盖公司内网等自定义直连域名。

首次配置 `npm`、`git`、`pip` 全局代理时，脚本会在 `~/.proxy-setup/proxy-config-state.v1` 保存原值。执行“移除代理配置”时，只有当前值仍是本脚本写入的本地代理才会恢复原值；若之后被其他工具修改，则保留该值。没有该状态文件的旧版本配置仅会清理 `127.0.0.1` / `localhost` 本地代理，不会删除外部代理。

### Claude / OpenAI 出口 IP 检测

脚本支持通过 Cloudflare `cdn-cgi/trace` 检测访问 Claude、Anthropic API、ChatGPT、OpenAI API 时的真实出口 IP、地区代码和接入节点。

菜单入口：

- **Python 版** (`setup_proxy.py`)：菜单选项 `7`
- **Bash 版** (`setup_proxy_macos.sh`)：菜单选项 `7`
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

- **Bash 版** (`setup_proxy_macos.sh`)：菜单选项 `8`
- **PowerShell 版** (`setup_proxy.ps1`)：菜单选项 `9`
- **Python 版** (`setup_proxy.py`)：Windows 菜单选项 `9`，macOS 菜单选项 `8`（仅影响脚本进程本身）

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
- **5) 全部恢复** — PowerShell 版从 `~/.proxy-setup/smart-dns-state.json` 恢复脚本修改前的值；若值已被其他程序修改或没有备份，则保留当前值。Python 版目前删除对应策略值并恢复系统默认
- **6) 检测 DNS 泄漏** — 输出分项风险画像：检查 Windows DNS 策略、系统 DNS 服务器、直连公网 DNS、CDN 解析辅助对比和代理域名访问能力

> 需要**管理员权限**。

## 项目结构

```
proxy-setup/
├── install_python.bat              # Windows 一键安装启动器
├── install_python.sh               # macOS Bash 版本
├── install_claude_code_windows.ps1 # Windows Claude Code 安装脚本
├── install_claude_code_macos.sh    # macOS Claude Code 安装脚本
├── install_claude_code_linux.sh    # Linux Claude Code 安装脚本
├── setup_proxy.py                  # Python 代理配置主脚本
├── setup_proxy.sh                  # macOS Bash 平台分发入口
├── setup_proxy_macos.sh            # macOS Bash 代理配置脚本
├── setup_proxy.cmd                 # Windows CMD 代理配置启动器
├── setup_proxy_cmd.txt             # jsdelivr 可下载的 CMD 启动器镜像
├── setup_proxy.ps1                 # PowerShell 代理配置脚本
├── clear_claude_login_state.ps1        # Windows Claude 登录状态清理脚本
└── clear_claude_login_state_macos.sh   # macOS Claude 登录状态清理脚本
```

## 仓库地址

https://github.com/chenzai666/proxy-setup

## Claude Code 安装

Windows、macOS、Linux 安装脚本都会先检测现有的 `claude` 可执行文件并运行 `claude --version`。如果检测成功，脚本直接输出已安装版本并结束，不再下载或重复运行安装器；设置 `CLAUDE_CODE_SKIP_INSTALL=1` 时仍按原行为跳过安装并修复命令或 PATH。

### Windows

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install_claude_code_windows.ps1
```

远程执行：

```powershell
$u='https://raw.githubusercontent.com/chenzai666/proxy-setup/master/install_claude_code_windows.ps1';$p="$env:TEMP\install_claude_code_windows.ps1";Invoke-WebRequest -UseBasicParsing $u -OutFile $p;powershell -NoProfile -ExecutionPolicy Bypass -File $p;Remove-Item $p -Force
```

加速版（jsdelivr CDN，国内更快；跟随 master 最新版本，CDN 可能有缓存延迟）：

```powershell
$u='https://cdn.jsdelivr.net/gh/chenzai666/proxy-setup@master/install_claude_code_windows.ps1';$p="$env:TEMP\install_claude_code_windows.ps1";Invoke-WebRequest -UseBasicParsing $u -OutFile $p;powershell -NoProfile -ExecutionPolicy Bypass -File $p;Remove-Item $p -Force
```

默认使用 WinGet 安装 Claude Code。也可切换为官方 Native Install：

```powershell
$env:CLAUDE_CODE_INSTALL_METHOD='native'
powershell -NoProfile -ExecutionPolicy Bypass -File .\install_claude_code_windows.ps1
```

支持环境变量：

| 变量 | 说明 | 默认值 |
|------|------|--------|
| `CLAUDE_CODE_SKIP_INSTALL=1` | 跳过下载安装，仅验证/修复 PATH | 否 |
| `CLAUDE_CODE_INSTALL_METHOD=winget|native` | Windows 安装方式 | `winget` |
| `CLAUDE_CODE_INSTALL_URL=URL` | 覆盖官方 PowerShell 安装脚本地址 | `https://claude.ai/install.ps1` |
| `CLAUDE_CODE_SKIP_PATH_UPDATE=1` | 不自动写入用户 PATH | 否 |
| `CLAUDE_CODE_PROGRESS_SECONDS=60` | 安装器运行时的进度提示间隔 | `60` |

Windows 安装器运行期间会定时输出 `still running... elapsed ...`，表示 WinGet 或官方安装器仍在执行。

### macOS

```bash
bash install_claude_code_macos.sh
```

远程一行命令：

```bash
t="$(mktemp -t install_claude_code_macos.XXXXXX)" && trap 'rm -f "$t"' EXIT && curl -fsSL https://raw.githubusercontent.com/chenzai666/proxy-setup/master/install_claude_code_macos.sh -o "$t" && bash "$t"
```

远程一行命令加速版（jsDelivr CDN）：

```bash
t="$(mktemp -t install_claude_code_macos.XXXXXX)" && trap 'rm -f "$t"' EXIT && curl -4 --retry 3 --retry-delay 2 --connect-timeout 8 --max-time 30 -fsSL https://cdn.jsdelivr.net/gh/chenzai666/proxy-setup@master/install_claude_code_macos.sh -o "$t" && bash "$t"
```

支持环境变量自定义：

| 变量 | 说明 | 默认值 |
|------|------|--------|
| `CLAUDE_CODE_SKIP_INSTALL=1` | 跳过下载安装，仅修复 PATH / 符号链接 | 否 |
| `CLAUDE_CODE_RC_FILE=PATH` | 指定写入的 shell 配置文件 | zsh→`~/.zshrc`，bash→`~/.bash_profile` |
| `CLAUDE_CODE_BIN_DIR=PATH` | claude 符号链接目录 | `~/.local/bin` |
| `CLAUDE_CODE_INSTALL_URL=URL` | 覆盖官方安装脚本地址 | `https://claude.ai/install.sh` |
| `CLAUDE_CODE_PROGRESS_SECONDS=60` | 安装器状态刷新间隔，最小 2 秒 | `60` |

macOS 交互终端会在同一行更新 `still running... elapsed ...`；重定向输出时才会逐行记录。官方安装器未提供可读取的百分比进度。

### Linux

```bash
bash install_claude_code_linux.sh
```

支持同名环境变量，rc 文件默认为 bash→`~/.bashrc`，zsh→`~/.zshrc`，fish→`~/.config/fish/config.fish`。

> `npm` 不是此脚本的前置依赖；如果系统已安装 npm，脚本会顺带检查 npm 全局路径里的 `claude`。
> 如需通过代理下载，请在运行前设置 `http_proxy` / `https_proxy`。

## Claude 登录状态清理

用于清理 Claude 桌面端或 Claude Code 的本地登录状态和缓存，也包含旧 Claude Code 数据迁移。执行脚本后会让你选择：

```text
1) Claude Desktop only
2) Clear Claude Code login state and cache
3) Migrate old Claude Code data into the current new account
```

选桌面端只清桌面端；选 Claude Code 只清 Claude Code 登录状态和缓存；选迁移则只合并旧的本地工作数据到当前已登录的新账号，不会顺手影响另一个。

清理范围：

- Claude Desktop：只清 Claude 桌面端 Electron 应用数据、缓存、偏好和保存状态。
- Claude Code：只清理 `~/.claude/.credentials.json`、`~/.claude/cache` 和登录凭据；macOS 会额外尝试清理 Claude Code 的 Keychain 凭据。不会删除 `~/.claude`、项目、对话历史、设置、commands、agents、skills 或 plugins；在完整备份后，仅从 `~/.claude.json` 移除旧账号的 `oauthAccount`、`userID`、`machineID`，项目登记和用户设置仍保留。

执行 Claude Code 清理前，脚本会把现有的项目会话、历史、设置和扩展配置自动备份到 `~/.claude-cleanup-backups/时间戳/`。备份不包含 `.credentials.json`，避免在登出后继续保存可用令牌；清理失败或误操作时，可从该目录恢复受保护数据。

切换账号的流程是：先选择 `2` 清缓存，脚本会自动备份旧项目数据；登录新账号后，再运行同一个脚本选择 `3`。迁移会自动使用最新清理备份，也可手动指定旧 `.claude` 或备份目录。只合并 `projects`、`sessions`、`history.jsonl`、`commands`、`agents`、`skills`、`plugins`、`todos`、`plans` 等本地工作数据；旧账号的 `.credentials.json`、`cache`、`telemetry`、`oauthAccount`、`userID`、`machineID` 永不导入。同名冲突时保留新账号版本。

迁移提交前会把当前新账号的完整 `.claude` 快照保存到 `~/.claude-migration-backups/时间戳/current-claude`，提交失败时自动回滚。确认迁移正常前不要删除该目录。已经被永久删除且没有任何备份的本地 JSONL 对话，以及云端 Cowork/Chat 数据，无法由本脚本恢复。

浏览器/PWA 的 `claude.ai` 站点存储不会默认清理；需要时再额外启用浏览器清理选项。

### Windows

本地执行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\clear_claude_login_state.ps1
```

远程一行命令：

```powershell
$u='https://raw.githubusercontent.com/chenzai666/proxy-setup/master/clear_claude_login_state.ps1';$p="$env:TEMP\clear_claude_login_state.ps1";Invoke-WebRequest -UseBasicParsing $u -OutFile $p;powershell -NoProfile -ExecutionPolicy Bypass -File $p;Remove-Item $p -Force
```

远程一行命令加速版（jsDelivr CDN）：

```powershell
$u='https://cdn.jsdelivr.net/gh/chenzai666/proxy-setup@master/clear_claude_login_state.ps1';$p="$env:TEMP\clear_claude_login_state.ps1";Invoke-WebRequest -UseBasicParsing $u -OutFile $p;powershell -NoProfile -ExecutionPolicy Bypass -File $p;Remove-Item $p -Force
```

预演，不真正删除：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\clear_claude_login_state.ps1 -WhatIf
```

如需自动化跳过菜单，可显式指定：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\clear_claude_login_state.ps1 -Target Desktop
powershell -NoProfile -ExecutionPolicy Bypass -File .\clear_claude_login_state.ps1 -Target Code
powershell -NoProfile -ExecutionPolicy Bypass -File .\clear_claude_login_state.ps1 -Target Migrate
```

迁移前请先登录新账号；自动化时可用 `-Yes` 跳过确认。未指定来源时自动使用最新清理备份，手动指定旧数据或预演示例：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\clear_claude_login_state.ps1 -Target Migrate -MigrationSource "D:\backup\.claude" -WhatIf
powershell -NoProfile -ExecutionPolicy Bypass -File .\clear_claude_login_state.ps1 -Target Migrate -MigrationSource "D:\backup\.claude" -Yes
```

确实准备在未登录状态迁移时，才额外使用 `-AllowLoggedOut`。

如需额外清理浏览器/PWA 的 `claude.ai` IndexedDB/Storage，可在选择桌面端时加 `-IncludeBrowserIndexedDb`。

脚本会在删除前结束 Claude 及其数据目录内仍在运行的辅助进程（包括商店版的 ChromeNativeHost）。若仍有文件被其他进程占用，脚本会明确提示未清理的路径并以失败状态结束，不会误报清理完成；关闭占用进程后重新执行即可。

### macOS

本地执行：

```bash
bash clear_claude_login_state_macos.sh
```

远程一行命令：

```bash
t="$(mktemp -t clear_claude_login_state_macos.XXXXXX)" && trap 'rm -f "$t"' EXIT && curl -fsSL https://raw.githubusercontent.com/chenzai666/proxy-setup/master/clear_claude_login_state_macos.sh -o "$t" && bash "$t"
```

远程一行命令加速版（jsDelivr CDN）：

```bash
t="$(mktemp -t clear_claude_login_state_macos.XXXXXX)" && trap 'rm -f "$t"' EXIT && curl -4 --retry 3 --retry-delay 2 --connect-timeout 8 --max-time 30 -fsSL https://cdn.jsdelivr.net/gh/chenzai666/proxy-setup@master/clear_claude_login_state_macos.sh -o "$t" && bash "$t"
```

预演，不真正删除：

```bash
DRY_RUN=1 bash clear_claude_login_state_macos.sh
```

如需自动化跳过菜单，可显式指定：

```bash
bash clear_claude_login_state_macos.sh --target desktop
bash clear_claude_login_state_macos.sh --target code
bash clear_claude_login_state_macos.sh --target migrate
```

迁移前请先登录新账号；自动化时可用 `--yes` 跳过确认。未指定来源时自动使用最新清理备份，手动指定旧数据或预演示例：

```bash
bash clear_claude_login_state_macos.sh --target migrate --source "/Volumes/Backup/.claude" --dry-run
bash clear_claude_login_state_macos.sh --target migrate --source "/Volumes/Backup/.claude" --yes
```

确实准备在未登录状态迁移时，才额外使用 `--allow-logged-out`。

如需额外清理浏览器/PWA 的 `claude.ai` IndexedDB/Storage，可在选择桌面端时加 `INCLUDE_BROWSER_SITE_DATA=1`。

> CDN 可能有缓存延迟；需要立即使用最新版本时，请优先用 raw.githubusercontent 命令。

## Claude Code 画像一致启动器

`proxy-setup` 可以通过菜单安装一个 `claude-geo` 启动命令，用来让 Claude Code 的运行时画像尽量和当前代理出口 IP 保持一致。

它不是永久写死某个时区或语言，而是每次启动前重新检测当前代理出口 IP，并临时注入到这次 Claude Code 进程：

- `HTTP_PROXY` / `HTTPS_PROXY` / `ALL_PROXY`
- `TZ`
- `LANG` / `LC_ALL` / `LC_MESSAGES` / `LANGUAGE`
- `ACCEPT_LANGUAGE`

Windows 版：

- 菜单 `1` / `2` 只配置代理，不会自动安装 `claude-geo`
- 菜单 `10` 安装或更新 `claude-geo`
- 菜单 `3` 移除代理时会同时移除 `claude-geo`
- 安装时会生成 `claude-geo.ps1` 和 `claude-geo.cmd`，并把 `%USERPROFILE%\.proxy-setup` 加入用户 PATH；重新打开 PowerShell 或 CMD 后都可以直接运行 `claude-geo`

macOS Bash 版：

- 菜单 `1` / `2` 只配置代理，不会自动安装 `claude-geo`
- 菜单 `9` 安装或更新 `claude-geo`
- 菜单 `3` 移除代理时会同时移除 `claude-geo`

安装后重新打开终端，使用：

```bash
claude-geo
```

Claude Code 参数会原样透传，例如：

```bash
claude-geo -c
claude-geo --dangerously-skip-permissions
```

端口在安装时已自动检测并写入脚本，如需临时切换代理端口，可通过参数覆盖：

```bash
claude-geo --http-port 7890 --socks-port 7891
claude-geo --http-port 10808
```

Windows 版同样支持（也接受 `-HttpPort`、`-SocksPort`、`-ProxyHost` 的 PS 风格写法）。

如果需要把 `--print-only`、`--claude-command` 或上述覆盖参数当作 Claude Code 自己的参数传入，请用 `--` 分隔：

```bash
claude-geo -- --print-only
```

或短别名：

```bash
cgeo
```

注意：`TZ` 对 Node/Claude Code 的时区通常有效；语言会按出口 IP 注入到 `LANG`、`LC_ALL`、`LANGUAGE`、`ACCEPT_LANGUAGE`。语言变量对 macOS/Linux 更容易影响运行时 locale；Windows 上 Node/Bun 的默认 `Intl` locale 往往来自系统区域设置，`LANG/LC_ALL` 不一定能把 `Intl.DateTimeFormat().resolvedOptions().locale` 改掉。如需完全改变这一项，需要修改 Windows 用户区域设置，这会影响整个用户账户，脚本不会默认执行。

## 切换为台湾时区（TW）

台湾使用 IANA 时区名 `Asia/Taipei`（UTC+8，当前不使用夏令时）；Windows 的对应时区 ID 是 `Taipei Standard Time`。下面的“系统时区”命令会影响整台电脑的时间显示和所有应用，执行前请确认这是预期行为。

### Windows

以**管理员身份**打开 PowerShell，先查看当前时区，再设置为台湾并验证：

```powershell
# 查看当前 Windows 时区
Get-TimeZone

# 设置系统时区为台湾
Set-TimeZone -Id "Taipei Standard Time"

# 验证时区和当前时间
Get-TimeZone
Get-Date -Format "yyyy-MM-dd HH:mm:ss K"
```

如果使用 CMD，或系统缺少 `Set-TimeZone` 命令，可使用等价的 `tzutil`：

```bat
:: 查询当前系统时区
tzutil /g

:: 设置系统时区为台湾
tzutil /s "Taipei Standard Time"

:: 再次查询确认
tzutil /g
```

只想让新启动的 Claude Code 使用台湾时区、不修改 Windows 系统时区时，在 PowerShell 中运行：

```powershell
$env:TZ = "Asia/Taipei"
claude

# 验证 Node/Claude Code 运行时将使用的时区（如已安装 Node.js）
node -e "console.log(Intl.DateTimeFormat().resolvedOptions().timeZone)"
```

如需让当前用户后续新开的终端默认带上该变量，可运行以下命令；设置后关闭并重新打开终端。它只影响支持 `TZ` 的应用，不会修改 Windows 系统时区：

```powershell
[Environment]::SetEnvironmentVariable("TZ", "Asia/Taipei", "User")
```

### macOS

在“终端”中执行。`sudo` 会要求输入当前账户密码；`systemsetup` 会修改整个 macOS 系统的时区：

```bash
# 查看当前系统时区
sudo systemsetup -gettimezone

# 设置系统时区为台湾
sudo systemsetup -settimezone Asia/Taipei

# 验证时区和当前时间
sudo systemsetup -gettimezone
date '+%Y-%m-%d %H:%M:%S %Z (%z)'
```

只想让单次 Claude Code 会话使用台湾时区、不修改 macOS 系统时区时：

```bash
TZ=Asia/Taipei claude

# 验证 Node/Claude Code 运行时将使用的时区（如已安装 Node.js）
TZ=Asia/Taipei node -e 'console.log(Intl.DateTimeFormat().resolvedOptions().timeZone)'
```

如需让 zsh 的后续新终端默认使用台湾时区，请写入 `~/.zshrc` 后重新打开终端：

```bash
printf '\n# 台湾时区\nexport TZ=Asia/Taipei\n' >> ~/.zshrc
source ~/.zshrc
```

恢复为按代理出口自动匹配的时区时，不要设置全局 `TZ`；使用本项目安装的 `claude-geo` 启动 Claude Code 即可。若此前写入过 `TZ`，Windows 可执行 `[Environment]::SetEnvironmentVariable("TZ", $null, "User")`，macOS 则从 `~/.zshrc` 删除 `export TZ=Asia/Taipei` 后重新打开终端。
