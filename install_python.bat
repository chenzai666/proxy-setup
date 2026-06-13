@echo off
chcp 65001 >nul
setlocal enabledelayedexpansion

echo.
echo === Python 3 安装脚本（Windows） ===
echo.

:: 检查是否已安装
where python >nul 2>&1
if %errorlevel% equ 0 (
    for /f "tokens=*" %%i in ('python --version 2^>^&1') do set "pyver=%%i"
    echo   [OK] 已安装: !pyver!
    echo.
    echo   Python 已就绪，可直接运行:
    echo       python setup_proxy.py
    goto :end
)

where python3 >nul 2>&1
if %errorlevel% equ 0 (
    for /f "tokens=*" %%i in ('python3 --version 2^>^&1') do set "pyver=%%i"
    echo   [OK] 已安装: !pyver!
    echo.
    echo   Python 已就绪，可直接运行:
    echo       python3 setup_proxy.py
    goto :end
)

echo   [WARN] 未检测到 Python 3，开始安装...
echo.

:: 方案1: winget
where winget >nul 2>&1
if %errorlevel% equ 0 (
    echo   通过 winget 安装 Python 3.13...
    winget install Python.Python.3.13 --accept-package-agreements --accept-source-agreements
    if !errorlevel! equ 0 (
        :: 刷新 PATH
        for /f "tokens=2*" %%a in ('reg query "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment" /v PATH 2^>nul') do set "SysPath=%%b"
        for /f "tokens=2*" %%a in ('reg query "HKCU\Environment" /v PATH 2^>nul') do set "UserPath=%%b"
        set "PATH=!SysPath!;!UserPath!;!PATH!"

        where python >nul 2>&1
        if !errorlevel! equ 0 (
            for /f "tokens=*" %%i in ('python --version 2^>^&1') do set "pyver=%%i"
            echo   [OK] Python 3 安装成功: !pyver!
            echo.
            echo   请重新打开终端后即可使用:
            echo       python setup_proxy.py
            goto :end
        )
        echo   [ERR] 安装完成但 python 未在 PATH 中，请重启终端
        goto :end
    )
    echo   [ERR] winget 安装失败
    echo.
)

:: 方案2: 打开官网
echo   [WARN] 未找到 winget，即将打开 Python 官网下载页...
echo   请在浏览器中下载安装，务必勾选 "Add Python to PATH"
start https://www.python.org/downloads/

:end
echo.
pause
