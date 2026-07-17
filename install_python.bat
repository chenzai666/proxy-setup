@echo off

echo.
echo ==========
echo  Proxy Setup Launcher
echo ==========
echo.

set "FOUND_PS="
set "FOUND_PY="

REM ---- Find setup_proxy.ps1 / setup_proxy.py ----

REM 1) Same folder as this bat
if exist "%~dp0setup_proxy.ps1" set "FOUND_PS=%~dp0setup_proxy.ps1"
if exist "%~dp0setup_proxy.py" set "FOUND_PY=%~dp0setup_proxy.py"

REM 2) Parent folder
if not defined FOUND_PS if exist "%~dp0..\setup_proxy.ps1" set "FOUND_PS=%~dp0..\setup_proxy.ps1"
if not defined FOUND_PY if exist "%~dp0..\setup_proxy.py" set "FOUND_PY=%~dp0..\setup_proxy.py"

if defined FOUND_PS goto :found_ps
if defined FOUND_PY goto :found_py

REM Not found
echo.
echo   setup_proxy.ps1 / setup_proxy.py not found.
echo.
echo   Contents of this folder:
echo   ---------------------------
dir /b "%~dp0" 2>nul
echo   ---------------------------
echo.
echo   Download full package:
echo   https://github.com/chenzai666/proxy-setup
echo.
echo   Or enter the full path to your proxy-setup folder:
echo.
set /p "FOLDER=  Path: "
if not defined FOLDER goto :done
set "FOLDER=%FOLDER:"=%"
call :is_absolute_path "%FOLDER%"
if errorlevel 1 (
    echo   Please enter an absolute path, for example: C:\proxy-setup
    goto :done
)
if "%FOLDER:~-1%"=="\" set "FOLDER=%FOLDER:~0,-1%"

if exist "%FOLDER%\setup_proxy.ps1" set "FOUND_PS=%FOLDER%\setup_proxy.ps1" & goto :found_ps
if exist "%FOLDER%\setup_proxy.py" set "FOUND_PY=%FOLDER%\setup_proxy.py" & goto :found_py

echo   Still not found.
goto :done

:found_ps
echo.
echo   [OK] Found PowerShell script: %FOUND_PS%
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%FOUND_PS%"
goto :done

:found_py
echo.
echo   [OK] Found Python script: %FOUND_PY%
echo.

REM ---- Check / Install Python ----

python --version >nul 2>&1
if not errorlevel 1 goto :py_ok

python3 --version >nul 2>&1
if not errorlevel 1 goto :py3_ok

echo   Python not found. Installing via winget...
echo.

winget --version >nul 2>&1
if errorlevel 1 goto :no_winget

winget install --id Python.Python.3.13 --exact --source winget --accept-package-agreements --accept-source-agreements --disable-interactivity
if errorlevel 1 goto :no_winget

echo.
echo   [OK] Python installed. Run this bat again.
goto :done

:no_winget
echo.
echo   Manual install: https://www.python.org/downloads/
echo   (Check "Add to PATH" during install)
goto :done

:py_ok
python --version
python "%FOUND_PY%"
goto :done

:py3_ok
python3 --version
python3 "%FOUND_PY%"

:done
echo.
pause
exit /b

:is_absolute_path
set "INPUT_PATH=%~1"
if "%INPUT_PATH:~0,2%"=="\\" exit /b 0
if "%INPUT_PATH:~1,1%"==":" if "%INPUT_PATH:~2,1%"=="\" exit /b 0
exit /b 1
