<#
.SYNOPSIS
Clears Claude Desktop or Claude Code login/session state for a Windows user.

.DESCRIPTION
By default this removes only per-user Claude Desktop/Electron app data such as
cookies, local storage, IndexedDB, cache, and Crashpad state. Use -Target Code
to remove only Claude Code CLI state such as .claude and .claude.json.

It does not uninstall Claude and does not delete files outside the selected
Windows user profile.

Run with -WhatIf first if you want to preview what will be removed.

.EXAMPLE
.\clear_claude_login_state.ps1

.EXAMPLE
.\clear_claude_login_state.ps1 -Target Desktop -UserProfile $env:USERPROFILE

.EXAMPLE
.\clear_claude_login_state.ps1 -Target Code -UserProfile $env:USERPROFILE
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [ValidateSet('Desktop', 'Code')]
    [string]$Target = 'Desktop',

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

function Test-ClaudeDesktopProcess {
    param([Parameter(Mandatory = $true)]$Process)

    $path = [string]$Process.ExecutablePath
    $commandLine = [string]$Process.CommandLine

    $mentionsClaude = (
        $path -match '(?i)(\\Claude_|\\Claude\\|\\Anthropic)' -or
        $commandLine -match '(?i)(Claude|Anthropic)'
    )

    if (-not $mentionsClaude) {
        return $false
    }

    return (
        $commandLine -match '--user-data-dir=(?:"[^"]*\\Claude"|[^\s]*\\Claude)' -or
        ($commandLine -match 'resources\\app\.asar' -and $commandLine -match '(?i)Claude') -or
        $path -match '\\WindowsApps\\Claude_' -or
        $path -match '\\AppData\\Local\\Programs\\Claude\\' -or
        $path -match '\\Program Files\\Claude\\'
    )
}

function Test-ClaudeCodeProcess {
    param([Parameter(Mandatory = $true)]$Process)

    if (Test-ClaudeDesktopProcess -Process $Process) {
        return $false
    }

    $name = [string]$Process.Name
    $commandLine = [string]$Process.CommandLine

    return (
        $name -match '^(claude|node)\.exe$' -and
        $commandLine -match '(?i)(claude-code|@anthropic-ai|\\claude(\.cmd)?|/claude)'
    )
}

if (-not (Test-Path -LiteralPath $UserProfile)) {
    throw "User profile does not exist: $UserProfile"
}

$UserProfile = Resolve-FullPath $UserProfile
$targets = [System.Collections.Generic.List[string]]::new()

if ($IncludeClaudeCli) {
    if ($PSBoundParameters.ContainsKey('Target') -and $Target -ne 'Code') {
        throw 'Do not combine -IncludeClaudeCli with -Target Desktop. Use -Target Code to clean Claude Code only.'
    }

    Write-Warning '-IncludeClaudeCli is deprecated. Use -Target Code instead.'
    $Target = 'Code'
}

if ($Target -eq 'Code' -and $IncludeBrowserIndexedDb) {
    Write-Warning '-IncludeBrowserIndexedDb applies only to -Target Desktop and will be ignored.'
}

Write-Host "Target user profile: $UserProfile"
Write-Host "Cleanup target: $Target"
Write-Host "Finding Claude data directories..."

$allProcesses = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
$claudeProcesses = @()

if ($Target -eq 'Desktop') {
    # Capture the live Electron user-data-dir before stopping processes.
    $claudeProcesses = @($allProcesses | Where-Object { Test-ClaudeDesktopProcess -Process $_ })

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
            Where-Object { $_.Name -match '^(Claude_|AnthropicClaude|com\.anthropic\.claude)' } |
            ForEach-Object { Add-Target -Targets $targets -Path $_.FullName }
    }

    # If the script is running as the same user, AppX can reveal the package family name.
    try {
        Get-AppxPackage -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Name -match '^(Claude|AnthropicClaude)$' -or
                $_.PackageFamilyName -match '^(Claude_|AnthropicClaude|com\.anthropic\.claude)' -or
                $_.PackageFullName -match '^(Claude_|AnthropicClaude|com\.anthropic\.claude)'
            } |
            ForEach-Object {
                Add-Target -Targets $targets -Path (Join-Path $packageRoot $_.PackageFamilyName)
            }
    } catch {
        Write-Verbose "Could not query AppX packages: $($_.Exception.Message)"
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
}

if ($Target -eq 'Code') {
    $claudeProcesses = @($allProcesses | Where-Object { Test-ClaudeCodeProcess -Process $_ })

    $codeConfigDir = if ($env:CLAUDE_CONFIG_DIR) {
        [string]$env:CLAUDE_CONFIG_DIR
    } else {
        Join-Path $UserProfile '.claude'
    }

    Add-Target -Targets $targets -Path $codeConfigDir
    Add-Target -Targets $targets -Path (Join-Path $UserProfile '.claude.json')
}

Write-Host "Stopping Claude processes..."

foreach ($process in $claudeProcesses) {
    try {
        if ($PSCmdlet.ShouldProcess("PID $($process.ProcessId)", "Stop Claude $Target process")) {
            Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
        }
    } catch {
        Write-Warning "Could not stop PID $($process.ProcessId): $($_.Exception.Message)"
    }
}

Start-Sleep -Seconds 2

Write-Host "Removing Claude $Target login/session data..."

foreach ($targetPath in $targets) {
    Remove-Target -Path $targetPath
}

Write-Host ''
Write-Host 'Done.'
if ($Target -eq 'Desktop') {
    Write-Host 'Reopen Claude Desktop. If it asks you to sign in, local desktop login state was cleared.'
    Write-Host 'If you sign in and still see account_banned/account on hold, that is server-side account status.'
} else {
    Write-Host 'Run Claude Code again. If it asks you to sign in, local Claude Code login state was cleared.'
    Write-Host 'If it still authenticates, check environment variables such as ANTHROPIC_API_KEY, ANTHROPIC_AUTH_TOKEN, or CLAUDE_CODE_OAUTH_TOKEN.'
}

if ($Target -eq 'Desktop' -and $IncludeBrowserIndexedDb) {
    Write-Host ''
    Write-Host 'Browser note: this script removes named claude.ai IndexedDB/storage folders only.'
    Write-Host 'For cookies, open chrome://settings/content/all, edge://settings/siteData, brave://settings/content/all, or Firefox about:preferences#privacy and delete claude.ai site data.'
}
