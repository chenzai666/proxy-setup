@echo off
setlocal EnableExtensions

set "SCRIPT_DIR=%~dp0"
set "LOCAL_PY=%SCRIPT_DIR%setup_proxy.py"
set "REMOTE_URL=https://raw.githubusercontent.com/chenzai666/proxy-setup/master/setup_proxy.py"
set "TMP_PY=%TEMP%\setup_proxy_%RANDOM%%RANDOM%.py"

if defined PROXY_SETUP_REMOTE_URL set "REMOTE_URL=%PROXY_SETUP_REMOTE_URL%"

echo.
echo ==========
echo   Windows CMD Proxy Setup
echo ==========
echo.

call :find_python
if not defined PYTHON_CMD (
    echo   [ERR] Python not found.
    echo.
    echo   Run install_python.bat from this repository first, or install Python from:
    echo   https://www.python.org/downloads/
    echo.
    exit /b 1
)

if exist "%LOCAL_PY%" (
    echo   [OK] Using local setup_proxy.py
    %PYTHON_CMD% "%LOCAL_PY%"
    exit /b %ERRORLEVEL%
)

echo   Local setup_proxy.py not found.
echo   Downloading: %REMOTE_URL%
echo.

where curl.exe >nul 2>nul
if not errorlevel 1 (
    curl.exe -fsSL "%REMOTE_URL%" -o "%TMP_PY%"
) else (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri '%REMOTE_URL%' -OutFile '%TMP_PY%'"
)

if not exist "%TMP_PY%" (
    echo.
    echo   [ERR] Failed to download setup_proxy.py
    exit /b 1
)

%PYTHON_CMD% "%TMP_PY%"
set "EXIT_CODE=%ERRORLEVEL%"
del "%TMP_PY%" >nul 2>nul
exit /b %EXIT_CODE%

:find_python
where py.exe >nul 2>nul
if not errorlevel 1 (
    set "PYTHON_CMD=py -3"
    exit /b 0
)

where python.exe >nul 2>nul
if not errorlevel 1 (
    set "PYTHON_CMD=python"
    exit /b 0
)

where python3.exe >nul 2>nul
if not errorlevel 1 (
    set "PYTHON_CMD=python3"
    exit /b 0
)

exit /b 0
