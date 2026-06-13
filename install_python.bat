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

echo  Searching for setup_proxy.py...

REM Exact known locations (fast)
call :check "%~dp0setup_proxy.py"
call :check "%~dp0setup_proxy.ps1"
call :check "C:\Users\tt\WorkBuddy\Claw\proxy-setup\setup_proxy.py"
call :check "C:\Users\tt\WorkBuddy\Claw\proxy-setup\setup_proxy.ps1"

REM Recursive search from bat location (1 level)
if not defined PROXY_SCRIPT (
    for /d %%d in ("%~dp0*proxy*") do (
        if exist "%%d\setup_proxy.py" set "PROXY_SCRIPT=%%d\setup_proxy.py"
        if not defined PROXY_SCRIPT if exist "%%d\setup_proxy.ps1" set "PROXY_SCRIPT=%%d\setup_proxy.ps1"
        if defined PROXY_SCRIPT (
            echo    Found: %PROXY_SCRIPT%
            goto after_check
        )
    )
)

REM Recursive search from common download dirs
if not defined PROXY_SCRIPT (
    for %%b in ("%USERPROFILE%\Downloads" "%USERPROFILE%\Desktop" "%USERPROFILE%\Documents") do (
        if exist "%%~b\" (
            for /d %%d in ("%%~b\*proxy*") do (
                if exist "%%d\setup_proxy.py" set "PROXY_SCRIPT=%%d\setup_proxy.py"
                if not defined PROXY_SCRIPT if exist "%%d\setup_proxy.ps1" set "PROXY_SCRIPT=%%d\setup_proxy.ps1"
                if defined PROXY_SCRIPT (
                    echo    Found: %PROXY_SCRIPT%
                    goto after_check
                )
            )
        )
    )
)

goto after_check

:check
if defined PROXY_SCRIPT exit /b 0
set "F=%~1"
if exist "%F%" (
    set "PROXY_SCRIPT=%F%"
    echo    Found: %F%
)
exit /b 0

:after_check

if not defined PROXY_SCRIPT (
    echo.
    echo  [INFO] setup_proxy files not found.
    echo.
    echo  Files in this folder:
    echo  ---------------------
    dir /b "%~dp0" 2>nul
    echo  ---------------------
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
echo  Place this bat next to setup_proxy.py, or download:
echo  https://github.com/chenzai666/proxy-setup
goto DONE

:PYTHON3_OK
python3 --version
echo.
echo  Python ready.
echo.
if defined PROXY_SCRIPT goto RUN_PROXY_PY3
echo  setup_proxy files not found.
echo  Place this bat next to setup_proxy.py, or download:
echo  https://github.com/chenzai666/proxy-setup
goto DONE

:RUN_PROXY
echo.
echo  Starting proxy setup...
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
