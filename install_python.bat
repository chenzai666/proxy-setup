@echo off
cd /d "%~dp0"

echo.
echo ==========
echo  Python 3 + Proxy Setup
echo ==========
echo.
echo  Script: %~dp0
echo.

REM Check if setup_proxy files exist
if not exist "%~dp0setup_proxy.py" if not exist "%~dp0setup_proxy.ps1" goto MISSING_FILES

REM Check python
python --version >nul 2>&1
if not errorlevel 1 goto RUN_SETUP

python3 --version >nul 2>&1
if not errorlevel 1 goto RUN_SETUP_PY3

REM Not found - try install
echo  Python not found. Installing via winget...
echo.

winget --version >nul 2>&1
if errorlevel 1 goto NO_WINGET

winget install Python.Python.3.13 --accept-package-agreements --accept-source-agreements
if errorlevel 1 (
    echo.
    echo  [ERR] Install failed.
    goto MANUAL
)

echo.
echo  [OK] Python installed!
echo  Please RE-OPEN terminal and run this bat again.
goto DONE

:NO_WINGET
echo  winget not found.
goto MANUAL

:MANUAL
echo.
echo  Please install Python manually:
echo  https://www.python.org/downloads/
echo  (Check "Add Python to PATH" box!)
goto DONE

:MISSING_FILES
echo  [ERR] setup_proxy.py / setup_proxy.ps1 not found!
echo.
echo  Please download the FULL repo, not just this bat file:
echo    https://github.com/chenzai666/proxy-setup
echo.
echo  git clone or Download ZIP  (green Code button)
goto DONE

:RUN_SETUP
python --version
echo.
echo  Python OK. Starting proxy setup...
echo.
timeout /t 2 >nul
if exist "%~dp0setup_proxy.py" (
    python "%~dp0setup_proxy.py"
) else (
    powershell -ExecutionPolicy Bypass -File "%~dp0setup_proxy.ps1"
)
goto DONE

:RUN_SETUP_PY3
python3 --version
echo.
echo  Python OK. Starting proxy setup...
echo.
timeout /t 2 >nul
if exist "%~dp0setup_proxy.py" (
    python3 "%~dp0setup_proxy.py"
) else (
    powershell -ExecutionPolicy Bypass -File "%~dp0setup_proxy.ps1"
)
goto DONE

:DONE
echo.
echo  Press any key to close...
pause
