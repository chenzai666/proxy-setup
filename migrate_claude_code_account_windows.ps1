<#
.SYNOPSIS
安全地把旧 Claude Code 本地工作记录合并到当前 Windows 账号。

.DESCRIPTION
只迁移 projects、sessions、history、用户命令和扩展配置。旧账号的
.credentials.json、cache、telemetry、oauthAccount、userID 和 machineID
不会导入。当前账号数据优先，同名冲突不会覆盖。

.EXAMPLE
powershell -NoProfile -ExecutionPolicy Bypass -File .\migrate_claude_code_account_windows.ps1 -Source "$HOME\.claude-cleanup-backups\20260716-120000" -Yes

.EXAMPLE
powershell -NoProfile -ExecutionPolicy Bypass -File .\migrate_claude_code_account_windows.ps1 -Source "D:\backup\.claude" -WhatIf
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [string]$Source = '',

    [string]$UserProfile = $env:USERPROFILE,

    [string]$Destination = '',

    [string]$BackupRoot = '',

    [switch]$Yes,

    [switch]$AllowLoggedOut
)

$ErrorActionPreference = 'Stop'

function Info([string]$Message) { Write-Host "  $Message" -ForegroundColor Cyan }
function Ok([string]$Message) { Write-Host "  [OK] $Message" -ForegroundColor Green }
function Warn([string]$Message) { Write-Host "  [WARN] $Message" -ForegroundColor Yellow }
function Fail([string]$Message) { Write-Host "  [ERR] $Message" -ForegroundColor Red }

function Resolve-FullPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    return [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Path))
}

function Test-PathInsideRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Root
    )
    $fullPath = (Resolve-FullPath $Path).TrimEnd('\')
    $rootPath = (Resolve-FullPath $Root).TrimEnd('\')
    return $fullPath.StartsWith($rootPath + '\', [System.StringComparison]::OrdinalIgnoreCase)
}

function Find-LatestCleanupBackup {
    $root = Join-Path $UserProfile '.claude-cleanup-backups'
    if (-not (Test-Path -LiteralPath $root)) { return $null }
    return @(
        Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName '.claude') } |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
    ) | ForEach-Object { $_.FullName }
}

function Get-FileCount {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }
    return @(Get-ChildItem -LiteralPath $Path -File -Recurse -Force -ErrorAction SilentlyContinue).Count
}

function Stop-ClaudeCodeProcesses {
    $processes = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $name = [string]$_.Name
        $commandLine = [string]$_.CommandLine
        ($name -match '^claude(\.exe)?$') -or
        ($name -match '^node\.exe$' -and $commandLine -match '(?i)@anthropic-ai[\\/]claude-code')
    })
    foreach ($process in $processes) {
        try {
            Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction Stop
            Info "已停止 Claude Code 进程 PID $($process.ProcessId)"
        } catch {
            Warn "无法停止 PID $($process.ProcessId): $($_.Exception.Message)"
        }
    }
}

function Merge-DirectoryNoClobber {
    param(
        [Parameter(Mandatory = $true)][string]$SourceDir,
        [Parameter(Mandatory = $true)][string]$TargetDir
    )
    if (-not (Test-Path -LiteralPath $SourceDir)) { return }
    if (-not (Test-Path -LiteralPath $TargetDir)) {
        New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
    }

    $sourceRoot = (Resolve-FullPath $SourceDir).TrimEnd('\')
    foreach ($item in Get-ChildItem -LiteralPath $SourceDir -Force -ErrorAction Stop) {
        Merge-ItemNoClobber -Item $item -SourceRoot $sourceRoot -TargetRoot $TargetDir
    }
}

function Merge-ItemNoClobber {
    param(
        [Parameter(Mandatory = $true)]$Item,
        [Parameter(Mandatory = $true)][string]$SourceRoot,
        [Parameter(Mandatory = $true)][string]$TargetRoot
    )
    $relative = $Item.FullName.Substring($SourceRoot.Length).TrimStart('\')
    $target = Join-Path $TargetRoot $relative
    $isReparsePoint = ($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0

    if ($Item.PSIsContainer -and -not $isReparsePoint) {
        if (-not (Test-Path -LiteralPath $target)) {
            New-Item -ItemType Directory -Path $target -Force | Out-Null
        }
        foreach ($child in Get-ChildItem -LiteralPath $Item.FullName -Force -ErrorAction Stop) {
            Merge-ItemNoClobber -Item $child -SourceRoot $SourceRoot -TargetRoot $TargetRoot
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

function Merge-HistoryFile {
    param(
        [Parameter(Mandatory = $true)][string]$SourceFile,
        [Parameter(Mandatory = $true)][string]$TargetFile
    )
    if (-not (Test-Path -LiteralPath $SourceFile)) { return }
    if (-not (Test-Path -LiteralPath $TargetFile)) {
        Copy-Item -LiteralPath $SourceFile -Destination $TargetFile -Force
        return
    }

    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $temp = "$TargetFile.migration-$([guid]::NewGuid().ToString('N')).tmp"
    $encoding = [System.Text.UTF8Encoding]::new($false)
    $writer = [System.IO.StreamWriter]::new($temp, $false, $encoding)
    try {
        foreach ($path in @($TargetFile, $SourceFile)) {
            $reader = [System.IO.StreamReader]::new($path, [System.Text.Encoding]::UTF8, $true)
            try {
                while (-not $reader.EndOfStream) {
                    $line = $reader.ReadLine()
                    if (-not [string]::IsNullOrWhiteSpace($line) -and $seen.Add($line)) {
                        $writer.WriteLine($line)
                    }
                }
            } finally {
                $reader.Dispose()
            }
        }
    } finally {
        $writer.Dispose()
    }
    Move-Item -LiteralPath $temp -Destination $TargetFile -Force
}

function Merge-DictionaryValue {
    param(
        [System.Collections.IDictionary]$SourceMap,
        [System.Collections.IDictionary]$DestinationMap
    )
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

function New-MergedRootConfig {
    param(
        [Parameter(Mandatory = $true)][string]$SourceFile,
        [Parameter(Mandatory = $true)][string]$DestinationFile,
        [Parameter(Mandatory = $true)][string]$OutputFile
    )
    Add-Type -AssemblyName System.Web.Extensions
    $serializer = [System.Web.Script.Serialization.JavaScriptSerializer]::new()
    $serializer.MaxJsonLength = [int]::MaxValue
    $sourceObject = $serializer.DeserializeObject([System.IO.File]::ReadAllText($SourceFile, [System.Text.Encoding]::UTF8))
    $destinationObject = if (Test-Path -LiteralPath $DestinationFile) {
        $serializer.DeserializeObject([System.IO.File]::ReadAllText($DestinationFile, [System.Text.Encoding]::UTF8))
    } else {
        [System.Collections.Generic.Dictionary[string, object]]::new()
    }

    foreach ($key in @('projects', 'mcpServers')) {
        if (-not ($sourceObject -is [System.Collections.IDictionary]) -or -not $sourceObject.ContainsKey($key)) { continue }
        $sourceMap = $sourceObject[$key]
        if (-not ($sourceMap -is [System.Collections.IDictionary])) { continue }
        if (-not $destinationObject.ContainsKey($key) -or -not ($destinationObject[$key] -is [System.Collections.IDictionary])) {
            $destinationObject[$key] = [System.Collections.Generic.Dictionary[string, object]]::new()
        }
        Merge-DictionaryValue -SourceMap $sourceMap -DestinationMap $destinationObject[$key]
    }

    # oauthAccount, userID, machineID and all other source account fields are deliberately ignored.
    $json = $serializer.Serialize($destinationObject)
    [System.IO.File]::WriteAllText($OutputFile, $json, [System.Text.UTF8Encoding]::new($false))
}

if (-not (Test-Path -LiteralPath $UserProfile)) {
    throw "用户目录不存在: $UserProfile"
}
$UserProfile = Resolve-FullPath $UserProfile
if ([string]::IsNullOrWhiteSpace($Destination)) {
    $Destination = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $UserProfile '.claude' }
}
if ([string]::IsNullOrWhiteSpace($BackupRoot)) {
    $BackupRoot = Join-Path $UserProfile '.claude-migration-backups'
}

if ([string]::IsNullOrWhiteSpace($Source)) {
    $Source = Find-LatestCleanupBackup
    if ([string]::IsNullOrWhiteSpace($Source)) {
        throw '未找到可自动使用的备份，请通过 -Source 指定旧 .claude 或备份目录。'
    }
    Info "自动选择最新清理备份: $Source"
}
if (-not (Test-Path -LiteralPath $Source)) { throw "源目录不存在: $Source" }
$sourcePath = (Resolve-Path -LiteralPath $Source).Path

$sourceConfig = $null
$sourceRootJson = $null
if (Test-Path -LiteralPath (Join-Path $sourcePath '.claude')) {
    $sourceConfig = (Resolve-Path -LiteralPath (Join-Path $sourcePath '.claude')).Path
    $candidateRoot = Join-Path $sourcePath '.claude.json'
    if (Test-Path -LiteralPath $candidateRoot) { $sourceRootJson = $candidateRoot }
} elseif ((Split-Path -Leaf $sourcePath) -eq '.claude' -or
          (Test-Path -LiteralPath (Join-Path $sourcePath 'projects')) -or
          (Test-Path -LiteralPath (Join-Path $sourcePath 'history.jsonl'))) {
    $sourceConfig = $sourcePath
    $candidateRoot = Join-Path (Split-Path -Parent $sourcePath) '.claude.json'
    if (Test-Path -LiteralPath $candidateRoot) { $sourceRootJson = $candidateRoot }
} else {
    throw "源目录不包含可识别的 Claude Code 数据: $sourcePath"
}

$Destination = Resolve-FullPath $Destination
$BackupRoot = Resolve-FullPath $BackupRoot
if (-not (Test-PathInsideRoot -Path $Destination -Root $UserProfile)) {
    throw "目标目录必须位于用户目录内，且不能是用户目录本身: $Destination"
}
if (-not (Test-PathInsideRoot -Path $BackupRoot -Root $UserProfile)) {
    throw "备份目录必须位于用户目录内: $BackupRoot"
}
if ($sourceConfig.Equals($Destination, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw '源目录和目标目录相同，已停止迁移。'
}
if (Test-PathInsideRoot -Path $sourceConfig -Root $Destination) {
    throw '源目录不能位于目标目录内部。'
}
if ((Test-PathInsideRoot -Path $BackupRoot -Root $Destination) -or
    (Test-PathInsideRoot -Path $Destination -Root $BackupRoot) -or
    $BackupRoot.Equals($Destination, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw '目标目录和回滚备份目录不能相同或互相包含。'
}

$mergeDirs = @('projects', 'sessions', 'commands', 'agents', 'skills', 'plugins', 'backups', 'session-env', 'shell-snapshots', 'todos', 'plans')
$copyIfMissingFiles = @('settings.json', 'settings.local.json', 'config.json', 'CLAUDE.md')
$hasImportable = (Test-Path -LiteralPath (Join-Path $sourceConfig 'history.jsonl'))
foreach ($name in $mergeDirs + $copyIfMissingFiles) {
    if (Test-Path -LiteralPath (Join-Path $sourceConfig $name)) { $hasImportable = $true; break }
}
if (-not $hasImportable) { throw '源目录没有 projects、history、sessions 或可迁移的用户配置。' }

$sourceProjectFiles = Get-FileCount (Join-Path $sourceConfig 'projects')
$destinationProjectFiles = Get-FileCount (Join-Path $Destination 'projects')
$currentCredential = Join-Path $Destination '.credentials.json'
$currentLoginFound = (Test-Path -LiteralPath $currentCredential) -or
    -not [string]::IsNullOrWhiteSpace($env:ANTHROPIC_API_KEY) -or
    -not [string]::IsNullOrWhiteSpace($env:ANTHROPIC_AUTH_TOKEN) -or
    -not [string]::IsNullOrWhiteSpace($env:CLAUDE_CODE_OAUTH_TOKEN)

Write-Host ''
Write-Host 'Claude Code 旧数据迁移计划'
Write-Host "  源数据:       $sourceConfig"
Write-Host "  当前账号目录: $Destination"
Write-Host "  回滚备份目录: $BackupRoot"
Write-Host "  源项目文件数: $sourceProjectFiles"
Write-Host "  当前项目文件: $destinationProjectFiles"
Write-Host "  当前登录凭据: $(if ($currentLoginFound) { '已检测到，将保留' } else { '未检测到' })"
Write-Host ''
Write-Host '源账号凭据、cache、telemetry、oauthAccount 和 userID 不会导入。'
Write-Host '同名文件冲突时保留当前账号版本；旧数据只补充缺失内容。'

if (-not $currentLoginFound -and -not $AllowLoggedOut) {
    throw '未检测到当前新账号登录凭据。请先登录新账号，或明确使用 -AllowLoggedOut。'
}

if ($WhatIfPreference) {
    Write-Host ''
    Ok '预演完成，没有停止进程、复制或修改任何文件。'
    exit 0
}

if (-not $Yes) {
    $answer = Read-Host '确认开始迁移？[y/N]'
    if ($answer -notmatch '^(?i:y|yes)$') {
        Warn '已取消，未修改任何文件。'
        exit 0
    }
}

Stop-ClaudeCodeProcesses

$destinationParent = Split-Path -Parent $Destination
$destinationName = Split-Path -Leaf $Destination
if (-not (Test-Path -LiteralPath $destinationParent)) {
    New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null
}
if (-not (Test-Path -LiteralPath $BackupRoot)) {
    New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null
}

$stage = Join-Path $destinationParent (".$destinationName.migration-stage-$([guid]::NewGuid().ToString('N'))")
$rootStage = Join-Path $destinationParent (".claude-root-migration-stage-$([guid]::NewGuid().ToString('N')).json")
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$rollbackDir = Join-Path $BackupRoot $stamp
if (Test-Path -LiteralPath $rollbackDir) {
    $rollbackDir = Join-Path $BackupRoot ("$stamp-$([guid]::NewGuid().ToString('N').Substring(0, 8))")
}

New-Item -ItemType Directory -Path $stage -Force | Out-Null
try {
    if (Test-Path -LiteralPath $Destination) {
        Info '复制当前账号数据到 staging...'
        Get-ChildItem -LiteralPath $Destination -Force -ErrorAction Stop | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination $stage -Recurse -Force -ErrorAction Stop
        }
    }

    Info '合并旧项目、会话和扩展配置...'
    foreach ($name in $mergeDirs) {
        Merge-DirectoryNoClobber -SourceDir (Join-Path $sourceConfig $name) -TargetDir (Join-Path $stage $name)
    }
    foreach ($name in $copyIfMissingFiles) {
        $sourceFile = Join-Path $sourceConfig $name
        $targetFile = Join-Path $stage $name
        if ((Test-Path -LiteralPath $sourceFile) -and -not (Test-Path -LiteralPath $targetFile)) {
            Copy-Item -LiteralPath $sourceFile -Destination $targetFile -Force
        }
    }
    Merge-HistoryFile -SourceFile (Join-Path $sourceConfig 'history.jsonl') -TargetFile (Join-Path $stage 'history.jsonl')

    # Source credentials/cache are not part of the allowlist. Existing target copies remain untouched.
    $destinationRootJson = Join-Path $UserProfile '.claude.json'
    $rootMergeReady = $false
    if ($sourceRootJson) {
        try {
            Info '合并 .claude.json 中的 projects/mcpServers 登记（不导入账号字段）...'
            New-MergedRootConfig -SourceFile $sourceRootJson -DestinationFile $destinationRootJson -OutputFile $rootStage
            $rootMergeReady = $true
        } catch {
            Warn ".claude.json 项目登记合并失败；会话仍可迁移，但旧项目首次打开时可能需要重新授权: $($_.Exception.Message)"
            Remove-Item -LiteralPath $rootStage -Force -ErrorAction SilentlyContinue
        }
    }

    $stageProjectFiles = Get-FileCount (Join-Path $stage 'projects')
    $importedProjectFiles = [Math]::Max(0, $stageProjectFiles - $destinationProjectFiles)
    New-Item -ItemType Directory -Path $rollbackDir -Force | Out-Null

    $destinationMoved = $false
    $destinationInstalled = $false
    $rootMoved = $false
    $rootInstalled = $false
    try {
        Info '原子切换到合并后的数据目录...'
        if (Test-Path -LiteralPath $Destination) {
            Move-Item -LiteralPath $Destination -Destination (Join-Path $rollbackDir 'current-claude') -ErrorAction Stop
            $destinationMoved = $true
        }
        Move-Item -LiteralPath $stage -Destination $Destination -ErrorAction Stop
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
        Fail "提交迁移失败，正在自动回滚: $($_.Exception.Message)"
        if ($destinationInstalled -and (Test-Path -LiteralPath $Destination)) {
            Remove-Item -LiteralPath $Destination -Recurse -Force -ErrorAction SilentlyContinue
        }
        $oldDestination = Join-Path $rollbackDir 'current-claude'
        if ($destinationMoved -and (Test-Path -LiteralPath $oldDestination)) {
            Move-Item -LiteralPath $oldDestination -Destination $Destination -ErrorAction SilentlyContinue
        }
        if ($rootInstalled -and (Test-Path -LiteralPath $destinationRootJson)) {
            Remove-Item -LiteralPath $destinationRootJson -Force -ErrorAction SilentlyContinue
        }
        $oldRoot = Join-Path $rollbackDir 'current-claude.json'
        if ($rootMoved -and (Test-Path -LiteralPath $oldRoot)) {
            Move-Item -LiteralPath $oldRoot -Destination $destinationRootJson -ErrorAction SilentlyContinue
        }
        throw
    }

    $manifest = @"
迁移时间: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
源目录: $sourceConfig
目标目录: $Destination
迁移前项目文件数: $destinationProjectFiles
源项目文件数: $sourceProjectFiles
新增项目文件数: $importedProjectFiles

current-claude 是迁移前当前账号的完整 Claude 配置快照，可能包含当前账号凭据。
确认迁移无误后，请妥善保管或删除该回滚目录。
"@
    try {
        [System.IO.File]::WriteAllText((Join-Path $rollbackDir 'MIGRATION_INFO.txt'), $manifest, [System.Text.UTF8Encoding]::new($false))
    } catch {
        Warn "迁移已完成，但写入回滚说明失败: $($_.Exception.Message)"
    }

    Write-Host ''
    Ok '迁移完成'
    Write-Host "  新增项目文件: $importedProjectFiles"
    Write-Host "  当前项目文件: $stageProjectFiles"
    Write-Host "  回滚快照:     $rollbackDir"
    Write-Host ''
    Write-Host '旧账号凭据没有导入；当前新账号凭据已保留。'
    Write-Host '重新运行 Claude Code 后，可使用 /resume 检查旧会话，或进入原项目目录继续工作。'
    Write-Host '注意：已经被永久删除且没有备份的对话、云端 Cowork/Chat 数据无法由本脚本恢复。'
} finally {
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $rootStage) { Remove-Item -LiteralPath $rootStage -Force -ErrorAction SilentlyContinue }
}
