@echo off
cd /d "%~dp0"

echo.
echo   ========================================
echo     Python 3 Installer for Windows
echo   ========================================
echo.
echo   Script dir: %~dp0
echo.

REM --- Check if Python already installed ---
python --version >nul 2>&1
if not errorlevel 1 (
    python --version 2>&1
    echo.
    echo   [OK] Python is ready!
    echo   --------------------------------
    echo   Run:   python setup_proxy.py
    echo   Or:    powershell -ExecutionPolicy Bypass -File setup_proxy.ps1
    echo   --------------------------------
    goto end
)

python3 --version >nul 2>&1
if not errorlevel 1 (
    python3 --version 2>&1
    echo.
    echo   [OK] Python is ready!
    echo   --------------------------------
    echo   Run:   python3 setup_proxy.py
    echo   --------------------------------
    goto end
)

echo   [WARN] Python 3 not found.
echo.
echo   Trying to install via winget...

winget --version >nul 2>&1
if errorlevel 1 goto no_winget

echo   Downloading Python 3.13...
winget install Python.Python.3.13 --accept-package-agreements --accept-source-agreements --silent
if errorlevel 1 (
    echo   [ERR] winget install failed.
    goto end
)
echo   [OK] Installed!
echo   Close and re-open terminal, then run: python setup_proxy.py
goto end

:no_winget
echo   Winget not available.
echo   Opening Python download page...
start "" https://www.python.org/downloads/
echo.
echo   After install (check "Add Python to PATH!"), run:
echo       python "%~dp0setup_proxy.py"

:end
echo.
echo   Press any key to exit...
pause >nul
