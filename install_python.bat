@echo off
cd /d "%~dp0"

echo.
echo   ========================================
echo     Python 3 + Proxy Setup for Windows
echo   ========================================
echo.
echo   Script dir: %~dp0
echo.

REM --- Check if Python already installed ---
python --version >nul 2>&1
if not errorlevel 1 (
    python --version 2>&1
    echo.
    echo   [OK] Python is ready!
    echo   --------------------------------
    echo.
    set /p RUN="   Run proxy setup now? [Y/n] "
    if /i not "%RUN%"=="n" (
        python "%~dp0setup_proxy.py"
    )
    goto end
)

python3 --version >nul 2>&1
if not errorlevel 1 (
    python3 --version 2>&1
    echo.
    echo   [OK] Python is ready!
    echo   --------------------------------
    echo.
    set /p RUN="   Run proxy setup now? [Y/n] "
    if /i not "%RUN%"=="n" (
        python3 "%~dp0setup_proxy.py"
    )
    goto end
)

echo   [WARN] Python 3 not found.
echo.
echo   Trying to install via winget...

winget --version >nul 2>&1
if errorlevel 1 goto no_winget

echo   Downloading Python 3.13...
winget install Python.Python.3.13 --accept-package-agreements --accept-source-agreements --silent
if errorlevel 1 (
    echo   [ERR] winget install failed.
    goto end
)
echo   [OK] Installed!
echo.
echo   Refreshing PATH...
REM 刷新 PATH（从系统注册表重新读取）
for /f "tokens=2*" %%a in ('reg query "HKCU\Environment" /v Path 2^>nul') do set "UPath=%%b"
for /f "tokens=2*" %%a in ('reg query "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment" /v Path 2^>nul') do set "SPath=%%b"
set "PATH=%UPath%;%SPath%"
REM 把 Python 安装目录塞进当前 PATH（典型路径）
set "PATH=%LOCALAPPDATA%\Programs\Python\Python313;%LOCALAPPDATA%\Programs\Python\Python313\Scripts;%PATH%"
set "PATH=C:\Python313;C:\Python313\Scripts;%PATH%"

python --version >nul 2>&1
if not errorlevel 1 (
    echo   [OK] Python ready after install!
    echo.
    python "%~dp0setup_proxy.py"
    goto end
)

echo   Python installed but not in PATH yet.
echo   Please close this window and re-open terminal, then run:
echo       python "%~dp0setup_proxy.py"
goto end

:no_winget
echo   Winget not available.
echo   Opening Python download page...
start "" https://www.python.org/downloads/
echo.
echo   After install (check "Add Python to PATH!"), run:
echo       python "%~dp0setup_proxy.py"

:end
echo.
echo   Press any key to exit...
pause >nul
