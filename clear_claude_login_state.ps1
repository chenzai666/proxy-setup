<#
.SYNOPSIS
Clears Claude Desktop login/session state for a Windows user.

.DESCRIPTION
This removes per-user Claude Desktop/Electron app data such as cookies,
local storage, IndexedDB, cache, and Crashpad state. It does not uninstall
Claude and does not delete files outside the selected Windows user profile.

Run with -WhatIf first if you want to preview what will be removed.

.EXAMPLE
.\clear_claude_login_state.ps1

.EXAMPLE
.\clear_claude_login_state.ps1 -UserProfile $env:USERPROFILE

.EXAMPLE
.\clear_claude_login_state.ps1 -UserProfile $env:USERPROFILE -IncludeClaudeCli
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [string]$UserProfile = $env:USERPROFILE,

    [switch]$IncludeClaudeCli,

    [switch]$IncludeBrowserIndexedDb
)

$ErrorActionPreference = 'Stop'

function Resolve-FullPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    return [System.IO.Path]::GetFullPath(
        [Environment]::ExpandEnvironmentVariables($Path)
    )
}

function Test-PathInsideUserProfile {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = Resolve-FullPath $Path
    $root = (Resolve-FullPath $UserProfile).TrimEnd('\')

    return ($fullPath -eq $root) -or
        $fullPath.StartsWith($root + '\', [System.StringComparison]::OrdinalIgnoreCase)
}

function Add-Target {
    param(
        [System.Collections.Generic.List[string]]$Targets,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return
    }

    $fullPath = Resolve-FullPath $Path

    if (-not (Test-PathInsideUserProfile $fullPath)) {
        Write-Warning "Skipped path outside user profile: $fullPath"
        return
    }

    if (-not $Targets.Contains($fullPath)) {
        $Targets.Add($fullPath) | Out-Null
    }
}

function Remove-Target {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-PathInsideUserProfile $Path)) {
        Write-Warning "Skipped path outside user profile: $Path"
        return
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    if ($PSCmdlet.ShouldProcess($Path, 'Remove recursively')) {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Continue
        Write-Host "Removed: $Path"
    }
}

if (-not (Test-Path -LiteralPath $UserProfile)) {
    throw "User profile does not exist: $UserProfile"
}

$UserProfile = Resolve-FullPath $UserProfile
$targets = [System.Collections.Generic.List[string]]::new()

Write-Host "Target user profile: $UserProfile"
Write-Host "Finding Claude data directories..."

# Capture the live Electron user-data-dir before stopping processes.
$claudeProcesses = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object {
        $_.Name -match '^claude\.exe$' -or
        $_.ExecutablePath -match '\\Claude\.exe$' -or
        $_.CommandLine -match 'Claude\.exe|--user-data-dir=.*Claude'
    })

foreach ($process in $claudeProcesses) {
    if ($process.CommandLine -match '--user-data-dir=(?:"([^"]+)"|([^\s]+))') {
        $dir = if ($Matches[1]) { $Matches[1] } else { $Matches[2] }
        Add-Target -Targets $targets -Path $dir
    }
}

# Known Claude Desktop locations.
Add-Target -Targets $targets -Path (Join-Path $UserProfile 'AppData\Roaming\Claude')
Add-Target -Targets $targets -Path (Join-Path $UserProfile 'AppData\Local\Claude')
Add-Target -Targets $targets -Path (Join-Path $UserProfile 'AppData\Roaming\AnthropicClaude')
Add-Target -Targets $targets -Path (Join-Path $UserProfile 'AppData\Local\AnthropicClaude')

# Microsoft Store / MSIX per-user package data, if present.
$packageRoot = Join-Path $UserProfile 'AppData\Local\Packages'
if (Test-Path -LiteralPath $packageRoot) {
    Get-ChildItem -LiteralPath $packageRoot -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match 'Claude|Anthropic' } |
        ForEach-Object { Add-Target -Targets $targets -Path $_.FullName }
}

# If the script is running as the same user, AppX can reveal the package family name.
try {
    Get-AppxPackage -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -match 'Claude|Anthropic' -or
            $_.PackageFamilyName -match 'Claude|Anthropic' -or
            $_.PackageFullName -match 'Claude|Anthropic'
        } |
        ForEach-Object {
            Add-Target -Targets $targets -Path (Join-Path $packageRoot $_.PackageFamilyName)
        }
} catch {
    Write-Verbose "Could not query AppX packages: $($_.Exception.Message)"
}

if ($IncludeClaudeCli) {
    Add-Target -Targets $targets -Path (Join-Path $UserProfile '.claude')
}

if ($IncludeBrowserIndexedDb) {
    Write-Host "Including named browser IndexedDB folders for claude.ai..."

    $browserRoots = @(
        'AppData\Local\Google\Chrome\User Data',
        'AppData\Local\Microsoft\Edge\User Data',
        'AppData\Local\BraveSoftware\Brave-Browser\User Data',
        'AppData\Local\BraveSoftware\Brave-Browser-Beta\User Data'
    ) | ForEach-Object { Join-Path $UserProfile $_ }

    foreach ($browserRoot in $browserRoots) {
        if (-not (Test-Path -LiteralPath $browserRoot)) {
            continue
        }

        Get-ChildItem -LiteralPath $browserRoot -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Name -eq 'Default' -or
                $_.Name -like 'Profile *' -or
                (Test-Path -LiteralPath (Join-Path $_.FullName 'Preferences'))
            } |
            ForEach-Object {
                Add-Target -Targets $targets -Path (Join-Path $_.FullName 'IndexedDB\https_claude.ai_0.indexeddb.leveldb')
                Add-Target -Targets $targets -Path (Join-Path $_.FullName 'IndexedDB\https_claude.ai_0.indexeddb.blob')
            }
    }

    # Firefox profiles: %APPDATA%\Mozilla\Firefox\Profiles\*
    $ffProfilesRoot = Join-Path $UserProfile 'AppData\Roaming\Mozilla\Firefox\Profiles'
    if (Test-Path -LiteralPath $ffProfilesRoot) {
        Get-ChildItem -LiteralPath $ffProfilesRoot -Directory -Force -ErrorAction SilentlyContinue |
            ForEach-Object {
                Add-Target -Targets $targets -Path (Join-Path $_.FullName 'storage\default\https+++claude.ai')
                Add-Target -Targets $targets -Path (Join-Path $_.FullName 'storage\default\https+++claude.ai^firstPartyDomain=claude.ai')
            }
    }
}

Write-Host "Stopping Claude processes..."

foreach ($process in $claudeProcesses) {
    try {
        if ($PSCmdlet.ShouldProcess("PID $($process.ProcessId)", 'Stop Claude process')) {
            Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
        }
    } catch {
        Write-Warning "Could not stop PID $($process.ProcessId): $($_.Exception.Message)"
    }
}

Start-Sleep -Seconds 2

Write-Host "Removing Claude login/session data..."

foreach ($target in $targets) {
    Remove-Target -Path $target
}

Write-Host ''
Write-Host 'Done.'
Write-Host 'Reopen Claude. If it asks you to sign in, local login state was cleared.'
Write-Host 'If you sign in and still see account_banned/account on hold, that is server-side account status.'

if ($IncludeBrowserIndexedDb) {
    Write-Host ''
    Write-Host 'Browser note: this script removes named claude.ai IndexedDB/storage folders only.'
    Write-Host 'For cookies, open chrome://settings/content/all, edge://settings/siteData, brave://settings/content/all, or Firefox about:preferences#privacy and delete claude.ai site data.'
}
