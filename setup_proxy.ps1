<#
.SYNOPSIS
    Windows 终端代理一键配置（纯 PowerShell，无需 Python）
    支持 v2rayN / Clash / sing-box
    适用于 Codex CLI / Claude Code / npm / git
#>

$DEFAULT_HTTP_PORT   = 7890
$DEFAULT_SOCKS5_PORT = 7891
$PROXY_HOST = "127.0.0.1"
$NO_PROXY = "localhost,127.0.0.1,::1"
$ANTHROPIC_BASE_URL = ""

$PROXY_BLOCK_START = "# >>> proxy-config start <<<"
$PROXY_BLOCK_END   = "# >>> proxy-config end <<<"

function info($msg)  { Write-Host "  $msg" }
function ok($msg)    { Write-Host "  [OK] $msg" -ForegroundColor Green }
function warn($msg)  { Write-Host "  [WARN] $msg" -ForegroundColor Yellow }
function err($msg)   { Write-Host "  [ERR] $msg" -ForegroundColor Red }
function bold($msg)  { Write-Host $msg }

# PowerShell 5.1 兼容: 控制台 UTF-8 输出
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# ---- 端口检测 ----

function Check-PortListening($port) {
    $conn = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue |
        Where-Object { $_.LocalAddress -eq "0.0.0.0" -or $_.LocalAddress -eq "127.0.0.1" -or $_.LocalAddress -eq "::" }
    return [bool]$conn
}

function Detect-V2rayNPort {
    $http_port = 10808; $socks_port = 10808

    $dirs = @(
        "$env:APPDATA\v2rayN",
        "$env:USERPROFILE\v2rayN",
        "C:\v2rayN"
    )

    foreach ($base in $dirs) {
        $gui = Join-Path $base "guiNConfig.json"
        if (Test-Path $gui) {
            try {
                $data = Get-Content $gui -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($data.httpPort) { $http_port = [int]$data.httpPort }
                if ($data.socksPort) { $socks_port = [int]$data.socksPort }
                info "检测到 v2rayN 端口: HTTP=$http_port, SOCKS=$socks_port  ($gui)"
                return @($http_port, $socks_port)
            } catch {}
        }

        $core = Join-Path $base "config.json"
        if (Test-Path $core) {
            try {
                $data = Get-Content $core -Raw -Encoding UTF8 | ConvertFrom-Json
                foreach ($ib in $data.inbounds) {
                    $p  = $ib.port; if (-not $p) { $p = $ib.listenPort }
                    if (-not $p) { continue }
                    $pr = $ib.protocol
                    if ($pr -in @("http","mixed")) { $http_port = [int]$p }
                    if ($pr -eq "socks") { $socks_port = [int]$p }
                }
                if ($http_port) { return @($http_port, $socks_port) }
            } catch {}
        }
    }

    foreach ($p in @(10808, 10809, 1080, 7890, 8080)) {
        if (Check-PortListening $p) {
            info "端口嗅探: $p 正在监听（混合端口模式）"
            return @($p, $p)
        }
    }

    return @(10808, 10808)
}

function Detect-SingBoxPort {
    $configs = @()
    if ($env:APPDATA) {
        $configs += "$env:APPDATA\sing-box\config.json"
        $configs += "$env:APPDATA\sing-box\config.yaml"
    }
    $configs += "$env:USERPROFILE\sing-box\config.json"
    $configs += "C:\Program Files\sing-box\config.json"

    foreach ($cfg in $configs) {
        if (-not (Test-Path $cfg)) { continue }
        try {
            $content = Get-Content $cfg -Raw -Encoding UTF8
            if ($content -match '"listen_port"\s*:\s*(\d+)') {
                $port = [int]$Matches[1]
                info "检测到 sing-box 端口: $port  ($cfg)"
                return @($port, $port + 1)
            }
        } catch {}
    }
    return @($DEFAULT_HTTP_PORT, $DEFAULT_SOCKS5_PORT)
}

function Auto-DetectPorts {
    $candidates = @(
        @{Name="v2rayN";   Ports=(Detect-V2rayNPort)},
        @{Name="sing-box"; Ports=(Detect-SingBoxPort)},
        @{Name="Clash";    Ports=@($DEFAULT_HTTP_PORT, $DEFAULT_SOCKS5_PORT)}
    )

    foreach ($c in $candidates) {
        $hp = $c.Ports[0]; $sp = $c.Ports[1]
        if ((Check-PortListening $hp) -or (Check-PortListening $sp)) {
            info "自动检测: $($c.Name) 端口 $hp/$sp 正在监听"
            return @($hp, $sp)
        }
    }
    info "未检测到监听端口，使用默认值"
    return @($DEFAULT_HTTP_PORT, $DEFAULT_SOCKS5_PORT)
}

# ---- Shell Profile 配置 ----

function Get-ProfilePath {
    try {
        $p = powershell -NoProfile -Command '$PROFILE'
        if ($p) { return $p }
    } catch {}
    return "$env:USERPROFILE\Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1"
}

function Get-CmdBatPath {
    return "$env:USERPROFILE\.proxy_init.cmd"
}

function Build-ProxyBlock($http_port, $socks5_port) {
    $proxy_url = "http://${PROXY_HOST}:${http_port}"
    $socks_url = "socks5://${PROXY_HOST}:${socks5_port}"
    $lines = @($PROXY_BLOCK_START)
    $lines += "`$env:http_proxy  = `"$proxy_url`""
    $lines += "`$env:https_proxy = `"$proxy_url`""
    $lines += "`$env:all_proxy   = `"$socks_url`""
    $lines += "`$env:HTTP_PROXY  = `"$proxy_url`""
    $lines += "`$env:HTTPS_PROXY = `"$proxy_url`""
    $lines += "`$env:ALL_PROXY   = `"$socks_url`""
    $lines += "`$env:no_proxy    = `"$NO_PROXY`""
    $lines += "`$env:NO_PROXY    = `"$NO_PROXY`""
    if ($ANTHROPIC_BASE_URL) {
        $lines += "`$env:ANTHROPIC_BASE_URL = `"$ANTHROPIC_BASE_URL`""
    }
    $lines += $PROXY_BLOCK_END
    return ($lines -join "`r`n") + "`r`n"
}

function Write-Profile($http_port, $socks5_port) {
    $rc = Get-ProfilePath
    $dir = Split-Path $rc -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $block = Build-ProxyBlock $http_port $socks5_port
    $startEsc = [regex]::Escape($PROXY_BLOCK_START)
    $endEsc   = [regex]::Escape($PROXY_BLOCK_END)

    if (Test-Path $rc) {
        $content = Get-Content $rc -Raw -Encoding UTF8
        if ($content -match $startEsc) {
            $pattern = "(?s)$startEsc.*$endEsc"
            $newContent = [regex]::Replace($content, $pattern, $block)
            Set-Content -Path $rc -Value $newContent -Encoding UTF8
            ok "已更新 $rc"
        } else {
            Add-Content -Path $rc -Value "`r`n$block" -Encoding UTF8
            ok "已追加到 $rc"
        }
    } else {
        Set-Content -Path $rc -Value $block -Encoding UTF8
        ok "已创建 $rc 并写入代理配置"
    }

    Setup-CmdAutoRun $http_port $socks5_port
}

function Setup-CmdAutoRun($http_port, $socks5_port) {
    $bat = Get-CmdBatPath
    $proxy_url = "http://${PROXY_HOST}:${http_port}"
    $socks_url = "socks5://${PROXY_HOST}:${socks5_port}"

    $batContent = "@echo off`r`n"
    $batContent += "rem >>> proxy-config start <<<`r`n"
    $batContent += "set http_proxy=$proxy_url`r`n"
    $batContent += "set https_proxy=$proxy_url`r`n"
    $batContent += "set all_proxy=$socks_url`r`n"
    $batContent += "set HTTP_PROXY=$proxy_url`r`n"
    $batContent += "set HTTPS_PROXY=$proxy_url`r`n"
    $batContent += "set ALL_PROXY=$socks_url`r`n"
    $batContent += "set no_proxy=$NO_PROXY`r`n"
    $batContent += "set NO_PROXY=$NO_PROXY`r`n"
    if ($ANTHROPIC_BASE_URL) {
        $batContent += "set ANTHROPIC_BASE_URL=$ANTHROPIC_BASE_URL`r`n"
    }
    $batContent += "rem >>> proxy-config end <<<`r`n"

    Set-Content -Path $bat -Value $batContent -Encoding ASCII
    ok "已写入 CMD 批处理: $bat"

    try {
        Set-ItemProperty -Path "HKCU:\Software\Microsoft\Command Processor" -Name "AutoRun" -Value $bat -Force
        ok "CMD AutoRun 注册表已设置"
    } catch {
        warn "CMD AutoRun 注册表设置失败: $_"
    }
}

function Remove-CmdAutoRun {
    $bat = Get-CmdBatPath
    if (Test-Path $bat) {
        Remove-Item $bat -Force
        ok "已删除 $bat"
    }
    try {
        Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Command Processor" -Name "AutoRun" -Force -ErrorAction Stop
        ok "CMD AutoRun 注册表已删除"
    } catch {
        try {
            Set-ItemProperty -Path "HKCU:\Software\Microsoft\Command Processor" -Name "AutoRun" -Value "" -Force
            ok "CMD AutoRun 注册表已清除"
        } catch {}
    }
}

function Remove-Proxy {
    $rc = Get-ProfilePath
    $startEsc = [regex]::Escape($PROXY_BLOCK_START)
    $endEsc   = [regex]::Escape($PROXY_BLOCK_END)

    if (Test-Path $rc) {
        $content = Get-Content $rc -Raw -Encoding UTF8
        if ($content -match $startEsc) {
            $pattern = "(?s)$startEsc.*$endEsc\r?\n?"
            $newContent = [regex]::Replace($content, $pattern, "")
            Set-Content -Path $rc -Value $newContent -Encoding UTF8
            ok "已从 $rc 移除代理配置"
        }
    }

    Remove-CmdAutoRun

    if (Get-Command npm -ErrorAction SilentlyContinue) {
        npm config delete proxy 2>$null
        npm config delete https-proxy 2>$null
        ok "npm 代理已清除"
    }

    if (Get-Command git -ErrorAction SilentlyContinue) {
        git config --global --unset http.proxy 2>$null
        git config --global --unset https.proxy 2>$null
        ok "git 代理已清除"
    }
}

# ---- npm / git 配置 ----

function Configure-Npm($http_port) {
    if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
        warn "未找到 npm，跳过"
        return
    }
    $url = "http://${PROXY_HOST}:${http_port}"
    npm config set proxy $url 2>$null
    npm config set https-proxy $url 2>$null
    ok "npm 代理已设置: $url"
}

function Configure-Git($http_port) {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        warn "未找到 git，跳过"
        return
    }
    $url = "http://${PROXY_HOST}:${http_port}"
    git config --global http.proxy $url 2>$null
    git config --global https.proxy $url 2>$null
    ok "git 代理已设置: $url"
}

# ---- 验证与测试 ----

function Invoke-CurlTest($http_port, $url) {
    $proxy = "http://${PROXY_HOST}:${http_port}"
    try {
        $result = curl.exe -s -o NUL `
            -w "%{exitcode}|%{http_code}|%{ssl_verify_result}|%{time_total}" `
            --proxy $proxy --connect-timeout 8 --max-time 15 $url 2>&1
        $parts = $result -split '\|'
        return @{
            exitcode  = if ($parts.Length -gt 0) { $parts[0] } else { "1" }
            http_code = if ($parts.Length -gt 1) { $parts[1] } else { "000" }
            ssl       = if ($parts.Length -gt 2) { $parts[2] } else { "1" }
            time_ms   = if ($parts.Length -gt 3 -and $parts[3]) { [math]::Round([float]$parts[3] * 1000) } else { 0 }
        }
    } catch {
        return @{ exitcode="1"; http_code="000"; ssl="1"; time_ms=0 }
    }
}

function Get-ExitIP($http_port) {
    $proxy = "http://${PROXY_HOST}:${http_port}"

    try {
        $r = curl.exe -s --proxy $proxy --connect-timeout 5 --max-time 8 `
            "http://ip-api.com/json?fields=country,city,regionName,isp,query" 2>&1
        if ($r -match '\{') {
            $j = $r | ConvertFrom-Json
            if ($j.query) {
                $parts = @($j.country, $j.regionName, $j.city | Where-Object { $_ })
                $region = $parts -join ", "
                if ($j.isp) { $region += " [$($j.isp)]" }
                return @($j.query, $region)
            }
        }
    } catch {}

    foreach ($svc in @("https://ifconfig.me", "https://api.ipify.org", "https://ip.sb")) {
        try {
            $r = curl.exe -s --proxy $proxy --connect-timeout 5 --max-time 8 $svc 2>&1
            if ($r -and $r -notmatch '[{<]') { return @($r, "") }
        } catch {}
    }
    return @("", "")
}

function Test-FullConnectivity($http_port) {
    bold ""
    bold "  全面连通性测试 (端口 $http_port)"
    Write-Host "  $( '-' * 45 )"

    $targets = @(
        @{Name="OpenAI API";    URL="https://api.openai.com";              Tool="Codex"},
        @{Name="Anthropic API"; URL="https://api.anthropic.com/v1/models"; Tool="Claude Code"}
    )

    Write-Host ("  {0,-20} {1,-10} {2,-8} {3}" -f "服务","状态","耗时","对应工具")
    Write-Host "  $( '-' * 45 )"

    $allOk = $true
    foreach ($t in $targets) {
        $r = Invoke-CurlTest $http_port $t.URL
        if ($r.exitcode -eq "0" -and $r.http_code -ne "000") {
            $tagMap = @{200="OK"; 401="连通"; 403="连通"; 405="连通"; 421="连通"; 404="连通"}
            $tag = $tagMap[$r.http_code]
            if (-not $tag) { $tag = $r.http_code }
            Write-Host ("  {0,-20} " -f $t.Name) -NoNewline
            Write-Host ("[{0}]" -f $tag).PadRight(12) -NoNewline -ForegroundColor Green
            Write-Host ("{0}ms" -f $r.time_ms).PadRight(10) -NoNewline
            Write-Host $t.Tool
        } else {
            $allOk = $false
            Write-Host ("  {0,-20} " -f $t.Name) -NoNewline
            Write-Host "[失败]".PadRight(12) -NoNewline -ForegroundColor Red
            Write-Host ("{0}ms" -f $r.time_ms).PadRight(10) -NoNewline
            Write-Host $t.Tool
            if ($r.http_code -eq "000") {
                warn "    $($t.Name) 连接失败 -- 请检查代理端口 $http_port"
            }
        }
    }

    Write-Host "  $( '-' * 45 )"
    if ($allOk) {
        ok "OpenAI & Anthropic 均连通，Codex / Claude Code 可用"
    } else {
        warn "部分 API 不通，检查对应目标是否被节点屏蔽"
    }

    $ip, $region = Get-ExitIP $http_port
    if ($ip) {
        if ($region) { ok "出口 IP: $ip  ($region)" }
        else { ok "出口 IP: $ip" }
    }
}

function Test-ProxyConnectivity($http_port) {
    info "验证代理连通性 (端口 $http_port) ..."
    $r = Invoke-CurlTest $http_port "https://api.openai.com"

    if ($r.exitcode -eq "0") {
        ok "代理可用 (HTTP $($r.http_code))"
        $ip, $region = Get-ExitIP $http_port
        if ($ip) {
            if ($region) { ok "出口 IP: $ip  ($region)" }
            else { ok "出口 IP: $ip" }
        } else {
            info "无法获取出口 IP（不影响使用）"
        }
    } elseif ($r.http_code -eq "000") {
        warn "代理连接失败 (curl exitcode=$($r.exitcode))，请确认客户端已启动且端口 $http_port 正确"
    } else {
        warn "代理返回状态码: $($r.http_code) (exitcode=$($r.exitcode))，请检查节点是否可用"
    }
}

# ---- 当前配置展示 ----

function Show-CurrentConfig {
    bold ""
    bold "  当前环境代理配置:"
    Write-Host "  $( '-' * 50 )"

    $keys = @(
        @{Var="http_proxy";  Label="HTTP 代理"},
        @{Var="https_proxy"; Label="HTTPS 代理"},
        @{Var="all_proxy";   Label="SOCKS5 代理"},
        @{Var="no_proxy";    Label="不走代理"}
    )

    $anySet = $false
    foreach ($k in $keys) {
        $v = [Environment]::GetEnvironmentVariable($k.Var)
        if ($v) {
            $anySet = $true
            Write-Host "  " -NoNewline
            Write-Host $k.Label.PadRight(14) -NoNewline
            Write-Host " $v" -ForegroundColor Green
        } else {
            Write-Host "  " -NoNewline
            Write-Host $k.Label.PadRight(14) -NoNewline
            Write-Host " 未设置" -ForegroundColor Red
        }
    }

    if ($ANTHROPIC_BASE_URL) {
        $abu = [Environment]::GetEnvironmentVariable("ANTHROPIC_BASE_URL")
        if (-not $abu) { $abu = $ANTHROPIC_BASE_URL }
        Write-Host "  Anthropic".PadRight(16) -NoNewline
        Write-Host " $abu" -ForegroundColor Green
        $anySet = $true
    }

    Write-Host "  $( '-' * 50 )"
    if ($anySet) { ok "代理环境变量已生效" }
    else { warn "代理环境变量未生效，请重新打开终端或运行 . `$PROFILE" }
}

# ---- 环境变量生效 ----

function Set-EnvCurrentSession($http_port, $socks5_port) {
    $proxy_url = "http://${PROXY_HOST}:${http_port}"
    $socks_url = "socks5://${PROXY_HOST}:${socks5_port}"
    [Environment]::SetEnvironmentVariable("http_proxy",   $proxy_url, "Process")
    [Environment]::SetEnvironmentVariable("https_proxy",  $proxy_url, "Process")
    [Environment]::SetEnvironmentVariable("all_proxy",    $socks_url, "Process")
    [Environment]::SetEnvironmentVariable("HTTP_PROXY",   $proxy_url, "Process")
    [Environment]::SetEnvironmentVariable("HTTPS_PROXY",  $proxy_url, "Process")
    [Environment]::SetEnvironmentVariable("ALL_PROXY",    $socks_url, "Process")
    [Environment]::SetEnvironmentVariable("no_proxy",     $NO_PROXY, "Process")
    [Environment]::SetEnvironmentVariable("NO_PROXY",     $NO_PROXY, "Process")
    if ($ANTHROPIC_BASE_URL) {
        [Environment]::SetEnvironmentVariable("ANTHROPIC_BASE_URL", $ANTHROPIC_BASE_URL, "Process")
    }
    ok "当前会话环境变量已设置（仅本终端有效）"
}

# ---- 菜单 ----

function Show-Menu {
    bold ""
    bold "===  Windows 代理一键配置 -- Codex / Claude Code  ==="
    Write-Host "  1) 配置代理（自动检测端口）"
    Write-Host "  2) 配置代理（手动指定端口）"
    Write-Host "  3) 移除所有代理配置"
    Write-Host "  4) 验证当前代理连通性"
    Write-Host "  5) 全链路测试 (OpenAI + Anthropic)"
    Write-Host "  6) 查看当前代理配置"
    Write-Host "  0) 退出"
    Write-Host ""
}

# ---- 主函数 ----

function Main {
    $rc = Get-ProfilePath
    info "代理配置将写入: $rc"

    while ($true) {
        Show-Menu
        $choice = Read-Host "请选择 [0-6]"

        switch ($choice) {
            "0" { Write-Host "退出"; break }
            "1" {
                $hp, $sp = Auto-DetectPorts
                info "使用端口: HTTP=$hp, SOCKS5=$sp"

                if (Check-PortListening $hp) {
                    ok "端口 $hp 正在监听"
                } else {
                    warn "端口 $hp 未监听，请确认代理客户端已启动"
                }

                Write-Profile $hp $sp
                Configure-Npm $hp

                Write-Host "  是否同时配置 git 代理？[y/N] " -NoNewline
                $cfg_git = Read-Host ""
                if ($cfg_git -eq "y") { Configure-Git $hp }

                Test-ProxyConnectivity $hp
                Set-EnvCurrentSession $hp $sp
                Show-CurrentConfig

                Write-Host ""
                bold "=== 配置完成 ==="
                bold "  请重新打开 CMD / PowerShell 窗口使代理生效。"
                Write-Host "  PowerShell 当前窗口可运行: . `$PROFILE"
                Write-Host "  CMD 已配置 AutoRun，新窗口自动加载"
            }
            "2" {
                $h = Read-Host "  输入 HTTP 代理端口 [默认 $DEFAULT_HTTP_PORT]"
                if ([string]::IsNullOrWhiteSpace($h)) { $hp = $DEFAULT_HTTP_PORT } else { $hp = [int]$h }
                $ds = $hp + 1
                $s = Read-Host "  输入 SOCKS5 代理端口 [默认 $ds]"
                if ([string]::IsNullOrWhiteSpace($s)) { $sp = $ds } else { $sp = [int]$s }

                Write-Profile $hp $sp
                Configure-Npm $hp

                Write-Host "  是否同时配置 git 代理？[y/N] " -NoNewline
                $cfg_git = Read-Host ""
                if ($cfg_git -eq "y") { Configure-Git $hp }

                Test-ProxyConnectivity $hp
                Set-EnvCurrentSession $hp $sp
                Show-CurrentConfig

                Write-Host ""
                bold "=== 配置完成 ==="
                bold "  请重新打开 CMD / PowerShell 窗口使代理生效。"
            }
            "3" {
                Remove-Proxy
                bold "=== 代理配置已全部清除 ==="
            }
            "4" {
                $hp, $null = Auto-DetectPorts
                Test-ProxyConnectivity $hp
            }
            "5" {
                $hp, $null = Auto-DetectPorts
                Test-FullConnectivity $hp
            }
            "6" {
                Show-CurrentConfig
            }
            default {
                warn "无效选项，请重新输入"
            }
        }
        if ($choice -eq "0") { break }
        Write-Host ""
    }
}

Main