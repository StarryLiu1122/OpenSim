@echo off
setlocal
set "PSModulePath="
where pwsh.exe >nul 2>nul
if "%errorlevel%"=="0" (
    pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\Start-WorldModelDemo.ps1" %*
) else (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\Start-WorldModelDemo.ps1" %*
)
set "result=%errorlevel%"
if not "%result%"=="0" pause
exit /b %result%
