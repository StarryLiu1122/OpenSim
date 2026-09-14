@echo off
setlocal
rem Avoid inheriting PowerShell 7 modules through a CMD parent process.
set "PSModulePath="
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\Start-RegionLab.ps1" %*
set "launchExit=%errorlevel%"
if not "%launchExit%"=="0" pause
exit /b %launchExit%
