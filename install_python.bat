@echo off
title Python 3 Installer for Windows

echo.
echo   ========================================
echo     Python 3 Installer for Windows
echo   ========================================
echo.

where python >nul 2>&1
if %errorlevel%==0 (
    for /f "tokens=*" %%a in ('python --version 2^>^&1') do echo   [OK] Found: %%a
    echo.
    echo   Python is ready! Run:
    echo       python setup_proxy.py
    goto done
)

where python3 >nul 2>&1
if %errorlevel%==0 (
    for /f "tokens=*" %%a in ('python3 --version 2^>^&1') do echo   [OK] Found: %%a
    echo.
    echo   Python is ready! Run:
    echo       python3 setup_proxy.py
    goto done
)

echo   [WARN] Python 3 not found, installing...
echo.

where winget >nul 2>&1
if not %errorlevel%==0 goto no_winget

echo   Installing Python 3.13 via winget...
winget install Python.Python.3.13 --accept-package-agreements --accept-source-agreements --silent
if %errorlevel%==0 (
    echo   [OK] Installed! Restart terminal and run: python setup_proxy.py
) else (
    echo   [ERR] winget install failed
)
goto done

:no_winget
echo   Opening Python download page...
echo   Make sure to check "Add Python to PATH" during install
start https://www.python.org/downloads/

:done
echo.
pause
