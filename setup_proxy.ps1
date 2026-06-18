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

# ---- Windows 智能DNS 禁用 ----

$SMART_DNS_REGS = @(
    @{
        Key   = "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient"
        Name  = "DisableSmartNameResolution"
        Value = 1
        Desc  = "智能多宿主 DNS 解析"
    },
    @{
        Key   = "HKLM:\SYSTEM\CurrentControlSet\Services\Dnscache\Parameters"
        Name  = "DisableParallelAandAAAA"
        Value = 1
        Desc  = "并行 A/AAAA 查询"
    },
    @{
        Key   = "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient"
        Name  = "EnableMulticast"
        Value = 0
        Desc  = "mDNS/LLMNR 组播"
    }
)

function Check-SmartDNSStatus {
    $results = @()
    foreach ($reg in $SMART_DNS_REGS) {
        try {
            $current = Get-ItemProperty -Path $reg.Key -Name $reg.Name -ErrorAction Stop
            $val = $current.$($reg.Name)
            $isDisabled = ($val -eq $reg.Value)
            $results += @{
                Desc       = $reg.Desc
                Current    = $val
                Target     = $reg.Value
                IsDisabled = $isDisabled
            }
        } catch {
            $results += @{
                Desc       = $reg.Desc
                Current    = -1
                Target     = $reg.Value
                IsDisabled = $false
            }
        }
    }
    return $results
}

function Toggle-SmartDNSSingle($key, $name, $value, $enable) {
    <#
    .SYNOPSIS
        切换单个智能DNS 注册表项
    #>
    if ($enable) {
        try {
            if (-not (Test-Path $key)) {
                New-Item -Path $key -Force | Out-Null
            }
            Set-ItemProperty -Path $key -Name $name -Value $value -Type DWord -Force
            ok "$name = $value"
        } catch {
            warn "设置失败（可能需要管理员权限）: $_"
        }
    } else {
        try {
            Remove-ItemProperty -Path $key -Name $name -Force -ErrorAction Stop
            ok "$name 已恢复系统默认"
        } catch {
            warn "恢复失败（可能需要管理员权限）: $_"
        }
    }
}

function Disable-SmartDNS {
    bold ""
    bold "  禁用 Windows 智能DNS ..."
    Write-Host "  $( '-' * 45 )"

    $allOk = $true
    foreach ($reg in $SMART_DNS_REGS) {
        info "正在设置 $($reg.Name) = $($reg.Value) ..."
        try {
            if (-not (Test-Path $reg.Key)) {
                New-Item -Path $reg.Key -Force | Out-Null
            }
            Set-ItemProperty -Path $reg.Key -Name $reg.Name -Value $reg.Value -Type DWord -Force
            ok "$($reg.Name) = $($reg.Value)"
        } catch {
            warn "设置失败（可能需要管理员权限）: $_"
            $allOk = $false
        }
    }

    if ($allOk) {
        ok "Windows 智能DNS 已禁用"
        Write-Host "  $( '-' * 45 )"
        info "效果: DNS 查询不再向所有网卡广播，避免代理环境 DNS 泄漏"
        info "恢复方法: 重新运行本脚本 -> 选项 7 -> 恢复"
    } else {
        warn "部分设置失败，请以管理员身份运行后重试"
    }
}

function Restore-SmartDNS {
    bold ""
    bold "  恢复 Windows 智能DNS 默认设置 ..."
    Write-Host "  $( '-' * 45 )"

    foreach ($reg in $SMART_DNS_REGS) {
        info "正在恢复 $($reg.Name) ..."
        try {
            Remove-ItemProperty -Path $reg.Key -Name $reg.Name -Force -ErrorAction Stop
            ok "$($reg.Name) 已恢复系统默认"
        } catch {
            ok "$($reg.Name) 已是系统默认"
        }
    }
    ok "已恢复默认 DNS 行为"
}

function Test-DNSLeak {
    <#
    .SYNOPSIS
        检测 DNS 是否泄漏 — 检查系统实际使用的 DNS 解析器
    #>
    bold ""
    bold "  正在检测 DNS 泄漏 ..."
    Write-Host "  $( '-' * 45 )"

    $okCount = 0

    # ── 1. nslookup（不指定 DNS 服务器）→ 使用系统 DNS 配置 ──
    try {
        $out = nslookup google.com 2>&1
        $dnsServer = ""
        foreach ($line in $out) {
            if ($line -match "Server:\s+(.+)") {
                $dnsServer = $Matches[1].Trim()
            }
        }
        if ($dnsServer) {
            if ($dnsServer -in @("127.0.0.1", "localhost", "::1")) {
                ok "nslookup DNS 服务器 → $dnsServer (代理本地)"
                $okCount++
            } elseif ($dnsServer -eq "Unknown" -or $dnsServer -like "UnKnown*") {
                info "nslookup DNS 服务器 → $dnsServer (查询失败或走代理)"
                $okCount++
            } else {
                warn "nslookup DNS 服务器 → $dnsServer (可能是 ISP/路由器 DNS)"
            }
        } else {
            info "nslookup 无法解析 DNS 服务器（可能被代理拦截）"
            $okCount++
        }
    } catch {
        info "nslookup 超时（可能被代理拦截）"
        $okCount++
    }

    # ── 2. 用 Invoke-WebRequest 通过代理发 HTTPS 请求 ──
    $ports = Auto-DetectPorts
    $httpPort = $ports[0]
    try {
        $resp = Invoke-WebRequest -Uri "https://www.google.com" `
            -Proxy "http://127.0.0.1:$httpPort" `
            -Method Head `
            -TimeoutSec 10 `
            -SkipCertificateCheck `
            -ErrorAction Stop
        if ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 400) {
            ok "代理 DNS 解析正常 (IWR → google, 状态码 $($resp.StatusCode))"
            $okCount++
        } else {
            warn "代理 DNS 解析异常 (IWR → google, 状态码 $($resp.StatusCode))"
        }
    } catch {
        warn "代理 HTTPS 连通性检测失败: $_"
        info "可能原因: 代理未开 / 节点不通 / 需要认证"
    }

    # ── 3. 辅助: 直连 8.8.8.8 ──
    info "辅助检测: 直连公网 DNS 8.8.8.8 ..."
    try {
        $out8 = nslookup google.com 8.8.8.8 2>&1
        if ($LASTEXITCODE -eq 0 -and ($out8 -join "`n") -match "Address") {
            info "8.8.8.8 可达（UDP 53 未被防火墙拦截，但不等于 DNS 泄漏）"
        } else {
            ok "8.8.8.8 不可达 — 防火墙已拦截直连 DNS"
            $okCount++
        }
    } catch {}

    # ── 汇总 ──
    Write-Host ""
    Write-Host "  $( '-' * 45 )"
    if ($okCount -ge 2) {
        ok "DNS 泄漏检测通过 ($okCount/3 项正常)"
    } elseif ($okCount -eq 1) {
        warn "DNS 存在可疑 ($okCount/3 项正常) — 建议检查代理客户端 DNS 设置"
    } else {
        warn "DNS 泄漏风险较高 — 建议检查代理客户端 DNS 设置"
    }
    info "提示: 代理客户端 (v2rayN/Clash) 需确认 `"系统代理`" 和 `"DNS 设置`" 已开启"
}

function Show-SmartDNSMenu {
    <#
    .SYNOPSIS
        智能DNS 管理子菜单（独立切换每项）
    #>
    bold ""
    bold "===  Windows 智能DNS 管理 ==="

    $keyLabels = @(
        @{Label="智能多宿主 DNS 解析"; Idx=0},
        @{Label="并行 A/AAAA 查询";    Idx=1},
        @{Label="mDNS/LLMNR 组播";     Idx=2}
    )

    while ($true) {
        $status = Check-SmartDNSStatus

        Write-Host ""
        Write-Host "  当前状态:"
        Write-Host "  $( '-' * 52 )"
        foreach ($s in $status) {
            if ($s.Current -ge 0) {
                if ($s.IsDisabled) {
                    Write-Host ("  {0,-22} 当前={1}  目标={2}  " -f $s.Desc, $s.Current, $s.Target) -NoNewline
                    Write-Host "已禁用" -ForegroundColor Green
                } else {
                    Write-Host ("  {0,-22} 当前={1}  目标={2}  " -f $s.Desc, $s.Current, $s.Target) -NoNewline
                    Write-Host "未禁用" -ForegroundColor Yellow
                }
            } else {
                Write-Host ("  {0,-22} 未配置（系统默认）" -f $s.Desc)
            }
        }
        Write-Host "  $( '-' * 52 )"

        # 逐项开关
        for ($i = 0; $i -lt $keyLabels.Count; $i++) {
            $idx = $keyLabels[$i].Idx
            $label = $keyLabels[$i].Label
            $s = $status[$idx]
            $action = if ($s.IsDisabled) { "恢复" } else { "禁用" }
            $tag = if ($idx -eq 2) { "（⚠ 影响内网 .local / 打印机发现）" } else { "" }
            Write-Host "  $($i+1)) $action $label$tag"
        }

        # 快捷操作
        Write-Host "  4) 一键禁用推荐项 (前两项，保留组播)"
        Write-Host "  5) 全部恢复默认"
        Write-Host "  6) 检测 DNS 泄漏"
        Write-Host "  0) 返回主菜单"

        $choice = Read-Host "请选择 [0-6]"
        switch ($choice) {
            "0" { return }
            "1" {
                $reg = $SMART_DNS_REGS[0]
                $enable = -not $status[0].IsDisabled
                Toggle-SmartDNSSingle $reg.Key $reg.Name $reg.Value $enable
            }
            "2" {
                $reg = $SMART_DNS_REGS[1]
                $enable = -not $status[1].IsDisabled
                Toggle-SmartDNSSingle $reg.Key $reg.Name $reg.Value $enable
            }
            "3" {
                $reg = $SMART_DNS_REGS[2]
                $enable = -not $status[2].IsDisabled
                Toggle-SmartDNSSingle $reg.Key $reg.Name $reg.Value $enable
            }
            "4" {
                for ($i = 0; $i -lt 2; $i++) {
                    if (-not $status[$i].IsDisabled) {
                        $reg = $SMART_DNS_REGS[$i]
                        Toggle-SmartDNSSingle $reg.Key $reg.Name $reg.Value $true
                    }
                }
                ok "推荐项已禁用 (前两项)"
            }
            "5" { Restore-SmartDNS }
            "6" { Test-DNSLeak }
            default { warn "无效选项" }
        }
    }
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
    Write-Host "  7) 禁用 Windows 智能DNS"
    Write-Host "  0) 退出"
    Write-Host ""
}

# ---- 主函数 ----

function Main {
    $rc = Get-ProfilePath
    info "配置文件: $rc"

    while ($true) {
        Show-Menu
        $choice = Read-Host "请选择 [0-7]"

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
            "7" {
                Show-SmartDNSMenu
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