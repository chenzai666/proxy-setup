@echo off

echo.
echo ==========
echo  Python 3 Installer + Proxy Setup Launcher
echo ==========
echo.

set "FOUND="

REM ---- Find setup_proxy.py ----

REM 1) Same folder as this bat
if exist "%~dp0setup_proxy.py" set "FOUND=%~dp0setup_proxy.py" & goto :found_ok

REM 2) Parent folder
if exist "%~dp0..\setup_proxy.py" set "FOUND=%~dp0..\setup_proxy.py" & goto :found_ok

REM 3) Downloads
if exist "%USERPROFILE%\Downloads\setup_proxy.py" set "FOUND=%USERPROFILE%\Downloads\setup_proxy.py" & goto :found_ok
if exist "%USERPROFILE%\Downloads\proxy-setup\setup_proxy.py" set "FOUND=%USERPROFILE%\Downloads\proxy-setup\setup_proxy.py" & goto :found_ok
if exist "%USERPROFILE%\Downloads\proxy-setup-master\setup_proxy.py" set "FOUND=%USERPROFILE%\Downloads\proxy-setup-master\setup_proxy.py" & goto :found_ok
if exist "%USERPROFILE%\Downloads\proxy-setup-main\setup_proxy.py" set "FOUND=%USERPROFILE%\Downloads\proxy-setup-main\setup_proxy.py" & goto :found_ok

REM 4) Desktop
if exist "%USERPROFILE%\Desktop\proxy-setup\setup_proxy.py" set "FOUND=%USERPROFILE%\Desktop\proxy-setup\setup_proxy.py" & goto :found_ok
if exist "%USERPROFILE%\Desktop\proxy-setup-master\setup_proxy.py" set "FOUND=%USERPROFILE%\Desktop\proxy-setup-master\setup_proxy.py" & goto :found_ok

REM Not found
echo.
echo   setup_proxy.py not found.
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
if "%FOLDER:~-1%"=="\" set "FOLDER=%FOLDER:~0,-1%"

if exist "%FOLDER%\setup_proxy.py" set "FOUND=%FOLDER%\setup_proxy.py" & goto :found_ok

echo   Still not found.
goto :done

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
python "%FOUND%"
goto :done

:py3_ok
python3 --version
python3 "%FOUND%"

:done
echo.
pause
