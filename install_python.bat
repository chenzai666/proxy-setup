@echo off

echo.
echo ==========
echo  Python 3 Installer + Proxy Setup Launcher
echo ==========
echo.

set "FOUND="

REM ---- Find setup_proxy files ----

REM 1) Same folder as this bat
if exist "%~dp0setup_proxy.py"  set "FOUND=%~dp0setup_proxy.py"  & goto :found
if exist "%~dp0setup_proxy.ps1" set "FOUND=%~dp0setup_proxy.ps1" & goto :found

REM 2) Parent folder (common when bat is in a subfolder)
if exist "%~dp0..\setup_proxy.py"  set "FOUND=%~dp0..\setup_proxy.py"  & goto :found
if exist "%~dp0..\setup_proxy.ps1" set "FOUND=%~dp0..\setup_proxy.ps1" & goto :found

REM 3) Known paths
if exist "C:\Users\tt\WorkBuddy\Claw\setup_proxy.py"  set "FOUND=C:\Users\tt\WorkBuddy\Claw\setup_proxy.py"  & goto :found
if exist "C:\Users\tt\WorkBuddy\Claw\setup_proxy.ps1" set "FOUND=C:\Users\tt\WorkBuddy\Claw\setup_proxy.ps1" & goto :found

REM 4) Downloads (where user downloads ZIPs)
if exist "%USERPROFILE%\Downloads\proxy-setup\setup_proxy.py"  set "FOUND=%USERPROFILE%\Downloads\proxy-setup\setup_proxy.py"  & goto :found
if exist "%USERPROFILE%\Downloads\proxy-setup\setup_proxy.ps1" set "FOUND=%USERPROFILE%\Downloads\proxy-setup\setup_proxy.ps1" & goto :found
if exist "%USERPROFILE%\Downloads\proxy-setup-main\setup_proxy.py"  set "FOUND=%USERPROFILE%\Downloads\proxy-setup-main\setup_proxy.py"  & goto :found
if exist "%USERPROFILE%\Downloads\proxy-setup-main\setup_proxy.ps1" set "FOUND=%USERPROFILE%\Downloads\proxy-setup-main\setup_proxy.ps1" & goto :found
if exist "%USERPROFILE%\Downloads\proxy-setup-master\setup_proxy.py"  set "FOUND=%USERPROFILE%\Downloads\proxy-setup-master\setup_proxy.py"  & goto :found
if exist "%USERPROFILE%\Downloads\proxy-setup-master\setup_proxy.ps1" set "FOUND=%USERPROFILE%\Downloads\proxy-setup-master\setup_proxy.ps1" & goto :found

REM 5) Desktop
if exist "%USERPROFILE%\Desktop\proxy-setup\setup_proxy.py"  set "FOUND=%USERPROFILE%\Desktop\proxy-setup\setup_proxy.py"  & goto :found
if exist "%USERPROFILE%\Desktop\proxy-setup\setup_proxy.ps1" set "FOUND=%USERPROFILE%\Desktop\proxy-setup\setup_proxy.ps1" & goto :found

REM Not found
:found
if defined FOUND goto :found_ok

echo.
echo   setup_proxy files not found.
echo.
echo   Contents of this folder:
echo   ---------------------------
dir /b "%~dp0" 2>nul
echo   ---------------------------
echo.
echo   Paste the full path to your proxy-setup folder:
echo.
set /p "FOLDER=  Path: "
if not defined FOLDER goto :notfound
if "%FOLDER:~-1%"=="\" set "FOLDER=%FOLDER:~0,-1%"

if exist "%FOLDER%\setup_proxy.py"  set "FOUND=%FOLDER%\setup_proxy.py"  & goto :found_ok
if exist "%FOLDER%\setup_proxy.ps1" set "FOUND=%FOLDER%\setup_proxy.ps1" & goto :found_ok

echo   Still not found.
goto :notfound

:found_ok
echo.
echo   [OK] Found: %FOUND%
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

winget install Python.Python.3.13 --accept-package-agreements --accept-source-agreements
if errorlevel 1 goto :no_winget

echo.
echo   [OK] Python installed. Run this bat again.
goto :done

:no_winget
echo.
echo   Manual install: https://www.python.org/downloads/
echo   (Check "Add to PATH" during install)
goto :done

:notfound
echo.
echo   Download full package:
echo   https://github.com/chenzai666/proxy-setup
goto :done

:py_ok
python --version
echo %FOUND% | find ".py" >nul
if not errorlevel 1 (
    python "%FOUND%"
) else (
    powershell -ExecutionPolicy Bypass -File "%FOUND%"
)
goto :done

:py3_ok
python3 --version
echo %FOUND% | find ".py" >nul
if not errorlevel 1 (
    python3 "%FOUND%"
) else (
    powershell -ExecutionPolicy Bypass -File "%FOUND%"
)

:done
echo.
pause
