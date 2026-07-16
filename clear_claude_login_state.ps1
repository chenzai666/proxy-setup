<#
.SYNOPSIS
Clears Claude Desktop or Claude Code login/session state for a Windows user.

.DESCRIPTION
When -Target is not supplied, the script asks whether to clean Claude Desktop
or Claude Code. Desktop mode removes only per-user Claude Desktop/Electron app
data such as cookies, local storage, IndexedDB, cache, and Crashpad state. Code
mode removes only Claude Code credentials and explicit cache data. It preserves
projects, conversation history, settings, extensions, and .claude.json.

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
    [string]$Target = '',

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

    return Test-PathInsideRoot -Path $Path -Root $UserProfile
}

function Test-PathInsideRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Path,

        [Parameter(Mandatory = $true)][string]$Root
    )

    $fullPath = Resolve-FullPath $Path
    $rootPath = (Resolve-FullPath $Root).TrimEnd('\')

    return ($fullPath -eq $rootPath) -or
        $fullPath.StartsWith($rootPath + '\', [System.StringComparison]::OrdinalIgnoreCase)
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
        return $true
    }

    if ($PSCmdlet.ShouldProcess($Path, 'Remove recursively')) {
        try {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
        } catch {
            Write-Warning "Could not completely remove '$Path': $($_.Exception.Message)"
        }

        if (Test-Path -LiteralPath $Path) {
            Write-Warning "Still present after cleanup: $Path"
            return $false
        }

        Write-Host "Removed: $Path"
    }

    return $true
}

function Backup-ClaudeCodeUserData {
    param([Parameter(Mandatory = $true)][string]$CodeConfigDir)

    $protectedNames = @(
        'projects',
        'sessions',
        'backups',
        'commands',
        'agents',
        'skills',
        'plugins',
        'history.jsonl',
        'settings.json',
        'settings.local.json',
        'config.json',
        'CLAUDE.md'
    )
    $sources = [System.Collections.Generic.List[object]]::new()
    foreach ($name in $protectedNames) {
        $source = Join-Path $CodeConfigDir $name
        if (Test-Path -LiteralPath $source) {
            $sources.Add([pscustomobject]@{ Source = $source; Relative = Join-Path '.claude' $name }) | Out-Null
        }
    }

    $rootConfig = Join-Path $UserProfile '.claude.json'
    if (Test-Path -LiteralPath $rootConfig) {
        $sources.Add([pscustomobject]@{ Source = $rootConfig; Relative = '.claude.json' }) | Out-Null
    }

    if ($sources.Count -eq 0) {
        Write-Host 'No Claude Code project history or user configuration needed backup.'
        return $null
    }

    $backupRoot = Join-Path $UserProfile '.claude-cleanup-backups'
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $destination = Join-Path $backupRoot $stamp
    if (Test-Path -LiteralPath $destination) {
        $destination = Join-Path $backupRoot ("$stamp-$([guid]::NewGuid().ToString('N').Substring(0, 8))")
    }

    if ($PSCmdlet.ShouldProcess($destination, 'Back up protected Claude Code data before credential cleanup')) {
        New-Item -ItemType Directory -Path $destination -Force | Out-Null
        foreach ($item in $sources) {
            $target = Join-Path $destination $item.Relative
            $parent = Split-Path -Parent $target
            if (-not (Test-Path -LiteralPath $parent)) {
                New-Item -ItemType Directory -Path $parent -Force | Out-Null
            }
            Copy-Item -LiteralPath $item.Source -Destination $target -Recurse -Force -ErrorAction Stop
        }
        Write-Host "Backup created: $destination"
    } else {
        Write-Host "Would back up protected Claude Code data to: $destination"
    }

    return $destination
}

function Test-ProcessInsideTargets {
    param(
        [Parameter(Mandatory = $true)]$Process,

        [Parameter(Mandatory = $true)][System.Collections.Generic.List[string]]$Targets
    )

    $processPath = [string]$Process.ExecutablePath
    if ([string]::IsNullOrWhiteSpace($processPath)) {
        return $false
    }

    foreach ($targetPath in $Targets) {
        if (Test-PathInsideRoot -Path $processPath -Root $targetPath) {
            return $true
        }
    }

    return $false
}

function Get-TargetDataProcesses {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$Targets)

    if ($Targets.Count -eq 0) {
        return @()
    }

    return @(
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object { Test-ProcessInsideTargets -Process $_ -Targets $Targets }
    )
}

function Stop-CleanupProcesses {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][array]$ClaudeProcesses,

        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$Targets
    )

    $stoppedProcessIds = [System.Collections.Generic.HashSet[int]]::new()
    $candidates = @($ClaudeProcesses)

    # MSIX Claude can leave ChromeNativeHost running from its per-user data folder.
    # Re-scan after stopping known Claude processes so it cannot keep data files locked.
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $candidates += @(Get-TargetDataProcesses -Targets $Targets)
        $stoppedAny = $false

        foreach ($process in $candidates) {
            $processId = [int]$process.ProcessId
            if (-not $stoppedProcessIds.Add($processId)) {
                continue
            }

            try {
                if ($PSCmdlet.ShouldProcess("PID $processId", 'Stop Claude cleanup process')) {
                    Stop-Process -Id $processId -Force -ErrorAction Stop
                    $stoppedAny = $true
                }
            } catch {
                Write-Warning "Could not stop PID ${processId}: $($_.Exception.Message)"
            }
        }

        if (-not $stoppedAny) {
            break
        }

        Start-Sleep -Seconds 1
        $candidates = @()
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

function Select-CleanupTarget {
    while ($true) {
        Write-Host ''
        Write-Host 'Select cleanup target:'
        Write-Host '  1) Claude Desktop only'
        Write-Host '  2) Claude Code only'
        Write-Host ''

        $choice = Read-Host 'Enter 1 or 2'

        switch -Regex ($choice.Trim()) {
            '^(1|desktop|d)$' { return 'Desktop' }
            '^(2|code|c|claude-code)$' { return 'Code' }
            default { Write-Host 'Invalid choice. Please enter 1 or 2.' }
        }
    }
}

if (-not (Test-Path -LiteralPath $UserProfile)) {
    throw "User profile does not exist: $UserProfile"
}

$UserProfile = Resolve-FullPath $UserProfile
$targets = [System.Collections.Generic.List[string]]::new()
$codeConfigDir = $null

if ($IncludeClaudeCli) {
    if ($PSBoundParameters.ContainsKey('Target') -and -not [string]::IsNullOrWhiteSpace($Target) -and $Target -ne 'Code') {
        throw 'Do not combine -IncludeClaudeCli with -Target Desktop. Use -Target Code to clean Claude Code only.'
    }

    Write-Warning '-IncludeClaudeCli is deprecated. Use -Target Code instead.'
    $Target = 'Code'
}

if ([string]::IsNullOrWhiteSpace($Target)) {
    $Target = Select-CleanupTarget
} elseif ($Target -match '^(?i:desktop|d|1)$') {
    $Target = 'Desktop'
} elseif ($Target -match '^(?i:code|c|claude-code|2)$') {
    $Target = 'Code'
} else {
    throw "Invalid -Target '$Target'. Use Desktop or Code."
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

    $codeConfigDir = Resolve-FullPath $codeConfigDir
    if (-not (Test-PathInsideUserProfile $codeConfigDir) -or $codeConfigDir -eq $UserProfile) {
        Write-Warning "Unsafe CLAUDE_CONFIG_DIR was rejected; file cleanup will be skipped: $codeConfigDir"
        $codeConfigDir = $null
    } else {
        Add-Target -Targets $targets -Path (Join-Path $codeConfigDir '.credentials.json')
        Add-Target -Targets $targets -Path (Join-Path $codeConfigDir 'cache')
    }
}

Write-Host "Stopping Claude processes..."

Stop-CleanupProcesses -ClaudeProcesses $claudeProcesses -Targets $targets

if ($Target -eq 'Code' -and $codeConfigDir) {
    Backup-ClaudeCodeUserData -CodeConfigDir $codeConfigDir | Out-Null
    Write-Host 'Preserving Claude Code projects, conversations, settings, extensions, and .claude.json.'
}

if ($Target -eq 'Code') {
    Write-Host 'Removing Claude Code login credentials and cache...'
} else {
    Write-Host 'Removing Claude Desktop local app data and cache...'
}

$failedTargets = [System.Collections.Generic.List[string]]::new()
foreach ($targetPath in $targets) {
    if (-not (Remove-Target -Path $targetPath)) {
        $failedTargets.Add($targetPath) | Out-Null
    }
}

if ($failedTargets.Count -gt 0) {
    Write-Error "Cleanup was incomplete. Close the remaining Claude-related processes and run the script again. Remaining paths: $($failedTargets -join '; ')"
    exit 1
}

if ($WhatIfPreference) {
    Write-Host ''
    Write-Host 'Preview complete. No files or credentials were removed.'
    exit 0
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
