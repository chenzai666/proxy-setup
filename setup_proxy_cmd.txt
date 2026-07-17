@echo off
setlocal EnableExtensions

set "SCRIPT_DIR=%~dp0"
set "LOCAL_PS1=%SCRIPT_DIR%setup_proxy.ps1"
set "RAW_REMOTE_URL=https://raw.githubusercontent.com/chenzai666/proxy-setup/master/setup_proxy.ps1"
set "CDN_REMOTE_URL=https://cdn.jsdelivr.net/gh/chenzai666/proxy-setup@master/setup_proxy.ps1"
set "REMOTE_URL=%RAW_REMOTE_URL%"

if defined PROXY_SETUP_REMOTE_URL (
    if /I "%PROXY_SETUP_REMOTE_URL%"=="%RAW_REMOTE_URL%" (
        set "REMOTE_URL=%RAW_REMOTE_URL%"
    ) else if /I "%PROXY_SETUP_REMOTE_URL%"=="%CDN_REMOTE_URL%" (
        set "REMOTE_URL=%CDN_REMOTE_URL%"
    ) else (
        echo [ERR] PROXY_SETUP_REMOTE_URL only accepts the built-in GitHub or jsDelivr URL.
        exit /b 2
    )
)
if /I "%PROXY_SETUP_USE_CDN%"=="1" set "REMOTE_URL=%CDN_REMOTE_URL%"
if "%~1"=="" goto :source_selected
if /I "%~1"=="--cdn" if "%~2"=="" (
    set "REMOTE_URL=%CDN_REMOTE_URL%"
    goto :source_selected
)
echo [ERR] Unknown argument. Use --cdn or no argument.
exit /b 2

:source_selected

echo.
echo ==========
echo   Windows CMD Proxy Setup
echo ==========
echo.

if exist "%LOCAL_PS1%" (
    echo   [OK] Using local setup_proxy.ps1
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%LOCAL_PS1%"
    exit /b %ERRORLEVEL%
)

echo   Local setup_proxy.ps1 not found.
echo   Downloading: %REMOTE_URL%
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$u='%REMOTE_URL%';$p=Join-Path $env:TEMP ('proxy-setup-'+[guid]::NewGuid().ToString('N')+'.ps1');try{[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12;Invoke-WebRequest -UseBasicParsing -Uri $u -OutFile $p;& $p;exit $LASTEXITCODE}finally{Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue}"
exit /b %ERRORLEVEL%
