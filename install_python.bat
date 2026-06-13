@echo off
cd /d "%~dp0"

echo.
echo ==========
echo  Python 3 + Proxy Setup
echo ==========
echo.
echo  Script: %~dp0
echo.

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

:RUN_SETUP
python --version
echo.
echo  Python OK. Starting proxy setup...
echo.
timeout /t 2 >nul
python "%~dp0setup_proxy.py"
goto DONE

:RUN_SETUP_PY3
python3 --version
echo.
echo  Python OK. Starting proxy setup...
echo.
timeout /t 2 >nul
python3 "%~dp0setup_proxy.py"
goto DONE

:DONE
echo.
echo  Press any key to close...
pause
