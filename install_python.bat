@echo off
title Python 3 Installer for Windows

echo.
echo   ========================================
echo     Python 3 Installer for Windows
echo   ========================================
echo.
echo   Script dir: %~dp0
echo.

where python >nul 2>&1
if %errorlevel%==0 goto python_found

where python3 >nul 2>&1
if %errorlevel%==0 goto python3_found

echo   [WARN] Python 3 not found, installing...
echo.

where winget >nul 2>&1
if not %errorlevel%==0 goto no_winget

echo   Installing Python 3.13 via winget...
winget install Python.Python.3.13 --accept-package-agreements --accept-source-agreements --silent
if errorlevel 1 goto winget_failed

echo   [OK] Installed! Restart terminal and run: python "%~dp0setup_proxy.py"
goto done

:winget_failed
echo   [ERR] winget install failed
goto done

:no_winget
echo   Opening Python download page...
echo   Make sure to check "Add Python to PATH" during install
start https://www.python.org/downloads/
echo.
echo   After install, run:
echo       python "%~dp0setup_proxy.py"

:done
echo.
pause
exit /b 0

:python_found
for /f "tokens=*" %%a in ('python --version 2^>^&1') do echo   [OK] Found: %%a
echo.
echo   -----
echo   Run proxy setup:
echo       cd /d "%~dp0"
echo       python setup_proxy.py
echo.
echo   Or use PowerShell (no Python needed):
echo       powershell -ExecutionPolicy Bypass -File "%~dp0setup_proxy.ps1"
echo   -----
goto done

:python3_found
for /f "tokens=*" %%a in ('python3 --version 2^>^&1') do echo   [OK] Found: %%a
echo.
echo   -----
echo   Run proxy setup:
echo       cd /d "%~dp0"
echo       python3 setup_proxy.py
echo   -----
goto done
