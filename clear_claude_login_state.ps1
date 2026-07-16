<#
.SYNOPSIS
Clears Claude Desktop or Claude Code login/session state for a Windows user.

.DESCRIPTION
When -Target is not supplied, the script asks whether to clean Claude Desktop,
clean Claude Code, or migrate a previous Claude Code backup after signing in to
a new account. Desktop mode removes only per-user Claude Desktop/Electron app
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

.EXAMPLE
.\clear_claude_login_state.ps1 -Target Migrate -UserProfile $env:USERPROFILE -Yes
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [string]$Target = '',

    [string]$UserProfile = $env:USERPROFILE,

    [string]$MigrationSource = '',

    [switch]$Yes,

    [switch]$AllowLoggedOut,

    [switch]$IncludeClaudeCli,

    [switch]$IncludeBrowserIndexedDb
)

$ErrorActionPreference = 'Stop'
$unsafeCleanupTargets = [System.Collections.Generic.List[string]]::new()

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

function Assert-SafeUserProfilePath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Label,
        [switch]$AllowUserProfileRoot
    )
    $fullPath = Resolve-FullPath $Path
    if (-not (Test-PathInsideUserProfile $fullPath) -or (-not $AllowUserProfileRoot -and $fullPath -eq $UserProfile)) {
        throw "$Label must be a non-reparse path inside the selected user profile: $fullPath"
    }
    return $fullPath
}

function Test-PathInsideRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Path,

        [Parameter(Mandatory = $true)][string]$Root
    )

    $fullPath = Resolve-FullPath $Path
    $rootPath = (Resolve-FullPath $Root).TrimEnd('\')
    if ($fullPath -ne $rootPath -and -not $fullPath.StartsWith($rootPath + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }

    # GetFullPath is lexical only. Reject junctions/symlinks so a path that
    # looks user-scoped cannot resolve to data outside the selected profile.
    $currentPath = $rootPath
    if (Test-Path -LiteralPath $currentPath) {
        $rootItem = Get-Item -LiteralPath $currentPath -Force -ErrorAction Stop
        if (($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
    }
    $relativePath = $fullPath.Substring($rootPath.Length).TrimStart('\')
    foreach ($segment in $relativePath.Split('\', [System.StringSplitOptions]::RemoveEmptyEntries)) {
        $currentPath = Join-Path $currentPath $segment
        if (-not (Test-Path -LiteralPath $currentPath)) { break }
        $item = Get-Item -LiteralPath $currentPath -Force -ErrorAction Stop
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
    }
    return $true
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
        Write-Warning "Skipped unsafe or outside-user-profile path: $fullPath"
        if (-not $unsafeCleanupTargets.Contains($fullPath)) { $unsafeCleanupTargets.Add($fullPath) | Out-Null }
        return $false
    }

    if (-not $Targets.Contains($fullPath)) {
        $Targets.Add($fullPath) | Out-Null
    }
    return
}

function Remove-Target {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-PathInsideUserProfile $Path)) {
        Write-Warning "Skipped unsafe or outside-user-profile path: $Path"
        return $false
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
        'session-env',
        'shell-snapshots',
        'todos',
        'plans',
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
            Assert-NoMigrationReparsePoints -Path $source
            $sources.Add([pscustomobject]@{ Source = $source; Relative = Join-Path '.claude' $name }) | Out-Null
        }
    }

    $rootConfig = Join-Path $UserProfile '.claude.json'
    if (Test-Path -LiteralPath $rootConfig) {
        Assert-SafeUserProfilePath -Path $rootConfig -Label 'Claude Code root configuration' | Out-Null
        Assert-NoMigrationReparsePoints -Path $rootConfig
        $sources.Add([pscustomobject]@{ Source = $rootConfig; Relative = '.claude.json' }) | Out-Null
    }

    if ($sources.Count -eq 0) {
        Write-Host 'No Claude Code project history or user configuration needed backup.'
        return $null
    }

    $backupRoot = Assert-SafeUserProfilePath -Path (Join-Path $UserProfile '.claude-cleanup-backups') -Label 'Claude Code cleanup backup directory'
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $destination = Join-Path $backupRoot $stamp
    if (Test-Path -LiteralPath $destination) {
        $destination = Join-Path $backupRoot ("$stamp-$([guid]::NewGuid().ToString('N').Substring(0, 8))")
    }
    $stage = Join-Path $backupRoot (".$stamp.backup-stage-$([guid]::NewGuid().ToString('N'))")

    if ($PSCmdlet.ShouldProcess($destination, 'Back up protected Claude Code data before credential cleanup')) {
        New-Item -ItemType Directory -Path $stage -Force | Out-Null
        try {
            foreach ($item in $sources) {
                $target = Join-Path $stage $item.Relative
                $parent = Split-Path -Parent $target
                if (-not (Test-Path -LiteralPath $parent)) {
                    New-Item -ItemType Directory -Path $parent -Force | Out-Null
                }
                Copy-Item -LiteralPath $item.Source -Destination $target -Recurse -Force -ErrorAction Stop
            }
            [System.IO.File]::WriteAllText((Join-Path $stage 'BACKUP_COMPLETE'), (Get-Date -Format 'o'), [System.Text.UTF8Encoding]::new($false))
            Move-Item -LiteralPath $stage -Destination $destination -ErrorAction Stop
        } catch {
            Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
            throw
        }
        Write-Host "Backup created: $destination"
    } else {
        Write-Host "Would back up protected Claude Code data to: $destination"
    }

    return $destination
}

function Remove-ClaudeCodeRootAccountMetadata {
    $rootConfig = Join-Path $UserProfile '.claude.json'
    if (-not (Test-Path -LiteralPath $rootConfig)) { return $true }
    try {
        Assert-SafeUserProfilePath -Path $rootConfig -Label 'Claude Code root configuration' | Out-Null
    } catch {
        Write-Warning $_.Exception.Message
        return $false
    }
    if (-not $PSCmdlet.ShouldProcess($rootConfig, 'Remove Claude Code account metadata while preserving project configuration')) {
        return $true
    }
    try {
        Add-Type -AssemblyName System.Web.Extensions
        $serializer = [System.Web.Script.Serialization.JavaScriptSerializer]::new()
        $serializer.MaxJsonLength = [int]::MaxValue
        $config = $serializer.DeserializeObject([System.IO.File]::ReadAllText($rootConfig, [System.Text.Encoding]::UTF8))
        if (-not ($config -is [System.Collections.IDictionary])) {
            Write-Warning "Could not remove account metadata because .claude.json is not a JSON object: $rootConfig"
            return $false
        }
        $changed = $false
        foreach ($key in @('oauthAccount', 'userID', 'machineID', 'mcpServers')) {
            if ($config.ContainsKey($key)) {
                $config.Remove($key)
                $changed = $true
            }
        }
        if (-not $changed) { return $true }
        $temporary = "$rootConfig.cleanup-$([guid]::NewGuid().ToString('N')).tmp"
        [System.IO.File]::WriteAllText($temporary, $serializer.Serialize($config), [System.Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporary -Destination $rootConfig -Force
        Write-Host 'Removed account-specific fields from .claude.json while preserving project and user settings.'
        return $true
    } catch {
        if ($temporary -and (Test-Path -LiteralPath $temporary)) {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        }
        Write-Warning "Could not remove account metadata from .claude.json: $($_.Exception.Message)"
        return $false
    }
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

    if ($WhatIfPreference) { return $true }
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

    $remainingProcessIds = @()
    foreach ($processId in $stoppedProcessIds) {
        if (Get-Process -Id $processId -ErrorAction SilentlyContinue) {
            $remainingProcessIds += $processId
        }
    }
    if ($remainingProcessIds.Count -gt 0) {
        Write-Warning "Claude-related processes are still running: $($remainingProcessIds -join ', ')"
        return $false
    }
    return $true
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

function Get-ClaudeCodeConfigDirectory {
    $configDir = if ($env:CLAUDE_CONFIG_DIR) {
        [string]$env:CLAUDE_CONFIG_DIR
    } else {
        Join-Path $UserProfile '.claude'
    }
    $configDir = Resolve-FullPath $configDir
    if (-not (Test-PathInsideUserProfile $configDir) -or $configDir -eq $UserProfile) {
        throw "Unsafe CLAUDE_CONFIG_DIR was rejected: $configDir"
    }
    return $configDir
}

function Find-LatestClaudeCodeCleanupBackup {
    $backupRoot = Join-Path $UserProfile '.claude-cleanup-backups'
    try {
        $backupRoot = Assert-SafeUserProfilePath -Path $backupRoot -Label 'Claude Code cleanup backup directory'
    } catch {
        Write-Warning $_.Exception.Message
        return $null
    }
    if (-not (Test-Path -LiteralPath $backupRoot)) { return $null }
    $candidates = @(
        Get-ChildItem -LiteralPath $backupRoot -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object { -not $_.Name.StartsWith('.') -and (Test-Path -LiteralPath (Join-Path $_.FullName '.claude')) }
    )
    $completed = @($candidates | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'BACKUP_COMPLETE') })
    # A newer incomplete directory can be left behind by a failed copy. Prefer
    # a completed backup even when its timestamp is older than that staging data.
    $selected = @(
        if ($completed.Count -gt 0) {
            $completed | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        } else {
            $candidates | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        }
    )
    return $selected | ForEach-Object { $_.FullName }
}

function Assert-NoMigrationReparsePoints {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Unsafe reparse point was rejected: $Path"
    }
    if ($item.PSIsContainer) {
        foreach ($child in Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop) {
            Assert-NoMigrationReparsePoints -Path $child.FullName
        }
    }
}

function Get-MigrationFileCount {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }
    return @(Get-ChildItem -LiteralPath $Path -File -Recurse -Force -ErrorAction SilentlyContinue).Count
}

function Merge-MigrationItemNoClobber {
    param(
        [Parameter(Mandatory = $true)]$Item,
        [Parameter(Mandatory = $true)][string]$SourceRoot,
        [Parameter(Mandatory = $true)][string]$TargetRoot
    )
    $relative = $Item.FullName.Substring($SourceRoot.Length).TrimStart('\')
    $target = Join-Path $TargetRoot $relative
    $isReparsePoint = ($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
    if ($isReparsePoint) {
        throw "Unsafe reparse point was rejected: $($Item.FullName)"
    }
    if ($Item.PSIsContainer) {
        if (-not (Test-Path -LiteralPath $target)) {
            New-Item -ItemType Directory -Path $target -Force | Out-Null
        }
        foreach ($child in Get-ChildItem -LiteralPath $Item.FullName -Force -ErrorAction Stop) {
            Merge-MigrationItemNoClobber -Item $child -SourceRoot $SourceRoot -TargetRoot $TargetRoot
        }
        return
    }
    if (-not (Test-Path -LiteralPath $target)) {
        $parent = Split-Path -Parent $target
        if (-not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        Copy-Item -LiteralPath $Item.FullName -Destination $target -Force -ErrorAction Stop
    }
}

function Merge-MigrationDirectoryNoClobber {
    param([Parameter(Mandatory = $true)][string]$SourceDir, [Parameter(Mandatory = $true)][string]$TargetDir)
    if (-not (Test-Path -LiteralPath $SourceDir)) { return }
    if (-not (Test-Path -LiteralPath $TargetDir)) {
        New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
    }
    $sourceRoot = (Resolve-FullPath $SourceDir).TrimEnd('\')
    foreach ($item in Get-ChildItem -LiteralPath $SourceDir -Force -ErrorAction Stop) {
        Merge-MigrationItemNoClobber -Item $item -SourceRoot $sourceRoot -TargetRoot $TargetDir
    }
}

function Merge-MigrationHistoryFile {
    param([Parameter(Mandatory = $true)][string]$SourceFile, [Parameter(Mandatory = $true)][string]$TargetFile)
    if (-not (Test-Path -LiteralPath $SourceFile)) { return }
    if (-not (Test-Path -LiteralPath $TargetFile)) {
        Copy-Item -LiteralPath $SourceFile -Destination $TargetFile -Force
        return
    }
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $temporary = "$TargetFile.migration-$([guid]::NewGuid().ToString('N')).tmp"
    $writer = [System.IO.StreamWriter]::new($temporary, $false, [System.Text.UTF8Encoding]::new($false))
    try {
        foreach ($path in @($TargetFile, $SourceFile)) {
            $reader = [System.IO.StreamReader]::new($path, [System.Text.Encoding]::UTF8, $true)
            try {
                while (-not $reader.EndOfStream) {
                    $line = $reader.ReadLine()
                    if (-not [string]::IsNullOrWhiteSpace($line) -and $seen.Add($line)) { $writer.WriteLine($line) }
                }
            } finally { $reader.Dispose() }
        }
    } finally { $writer.Dispose() }
    Move-Item -LiteralPath $temporary -Destination $TargetFile -Force
}

function Merge-MigrationDictionary {
    param([System.Collections.IDictionary]$SourceMap, [System.Collections.IDictionary]$DestinationMap)
    foreach ($key in $SourceMap.Keys) {
        if (-not $DestinationMap.ContainsKey([string]$key)) {
            $DestinationMap[$key] = $SourceMap[$key]
            continue
        }
        $sourceValue = $SourceMap[$key]
        $destinationValue = $DestinationMap[$key]
        if ($sourceValue -is [System.Collections.IDictionary] -and $destinationValue -is [System.Collections.IDictionary]) {
            foreach ($nestedKey in $sourceValue.Keys) {
                if (-not $destinationValue.ContainsKey([string]$nestedKey)) {
                    $destinationValue[$nestedKey] = $sourceValue[$nestedKey]
                }
            }
        }
    }
}

function New-MergedClaudeCodeRootConfig {
    param([Parameter(Mandatory = $true)][string]$SourceFile, [Parameter(Mandatory = $true)][string]$DestinationFile, [Parameter(Mandatory = $true)][string]$OutputFile)
    Add-Type -AssemblyName System.Web.Extensions
    $serializer = [System.Web.Script.Serialization.JavaScriptSerializer]::new()
    $serializer.MaxJsonLength = [int]::MaxValue
    $sourceObject = $serializer.DeserializeObject([System.IO.File]::ReadAllText($SourceFile, [System.Text.Encoding]::UTF8))
    $destinationObject = if (Test-Path -LiteralPath $DestinationFile) {
        $serializer.DeserializeObject([System.IO.File]::ReadAllText($DestinationFile, [System.Text.Encoding]::UTF8))
    } else {
        [System.Collections.Generic.Dictionary[string, object]]::new()
    }
    foreach ($key in @('projects')) {
        if (-not ($sourceObject -is [System.Collections.IDictionary]) -or -not $sourceObject.ContainsKey($key)) { continue }
        $sourceMap = $sourceObject[$key]
        if (-not ($sourceMap -is [System.Collections.IDictionary])) { continue }
        if (-not $destinationObject.ContainsKey($key) -or -not ($destinationObject[$key] -is [System.Collections.IDictionary])) {
            $destinationObject[$key] = [System.Collections.Generic.Dictionary[string, object]]::new()
        }
        Merge-MigrationDictionary -SourceMap $sourceMap -DestinationMap $destinationObject[$key]
    }
    [System.IO.File]::WriteAllText($OutputFile, $serializer.Serialize($destinationObject), [System.Text.UTF8Encoding]::new($false))
}

function Restore-MigrationDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$CurrentPath,
        [Parameter(Mandatory = $true)][string]$RollbackPath
    )
    if (Test-Path -LiteralPath $CurrentPath) {
        Remove-Item -LiteralPath $CurrentPath -Recurse -Force -ErrorAction Stop
    }
    if (Test-Path -LiteralPath $CurrentPath) {
        throw "Cannot remove the partially installed directory: $CurrentPath"
    }
    Move-Item -LiteralPath $RollbackPath -Destination $CurrentPath -ErrorAction Stop
    if (-not (Test-Path -LiteralPath $CurrentPath)) {
        throw "Rollback directory was not restored: $CurrentPath"
    }
}

function Restore-MigrationFile {
    param(
        [Parameter(Mandatory = $true)][string]$CurrentPath,
        [Parameter(Mandatory = $true)][string]$RollbackPath
    )
    if (Test-Path -LiteralPath $CurrentPath) {
        Remove-Item -LiteralPath $CurrentPath -Force -ErrorAction Stop
    }
    if (Test-Path -LiteralPath $CurrentPath) {
        throw "Cannot remove the partially installed file: $CurrentPath"
    }
    Move-Item -LiteralPath $RollbackPath -Destination $CurrentPath -ErrorAction Stop
    if (-not (Test-Path -LiteralPath $CurrentPath)) {
        throw "Rollback file was not restored: $CurrentPath"
    }
}

function Invoke-ClaudeCodeDataMigration {
    param([string]$Source = '')

    $destination = Get-ClaudeCodeConfigDirectory
    $rollbackRoot = Assert-SafeUserProfilePath -Path (Join-Path $UserProfile '.claude-migration-backups') -Label 'Claude Code migration rollback directory'
    if ((Test-PathInsideRoot -Path $rollbackRoot -Root $destination) -or
        (Test-PathInsideRoot -Path $destination -Root $rollbackRoot)) {
        throw 'The Claude Code destination and migration rollback directory cannot contain each other.'
    }
    if ([string]::IsNullOrWhiteSpace($Source)) {
        $Source = Find-LatestClaudeCodeCleanupBackup
        if ([string]::IsNullOrWhiteSpace($Source)) { throw 'No Claude Code cleanup backup was found. Use -MigrationSource to select an old .claude directory or backup directory.' }
        Write-Host "Using latest cleanup backup: $Source"
    }
    if (-not (Test-Path -LiteralPath $Source)) { throw "Migration source does not exist: $Source" }
    # Check the original source before Resolve-Path can hide a junction or
    # symbolic-link entry point behind its target path.
    Assert-NoMigrationReparsePoints -Path $Source
    $sourcePath = (Resolve-Path -LiteralPath $Source).Path
    $sourceConfig = $null
    $sourceRootJson = $null
    if (Test-Path -LiteralPath (Join-Path $sourcePath '.claude')) {
        $sourceConfig = (Resolve-Path -LiteralPath (Join-Path $sourcePath '.claude')).Path
        $candidateRoot = Join-Path $sourcePath '.claude.json'
        if (Test-Path -LiteralPath $candidateRoot) { $sourceRootJson = $candidateRoot }
    } elseif ((Split-Path -Leaf $sourcePath) -eq '.claude' -or (Test-Path -LiteralPath (Join-Path $sourcePath 'projects')) -or (Test-Path -LiteralPath (Join-Path $sourcePath 'history.jsonl'))) {
        $sourceConfig = $sourcePath
        $candidateRoot = Join-Path (Split-Path -Parent $sourcePath) '.claude.json'
        if (Test-Path -LiteralPath $candidateRoot) { $sourceRootJson = $candidateRoot }
    } else {
        throw "Migration source has no recognizable Claude Code data: $sourcePath"
    }
    if ($sourceRootJson) { Assert-NoMigrationReparsePoints -Path $sourceRootJson }
    if ($sourceConfig.Equals($destination, [System.StringComparison]::OrdinalIgnoreCase) -or (Test-PathInsideRoot -Path $sourceConfig -Root $destination)) {
        throw 'Migration source cannot be the current Claude Code directory or a child of it.'
    }

    $mergeDirectories = @('projects', 'sessions', 'commands', 'agents', 'skills', 'plugins', 'backups', 'session-env', 'shell-snapshots', 'todos', 'plans')
    # Settings and MCP configuration can contain tokens, headers, or old router
    # endpoints. Only carry project guidance, never account/runtime configuration.
    $missingOnlyFiles = @('CLAUDE.md')
    $hasImportable = Test-Path -LiteralPath (Join-Path $sourceConfig 'history.jsonl')
    foreach ($name in $mergeDirectories + $missingOnlyFiles) {
        if (Test-Path -LiteralPath (Join-Path $sourceConfig $name)) { $hasImportable = $true; break }
    }
    if (-not $hasImportable) { throw 'Migration source contains no supported Claude Code work data.' }
    foreach ($name in $mergeDirectories + $missingOnlyFiles + @('history.jsonl')) {
        Assert-NoMigrationReparsePoints -Path (Join-Path $sourceConfig $name)
    }

    $currentCredential = Join-Path $destination '.credentials.json'
    $currentLoginFound = (Test-Path -LiteralPath $currentCredential) -or
        -not [string]::IsNullOrWhiteSpace($env:ANTHROPIC_API_KEY) -or
        -not [string]::IsNullOrWhiteSpace($env:ANTHROPIC_AUTH_TOKEN) -or
        -not [string]::IsNullOrWhiteSpace($env:CLAUDE_CODE_OAUTH_TOKEN)
    $sourceProjectFiles = Get-MigrationFileCount (Join-Path $sourceConfig 'projects')
    $destinationProjectFiles = Get-MigrationFileCount (Join-Path $destination 'projects')
    Write-Host ''
    Write-Host 'Claude Code data migration plan'
    Write-Host "  Source: $sourceConfig"
    Write-Host "  Current account: $destination"
    Write-Host "  Rollback backup: $rollbackRoot"
    Write-Host "  Current login: $(if ($currentLoginFound) { 'detected and preserved' } else { 'not detected' })"
    Write-Host 'Source credentials, cache, telemetry, oauthAccount, userID, and machineID are never imported.'
    Write-Host 'Current-account files win on conflict; old data fills only missing files.'
    if (-not $currentLoginFound -and -not $AllowLoggedOut) {
        throw 'No current-account login was detected. Sign in to the new account first, or explicitly use -AllowLoggedOut.'
    }
    if ($WhatIfPreference) {
        Write-Host 'Migration preview complete. No process was stopped and no file was modified.'
        return
    }
    if (-not $Yes) {
        $answer = Read-Host 'Migrate old local data into the current account? [y/N]'
        if ($answer -notmatch '^(?i:y|yes)$') { Write-Host 'Migration cancelled.'; return }
    }

    $processes = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { Test-ClaudeCodeProcess -Process $_ })
    $emptyTargets = [System.Collections.Generic.List[string]]::new()
    if (-not (Stop-CleanupProcesses -ClaudeProcesses $processes -Targets $emptyTargets)) {
        throw 'Claude Code is still running. Close it completely before migrating data.'
    }
    $remainingCodeProcesses = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { Test-ClaudeCodeProcess -Process $_ })
    if ($remainingCodeProcesses.Count -gt 0) {
        throw "Claude Code is still running (PID: $($remainingCodeProcesses.ProcessId -join ', ')). Close it completely before migrating data."
    }
    $destinationParent = Split-Path -Parent $destination
    $destinationName = Split-Path -Leaf $destination
    New-Item -ItemType Directory -Path $destinationParent, $rollbackRoot -Force | Out-Null
    $stage = Join-Path $destinationParent (".$destinationName.migration-stage-$([guid]::NewGuid().ToString('N'))")
    $rootStage = Join-Path $destinationParent (".claude-root-migration-stage-$([guid]::NewGuid().ToString('N')).json")
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $rollbackDir = Join-Path $rollbackRoot $stamp
    if (Test-Path -LiteralPath $rollbackDir) { $rollbackDir = Join-Path $rollbackRoot ("$stamp-$([guid]::NewGuid().ToString('N').Substring(0, 8))") }
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    try {
        if (Test-Path -LiteralPath $destination) {
            Get-ChildItem -LiteralPath $destination -Force -ErrorAction Stop | ForEach-Object {
                Copy-Item -LiteralPath $_.FullName -Destination $stage -Recurse -Force -ErrorAction Stop
            }
        }
        foreach ($name in $mergeDirectories) {
            Merge-MigrationDirectoryNoClobber -SourceDir (Join-Path $sourceConfig $name) -TargetDir (Join-Path $stage $name)
        }
        foreach ($name in $missingOnlyFiles) {
            $sourceFile = Join-Path $sourceConfig $name
            $targetFile = Join-Path $stage $name
            if ((Test-Path -LiteralPath $sourceFile) -and -not (Test-Path -LiteralPath $targetFile)) { Copy-Item -LiteralPath $sourceFile -Destination $targetFile -Force }
        }
        Merge-MigrationHistoryFile -SourceFile (Join-Path $sourceConfig 'history.jsonl') -TargetFile (Join-Path $stage 'history.jsonl')

        $destinationRootJson = Assert-SafeUserProfilePath -Path (Join-Path $UserProfile '.claude.json') -Label 'Claude Code root configuration'
        $rootMergeReady = $false
        if ($sourceRootJson) {
            try {
                New-MergedClaudeCodeRootConfig -SourceFile $sourceRootJson -DestinationFile $destinationRootJson -OutputFile $rootStage
                $rootMergeReady = $true
            } catch {
                Write-Warning ".claude.json project registry merge was skipped: $($_.Exception.Message)"
                Remove-Item -LiteralPath $rootStage -Force -ErrorAction SilentlyContinue
            }
        }

        $stageProjectFiles = Get-MigrationFileCount (Join-Path $stage 'projects')
        $importedProjectFiles = [Math]::Max(0, $stageProjectFiles - $destinationProjectFiles)
        New-Item -ItemType Directory -Path $rollbackDir -Force | Out-Null
        $destinationMoved = $false; $destinationInstalled = $false; $rootMoved = $false; $rootInstalled = $false
        try {
            if (Test-Path -LiteralPath $destination) {
                Move-Item -LiteralPath $destination -Destination (Join-Path $rollbackDir 'current-claude') -ErrorAction Stop
                $destinationMoved = $true
            }
            Move-Item -LiteralPath $stage -Destination $destination -ErrorAction Stop
            $destinationInstalled = $true
            if ($rootMergeReady) {
                if (Test-Path -LiteralPath $destinationRootJson) {
                    Move-Item -LiteralPath $destinationRootJson -Destination (Join-Path $rollbackDir 'current-claude.json') -ErrorAction Stop
                    $rootMoved = $true
                }
                Move-Item -LiteralPath $rootStage -Destination $destinationRootJson -ErrorAction Stop
                $rootInstalled = $true
            }
        } catch {
            $commitError = $_
            $rollbackErrors = [System.Collections.Generic.List[string]]::new()
            $oldDestination = Join-Path $rollbackDir 'current-claude'
            $oldRoot = Join-Path $rollbackDir 'current-claude.json'
            try {
                if ($destinationInstalled -and (Test-Path -LiteralPath $oldDestination)) {
                    Restore-MigrationDirectory -CurrentPath $destination -RollbackPath $oldDestination
                } elseif ($destinationMoved -and (Test-Path -LiteralPath $oldDestination)) {
                    if (Test-Path -LiteralPath $destination) {
                        throw "Destination unexpectedly exists before rollback: $destination"
                    }
                    Move-Item -LiteralPath $oldDestination -Destination $destination -ErrorAction Stop
                    if (-not (Test-Path -LiteralPath $destination)) { throw "Rollback directory was not restored: $destination" }
                }
            } catch {
                $rollbackErrors.Add("Claude directory: $($_.Exception.Message)") | Out-Null
            }
            try {
                if ($rootInstalled -and (Test-Path -LiteralPath $oldRoot)) {
                    Restore-MigrationFile -CurrentPath $destinationRootJson -RollbackPath $oldRoot
                } elseif ($rootMoved -and (Test-Path -LiteralPath $oldRoot)) {
                    if (Test-Path -LiteralPath $destinationRootJson) {
                        throw "Root configuration unexpectedly exists before rollback: $destinationRootJson"
                    }
                    Move-Item -LiteralPath $oldRoot -Destination $destinationRootJson -ErrorAction Stop
                    if (-not (Test-Path -LiteralPath $destinationRootJson)) { throw "Rollback root configuration was not restored: $destinationRootJson" }
                }
            } catch {
                $rollbackErrors.Add("Root configuration: $($_.Exception.Message)") | Out-Null
            }
            if ($rollbackErrors.Count -gt 0) {
                throw "Migration commit failed and automatic rollback was incomplete. Original data remains under $rollbackDir. $($rollbackErrors -join '; ')"
            }
            throw $commitError
        }
        try {
            $manifest = "Migration time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`r`nSource: $sourceConfig`r`nCurrent-account rollback: $rollbackDir`r`nImported project files: $importedProjectFiles`r`n"
            [System.IO.File]::WriteAllText((Join-Path $rollbackDir 'MIGRATION_INFO.txt'), $manifest, [System.Text.UTF8Encoding]::new($false))
        } catch { Write-Warning "Migration succeeded, but the rollback note could not be written: $($_.Exception.Message)" }
        Write-Host "Migration complete. Imported project files: $importedProjectFiles"
        Write-Host "Rollback snapshot: $rollbackDir"
    } finally {
        if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $rootStage) { Remove-Item -LiteralPath $rootStage -Force -ErrorAction SilentlyContinue }
    }
}

function Select-CleanupTarget {
    while ($true) {
        Write-Host ''
        Write-Host 'Select Claude operation:'
        Write-Host '  1) Claude Desktop only'
        Write-Host '  2) Clear Claude Code login state and cache'
        Write-Host '  3) Migrate old Claude Code data into the current new account'
        Write-Host ''

        $choice = Read-Host 'Enter 1, 2, or 3'

        switch -Regex ($choice.Trim()) {
            '^(1|desktop|d)$' { return 'Desktop' }
            '^(2|code|c|claude-code)$' { return 'Code' }
            '^(3|migrate|migration|m)$' { return 'Migrate' }
            default { Write-Host 'Invalid choice. Please enter 1, 2, or 3.' }
        }
    }
}

if (-not (Test-Path -LiteralPath $UserProfile)) {
    throw "User profile does not exist: $UserProfile"
}

$UserProfile = Resolve-FullPath $UserProfile
$targets = [System.Collections.Generic.List[string]]::new()
$codeConfigDir = $null
$rootMetadataCleanupFailed = $false

if ($IncludeClaudeCli) {
    if ($PSBoundParameters.ContainsKey('Target') -and -not [string]::IsNullOrWhiteSpace($Target) -and $Target -notmatch '^(?i:code|c|claude-code|2)$') {
        throw 'Do not combine -IncludeClaudeCli with a non-Code target. Use -Target Code to clean Claude Code only.'
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
} elseif ($Target -match '^(?i:migrate|migration|m|3)$') {
    $Target = 'Migrate'
} else {
    throw "Invalid -Target '$Target'. Use Desktop, Code, or Migrate."
}

if ($Target -eq 'Code' -and $IncludeBrowserIndexedDb) {
    Write-Warning '-IncludeBrowserIndexedDb applies only to -Target Desktop and will be ignored.'
}

if ($Target -eq 'Migrate') {
    Invoke-ClaudeCodeDataMigration -Source $MigrationSource
    return
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

    try {
        $codeConfigDir = Get-ClaudeCodeConfigDirectory
    } catch {
        Write-Error "Unsafe CLAUDE_CONFIG_DIR was rejected; no files were cleaned: $($_.Exception.Message)"
        exit 1
    }
    if ($codeConfigDir) {
        Add-Target -Targets $targets -Path (Join-Path $codeConfigDir '.credentials.json')
        Add-Target -Targets $targets -Path (Join-Path $codeConfigDir 'cache')
        foreach ($name in @('settings.json', 'settings.local.json', 'config.json')) {
            Add-Target -Targets $targets -Path (Join-Path $codeConfigDir $name)
        }
    }
}

Write-Host "Stopping Claude processes..."

if (-not (Stop-CleanupProcesses -ClaudeProcesses $claudeProcesses -Targets $targets)) {
    Write-Error 'Cleanup was not started because Claude-related processes are still running.'
    exit 1
}

if ($Target -eq 'Code' -and $codeConfigDir) {
    $cleanupBackup = Backup-ClaudeCodeUserData -CodeConfigDir $codeConfigDir
    Write-Host 'Preserving Claude Code projects, conversations, settings, extensions, and .claude.json.'
    if (-not (Remove-ClaudeCodeRootAccountMetadata)) {
        Write-Warning 'Claude Code credentials and cache will still be cleared, but .claude.json account metadata could not be removed.'
        $rootMetadataCleanupFailed = $true
    }
    if ($cleanupBackup) {
        Write-Host 'After signing in to the new account, run this same script again and choose option 3 to merge this backup.'
    }
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

if ($unsafeCleanupTargets.Count -gt 0) {
    Write-Error "Cleanup was not completed because unsafe paths were rejected: $($unsafeCleanupTargets -join '; ')"
    exit 1
}

if ($rootMetadataCleanupFailed) {
    Write-Error 'Cleanup was incomplete because .claude.json account metadata could not be safely removed.'
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
