<#
.SYNOPSIS
    Windows 终端代理一键配置（纯 PowerShell，无需 Python）
    支持 v2rayN / Clash / sing-box
    适用于 Codex CLI / Claude Code / npm / git
#>

$DEFAULT_HTTP_PORT   = 7897
$DEFAULT_SOCKS5_PORT = 7897
$PORT_SCAN_RADIUS = 10
$PROXY_HOST = "127.0.0.1"
$NO_PROXY = "localhost,127.0.0.1,::1"
$ANTHROPIC_BASE_URL = ""

$CF_TRACE_TARGETS = @(
    @{Name="Claude Web";     URL="https://claude.ai/cdn-cgi/trace"},
    @{Name="Claude Console"; URL="https://console.anthropic.com/cdn-cgi/trace"},
    @{Name="Anthropic API";  URL="https://api.anthropic.com/cdn-cgi/trace"},
    @{Name="ChatGPT Web";    URL="https://chatgpt.com/cdn-cgi/trace"},
    @{Name="OpenAI API";     URL="https://api.openai.com/cdn-cgi/trace"}
)

$PROXY_BLOCK_START = "# >>> proxy-config start <<<"
$PROXY_BLOCK_END   = "# >>> proxy-config end <<<"
$CLAUDE_GEO_BLOCK_START = "# >>> claude-geo start <<<"
$CLAUDE_GEO_BLOCK_END   = "# >>> claude-geo end <<<"

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

function Get-PortScanCandidates($basePort) {
    $basePort = [int]$basePort
    $ports = New-Object System.Collections.Generic.List[int]
    $seen = @{}
    for ($offset = 0; $offset -le $PORT_SCAN_RADIUS; $offset++) {
        foreach ($p in @(($basePort - $offset), ($basePort + $offset))) {
            if ($p -lt 1 -or $p -gt 65535 -or $seen.ContainsKey($p)) { continue }
            $ports.Add([int]$p)
            $seen[$p] = $true
        }
    }
    return $ports
}

function Find-ListeningPortNear($basePort, $label) {
    foreach ($p in (Get-PortScanCandidates $basePort)) {
        if (Check-PortListening $p) {
            info "端口扫描: $label 在 $p 监听（基准 $basePort ±$PORT_SCAN_RADIUS）"
            return [int]$p
        }
    }
    return $null
}

function Detect-ClashPort {
    $configs = @()
    if ($env:APPDATA) {
        $configs += "$env:APPDATA\clash\config.yaml"
        $configs += "$env:APPDATA\Clash for Windows\config.yaml"
        $configs += "$env:APPDATA\clash-verge\config.yaml"
        $configs += "$env:APPDATA\io.github.clash-verge-rev.clash-verge-rev\config.yaml"
        $configs += "$env:APPDATA\mihomo-party\config.yaml"
    }
    $configs += "$env:USERPROFILE\.config\clash\config.yaml"
    $configs += "$env:USERPROFILE\.config\mihomo\config.yaml"

    foreach ($cfg in $configs) {
        if (-not (Test-Path $cfg)) { continue }
        try {
            $content = Get-Content $cfg -Raw -Encoding UTF8
            if ($content -match '(?m)^\s*mixed-port\s*:\s*(\d+)') {
                $port = [int]$Matches[1]
                info "检测到 Clash/Mihomo 混合端口: $port  ($cfg)"
                return @($port, $port)
            }
            if ($content -match '(?m)^\s*port\s*:\s*(\d+)') {
                $port = [int]$Matches[1]
                $socks_port = $port
                if ($content -match '(?m)^\s*socks-port\s*:\s*(\d+)') {
                    $socks_port = [int]$Matches[1]
                }
                info "检测到 Clash/Mihomo HTTP 端口: $port  ($cfg)"
                return @($port, $socks_port)
            }
        } catch {}
    }

    $port = Find-ListeningPortNear $DEFAULT_HTTP_PORT "Clash/Mihomo"
    if ($port) { return @($port, $port) }
    return @($DEFAULT_HTTP_PORT, $DEFAULT_SOCKS5_PORT)
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

    foreach ($base in @(10808, 1080)) {
        $p = Find-ListeningPortNear $base "v2rayN"
        if ($p) { return @($p, $p) }
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
                return @($port, $port)
            }
        } catch {}
    }
    return @($DEFAULT_HTTP_PORT, $DEFAULT_SOCKS5_PORT)
}

function Auto-DetectPorts {
    $candidates = @(
        @{Name="v2rayN";   Ports=(Detect-V2rayNPort)},
        @{Name="Clash";    Ports=(Detect-ClashPort)},
        @{Name="sing-box"; Ports=(Detect-SingBoxPort)}
    )

    foreach ($c in $candidates) {
        $hp = $c.Ports[0]; $sp = $c.Ports[1]
        $found = Find-ListeningPortNear $hp $c.Name
        if ($null -ne $found) {
            $delta = $sp - $hp
            info "自动检测: $($c.Name) 端口 $found 正在监听"
            return @([int]$found, [int]($found + $delta))
        }
    }
    info "未检测到监听端口，使用默认值"
    return @($DEFAULT_HTTP_PORT, $DEFAULT_SOCKS5_PORT)
}

# ---- Shell Profile 配置 ----

function Get-ProfilePath {
    # 直接使用当前 PowerShell 会话的 $PROFILE（PS5 和 pwsh/PS7 路径不同，此处正确对应当前版本）
    if ($PROFILE -and $PROFILE -ne "") { return $PROFILE }
    # 兜底：按版本选择默认路径
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        return "$env:USERPROFILE\Documents\PowerShell\Microsoft.PowerShell_profile.ps1"
    }
    return "$env:USERPROFILE\Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1"
}

function Get-CmdBatPath {
    return "$env:USERPROFILE\.proxy_init.cmd"
}

function Get-ClaudeGeoDir {
    return (Join-Path $env:USERPROFILE ".proxy-setup")
}

function Get-ClaudeGeoLauncherPath {
    return (Join-Path (Get-ClaudeGeoDir) "claude-geo.ps1")
}

function Get-ClaudeGeoCmdPath {
    return (Join-Path (Get-ClaudeGeoDir) "claude-geo.cmd")
}

function Ensure-CmdProcessorKey {
    $key = "HKCU:\Software\Microsoft\Command Processor"
    if (-not (Test-Path $key)) {
        New-Item -Path $key -Force | Out-Null
    }
    return $key
}

function Build-ProxyBlock($http_port, $socks5_port) {
    $proxy_url = "http://${PROXY_HOST}:${http_port}"
    $socks_url = "socks5://${PROXY_HOST}:${socks5_port}"
    $lines = @($PROXY_BLOCK_START)
    $lines += "`$env:HTTP_PROXY  = `"$proxy_url`""
    $lines += "`$env:HTTPS_PROXY = `"$proxy_url`""
    $lines += "`$env:ALL_PROXY   = `"$socks_url`""
    $lines += "`$env:NO_PROXY    = `"$NO_PROXY`""
    $lines += "`$env:http_proxy  = `"$proxy_url`""
    $lines += "`$env:https_proxy = `"$proxy_url`""
    $lines += "`$env:all_proxy   = `"$socks_url`""
    $lines += "`$env:no_proxy    = `"$NO_PROXY`""
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

    Ensure-PowerShellExecutionPolicy
    Setup-CmdAutoRun $http_port $socks5_port
}

function Setup-CmdAutoRun($http_port, $socks5_port) {
    $bat = Get-CmdBatPath
    $proxy_url = "http://${PROXY_HOST}:${http_port}"
    $socks_url = "socks5://${PROXY_HOST}:${socks5_port}"
    $key = Ensure-CmdProcessorKey

    $batContent = "@echo off`r`n"
    $batContent += "rem >>> proxy-config start <<<`r`n"
    $batContent += "set HTTP_PROXY=$proxy_url`r`n"
    $batContent += "set HTTPS_PROXY=$proxy_url`r`n"
    $batContent += "set ALL_PROXY=$socks_url`r`n"
    $batContent += "set NO_PROXY=$NO_PROXY`r`n"
    $batContent += "set http_proxy=$proxy_url`r`n"
    $batContent += "set https_proxy=$proxy_url`r`n"
    $batContent += "set all_proxy=$socks_url`r`n"
    $batContent += "set no_proxy=$NO_PROXY`r`n"
    if ($ANTHROPIC_BASE_URL) {
        $batContent += "set ANTHROPIC_BASE_URL=$ANTHROPIC_BASE_URL`r`n"
    }
    $batContent += "rem >>> proxy-config end <<<`r`n"

    Set-Content -Path $bat -Value $batContent -Encoding ASCII
    ok "已写入 CMD 批处理: $bat"

    try {
        Set-ItemProperty -Path $key -Name "AutoRun" -Value $bat -Force
        ok "CMD AutoRun 注册表已设置"
    } catch {
        warn "CMD AutoRun 注册表设置失败: $_"
    }
}

function Remove-CmdAutoRun {
    $bat = Get-CmdBatPath
    $key = "HKCU:\Software\Microsoft\Command Processor"
    if (Test-Path $bat) {
        Remove-Item $bat -Force
        ok "已删除 $bat"
    }
    if (Test-Path $key) {
        try {
            Remove-ItemProperty -Path $key -Name "AutoRun" -Force -ErrorAction Stop
            ok "CMD AutoRun 注册表已删除"
        } catch {
            try {
                Set-ItemProperty -Path $key -Name "AutoRun" -Value "" -Force
                ok "CMD AutoRun 注册表已清除"
            } catch {}
        }
    }
}

function Build-ClaudeGeoLauncherScript($http_port, $socks5_port) {
    $template = @'
$ProxyHost = "127.0.0.1"
$HttpPort = __HTTP_PORT__
$SocksPort = __SOCKS_PORT__
$NoProxy = if ($env:NO_PROXY) { $env:NO_PROXY } elseif ($env:no_proxy) { $env:no_proxy } else { "localhost,127.0.0.1,::1" }
$IpinfoToken = $env:IPINFO_TOKEN
$ClaudeCommand = "claude"
$PrintOnly = $false
$claudeArgsList = New-Object System.Collections.Generic.List[string]

$rawArgs = @($args)
$i = 0
$passThrough = $false
while ($i -lt $rawArgs.Count) {
    $arg = [string]$rawArgs[$i]
    if (-not $passThrough -and ($arg -eq "--proxy-host" -or $arg -eq "-ProxyHost")) {
        if ($i + 1 -ge $rawArgs.Count) { Write-Error "$arg requires a value"; exit 2 }
        $ProxyHost = [string]$rawArgs[$i + 1]
        $i += 2
        continue
    }
    if (-not $passThrough -and ($arg -eq "--http-port" -or $arg -eq "-HttpPort")) {
        if ($i + 1 -ge $rawArgs.Count) { Write-Error "$arg requires a value"; exit 2 }
        $HttpPort = [int]$rawArgs[$i + 1]
        $i += 2
        continue
    }
    if (-not $passThrough -and ($arg -eq "--socks-port" -or $arg -eq "-SocksPort")) {
        if ($i + 1 -ge $rawArgs.Count) { Write-Error "$arg requires a value"; exit 2 }
        $SocksPort = [int]$rawArgs[$i + 1]
        $i += 2
        continue
    }
    if (-not $passThrough -and ($arg -eq "--claude-command" -or $arg -eq "-ClaudeCommand")) {
        if ($i + 1 -ge $rawArgs.Count) {
            Write-Error "$arg requires a value"
            exit 2
        }
        $ClaudeCommand = [string]$rawArgs[$i + 1]
        $i += 2
        continue
    }
    if (-not $passThrough -and ($arg -eq "--print-only" -or $arg -eq "-PrintOnly")) {
        $PrintOnly = $true
        $i += 1
        continue
    }
    if (-not $passThrough -and $arg -eq "--") {
        $passThrough = $true
        $i += 1
        continue
    }
    $claudeArgsList.Add($arg)
    $i += 1
}
$ClaudeArgs = [string[]]$claudeArgsList.ToArray()

function Get-Value($Object, [string]$Name) {
    if ($null -eq $Object) { return "" }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return "" }
    return [string]$property.Value
}

function Invoke-ProxyJson([string]$Url) {
    if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) {
        return [ordered]@{ ok = $false; error = "curl.exe not found" }
    }
    $proxy = "http://${ProxyHost}:${HttpPort}"
    $args = @("-sS", "--proxy", $proxy, "--connect-timeout", "5", "--max-time", "12", $Url)
    try {
        $output = & curl.exe @args 2>&1
        if ($LASTEXITCODE -ne 0) {
            return [ordered]@{ ok = $false; error = ($output -join "`n") }
        }
        return [ordered]@{ ok = $true; json = (($output -join "`n") | ConvertFrom-Json) }
    } catch {
        return [ordered]@{ ok = $false; error = $_.Exception.Message }
    }
}

function Convert-IpApi($Json) {
    return [ordered]@{
        ok = [bool](Get-Value $Json "ip")
        provider = "ipapi"
        ip = Get-Value $Json "ip"
        countryCode = (Get-Value $Json "country_code").ToUpperInvariant()
        country = Get-Value $Json "country_name"
        region = Get-Value $Json "region"
        city = Get-Value $Json "city"
        timezone = Get-Value $Json "timezone"
        isp = Get-Value $Json "org"
    }
}

function Convert-IpInfo($Json) {
    return [ordered]@{
        ok = [bool](Get-Value $Json "ip")
        provider = "ipinfo"
        ip = Get-Value $Json "ip"
        countryCode = (Get-Value $Json "country").ToUpperInvariant()
        country = ""
        region = Get-Value $Json "region"
        city = Get-Value $Json "city"
        timezone = Get-Value $Json "timezone"
        isp = Get-Value $Json "org"
    }
}

function Convert-IpWhoIs($Json) {
    $connection = $Json.PSObject.Properties["connection"]
    $isp = ""
    if ($null -ne $connection -and $null -ne $connection.Value) {
        $isp = Get-Value $connection.Value "isp"
        if (-not $isp) { $isp = Get-Value $connection.Value "org" }
    }
    return [ordered]@{
        ok = [bool]$Json.success
        provider = "ipwhois"
        ip = Get-Value $Json "ip"
        countryCode = (Get-Value $Json "country_code").ToUpperInvariant()
        country = Get-Value $Json "country"
        region = Get-Value $Json "region"
        city = Get-Value $Json "city"
        timezone = Get-Value $Json "timezone"
        isp = $isp
    }
}

function Get-ExitProfile {
    $providers = @(
        [ordered]@{ name = "ipapi"; url = "https://ipapi.co/json/" },
        [ordered]@{ name = "ipinfo"; url = $(if ($IpinfoToken) { "https://ipinfo.io/json?token=$IpinfoToken" } else { "https://ipinfo.io/json" }) },
        [ordered]@{ name = "ipwhois"; url = "https://ipwho.is/" }
    )
    $errors = @()
    foreach ($provider in $providers) {
        $response = Invoke-ProxyJson $provider.url
        if (-not $response.ok) {
            $errors += "$($provider.name): $($response.error)"
            continue
        }
        if ($provider.name -eq "ipapi") { $profile = Convert-IpApi $response.json }
        elseif ($provider.name -eq "ipinfo") { $profile = Convert-IpInfo $response.json }
        else { $profile = Convert-IpWhoIs $response.json }
        if ($profile.ok -and $profile.ip -and $profile.countryCode -and $profile.timezone) {
            return $profile
        }
        $errors += "$($provider.name): incomplete profile"
    }
    return [ordered]@{ ok = $false; error = ($errors -join "; ") }
}

function Get-LocaleBundle([string]$CountryCode, [string]$TimeZone) {
    $code = $CountryCode.ToUpperInvariant()
    $language = switch ($code) {
        "CN" { "zh-CN"; break }
        "HK" { "zh-HK"; break }
        "MO" { "zh-MO"; break }
        "TW" { "zh-TW"; break }
        "US" { "en-US"; break }
        "GB" { "en-GB"; break }
        "CA" { "en-CA"; break }
        "AU" { "en-AU"; break }
        "NZ" { "en-NZ"; break }
        "SG" { "en-SG"; break }
        "JP" { "ja-JP"; break }
        "KR" { "ko-KR"; break }
        "DE" { "de-DE"; break }
        "FR" { "fr-FR"; break }
        "IT" { "it-IT"; break }
        "ES" { "es-ES"; break }
        "NL" { "nl-NL"; break }
        "BR" { "pt-BR"; break }
        "PT" { "pt-PT"; break }
        "RU" { "ru-RU"; break }
        "IN" { "en-IN"; break }
        "ID" { "id-ID"; break }
        "TH" { "th-TH"; break }
        "VN" { "vi-VN"; break }
        "PH" { "en-PH"; break }
        "MY" { "ms-MY"; break }
        default { "en-US"; break }
    }
    $base = ($language -split "-")[0]
    return [ordered]@{
        language = $language
        posixLocale = "$($language.Replace("-", "_")).UTF-8"
        acceptLanguage = "$language,$base;q=0.9"
        timezone = $TimeZone
    }
}

$httpProxy = "http://${ProxyHost}:${HttpPort}"
$socksProxy = "socks5://${ProxyHost}:${SocksPort}"
$profile = Get-ExitProfile
if (-not $profile.ok) {
    Write-Error "无法检测代理出口画像: $($profile.error)"
    exit 1
}
$bundle = Get-LocaleBundle $profile.countryCode $profile.timezone
$envValues = @(
    [pscustomobject]@{ Name = "HTTP_PROXY"; Value = $httpProxy },
    [pscustomobject]@{ Name = "HTTPS_PROXY"; Value = $httpProxy },
    [pscustomobject]@{ Name = "ALL_PROXY"; Value = $socksProxy },
    [pscustomobject]@{ Name = "NO_PROXY"; Value = $NoProxy },
    [pscustomobject]@{ Name = "http_proxy"; Value = $httpProxy },
    [pscustomobject]@{ Name = "https_proxy"; Value = $httpProxy },
    [pscustomobject]@{ Name = "all_proxy"; Value = $socksProxy },
    [pscustomobject]@{ Name = "no_proxy"; Value = $NoProxy },
    [pscustomobject]@{ Name = "TZ"; Value = $bundle.timezone },
    [pscustomobject]@{ Name = "LANG"; Value = $bundle.posixLocale },
    [pscustomobject]@{ Name = "LC_ALL"; Value = $bundle.posixLocale },
    [pscustomobject]@{ Name = "LC_MESSAGES"; Value = $bundle.posixLocale },
    [pscustomobject]@{ Name = "LANGUAGE"; Value = $bundle.language },
    [pscustomobject]@{ Name = "ACCEPT_LANGUAGE"; Value = $bundle.acceptLanguage }
)

Write-Host "Claude Code geo profile:"
Write-Host ("  Exit: {0} {1}/{2}/{3} {4}" -f $profile.ip, $profile.countryCode, $profile.region, $profile.city, $profile.timezone)
Write-Host ("  Locale: {0} ({1})" -f $bundle.language, $bundle.posixLocale)

foreach ($item in $envValues) {
    [Environment]::SetEnvironmentVariable($item.Name, [string]$item.Value, "Process")
}

if ($PrintOnly) {
    $envValues | Format-Table Name, Value -AutoSize
    exit 0
}

$command = Get-Command $ClaudeCommand -ErrorAction SilentlyContinue
if (-not $command) {
    Write-Error "找不到 Claude Code 命令: $ClaudeCommand"
    exit 1
}
& $ClaudeCommand @ClaudeArgs
exit $LASTEXITCODE
'@
    $script = $template -replace "__HTTP_PORT__", [string]$http_port
    return ($script -replace "__SOCKS_PORT__", [string]$socks5_port)
}

function Build-ClaudeGeoCmdScript {
    return @'
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0claude-geo.ps1" %*
exit /b %ERRORLEVEL%
'@
}

function Add-ClaudeGeoDirToUserPath {
    $dir = Get-ClaudeGeoDir
    $current = [Environment]::GetEnvironmentVariable("Path", "User")
    $entries = @()
    if ($current) {
        $entries = @($current -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    $exists = $false
    foreach ($entry in $entries) {
        if ($entry.TrimEnd('\') -ieq $dir.TrimEnd('\')) {
            $exists = $true
            break
        }
    }
    if (-not $exists) {
        $newPath = if ($current) { "$current;$dir" } else { $dir }
        [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
        ok "已加入用户 PATH: $dir"
    } else {
        ok "用户 PATH 已包含: $dir"
    }

    $processEntries = @($env:Path -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $processExists = $false
    foreach ($entry in $processEntries) {
        if ($entry.TrimEnd('\') -ieq $dir.TrimEnd('\')) {
            $processExists = $true
            break
        }
    }
    if (-not $processExists) {
        $env:Path = "$dir;$env:Path"
    }
}

function Remove-ClaudeGeoDirFromUserPath {
    $dir = Get-ClaudeGeoDir
    $current = [Environment]::GetEnvironmentVariable("Path", "User")
    if ($current) {
        $entries = @($current -split ';' | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_) -and $_.TrimEnd('\') -ine $dir.TrimEnd('\')
        })
        $newPath = ($entries -join ';')
        if ($newPath -ne $current) {
            [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
            ok "已从用户 PATH 移除: $dir"
        }
    }
    if ($env:Path) {
        $env:Path = ((@($env:Path -split ';') | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_) -and $_.TrimEnd('\') -ine $dir.TrimEnd('\')
        }) -join ';')
    }
}

function Install-ClaudeGeoLauncher($http_port, $socks5_port) {
    $dir = Get-ClaudeGeoDir
    $launcher = Get-ClaudeGeoLauncherPath
    $cmdLauncher = Get-ClaudeGeoCmdPath
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Set-Content -Path $launcher -Value (Build-ClaudeGeoLauncherScript $http_port $socks5_port) -Encoding UTF8
    ok "已写入 Claude Code 画像启动器: $launcher"
    Set-Content -Path $cmdLauncher -Value (Build-ClaudeGeoCmdScript) -Encoding ASCII
    ok "已写入 CMD 启动器: $cmdLauncher"
    Add-ClaudeGeoDirToUserPath

    $rc = Get-ProfilePath
    $dirRc = Split-Path $rc -Parent
    if (-not (Test-Path $dirRc)) { New-Item -ItemType Directory -Path $dirRc -Force | Out-Null }
    $escapedLauncher = $launcher.Replace("'", "''")
    $block = @(
        $CLAUDE_GEO_BLOCK_START,
        "function claude-geo {",
        "    powershell.exe -NoProfile -ExecutionPolicy Bypass -File '$escapedLauncher' @args",
        "}",
        "Set-Alias cgeo claude-geo",
        $CLAUDE_GEO_BLOCK_END
    ) -join "`r`n"
    $block += "`r`n"

    $startEsc = [regex]::Escape($CLAUDE_GEO_BLOCK_START)
    $endEsc = [regex]::Escape($CLAUDE_GEO_BLOCK_END)
    if (Test-Path $rc) {
        $content = Get-Content $rc -Raw -Encoding UTF8
        if ($content -match $startEsc) {
            $pattern = "(?s)$startEsc.*$endEsc\r?\n?"
            $content = [regex]::Replace($content, $pattern, $block)
            Set-Content -Path $rc -Value $content -Encoding UTF8
        } else {
            Add-Content -Path $rc -Value "`r`n$block" -Encoding UTF8
        }
    } else {
        Set-Content -Path $rc -Value $block -Encoding UTF8
    }

    ok "已安装 PowerShell 命令: claude-geo (别名 cgeo)"
    info "以后从新 PowerShell/CMD 窗口运行 claude-geo，即可按当前代理出口自动匹配 TZ/LANG 后启动 Claude Code"
}

function Remove-ClaudeGeoLauncher {
    $rc = Get-ProfilePath
    $startEsc = [regex]::Escape($CLAUDE_GEO_BLOCK_START)
    $endEsc = [regex]::Escape($CLAUDE_GEO_BLOCK_END)
    if (Test-Path $rc) {
        $content = Get-Content $rc -Raw -Encoding UTF8
        if ($content -match $startEsc) {
            $pattern = "(?s)$startEsc.*$endEsc\r?\n?"
            Set-Content -Path $rc -Value ([regex]::Replace($content, $pattern, "")) -Encoding UTF8
            ok "已从 $rc 移除 claude-geo 命令"
        }
    }

    $launcher = Get-ClaudeGeoLauncherPath
    if (Test-Path $launcher) {
        Remove-Item $launcher -Force
        ok "已删除 $launcher"
    }
    $cmdLauncher = Get-ClaudeGeoCmdPath
    if (Test-Path $cmdLauncher) {
        Remove-Item $cmdLauncher -Force
        ok "已删除 $cmdLauncher"
    }
    Remove-ClaudeGeoDirFromUserPath
}

function Ensure-PowerShellExecutionPolicy {
    try {
        $machinePolicy = Get-ExecutionPolicy -Scope MachinePolicy -ErrorAction SilentlyContinue
        $userPolicy = Get-ExecutionPolicy -Scope UserPolicy -ErrorAction SilentlyContinue

        if ($machinePolicy -and $machinePolicy -ne "Undefined") {
            warn "PowerShell 执行策略受 MachinePolicy 管理 ($machinePolicy)，无法自动修改"
            return
        }
        if ($userPolicy -and $userPolicy -ne "Undefined") {
            warn "PowerShell 执行策略受 UserPolicy 管理 ($userPolicy)，无法自动修改"
            return
        }

        $current = Get-ExecutionPolicy -Scope CurrentUser -ErrorAction SilentlyContinue
        if ($current -in @("RemoteSigned", "Unrestricted", "Bypass")) {
            ok "PowerShell 执行策略: CurrentUser $current"
            return
        }

        Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force -ErrorAction Stop
        ok "PowerShell 执行策略已设置: CurrentUser RemoteSigned"
    } catch {
        warn "PowerShell 执行策略设置失败: $_"
    }
}

function Get-NpmCommand {
    foreach ($name in @("npm.cmd", "npm.exe", "npm")) {
        $cmd = @(Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($cmd.Count -gt 0 -and $cmd[0].Source) { return [string]$cmd[0].Source }
    }
    return $null
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
    Remove-ClaudeGeoLauncher

    $npm = Get-NpmCommand
    if ($npm) {
        & $npm config delete proxy 2>$null
        & $npm config delete https-proxy 2>$null
        ok "npm 代理已清除"
    }

    if (Get-Command git -ErrorAction SilentlyContinue) {
        git config --global --unset http.proxy 2>$null
        git config --global --unset https.proxy 2>$null
        ok "git 代理已清除"
    }

    $pip = Get-PipCommand
    if ($pip) {
        & $pip config unset global.proxy 2>$null
        ok "pip 代理已清除"
    }
}

# ---- npm / git 配置 ----

function Configure-Npm($http_port) {
    $npm = Get-NpmCommand
    if (-not $npm) {
        warn "未找到 npm，跳过"
        return
    }
    $url = "http://${PROXY_HOST}:${http_port}"
    & $npm config set proxy $url 2>$null
    & $npm config set https-proxy $url 2>$null
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

function Get-PipCommand {
    foreach ($name in @("pip3.exe", "pip.exe", "pip3", "pip")) {
        $cmd = @(Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($cmd.Count -gt 0 -and $cmd[0].Source) { return [string]$cmd[0].Source }
    }
    return $null
}

function Configure-Pip($http_port) {
    $pip = Get-PipCommand
    if (-not $pip) {
        warn "未找到 pip，跳过"
        return
    }
    $url = "http://${PROXY_HOST}:${http_port}"
    & $pip config set global.proxy $url 2>$null
    ok "pip 代理已设置: $url"
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

function Get-CfTrace($http_port, $url) {
    $proxy = "http://${PROXY_HOST}:${http_port}"
    try {
        return curl.exe -s --proxy $proxy --connect-timeout 8 --max-time 12 $url 2>&1
    } catch {
        return ""
    }
}

function Parse-CfTrace($output) {
    $trace = @{}
    if (-not $output) { return $trace }
    foreach ($line in ($output -split "`r?`n")) {
        if ($line -match "=") {
            $parts = $line -split "=", 2
            $trace[$parts[0].Trim()] = $parts[1].Trim()
        }
    }
    return $trace
}

function Test-CfTraceExitIPs($http_port, [bool]$ShowRaw = $true) {
    bold "  出口 IP 检测（通过 Cloudflare trace）:"
    foreach ($target in $CF_TRACE_TARGETS) {
        $output = Get-CfTrace $http_port $target.URL
        if (-not $output -or $output -notmatch "=") {
            warn "  $($target.Name): 无法访问 $($target.URL)"
            continue
        }

        $trace = Parse-CfTrace $output
        $ip = $trace["ip"]
        $loc = $trace["loc"]
        $colo = $trace["colo"]
        $warp = $trace["warp"]

        if ($ip) {
            $parts = @("$($target.Name) 出口 IP: $ip")
            if ($loc) { $parts += "地区: $loc" }
            if ($colo) { $parts += "接入: $colo" }
            if ($warp -and $warp -ne "off") { $parts += "WARP: $warp" }
            ok ($parts -join " | ")
        } else {
            warn "  $($target.Name): trace 返回异常"
        }

        if ($ShowRaw) {
            Write-Host ""
            Write-Host "  --- $($target.Name) trace 原始输出 ---"
            foreach ($line in ($output -split "`r?`n")) {
                Write-Host "  $line"
            }
            Write-Host "  $( '-' * 52 )"
        }
    }
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
            $tagMap = @{"200"="OK"; "401"="连通"; "403"="连通"; "405"="连通"; "421"="连通"; "404"="连通"}
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

    Write-Host "  $( '-' * 45 )"
    Test-CfTraceExitIPs $http_port $false
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

function Clear-CurrentEnv {
    $vars = @(
        "http_proxy", "https_proxy", "all_proxy",
        "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY",
        "no_proxy", "NO_PROXY", "ANTHROPIC_BASE_URL"
    )

    foreach ($v in $vars) {
        [Environment]::SetEnvironmentVariable($v, $null, "Process")
        Remove-Item "Env:\$v" -ErrorAction SilentlyContinue
    }
    ok "当前 PowerShell 会话代理环境变量已清空（不修改配置文件）"
}

# ---- 环境变量生效 ----

function Set-EnvCurrentSession($http_port, $socks5_port) {
    $proxy_url = "http://${PROXY_HOST}:${http_port}"
    $socks_url = "socks5://${PROXY_HOST}:${socks5_port}"
    [Environment]::SetEnvironmentVariable("HTTP_PROXY",   $proxy_url, "Process")
    [Environment]::SetEnvironmentVariable("HTTPS_PROXY",  $proxy_url, "Process")
    [Environment]::SetEnvironmentVariable("ALL_PROXY",    $socks_url, "Process")
    [Environment]::SetEnvironmentVariable("NO_PROXY",     $NO_PROXY, "Process")
    [Environment]::SetEnvironmentVariable("http_proxy",   $proxy_url, "Process")
    [Environment]::SetEnvironmentVariable("https_proxy",  $proxy_url, "Process")
    [Environment]::SetEnvironmentVariable("all_proxy",    $socks_url, "Process")
    [Environment]::SetEnvironmentVariable("no_proxy",     $NO_PROXY, "Process")
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
        检测 DNS 泄漏风险 — 分项风险画像法
    #>
    bold ""
    bold "  正在检测 DNS 泄漏风险..."
    Write-Host "  $( '-' * 55 )"

    $risk = 0.0
    $uncertain = 0.0

    function Parse-NSLookupIPs($output) {
        $ips = @()
        $inAnswer = $false
        foreach ($line in $output) {
            # 兼容中文 Windows 本地化：Server/服务器
            if ($line -match "^(?:Server|服务器):" -or $line -match "DNS request timed out") { continue }
            # 兼容中文 Windows 本地化：Name/名称
            if ($line -match "^(?:Name|名称):") { $inAnswer = $true; continue }
            if ($inAnswer) {
                if ($line -match "Addresses?:\s+(.+)$") {
                    $parts = $Matches[1] -split ",\s*"
                    foreach ($p in $parts) {
                        if ($p.Trim() -notmatch "^127\.") { $ips += $p.Trim() }
                    }
                } elseif ($line -match "Address:\s+(\S+)") {
                    if ($Matches[1] -notmatch "^127\.") { $ips += $Matches[1] }
                } elseif ($line -match "^\s+([\da-fA-F:.]+)\s*$") {
                    # 多地址续行：后续 IP 无标签
                    if ($Matches[1] -notmatch "^127\.") { $ips += $Matches[1] }
                }
            }
        }
        return $ips
    }

    function Resolve-DNS($domain, $server, $label) {
        try {
            if ($server) {
                $out = & nslookup $domain $server 2>&1
            } else {
                $out = & nslookup $domain 2>&1
            }
            $ips = Parse-NSLookupIPs $out
            if ($ips.Count -gt 0) {
                info "  $($label.PadRight(12)) -> $(($ips[0..([Math]::Min(3, $ips.Count-1))] -join ', '))$(' ...' * ($ips.Count -gt 4))"
            } else {
                info "  $($label.PadRight(12)) -> 无解析结果"
            }
            return $ips
        } catch {
            info "  $($label.PadRight(12)) -> 超时/不可达"
            return @()
        }
    }

    function Test-PrivateOrLocalIP($value) {
        try {
            $addr = [System.Net.IPAddress]::Parse($value)
            $bytes = $addr.GetAddressBytes()
            if ($addr.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
                return ($bytes[0] -eq 10) -or
                    ($bytes[0] -eq 127) -or
                    ($bytes[0] -eq 169 -and $bytes[1] -eq 254) -or
                    ($bytes[0] -eq 172 -and $bytes[1] -ge 16 -and $bytes[1] -le 31) -or
                    ($bytes[0] -eq 192 -and $bytes[1] -eq 168)
            }
            if ($addr.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetworkV6) {
                return $addr.IsIPv6LinkLocal -or $addr.IsIPv6SiteLocal -or $addr.Equals([System.Net.IPAddress]::IPv6Loopback)
            }
        } catch {}
        return $false
    }

    function Get-DNSServerLabel($server) {
        $known = @{
            "223.5.5.5" = "AliDNS(CN)"
            "223.6.6.6" = "AliDNS(CN)"
            "119.29.29.29" = "DNSPod(CN)"
            "180.76.76.76" = "BaiduDNS(CN)"
            "114.114.114.114" = "114DNS(CN)"
            "1.1.1.1" = "Cloudflare"
            "1.0.0.1" = "Cloudflare"
            "8.8.8.8" = "Google"
            "8.8.4.4" = "Google"
            "9.9.9.9" = "Quad9"
            "208.67.222.222" = "OpenDNS"
        }
        if ($known.ContainsKey($server)) { return $known[$server] }
        if (Test-PrivateOrLocalIP $server) { return "private/local" }
        return "public/unknown"
    }

    info "Windows DNS 策略状态:"
    $smartStatus = Check-SmartDNSStatus
    foreach ($item in $smartStatus) {
        $name = $item.Desc
        $currentText = if ($item.Current -eq -1) { "未设置" } else { "$($item.Current)" }
        if ($item.IsDisabled) {
            ok "  $name`: 已按推荐禁用 ($currentText)"
        } elseif ($name -match "mDNS|LLMNR") {
            info "  $name`: 未禁用 ($currentText) — 可选项，保留局域网发现时可忽略"
            $uncertain += 0.5
        } else {
            warn "  $name`: 未禁用 ($currentText) — 可能向多个网卡并行发起 DNS 查询"
            $risk += 1
        }
    }

    Write-Host ""
    info "系统 DNS 服务器:"
    $dnsServers = @()
    try {
        $dnsServers = Get-DnsClientServerAddress -AddressFamily IPv4,IPv6 -ErrorAction Stop |
            Where-Object { $_.ServerAddresses.Count -gt 0 } |
            ForEach-Object { $_.ServerAddresses } |
            Select-Object -Unique
    } catch {}
    if ($dnsServers.Count -gt 0) {
        foreach ($server in $dnsServers) {
            $label = Get-DNSServerLabel $server
            if ($label -like "*(CN)") {
                warn ("  {0,-39} {1} — 代理场景下泄漏风险较高" -f $server, $label)
                $risk += 1
            } elseif ($label -in @("Cloudflare","Google","Quad9","OpenDNS","public/unknown")) {
                warn ("  {0,-39} {1} — 系统会直连公网 DNS" -f $server, $label)
                $risk += 0.5
            } else {
                info ("  {0,-39} {1}" -f $server, $label)
            }
        }
    } else {
        warn "  未能读取系统 DNS 服务器"
        $uncertain += 1
    }

    Write-Host ""
    $directDomain = "cloudflare.com"
    info "直连公网 DNS 探测 ($directDomain) ..."
    $directResults = @{}
    foreach ($pair in @(
        @("Cloudflare", "1.1.1.1"),
        @("Google DNS", "8.8.8.8"),
        @("Quad9", "9.9.9.9"),
        @("AliDNS(CN)", "223.5.5.5")
    )) {
        $directResults[$pair[0]] = @(Resolve-DNS $directDomain $pair[1] $pair[0])
    }
    $reachablePublic = @($directResults.Keys | Where-Object { $directResults[$_].Count -gt 0 })
    if ($reachablePublic.Count -gt 0) {
        warn "系统可直连公网 DNS: $($reachablePublic -join ', ')"
        info "  说明: HTTP_PROXY/HTTPS_PROXY 不会接管系统 DNS；需要 TUN、系统级代理或应用使用远程 DNS。"
        $risk += 1
    } else {
        ok "直连公网 DNS 未返回结果 — 当前网络可能拦截了直接 DNS 查询"
    }

    Write-Host ""
    $compareDomain = "google.com"
    info "CDN 解析辅助对比 ($compareDomain) ..."
    $sys_ips = @(Resolve-DNS $compareDomain "" "系统 DNS")
    $cf_ips = @(Resolve-DNS $compareDomain "1.1.1.1" "Cloudflare")
    $gg_ips = @(Resolve-DNS $compareDomain "8.8.8.8" "Google DNS")
    $ali_ips = @(Resolve-DNS $compareDomain "223.5.5.5" "AliDNS(CN)")
    $foreign_ips = (@($cf_ips) + @($gg_ips)) | Where-Object { $_ } | Select-Object -Unique
    $china_ips = @($ali_ips) | Where-Object { $_ }
    $sys_vs_foreign = ($sys_ips | Where-Object { $foreign_ips -contains $_ }).Count
    $sys_vs_china = ($sys_ips | Where-Object { $china_ips -contains $_ }).Count
    info "  系统 DNS 与境外参考重合: $sys_vs_foreign"
    info "  系统 DNS 与国内参考重合: $sys_vs_china"
    if ($sys_ips.Count -gt 0 -and $sys_vs_china -gt 0 -and $sys_vs_foreign -eq 0) {
        warn "  辅助判断: 系统 DNS 更像本地/国内解析结果"
        $risk += 1
    } elseif ($sys_ips.Count -gt 0 -and $sys_vs_foreign -gt 0 -and $sys_vs_china -eq 0) {
        ok "  辅助判断: 系统 DNS 更像境外解析结果"
    } elseif ($sys_ips.Count -gt 0) {
        info "  辅助判断: 解析结果混合或独立，仅作参考"
        $uncertain += 0.5
    } else {
        info "  系统 DNS 无解析结果，可能被拦截或网络环境特殊"
        $uncertain += 0.5
    }

    Write-Host ""
    $ports = Auto-DetectPorts
    $httpPort = $ports[0]
    $socksPort = $ports[1]
    info "代理域名访问检测 ($httpPort / $socksPort) ..."
    $trace = Parse-CfTrace (Get-CfTrace $httpPort "https://cloudflare.com/cdn-cgi/trace")
    if ($trace["ip"]) {
        ok "代理可按域名访问 Cloudflare trace"
    } else {
        warn "代理按域名访问失败 — 代理端口或节点 DNS 可能异常"
        $risk += 1
    }

    Write-Host ""
    Write-Host "  $( '-' * 55 )"
    if ($risk -eq 0) {
        ok "未发现明确 DNS 泄漏风险"
    } elseif ($risk -le 2) {
        warn "发现 DNS 泄漏风险信号: $risk 项，建议按提示复核"
    } else {
        warn "DNS 泄漏风险较高: $risk 项，建议启用 TUN/系统代理并配置远程 DNS"
    }
    if ($uncertain -gt 0) {
        info "另有 $uncertain 项无法明确判断。CLI 检测不能替代浏览器 DNS leak test。"
    }
    info "手动验证网站:"
    info "  • https://dnsleaktest.com   — DNS 泄漏检测"
    info "  • https://ipleak.net        — 全量泄漏检测 (IP/WebRTC/DNS)"
    info "  • https://browserleaks.com/dns — 详细 DNS 请求分析"
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
    Write-Host "  8) 检测出口 IP (Claude + OpenAI cf-trace)"
    Write-Host "  9) 清空当前会话环境变量"
    Write-Host "  10) 安装/更新 Claude Code 画像一致启动器 (claude-geo)"
    Write-Host "  0) 退出"
    Write-Host ""
}

# ---- 主函数 ----

function Main {
    $rc = Get-ProfilePath
    info "配置文件: $rc"

    $running = $true
    while ($running) {
        Show-Menu
        $choice = Read-Host "请选择 [0-10]"

        switch ($choice) {
            "0" { Write-Host "退出"; $running = $false; break }
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
                Configure-Pip $hp

                $cfg_git = Read-Host "  是否同时配置 git 代理？[y/N]"
                if ($cfg_git -eq "y") { Configure-Git $hp }

                Test-ProxyConnectivity $hp
                Set-EnvCurrentSession $hp $sp
                Install-ClaudeGeoLauncher $hp $sp
                Show-CurrentConfig

                Write-Host ""
                bold "=== 配置完成 ==="
                bold "  请重新打开 CMD / PowerShell 窗口使代理生效。"
                Write-Host "  PowerShell 当前窗口可运行: . `$PROFILE"
                Write-Host "  CMD 已配置 AutoRun，新窗口自动加载"
                Write-Host "  Claude Code 画像一致启动: claude-geo"
            }
            "2" {
                $h = Read-Host "  输入 HTTP 代理端口 [默认 $DEFAULT_HTTP_PORT]"
                if ([string]::IsNullOrWhiteSpace($h)) { $hp = $DEFAULT_HTTP_PORT } else { $hp = [int]$h }
                $ds = $hp
                $s = Read-Host "  输入 SOCKS5 代理端口 [默认 $ds]"
                if ([string]::IsNullOrWhiteSpace($s)) { $sp = $ds } else { $sp = [int]$s }

                Write-Profile $hp $sp
                Configure-Npm $hp
                Configure-Pip $hp

                $cfg_git = Read-Host "  是否同时配置 git 代理？[y/N]"
                if ($cfg_git -eq "y") { Configure-Git $hp }

                Test-ProxyConnectivity $hp
                Set-EnvCurrentSession $hp $sp
                Install-ClaudeGeoLauncher $hp $sp
                Show-CurrentConfig

                Write-Host ""
                bold "=== 配置完成 ==="
                bold "  请重新打开 CMD / PowerShell 窗口使代理生效。"
                Write-Host "  Claude Code 画像一致启动: claude-geo"
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
            "8" {
                $hp, $null = Auto-DetectPorts
                bold ""
                bold "  正在通过代理端口 $hp 检测出口 IP ..."
                Write-Host "  $( '-' * 52 )"
                Test-CfTraceExitIPs $hp $true
                ok "检测完成"
            }
            "9" {
                Clear-CurrentEnv
                Show-CurrentConfig
            }
            "10" {
                $hp, $sp = Auto-DetectPorts
                info "使用端口: HTTP=$hp, SOCKS5=$sp"
                Install-ClaudeGeoLauncher $hp $sp
            }
            default {
                warn "无效选项，请重新输入"
            }
        }
        Write-Host ""
    }
}

Main
