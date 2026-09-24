@echo off
setlocal
set "PSModulePath="
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\Start-DelftPilot.ps1" %*
set "result=%errorlevel%"
if not "%result%"=="0" pause
exit /b %result%
