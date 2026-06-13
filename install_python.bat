@echo off
setlocal

echo.
echo ==========
echo  Python 3 Installer + Proxy Setup Launcher
echo ==========
echo.

REM ---- Step 1: Find setup_proxy files ----
set "FOUND="

if exist "%~dp0setup_proxy.py"  set "FOUND=%~dp0setup_proxy.py"  & goto :found
if exist "%~dp0setup_proxy.ps1" set "FOUND=%~dp0setup_proxy.ps1" & goto :found

if exist "C:\Users\tt\WorkBuddy\Claw\proxy-setup\setup_proxy.py"  set "FOUND=C:\Users\tt\WorkBuddy\Claw\proxy-setup\setup_proxy.py"  & goto :found
if exist "C:\Users\tt\WorkBuddy\Claw\proxy-setup\setup_proxy.ps1" set "FOUND=C:\Users\tt\WorkBuddy\Claw\proxy-setup\setup_proxy.ps1" & goto :found

for %%B in ("%USERPROFILE%\Downloads" "%USERPROFILE%\Desktop" "%USERPROFILE%\Documents") do (
    if exist "%%~B\" (
        for /d %%D in ("%%~B\proxy*") do (
            if exist "%%D\setup_proxy.py"  set "FOUND=%%D\setup_proxy.py"  & goto :found
            if exist "%%D\setup_proxy.ps1" set "FOUND=%%D\setup_proxy.ps1" & goto :found
        )
    )
)

:found
if not defined FOUND (
    echo   setup_proxy files not found.
    echo.
    echo   Contents of this folder:
    echo   ---------------------------
    dir /b "%~dp0" 2>nul
    echo   ---------------------------
    echo.
    set /p "FOLDER=  Paste full path to setup_proxy folder: "
    if not defined FOLDER goto :notfound
    REM Remove trailing backslash if any
    if "%FOLDER:~-1%"=="\" set "FOLDER=%FOLDER:~0,-1%"
    if exist "%FOLDER%\setup_proxy.py"  set "FOUND=%FOLDER%\setup_proxy.py"  & goto :check_python
    if exist "%FOLDER%\setup_proxy.ps1" set "FOUND=%FOLDER%\setup_proxy.ps1" & goto :check_python
) else (
    echo   [OK] Found: %FOUND%
    echo.
    goto :check_python
)

:notfound
echo.
echo   Download full package:
echo   https://github.com/chenzai666/proxy-setup
goto :done

:check_python
echo   [OK] Files ready: %FOUND%
echo.

REM ---- Step 2: Check / Install Python ----
python --version >nul 2>&1
if not errorlevel 1 goto :py_ok

python3 --version >nul 2>&1
if not errorlevel 1 goto :py3_ok

echo   Python not found. Installing via winget...
echo.

winget --version >nul 2>&1
if errorlevel 1 goto :no_winget

winget install Python.Python.3.13 --accept-package-agreements --accept-source-agreements
if errorlevel 1 goto :no_winget

echo.
echo   [OK] Python installed. Run this bat again to launch.
goto :done

:no_winget
echo.
echo   Manual install: https://www.python.org/downloads/
echo   (Check "Add Python to PATH" during install!)
goto :done

:py_ok
python --version
goto :run

:py3_ok
python3 --version
goto :run_py3

REM ---- Step 3: Launch ----
:run
echo.
echo   Starting proxy setup...
timeout /t 1 >nul
echo "%FOUND%" | find ".py" >nul
if not errorlevel 1 (
    python "%FOUND%"
) else (
    powershell -ExecutionPolicy Bypass -File "%FOUND%"
)
goto :done

:run_py3
echo.
echo   Starting proxy setup...
timeout /t 1 >nul
echo "%FOUND%" | find ".py" >nul
if not errorlevel 1 (
    python3 "%FOUND%"
) else (
    powershell -ExecutionPolicy Bypass -File "%FOUND%"
)

:done
echo.
pause
