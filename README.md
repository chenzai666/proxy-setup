# proxy-setup

终端代理一键配置脚本，让 Codex CLI、Claude Code、npm、git 走代理。

支持 v2rayN / Clash / sing-box 自动检测端口。

## 三个版本

| 文件 | 依赖 | 平台 |
|------|------|------|
| `setup_proxy.py` | Python 3 | Windows / Mac / Linux |
| `setup_proxy.sh` | bash | Mac / Linux |
| `setup_proxy.ps1` | 无（系统自带） | Windows |

## 功能

- 自动检测代理客户端端口（v2rayN guiNConfig.json / Clash config.yaml / sing-box config.json）
- 写入 shell 配置文件（`.zshrc` / `.bashrc` / PowerShell `$PROFILE`）
- Windows CMD 支持（注册表 AutoRun）
- 配置 npm & git 代理
- 代理连通性验证 + 出口 IP 展示（含地区识别）
- 全链路测试（OpenAI + Anthropic API）
- 查看/清空当前会话环境变量

## 用法

### Windows
```powershell
powershell -ExecutionPolicy Bypass -File setup_proxy.ps1
```

### Mac / Linux
```bash
bash setup_proxy.sh
```
