@echo off
chcp 65001 >nul

echo.
echo === Python 3 安装脚本（Windows） ===
echo.

:: 检查 python
where python >nul 2>&1
if not errorlevel 1 goto :found_python

where python3 >nul 2>&1
if not errorlevel 1 goto :found_python3

echo   [WARN] 未检测到 Python 3，开始安装...
echo.

:: 检查 winget
where winget >nul 2>&1
if not errorlevel 1 goto :winget_install

:: 没有 winget，打开官网
echo   [WARN] 未找到 winget，即将打开 Python 官网下载页...
echo   请在浏览器中下载安装，务必勾选 "Add Python to PATH"
start https://www.python.org/downloads/
goto :end

:found_python
for /f "tokens=*" %%i in ('python --version 2^>^&1') do set "pyver=%%i"
echo   [OK] 已安装: %pyver%
echo.
echo   Python 已就绪，可直接运行:
echo       python setup_proxy.py
goto :end

:found_python3
for /f "tokens=*" %%i in ('python3 --version 2^>^&1') do set "pyver=%%i"
echo   [OK] 已安装: %pyver%
echo.
echo   Python 已就绪，可直接运行:
echo       python3 setup_proxy.py
goto :end

:winget_install
echo   通过 winget 安装 Python 3.13...
winget install Python.Python.3.13 --accept-package-agreements --accept-source-agreements
if not errorlevel 1 (
    echo   [OK] Python 3 安装成功
    echo.
    echo   请重新打开 CMD 后即可使用:
    echo       python setup_proxy.py
    goto :end
)
echo   [ERR] winget 安装失败，请手动下载
start https://www.python.org/downloads/

:end
echo.
pause
