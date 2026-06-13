<#
.SYNOPSIS
    Python 3 安装脚本（Windows）
    proxy-setup 配套，确保 setup_proxy.py 可用
#>

function ok($msg)   { Write-Host "  [OK] $msg" -ForegroundColor Green }
function info($msg)  { Write-Host "  $msg" }
function warn($msg)  { Write-Host "  [WARN] $msg" -ForegroundColor Yellow }
function err($msg)   { Write-Host "  [ERR] $msg" -ForegroundColor Red }

Write-Host ""
Write-Host "=== Python 3 安装脚本（Windows）===" -ForegroundColor Yellow
Write-Host ""

# 检查是否已安装
$existing = Get-Command python -ErrorAction SilentlyContinue
if (-not $existing) { $existing = Get-Command python3 -ErrorAction SilentlyContinue }

if ($existing) {
    $ver = & $existing.Source --version 2>&1
    ok "已安装: $ver  ($($existing.Source))"
    Write-Host ""
    info "Python 已就绪，可直接运行:"
    Write-Host "    .\setup_proxy.ps1   (推荐, 零依赖)"
    Write-Host "    python setup_proxy.py  (Python 版)"
    return
}

warn "未检测到 Python 3，开始安装..."
Write-Host ""

# 方案1: winget（Win10 1809+ 内置）
$winget = Get-Command winget -ErrorAction SilentlyContinue
if ($winget) {
    info "通过 winget 安装 Python 3.13..."
    winget install Python.Python.3.13 --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -eq 0) {
        # 刷新 PATH
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
        $py = Get-Command python -ErrorAction SilentlyContinue
        if ($py) {
            $ver = & $py.Source --version 2>&1
            ok "Python 3 安装成功: $ver"
            Write-Host ""
            info "请重新打开终端后即可使用:"
            Write-Host "    python setup_proxy.py"
            return
        }
        err "安装完成但 python 未在 PATH 中，请重启终端"
        return
    }
    err "winget 安装失败，尝试备用方案..."
    Write-Host ""
}

# 方案2: 打开官网下载页
warn "未找到 winget，打开 Python 官网下载页..."
info "请在浏览器中下载安装，务必勾选 Add Python to PATH"
Start-Process "https://www.python.org/downloads/"