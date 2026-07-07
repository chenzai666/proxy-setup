<#
.SYNOPSIS
Installs Claude Code on Windows and verifies the `claude` command.

.DESCRIPTION
By default this script uses the official native Windows installer:
https://claude.ai/install.ps1

Set CLAUDE_CODE_INSTALL_METHOD=winget to install with WinGet instead.
Set CLAUDE_CODE_SKIP_INSTALL=1 to only verify and repair PATH.

.EXAMPLE
powershell -NoProfile -ExecutionPolicy Bypass -File .\install_claude_code_windows.ps1

.EXAMPLE
$env:CLAUDE_CODE_INSTALL_METHOD='winget'; powershell -NoProfile -ExecutionPolicy Bypass -File .\install_claude_code_windows.ps1
#>

[CmdletBinding()]
param(
    [ValidateSet('native', 'winget')]
    [string]$Method = $(if ($env:CLAUDE_CODE_INSTALL_METHOD) { $env:CLAUDE_CODE_INSTALL_METHOD } else { 'native' }),

    [string]$InstallUrl = $(if ($env:CLAUDE_CODE_INSTALL_URL) { $env:CLAUDE_CODE_INSTALL_URL } else { 'https://claude.ai/install.ps1' }),

    [switch]$SkipInstall,

    [switch]$NoPathUpdate
)

$ErrorActionPreference = 'Stop'

function Info($Message) { Write-Host "  $Message" -ForegroundColor Cyan }
function Ok($Message)   { Write-Host "  [OK] $Message" -ForegroundColor Green }
function Warn($Message) { Write-Host "  [WARN] $Message" -ForegroundColor Yellow }
function Fail($Message) { Write-Host "  [ERR] $Message" -ForegroundColor Red }

function Test-Truthy($Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    return $Value -match '^(1|true|yes|y)$'
}

function Require-Windows {
    if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
        throw 'This script is for Windows only.'
    }
}

function Test-ProxyEnv {
    return -not [string]::IsNullOrWhiteSpace($env:http_proxy) -or
        -not [string]::IsNullOrWhiteSpace($env:https_proxy) -or
        -not [string]::IsNullOrWhiteSpace($env:HTTP_PROXY) -or
        -not [string]::IsNullOrWhiteSpace($env:HTTPS_PROXY)
}

function Show-ProxyNote {
    if (Test-ProxyEnv) {
        Ok 'Using current proxy environment for installer'
    } else {
        Warn 'No proxy environment found. If download fails, run setup_proxy.ps1 first or set http_proxy/https_proxy.'
    }
}

function Save-Url {
    param(
        [string]$Url,
        [string]$OutFile
    )

    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($curl) {
        & $curl.Source -fsSL $Url -o $OutFile
        if ($LASTEXITCODE -eq 0) { return }
        Warn "curl download failed with exit code $LASTEXITCODE; falling back to Invoke-WebRequest"
    }

    Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $OutFile
}

function Invoke-NativeInstall {
    param([string]$Url)

    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("claude-code-install-{0}.ps1" -f ([guid]::NewGuid().ToString('N')))
    try {
        Info "Downloading Claude Code installer: $Url"
        Save-Url $Url $tmp

        Info 'Running Claude Code installer...'
        $ps = (Get-Command powershell.exe -ErrorAction Stop).Source
        & $ps -NoProfile -ExecutionPolicy Bypass -File $tmp
        if ($LASTEXITCODE -ne 0) {
            throw "Claude Code native installer failed with exit code $LASTEXITCODE"
        }
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-WinGetInstall {
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (-not $winget) {
        throw 'winget.exe was not found. Install App Installer or use CLAUDE_CODE_INSTALL_METHOD=native.'
    }

    Info 'Installing Claude Code with WinGet...'
    & $winget.Source install --id Anthropic.ClaudeCode --exact --source winget --accept-package-agreements --accept-source-agreements --disable-interactivity
    if ($LASTEXITCODE -ne 0) {
        throw "WinGet install failed with exit code $LASTEXITCODE"
    }
}

function Sync-ProcessPath {
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = (@($machinePath, $userPath, $env:Path) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ';'
}

function Add-Candidate {
    param(
        [System.Collections.Generic.List[string]]$List,
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    if (-not $List.Contains($Path)) {
        [void]$List.Add($Path)
    }
}

function Get-NpmCommand {
    foreach ($name in @('npm.cmd', 'npm.exe', 'npm')) {
        $cmd = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd -and $cmd.Source) { return [string]$cmd.Source }
    }
    return $null
}

function Get-ClaudeCandidates {
    $candidates = [System.Collections.Generic.List[string]]::new()

    foreach ($name in @('claude', 'claude.exe', 'claude.cmd')) {
        $commands = @(Get-Command $name -ErrorAction SilentlyContinue)
        foreach ($cmd in $commands) {
            if ($cmd.Source) {
                Add-Candidate $candidates ([string]$cmd.Source)
            } elseif ($cmd.Path) {
                Add-Candidate $candidates ([string]$cmd.Path)
            } elseif ($cmd.Definition -and (Test-Path -LiteralPath $cmd.Definition)) {
                Add-Candidate $candidates ([string]$cmd.Definition)
            }
        }
    }

    $commonDirs = @(
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links'),
        (Join-Path $env:USERPROFILE '.local\bin'),
        (Join-Path $env:APPDATA 'npm'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Claude Code'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Claude')
    )

    foreach ($dir in $commonDirs) {
        foreach ($name in @('claude.exe', 'claude.cmd', 'claude.ps1')) {
            Add-Candidate $candidates (Join-Path $dir $name)
        }
    }

    $npm = Get-NpmCommand
    if ($npm) {
        try {
            $prefix = (& $npm config get prefix 2>$null | Select-Object -First 1)
            if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($prefix)) {
                foreach ($name in @('claude.cmd', 'claude.exe', 'claude.ps1')) {
                    Add-Candidate $candidates (Join-Path $prefix $name)
                }
            }
        } catch {}
    }

    return $candidates
}

function Test-ClaudeCandidate {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return $false }

    try {
        if ($Path.EndsWith('.ps1', [System.StringComparison]::OrdinalIgnoreCase)) {
            $ps = (Get-Command powershell.exe -ErrorAction Stop).Source
            & $ps -NoProfile -ExecutionPolicy Bypass -File $Path --version *> $null
        } else {
            & $Path --version *> $null
        }
        return $LASTEXITCODE -eq 0
    } catch {
        return $false
    }
}

function Find-ClaudeCommand {
    Sync-ProcessPath
    $candidates = Get-ClaudeCandidates
    foreach ($candidate in $candidates) {
        if (Test-ClaudeCandidate $candidate) {
            return $candidate
        }
    }

    Fail 'Could not find a working Claude Code executable.'
    if ($candidates.Count -gt 0) {
        Write-Host '  Tried:'
        foreach ($candidate in $candidates) {
            Write-Host "  - $candidate"
        }
    }
    throw 'Claude Code verification failed.'
}

function Test-PathContains {
    param(
        [string]$PathValue,
        [string]$Dir
    )

    if ([string]::IsNullOrWhiteSpace($PathValue) -or [string]::IsNullOrWhiteSpace($Dir)) { return $false }
    $target = [System.IO.Path]::GetFullPath($Dir).TrimEnd('\')
    foreach ($entry in ($PathValue -split ';')) {
        if ([string]::IsNullOrWhiteSpace($entry)) { continue }
        try {
            $full = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($entry)).TrimEnd('\')
            if ($full.Equals($target, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $true
            }
        } catch {}
    }
    return $false
}

function Ensure-UserPath {
    param([string]$CommandPath)

    if ($NoPathUpdate -or (Test-Truthy $env:CLAUDE_CODE_SKIP_PATH_UPDATE)) {
        Warn 'Skipping PATH update because path update is disabled.'
        return
    }

    $dir = Split-Path -Parent $CommandPath
    if ([string]::IsNullOrWhiteSpace($dir) -or -not (Test-Path -LiteralPath $dir)) { return }

    if (Test-PathContains $env:Path $dir) {
        Ok "PATH already includes $dir"
        return
    }

    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (Test-PathContains $userPath $dir) {
        $env:Path = "$dir;$env:Path"
        Ok "User PATH already includes $dir"
        return
    }

    $newUserPath = if ([string]::IsNullOrWhiteSpace($userPath)) { $dir } else { "$userPath;$dir" }
    [Environment]::SetEnvironmentVariable('Path', $newUserPath, 'User')
    $env:Path = "$dir;$env:Path"
    Ok "Added Claude Code directory to user PATH: $dir"
}

function Show-Version {
    param([string]$CommandPath)

    if ($CommandPath.EndsWith('.ps1', [System.StringComparison]::OrdinalIgnoreCase)) {
        $ps = (Get-Command powershell.exe -ErrorAction Stop).Source
        & $ps -NoProfile -ExecutionPolicy Bypass -File $CommandPath --version
    } else {
        & $CommandPath --version
    }
}

function Main {
    Require-Windows

    $skip = $SkipInstall.IsPresent -or (Test-Truthy $env:CLAUDE_CODE_SKIP_INSTALL)
    Show-ProxyNote

    if ($skip) {
        Warn 'Skipping installer because CLAUDE_CODE_SKIP_INSTALL is set or -SkipInstall was passed.'
    } elseif ($Method -eq 'winget') {
        Invoke-WinGetInstall
    } else {
        Invoke-NativeInstall $InstallUrl
    }

    $claude = Find-ClaudeCommand
    Ensure-UserPath $claude

    Ok "claude command: $claude"
    Show-Version $claude

    Write-Host ''
    Ok 'Claude Code is ready.'
    Info 'If a new terminal cannot find claude, close and reopen PowerShell/CMD.'
}

Main
