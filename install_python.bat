@echo off
echo.
echo === Python 3 安装脚本 (Windows) ===
echo.

where python >nul 2>&1
if %errorlevel%==0 (
    for /f "tokens=*" %%a in ('python --version 2^>^&1') do echo   [OK] 已安装: %%a
    echo.
    echo   Python 就绪, 可直接运行: python setup_proxy.py
    goto done
)

where python3 >nul 2>&1
if %errorlevel%==0 (
    for /f "tokens=*" %%a in ('python3 --version 2^>^&1') do echo   [OK] 已安装: %%a
    echo.
    echo   Python 就绪, 可直接运行: python3 setup_proxy.py
    goto done
)

echo   [WARN] 未检测到 Python 3, 开始安装...
echo.

where winget >nul 2>&1
if not %errorlevel%==0 goto no_winget

echo   通过 winget 安装 Python 3.13 ...
winget install Python.Python.3.13 --accept-package-agreements --accept-source-agreements
if %errorlevel%==0 (
    echo   [OK] 安装成功! 请重启终端后使用: python setup_proxy.py
) else (
    echo   [ERR] winget 安装失败
)
goto done

:no_winget
echo   即将打开 Python 官网下载页 ...
echo   请下载安装时勾选 "Add Python to PATH"
start https://www.python.org/downloads/

:done
echo.
pause
