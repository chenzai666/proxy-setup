@echo off
cd /d "%~dp0"

echo.
echo ==========
echo  Python 3 Installer
echo ==========
echo.

REM -----------------------------------------------------------
REM  Step 1: Find setup_proxy.py
REM -----------------------------------------------------------
set "PROXY_SCRIPT="

REM Look in these locations (most likely first)
for %%p in (
    "%~dp0"
    "%~dp0proxy-setup"
    "%~dp0proxy-setup-main"
    "%USERPROFILE%\Downloads\proxy-setup"
    "%USERPROFILE%\Downloads\proxy-setup-main"
    "%USERPROFILE%\Downloads\proxy-setup-master"
    "%USERPROFILE%\Desktop\proxy-setup"
    "%USERPROFILE%\Desktop\proxy-setup-main"
    "%USERPROFILE%\Desktop\proxy-setup-master"
) do (
    if exist "%%~p\setup_proxy.py" set "PROXY_SCRIPT=%%~p\setup_proxy.py"
    if exist "%%~p\setup_proxy.ps1" if not defined PROXY_SCRIPT set "PROXY_SCRIPT=%%~p\setup_proxy.ps1"
)

if defined PROXY_SCRIPT (
    echo  Found: %PROXY_SCRIPT%
    echo.
)

REM -----------------------------------------------------------
REM  Step 2: Check Python
REM -----------------------------------------------------------
python --version >nul 2>&1
if not errorlevel 1 goto PYTHON_OK

python3 --version >nul 2>&1
if not errorlevel 1 goto PYTHON3_OK

REM Install
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
echo  Re-run this bat to set up proxy.
goto DONE

:NO_WINGET
echo  winget not found.
goto MANUAL

:MANUAL
echo.
echo  Manual install: https://www.python.org/downloads/
echo  (Check "Add Python to PATH"!)
goto DONE

:PYTHON_OK
python --version
echo.
echo  Python ready.
echo.
if defined PROXY_SCRIPT goto RUN_PROXY
goto PROXY_NOT_FOUND

:PYTHON3_OK
python3 --version
echo.
echo  Python ready.
echo.
if defined PROXY_SCRIPT goto RUN_PROXY_PY3
goto PROXY_NOT_FOUND

:RUN_PROXY
if "%PROXY_SCRIPT:~-3%"==".py" (
    python "%PROXY_SCRIPT%"
) else (
    powershell -ExecutionPolicy Bypass -File "%PROXY_SCRIPT%"
)
goto DONE

:RUN_PROXY_PY3
if "%PROXY_SCRIPT:~-3%"==".py" (
    python3 "%PROXY_SCRIPT%"
) else (
    powershell -ExecutionPolicy Bypass -File "%PROXY_SCRIPT%"
)
goto DONE

:PROXY_NOT_FOUND
echo  setup_proxy.py not found.
echo  Searched: current dir, Downloads, Desktop
echo.
echo  Download full package:
echo    https://github.com/chenzai666/proxy-setup
echo  Or run:  python ^<path^>\setup_proxy.py

:DONE
echo.
echo  Press any key to close...
pause
