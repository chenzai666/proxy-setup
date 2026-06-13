@echo off
cd /d "%~dp0"

echo.
echo ==========
echo  Python 3 Installer
echo ==========
echo.

REM Check python
python --version >nul 2>&1
if not errorlevel 1 goto PYTHON_OK

python3 --version >nul 2>&1
if not errorlevel 1 goto PYTHON3_OK

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
echo.
echo  Please RE-OPEN terminal and run this bat again,
echo  or run:  python setup_proxy.py
goto DONE

:NO_WINGET
echo  winget not found.
goto MANUAL

:MANUAL
echo.
echo  Manual install: https://www.python.org/downloads/
echo  (Check "Add Python to PATH" box!)
goto DONE

:PYTHON_OK
python --version
echo.
echo  Python is ready.
echo.
if exist "%~dp0setup_proxy.py" (
    echo  Starting proxy setup...
    echo.
    timeout /t 1 >nul
    python "%~dp0setup_proxy.py"
    goto DONE
)
if exist "%~dp0setup_proxy.ps1" (
    echo  Starting proxy setup...
    echo.
    timeout /t 1 >nul
    powershell -ExecutionPolicy Bypass -File "%~dp0setup_proxy.ps1"
    goto DONE
)
echo  Run proxy setup:
echo    python setup_proxy.py
echo    (download from https://github.com/chenzai666/proxy-setup)
goto DONE

:PYTHON3_OK
python3 --version
echo.
echo  Python is ready.
echo.
if exist "%~dp0setup_proxy.py" (
    echo  Starting proxy setup...
    echo.
    timeout /t 1 >nul
    python3 "%~dp0setup_proxy.py"
    goto DONE
)
if exist "%~dp0setup_proxy.ps1" (
    echo  Starting proxy setup...
    echo.
    timeout /t 1 >nul
    powershell -ExecutionPolicy Bypass -File "%~dp0setup_proxy.ps1"
    goto DONE
)
echo  Run proxy setup:
echo    python3 setup_proxy.py
echo    (download from https://github.com/chenzai666/proxy-setup)
goto DONE

:DONE
echo.
echo  Press any key to close...
pause
