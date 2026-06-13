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
set "BASE=%~dp0"

echo  Searching for setup_proxy.py...

call :trypath "%BASE%"
call :trypath "%BASE%proxy-setup"
call :trypath "%BASE%proxy-setup-main"
call :trypath "%BASE%proxy-setup-master"
call :trypath "%BASE%proxy-setup\"
call :trypath "%BASE%proxy-setup-main\"
call :trypath "%BASE%proxy-setup-master\"
call :trypath "%USERPROFILE%\Downloads\proxy-setup"
call :trypath "%USERPROFILE%\Downloads\proxy-setup-main"
call :trypath "%USERPROFILE%\Downloads\proxy-setup-master"
call :trypath "%USERPROFILE%\Desktop\proxy-setup"
call :trypath "%USERPROFILE%\Desktop\proxy-setup-main"
call :trypath "%USERPROFILE%\Desktop\proxy-setup-master"

if defined PROXY_SCRIPT (
    echo.
    echo  Found: %PROXY_SCRIPT%
)
goto :after_search

:trypath
if defined PROXY_SCRIPT exit /b 0
set "CHECK_DIR=%~1"
if not exist "%CHECK_DIR%\" exit /b 0
if exist "%CHECK_DIR%\setup_proxy.py" (
    echo    OK: %CHECK_DIR%\setup_proxy.py
    set "PROXY_SCRIPT=%CHECK_DIR%\setup_proxy.py"
    exit /b 0
)
if exist "%CHECK_DIR%\setup_proxy.ps1" (
    echo    OK: %CHECK_DIR%\setup_proxy.ps1
    set "PROXY_SCRIPT=%CHECK_DIR%\setup_proxy.ps1"
    exit /b 0
)
exit /b 0

:after_search

if not defined PROXY_SCRIPT (
    echo.
    echo  Not found automatically.
    echo  List of files in current dir:
    echo.
    dir /b "%~dp0"
    echo.
    dir /b "%~dp0*proxy*" 2>nul
)

REM -----------------------------------------------------------
REM  Step 2: Check Python
REM -----------------------------------------------------------
python --version >nul 2>&1
if not errorlevel 1 goto PYTHON_OK

python3 --version >nul 2>&1
if not errorlevel 1 goto PYTHON3_OK

echo.
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
echo  [OK] Python installed! Re-run this bat.
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
echo  setup_proxy files not found.
echo  Download full package or place bat in same folder as setup_proxy.py
echo    https://github.com/chenzai666/proxy-setup
goto DONE

:PYTHON3_OK
python3 --version
echo.
echo  Python ready.
echo.
if defined PROXY_SCRIPT goto RUN_PROXY_PY3
echo  setup_proxy files not found.
echo  Download full package or place bat in same folder as setup_proxy.py
echo    https://github.com/chenzai666/proxy-setup
goto DONE

:RUN_PROXY
echo.
echo  Starting proxy setup...
echo.
timeout /t 1 >nul
if "%PROXY_SCRIPT:~-3%"==".py" (
    python "%PROXY_SCRIPT%"
) else (
    powershell -ExecutionPolicy Bypass -File "%PROXY_SCRIPT%"
)
goto DONE

:RUN_PROXY_PY3
echo.
echo  Starting proxy setup...
echo.
timeout /t 1 >nul
if "%PROXY_SCRIPT:~-3%"==".py" (
    python3 "%PROXY_SCRIPT%"
) else (
    powershell -ExecutionPolicy Bypass -File "%PROXY_SCRIPT%"
)
goto DONE

:DONE
echo.
echo  Press any key to close...
pause
