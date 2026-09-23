@echo off
setlocal
set "PSModulePath="
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\Start-DelftPilot.ps1" %*
if not "%errorlevel%"=="0" pause
