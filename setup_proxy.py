#!/usr/bin/env python3
"""
跨平台终端代理一键配置脚本
支持: macOS (Clash/ClashX/v2rayN/v2rayU/sing-box) + Windows (v2rayN/sing-box)
适用于: Codex CLI / Claude Code / npm / git 等工具
"""

import os
import re
import sys
import json
import subprocess
import shutil
import platform
from pathlib import Path

# ─── 配置区（按需修改）───────────────────────────────────────────────
DEFAULT_HTTP_PORT   = 7890
DEFAULT_SOCKS5_PORT = 7891
HOST = "127.0.0.1"

# 不走代理的地址
NO_PROXY = "localhost,127.0.0.1,::1"

# 如需 Claude Code 中转地址，填在这里（留空则不写入）
ANTHROPIC_BASE_URL = ""
# ─────────────────────────────────────────────────────────────────────

PROXY_BLOCK_START = "# >>> proxy-config start <<<"
PROXY_BLOCK_END   = "# >>> proxy-config end <<<"

IS_WINDOWS = platform.system() == "Windows"
IS_MAC      = platform.system() == "Darwin"


def color(text, code):
    if IS_WINDOWS and sys.stdout.isatty():
        return f"\033[{code}m{text}\033[0m"
    elif not IS_WINDOWS:
        return f"\033[{code}m{text}\033[0m"
    return text

def info(msg):  print(f"  {msg}")
def ok(msg):    print(f"  [OK] {msg}")
def warn(msg):  print(f"  [WARN] {msg}")
def err(msg):   print(f"  [ERR] {msg}")
def bold(msg):  print(msg)


# ─── 端口检测 ────────────────────────────────────────────────────────

def detect_clash_port() -> int:
    """Mac: 从 Clash/Mihomo 配置文件读取端口"""
    configs = [
        Path.home() / ".config" / "clash" / "config.yaml",
        Path.home() / ".config" / "mihomo" / "config.yaml",
        Path.home() / "Library" / "Application Support" / "ClashX" / "config.yaml",
        Path.home() / "Library" / "Application Support" / "ClashX Pro" / "config.yaml",
    ]
    for cfg in configs:
        if cfg.exists():
            try:
                content = cfg.read_text(encoding="utf-8")
                m = re.search(r"^mixed-port:\s*(\d+)", content, re.MULTILINE)
                if m:
                    port = int(m.group(1))
                    info(f"检测到 Clash 混合端口: {port}  ({cfg.parent.parent.parent.name}/{cfg.name})")
                    return port
                m = re.search(r"^port:\s*(\d+)", content, re.MULTILINE)
                if m:
                    port = int(m.group(1))
                    info(f"检测到 Clash HTTP 端口: {port}")
                    return port
            except Exception:
                pass
    return DEFAULT_HTTP_PORT


def detect_v2rayn_port() -> tuple:
    """
    跨平台: 从 v2rayN 配置目录读取端口
    v2rayN (v2rayN.Core 跨平台版) 配置文件: guiNConfig.json
    返回 (http_port, socks5_port)
    """
    # 所有可能的 v2rayN 配置目录（跨平台）
    prog_dirs = [
        # Windows 路径
        Path.home() / "v2rayN",
        Path("C:/v2rayN"),
    ]
    appdata = os.environ.get("APPDATA", "")
    if appdata:
        prog_dirs.append(Path(appdata) / "v2rayN")

    # macOS / Linux 路径
    prog_dirs += [
        Path.home() / ".config" / "v2rayN",
        Path.home() / "Library" / "Application Support" / "v2rayN",
        Path.home() / "v2rayN",
    ]

    for base in prog_dirs:
        gui_cfg = base / "guiNConfig.json"
        if gui_cfg.exists():
            try:
                data = json.loads(gui_cfg.read_text(encoding="utf-8"))
                http_port  = int(data.get("httpPort", 10808))
                socks_port = int(data.get("socksPort", http_port))
                info(f"检测到 v2rayN 端口: HTTP={http_port}, SOCKS={socks_port}  ({gui_cfg})")
                return http_port, socks_port
            except Exception:
                pass

    # 尝试从 v2ray 核心配置文件 (config.json) 读取 inbound 端口
    for base in prog_dirs:
        core_cfg = base / "config.json"
        if core_cfg.exists():
            try:
                data = json.loads(core_cfg.read_text(encoding="utf-8"))
                inbounds = data.get("inbounds", [])
                http_port = None
                socks_port = None
                for ib in inbounds:
                    port = ib.get("port") or ib.get("listenPort")
                    proto = ib.get("protocol", "")
                    if port:
                        port = int(port)
                        if proto in ("http", "mixed"):
                            http_port = port
                        elif proto == "socks":
                            socks_port = port
                if http_port:
                    return http_port, socks_port or http_port
            except Exception:
                pass

    # 兜底: 扫描常见 v2rayN 默认端口是否在监听
    for port in [10808, 10809, 1080, 7890, 8080]:
        if check_port_listening(port):
            info(f"端口嗅探: 发现监听端口 {port}")
            # 混合端口模式：同一个端口同时支持 HTTP 和 SOCKS5
            return port, port

    # 都找不到，返回 v2rayN 最常见默认值
    return 10808, 10808


def detect_singbox_port() -> tuple:
    """跨平台: 检测 sing-box 配置端口"""
    configs = []
    if IS_MAC:
        configs = [
            Path.home() / ".config" / "sing-box" / "config.json",
            Path.home() / ".config" / "sing-box" / "config.yaml",
        ]
    elif IS_WINDOWS:
        appdata = os.environ.get("APPDATA", "")
        if appdata:
            configs = [
                Path(appdata) / "sing-box" / "config.json",
                Path(appdata) / "sing-box" / "config.yaml",
            ]
        configs += [
            Path.home() / "sing-box" / "config.json",
            Path("C:/Program Files/sing-box/config.json"),
        ]
    for cfg in configs:
        if cfg.exists():
            try:
                content = cfg.read_text(encoding="utf-8")
                # 尝试 JSON 解析
                try:
                    data = json.loads(content)
                    inbounds = data.get("inbounds", [])
                    for ib in inbounds:
                        port = ib.get("listen_port") or ib.get("port")
                        proto = ib.get("protocol", "")
                        if port:
                            if proto in ("http", "mixed") or "http" in str(ib.get("tag","")):
                                return int(port), int(port) + 1
                            elif proto in ("socks",):
                                return int(port) - 1, int(port)
                except json.JSONDecodeError:
                    pass
                # 尝试 YAML 风格正则
                m = re.search(r'"listen_port"\s*:\s*(\d+)', content)
                if m:
                    port = int(m.group(1))
                    info(f"检测到 sing-box 端口: {port}")
                    return port, port + 1
            except Exception:
                pass
    return DEFAULT_HTTP_PORT, DEFAULT_SOCKS5_PORT


def auto_detect_ports() -> tuple:
    """自动检测当前系统的代理端口，返回 (http_port, socks5_port)"""
    # 优先检测当前有端口在监听的客户端（跨平台通用）
    candidates = []

    if IS_MAC:
        candidates = [
            ("Clash/Mihomo", detect_clash_port(), detect_clash_port() + 1),
            ("v2rayN",) + detect_v2rayn_port(),
            ("sing-box",) + detect_singbox_port(),
        ]
    elif IS_WINDOWS:
        candidates = [
            ("v2rayN",) + detect_v2rayn_port(),
            ("sing-box",) + detect_singbox_port(),
            ("Clash", detect_clash_port(), detect_clash_port() + 1),
        ]
    else:
        candidates = [
            ("Clash", detect_clash_port(), detect_clash_port() + 1),
            ("v2rayN",) + detect_v2rayn_port(),
            ("sing-box",) + detect_singbox_port(),
        ]

    # 优先返回正在监听的端口
    for name, hp, sp in candidates:
        if check_port_listening(hp) or check_port_listening(sp):
            info(f"自动检测: {name} 端口 {hp}/{sp} 正在监听")
            return hp, sp

    # 都未监听，返回第一个候选（按平台优先级）
    info(f"未检测到监听端口，使用默认/首选项: {candidates[0][0]}")
    return candidates[0][1], candidates[0][2]


def check_port_listening(port: int) -> bool:
    """检测端口是否在监听"""
    try:
        if IS_WINDOWS:
            result = subprocess.run(
                ["netstat", "-ano"],
                capture_output=True, text=True, timeout=5,
                creationflags=subprocess.CREATE_NO_WINDOW if hasattr(subprocess, 'CREATE_NO_WINDOW') else 0
            )
            # 检查 TCP 0.0.0.0:{port} LISTENING 或 127.0.0.1:{port}
            pattern = re.compile(rf"\s+TCP\s+\S+:(\d+)\s+\S+\s+LISTENING")
            for line in result.stdout.splitlines():
                m = pattern.search(line)
                if m and int(m.group(1)) == port:
                    return True
            return False
        else:
            result = subprocess.run(
                ["lsof", "-iTCP", f":{port}", "-sTCP:LISTEN", "-n", "-P"],
                capture_output=True, text=True, timeout=5
            )
            return bool(result.stdout.strip())
    except Exception:
        return False


# ─── Shell / Profile 配置 ────────────────────────────────────────────

def get_rc_file() -> Path:
    """返回当前平台对应的 shell 配置文件路径"""
    if IS_MAC:
        shell = os.environ.get("SHELL", "/bin/zsh")
        home = Path.home()
        if "zsh" in shell:
            return home / ".zshrc"
        elif "bash" in shell:
            rc = home / ".bash_profile"
            if not rc.exists():
                rc = home / ".bashrc"
            return rc
        return home / ".zshrc"
    elif IS_WINDOWS:
        # PowerShell profile
        ps_profile = os.environ.get("PSPROFILE", "")
        if ps_profile and Path(ps_profile).exists():
            return Path(ps_profile)
        # 默认 PowerShell profile 路径
        doc = Path.home() / "Documents"
        ps_dir = doc / "WindowsPowerShell" / "Microsoft.PowerShell_profile.ps1"
        if ps_dir.exists():
            return ps_dir
        # 尝试获取实际 PS profile 路径
        try:
            result = subprocess.run(
                ["powershell", "-NoProfile", "-Command", "$PROFILE"],
                capture_output=True, text=True, timeout=5,
                creationflags=subprocess.CREATE_NO_WINDOW if hasattr(subprocess, 'CREATE_NO_WINDOW') else 0
            )
            p = result.stdout.strip()
            if p:
                return Path(p)
        except Exception:
            pass
        return Path.home() / "Documents" / "WindowsPowerShell" / "Microsoft.PowerShell_profile.ps1"
    else:
        return Path.home() / ".bashrc"


def build_proxy_block(http_port: int, socks5_port: int, for_powershell=False) -> str:
    """生成代理配置块文本"""
    proxy_url    = f"http://{HOST}:{http_port}"
    socks_url    = f"socks5://{HOST}:{socks5_port}"
    lines = []

    if for_powershell or IS_WINDOWS:
        lines = [
            PROXY_BLOCK_START,
            f'$env:http_proxy  = "{proxy_url}"',
            f'$env:https_proxy = "{proxy_url}"',
            f'$env:all_proxy  = "{socks_url}"',
            f'$env:HTTP_PROXY  = "{proxy_url}"',
            f'$env:HTTPS_PROXY = "{proxy_url}"',
            f'$env:ALL_PROXY  = "{socks_url}"',
            f'$env:no_proxy    = "{NO_PROXY}"',
            f'$env:NO_PROXY    = "{NO_PROXY}"',
        ]
    else:
        lines = [
            PROXY_BLOCK_START,
            f'export http_proxy="{proxy_url}"',
            f'export https_proxy="{proxy_url}"',
            f'export all_proxy="{socks_url}"',
            f'export HTTP_PROXY="{proxy_url}"',
            f'export HTTPS_PROXY="{proxy_url}"',
            f'export ALL_PROXY="{socks_url}"',
            f'export no_proxy="{NO_PROXY}"',
            f'export NO_PROXY="{NO_PROXY}"',
        ]

    if ANTHROPIC_BASE_URL:
        if for_powershell or IS_WINDOWS:
            lines.append(f'$env:ANTHROPIC_BASE_URL = "{ANTHROPIC_BASE_URL}"')
        else:
            lines.append(f'export ANTHROPIC_BASE_URL="{ANTHROPIC_BASE_URL}"')
    lines.append(PROXY_BLOCK_END)
    return "\n".join(lines) + "\n"


def write_rc_file(rc_file: Path, http_port: int, socks5_port: int):
    """写入或更新 shell/ps profile 中的代理块（Windows 同时配置 CMD AutoRun）"""
    is_ps = IS_WINDOWS or rc_file.suffix in (".ps1",)
    block = build_proxy_block(http_port, socks5_port, for_powershell=is_ps)

    # 确保目录存在
    rc_file.parent.mkdir(parents=True, exist_ok=True)

    if rc_file.exists():
        content = rc_file.read_text(encoding="utf-8")
        pattern = re.compile(
            rf"{re.escape(PROXY_BLOCK_START)}.*?{re.escape(PROXY_BLOCK_END)}\n?",
            re.DOTALL
        )
        if pattern.search(content):
            new_content = pattern.sub(block, content)
            rc_file.write_text(new_content, encoding="utf-8")
            ok(f"已更新 {rc_file}")
        else:
            with open(rc_file, "a", encoding="utf-8") as f:
                f.write(f"\n{block}")
            ok(f"已追加到 {rc_file}")
    else:
        rc_file.write_text(block, encoding="utf-8")
        ok(f"已创建 {rc_file} 并写入代理配置")

    # Windows: 同时写入 CMD AutoRun 批处理
    if IS_WINDOWS:
        setup_cmd_autorun(http_port, socks5_port)


def get_cmd_bat_path() -> Path:
    """CMD AutoRun 批处理文件路径"""
    return Path.home() / ".proxy_init.cmd"


def setup_cmd_autorun(http_port: int, socks5_port: int):
    """Windows CMD: 写入批处理文件 + 注册表 AutoRun"""
    bat = get_cmd_bat_path()
    proxy_url = f"http://{HOST}:{http_port}"
    socks_url = f"socks5://{HOST}:{socks5_port}"

    bat_content = f"""@echo off
rem >>> proxy-config start <<<
set http_proxy={proxy_url}
set https_proxy={proxy_url}
set all_proxy={socks_url}
set HTTP_PROXY={proxy_url}
set HTTPS_PROXY={proxy_url}
set ALL_PROXY={socks_url}
set no_proxy={NO_PROXY}
set NO_PROXY={NO_PROXY}
"""
    if ANTHROPIC_BASE_URL:
        bat_content += f'set ANTHROPIC_BASE_URL={ANTHROPIC_BASE_URL}\n'
    bat_content += "rem >>> proxy-config end <<<\n"

    bat.write_text(bat_content, encoding="ascii")
    ok(f"已写入 CMD 批处理: {bat}")

    # 设置注册表 AutoRun
    try:
        subprocess.run(
            ["reg", "add", r"HKCU\Software\Microsoft\Command Processor",
             "/v", "AutoRun", "/t", "REG_SZ",
             "/d", str(bat), "/f"],
            capture_output=True, check=True,
            creationflags=subprocess.CREATE_NO_WINDOW if hasattr(subprocess, 'CREATE_NO_WINDOW') else 0
        )
        ok("CMD AutoRun 注册表已设置")
    except subprocess.CalledProcessError as e:
        warn(f"CMD AutoRun 注册表设置失败（可能需要管理员权限）: {e}")


def remove_cmd_autorun():
    """清除 Windows CMD AutoRun 配置"""
    bat = get_cmd_bat_path()
    if bat.exists():
        bat.unlink()
        ok(f"已删除 {bat}")

    try:
        subprocess.run(
            ["reg", "add", r"HKCU\Software\Microsoft\Command Processor",
             "/v", "AutoRun", "/t", "REG_SZ",
             "/d", "", "/f"],
            capture_output=True, check=True,
            creationflags=subprocess.CREATE_NO_WINDOW if hasattr(subprocess, 'CREATE_NO_WINDOW') else 0
        )
        ok("CMD AutoRun 注册表已清除")
    except subprocess.CalledProcessError:
        # 尝试删除整个值
        try:
            subprocess.run(
                ["reg", "delete", r"HKCU\Software\Microsoft\Command Processor",
                 "/v", "AutoRun", "/f"],
                capture_output=True, check=True,
                creationflags=subprocess.CREATE_NO_WINDOW if hasattr(subprocess, 'CREATE_NO_WINDOW') else 0
            )
            ok("CMD AutoRun 注册表已删除")
        except subprocess.CalledProcessError:
            pass


def remove_proxy(rc_file: Path):
    """清除代理配置块"""
    is_ps = IS_WINDOWS or rc_file.suffix in (".ps1",)

    # 清除当前进程环境变量
    for k in ["http_proxy", "https_proxy", "all_proxy",
              "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY",
              "no_proxy", "NO_PROXY", "ANTHROPIC_BASE_URL"]:
        os.environ.pop(k, None)

    if rc_file.exists():
        content = rc_file.read_text(encoding="utf-8")
        pattern = re.compile(
            rf"\n?{re.escape(PROXY_BLOCK_START)}.*?{re.escape(PROXY_BLOCK_END)}\n?",
            re.DOTALL
        )
        new_content = pattern.sub("", content)
        rc_file.write_text(new_content, encoding="utf-8")
        ok(f"已从 {rc_file} 移除代理配置")

    # Windows: 同时清除 CMD AutoRun
    if IS_WINDOWS:
        remove_cmd_autorun()

    # 清除 npm
    npm = shutil.which("npm") or (shutil.which("npm.cmd") if IS_WINDOWS else None)
    if npm:
        try:
            subprocess.run([npm, "config", "delete", "proxy"], capture_output=True)
            subprocess.run([npm, "config", "delete", "https-proxy"], capture_output=True)
            ok("npm 代理已清除")
        except Exception:
            pass

    # 清除 git
    git = shutil.which("git") or (shutil.which("git.exe") if IS_WINDOWS else None)
    if git:
        try:
            subprocess.run([git, "config", "--global", "--unset", "http.proxy"], capture_output=True)
            subprocess.run([git, "config", "--global", "--unset", "https.proxy"], capture_output=True)
            ok("git 代理已清除")
        except Exception:
            pass


# ─── npm / git 配置 ─────────────────────────────────────────────────

def configure_npm(http_port: int):
    npm = shutil.which("npm") or (shutil.which("npm.cmd") if IS_WINDOWS else None)
    if not npm:
        warn("未找到 npm，跳过 npm 代理配置")
        return
    proxy_url = f"http://{HOST}:{http_port}"
    try:
        subprocess.run([npm, "config", "set", "proxy", proxy_url], check=True, capture_output=True)
        subprocess.run([npm, "config", "set", "https-proxy", proxy_url], check=True, capture_output=True)
        ok(f"npm 代理已设置: {proxy_url}")
    except subprocess.CalledProcessError as e:
        warn(f"npm 代理配置失败: {e}")


def configure_git(http_port: int):
    git = shutil.which("git") or (shutil.which("git.exe") if IS_WINDOWS else None)
    if not git:
        warn("未找到 git，跳过 git 代理配置")
        return
    proxy_url = f"http://{HOST}:{http_port}"
    try:
        subprocess.run([git, "config", "--global", "http.proxy", proxy_url], check=True, capture_output=True)
        subprocess.run([git, "config", "--global", "https.proxy", proxy_url], check=True, capture_output=True)
        ok(f"git 代理已设置: {proxy_url}")
    except subprocess.CalledProcessError as e:
        warn(f"git 代理配置失败: {e}")


# ─── 验证 ────────────────────────────────────────────────────────────

def _curl_test(http_port: int, url: str) -> dict:
    """执行单次 curl 代理测试，返回 {exitcode, http_code, ssl, time_ms}"""
    result = {"exitcode": "1", "http_code": "000", "ssl": "1", "time_ms": "0"}
    proxy_url = f"http://{HOST}:{http_port}"
    curl = shutil.which("curl") or (shutil.which("curl.exe") if IS_WINDOWS else None)
    if not curl:
        return result

    null_dev = "NUL" if IS_WINDOWS else "/dev/null"
    try:
        r = subprocess.run(
            [curl, "-s", "-o", null_dev,
             "-w", "%{exitcode}|%{http_code}|%{ssl_verify_result}|%{time_total}",
             "--proxy", proxy_url,
             "--connect-timeout", "8", "--max-time", "15",
             url],
            capture_output=True, text=True, timeout=20,
            creationflags=subprocess.CREATE_NO_WINDOW if IS_WINDOWS and hasattr(subprocess, 'CREATE_NO_WINDOW') else 0
        )
        parts = r.stdout.strip().split("|")
        result["exitcode"]  = parts[0] if len(parts) > 0 else "1"
        result["http_code"] = parts[1] if len(parts) > 1 else "000"
        result["ssl"]       = parts[2] if len(parts) > 2 else "1"
        result["time_ms"]   = f"{float(parts[3])*1000:.0f}" if len(parts) > 3 and parts[3] else "0"
    except Exception:
        pass
    return result


def full_connectivity_test(http_port: int):
    """测试 Claude (Anthropic) 和 OpenAI 两个 API 的代理连通性"""
    bold(f"\n  全面连通性测试 (端口 {http_port})")
    print(f"  {'─' * 45}")

    targets = [
        ("OpenAI API",    "https://api.openai.com",           "Codex"),
        ("Anthropic API", "https://api.anthropic.com/v1/models", "Claude Code"),
    ]

    headers = f"  {'服务':<20} {'状态':<10} {'耗时':<10} {'对应工具'}"
    print(headers)
    print(f"  {'─' * 45}")

    all_ok = True
    for name, url, tool in targets:
        r = _curl_test(http_port, url)
        ec = r["exitcode"]
        hc = r["http_code"]
        ms = r["time_ms"]

        if ec == "0" and hc != "000":
            # Anthropic 无 API key 返回 401 / OpenAI 返回 421，都是正常的
            tag_map = {"200": "OK", "401": "连通", "403": "连通", "405": "连通", "421": "连通", "404": "连通"}
            tag = tag_map.get(hc, hc)
            # 状态栏上色
            if tag in ("OK", "连通"):
                status = f"[{tag}]"
            else:
                status = f"[{hc}]"
            print(f"  {name:<20} \033[32m{status:<10}\033[0m {ms:<8}ms {tool}")
        else:
            all_ok = False
            print(f"  {name:<20} \033[31m[失败]\033[0m      {ms:<8}ms {tool}")
            if hc == "000":
                warn(f"    {name} 连接失败 — 请检查代理端口 {http_port}")
            else:
                warn(f"    {name} HTTP {hc} — 请检查节点是否支持该目标")

    print(f"  {'─' * 45}")
    if all_ok:
        ok("OpenAI & Anthropic 均连通，Codex / Claude Code 可用")
    else:
        warn("部分 API 不通，检查对应目标是否被节点屏蔽")

    # 查出口 IP
    exit_ip, region = _fetch_exit_ip(http_port)
    if exit_ip:
        if region:
            ok(f"出口 IP: {exit_ip}  ({region})")
        else:
            ok(f"出口 IP: {exit_ip}")

    return all_ok


def _fetch_exit_ip(http_port: int) -> tuple:
    """通过代理查询出口 IP 和地区，返回 (ip, region)"""
    proxy_url = f"http://{HOST}:{http_port}"
    curl = shutil.which("curl") or (shutil.which("curl.exe") if IS_WINDOWS else None)
    if not curl:
        return "", ""
    cf = subprocess.CREATE_NO_WINDOW if IS_WINDOWS and hasattr(subprocess, 'CREATE_NO_WINDOW') else 0

    # 优先用 ip-api.com（免费，返回国家/城市/ISP）
    try:
        r = subprocess.run(
            [curl, "-s", "--proxy", proxy_url, "--connect-timeout", "5", "--max-time", "8",
             "http://ip-api.com/json?fields=country,city,regionName,isp,query"],
            capture_output=True, text=True, timeout=10, creationflags=cf
        )
        data = r.stdout.strip()
        if data.startswith("{"):
            j = json.loads(data)
            ip = j.get("query", "")
            if ip:
                parts = [p for p in [j.get("country", ""), j.get("regionName", ""), j.get("city", "")] if p]
                region = ", ".join(parts) if parts else ""
                if j.get("isp"):
                    region += f" [{j['isp']}]"
                return ip, region
    except Exception:
        pass

    # 兜底：纯 IP 服务
    for svc in ("https://ifconfig.me", "https://api.ipify.org", "https://ip.sb"):
        try:
            r = subprocess.run(
                [curl, "-s", "--proxy", proxy_url, "--connect-timeout", "5", "--max-time", "8", svc],
                capture_output=True, text=True, timeout=10, creationflags=cf
            )
            ip = r.stdout.strip()
            if ip and not ip.startswith("{") and not ip.startswith("<"):
                return ip, ""
        except Exception:
            continue
    return "", ""


def verify_proxy(http_port: int):
    info(f"验证代理连通性 (端口 {http_port}) ...")
    proxy_url = f"http://{HOST}:{http_port}"
    curl = shutil.which("curl")
    if not curl and IS_WINDOWS:
        curl = shutil.which("curl.exe")

    if curl:
        try:
            result = subprocess.run(
                [curl, "-s", "-o", "NUL" if IS_WINDOWS else "/dev/null",
                 "-w", "%{exitcode}|%{http_code}|%{ssl_verify_result}",
                 "--proxy", proxy_url,
                 "--connect-timeout", "8",
                 "https://api.openai.com"],
                capture_output=True, text=True, timeout=15,
                creationflags=subprocess.CREATE_NO_WINDOW if IS_WINDOWS and hasattr(subprocess, 'CREATE_NO_WINDOW') else 0
            )
            parts = result.stdout.strip().split("|")
            exitcode = parts[0] if len(parts) > 0 else "1"
            http_code = parts[1] if len(parts) > 1 else "000"
            ssl_ok    = parts[2] if len(parts) > 2 else "1"

            if exitcode == "0":
                ok(f"代理可用 (HTTP {http_code})")
                # 获取出口 IP
                exit_ip, region = _fetch_exit_ip(http_port)
                if exit_ip:
                    if region:
                        ok(f"出口 IP: {exit_ip}  ({region})")
                    else:
                        ok(f"出口 IP: {exit_ip}")
                else:
                    info("无法获取出口 IP（不影响使用）")
            elif http_code == "000":
                warn(f"代理连接失败（curl exitcode={exitcode}），请确认客户端已启动且端口 {http_port} 正确")
            else:
                warn(f"代理返回状态码: {http_code}（exitcode={exitcode}），请检查节点是否可用")
        except subprocess.TimeoutExpired:
            warn("验证超时，请确认代理客户端已启动且端口正确")
        except Exception as e:
            warn(f"curl 验证失败: {e}")
    else:
        warn("未找到 curl，跳过验证（可手动测试）")


# ─── 菜单 ────────────────────────────────────────────────────────────

def print_menu():
    plat_name = "macOS" if IS_MAC else ("Windows" if IS_WINDOWS else platform.system())
    bold(f"\n===  {plat_name} 代理一键配置 — Codex / Claude Code  ===")
    print("  1) 配置代理（自动检测端口）")
    print("  2) 配置代理（手动指定端口）")
    print("  3) 移除所有代理配置")
    print("  4) 验证当前代理连通性")
    print("  5) 全链路测试 (OpenAI + Anthropic)")
    print("  6) 查看当前代理配置")
    print("  0) 退出")
    print()


def set_env_current_session(http_port: int, socks5_port: int):
    """在当前 Python 进程设置环境变量（仅影响当前终端会话）"""
    proxy_url = f"http://{HOST}:{http_port}"
    socks_url = f"socks5://{HOST}:{socks5_port}"
    os.environ["http_proxy"]    = proxy_url
    os.environ["https_proxy"]   = proxy_url
    os.environ["all_proxy"]     = socks_url
    os.environ["HTTP_PROXY"]    = proxy_url
    os.environ["HTTPS_PROXY"]   = proxy_url
    os.environ["ALL_PROXY"]     = socks_url
    os.environ["no_proxy"]      = NO_PROXY
    os.environ["NO_PROXY"]      = NO_PROXY
    if ANTHROPIC_BASE_URL:
        os.environ["ANTHROPIC_BASE_URL"] = ANTHROPIC_BASE_URL
    ok("当前会话环境变量已设置（仅本终端有效）")


def show_current_config():
    """展示当前代理环境变量是否生效"""
    bold("\n  当前环境代理配置:")
    print(f"  {'─' * 45}")

    keys = [
        ("http_proxy",   "HTTP 代理"),
        ("https_proxy",  "HTTPS 代理"),
        ("all_proxy",    "SOCKS5 代理"),
        ("no_proxy",     "不走代理"),
    ]
    any_set = False
    for k, label in keys:
        v = os.environ.get(k, "")
        if v:
            any_set = True
            print(f"  {label:<12}  \033[32m{v}\033[0m")
        else:
            print(f"  {label:<12}  \033[31m未设置\033[0m")

    if ANTHROPIC_BASE_URL:
        abu = os.environ.get("ANTHROPIC_BASE_URL", ANTHROPIC_BASE_URL)
        print(f"  {'Anthropic':<12}  \033[32m{abu}\033[0m")
        any_set = True

    print(f"  {'─' * 45}")
    if any_set:
        ok("代理环境变量已生效")
    else:
        warn("代理环境变量未生效，请重新打开终端")


def print_how_to_apply():
    if IS_MAC:
        rc = get_rc_file()
        bold(f"  请运行以下命令使环境变量立即生效（当前终端）：")
        print(f"    source {rc}")
        print("  或重新打开终端后自动生效。")
    elif IS_WINDOWS:
        bold("  请重新打开 CMD / PowerShell 窗口使代理生效。")
        print("  PowerShell 当前窗口可运行: . $PROFILE")
        print(f"  CMD 已配置 AutoRun，新窗口自动加载")


# ─── 主函数 ─────────────────────────────────────────────────────────

def main():
    if not (IS_MAC or IS_WINDOWS):
        warn(f"未测试的平台: {platform.system()}，部分功能可能不可用")

    rc_file = get_rc_file()
    info(f"代理配置将写入: {rc_file}")

    while True:
        print_menu()
        choice = input("请选择 [0-6]: ").strip()

        if choice == "0":
            print("退出")
            break

        elif choice == "1":
            http_port, socks5_port = auto_detect_ports()
            info(f"使用端口: HTTP={http_port}, SOCKS5={socks5_port}")

            if check_port_listening(http_port):
                ok(f"端口 {http_port} 正在监听 ✓")
            else:
                warn(f"端口 {http_port} 未监听，请确认代理客户端已启动")

            write_rc_file(rc_file, http_port, socks5_port)
            configure_npm(http_port)

            cfg_git = input("\n  是否同时配置 git 代理？[y/N] ").strip().lower()
            if cfg_git == "y":
                configure_git(http_port)

            verify_proxy(http_port)
            set_env_current_session(http_port, socks5_port)
            show_current_config()

            print()
            bold("=== 配置完成 ===")
            print_how_to_apply()
            print()
            warn("http_proxy 环境变量不代理 DNS 查询，存在 DNS 泄漏风险")
            info("防泄漏：v2rayN 开启 TUN 模式 / 浏览器设 SOCKS5 并关闭系统 DNS")

        elif choice == "2":
            try:
                default_http = DEFAULT_HTTP_PORT
                default_socks = DEFAULT_SOCKS5_PORT
                h = input(f"  输入 HTTP 代理端口 [默认 {default_http}]: ").strip()
                http_port = int(h) if h else default_http
                s = input(f"  输入 SOCKS5 代理端口 [默认 {http_port+1}]: ").strip()
                socks5_port = int(s) if s else http_port + 1
            except ValueError:
                err("端口必须是数字")
                continue

            write_rc_file(rc_file, http_port, socks5_port)
            configure_npm(http_port)

            cfg_git = input("\n  是否同时配置 git 代理？[y/N] ").strip().lower()
            if cfg_git == "y":
                configure_git(http_port)

            verify_proxy(http_port)
            set_env_current_session(http_port, socks5_port)
            show_current_config()

            print()
            bold("=== 配置完成 ===")
            print_how_to_apply()
            print()
            warn("http_proxy 环境变量不代理 DNS 查询，存在 DNS 泄漏风险")
            info("防泄漏：v2rayN 开启 TUN 模式 / 浏览器设 SOCKS5 并关闭系统 DNS")

        elif choice == "3":
            remove_proxy(rc_file)
            bold("=== 代理配置已全部清除 ===")

        elif choice == "4":
            http_port, _ = auto_detect_ports()
            verify_proxy(http_port)

        elif choice == "5":
            http_port, _ = auto_detect_ports()
            full_connectivity_test(http_port)

        elif choice == "6":
            show_current_config()

        else:
            warn("无效选项，请重新输入")


if __name__ == "__main__":
    main()
