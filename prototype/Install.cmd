@echo off
setlocal
rem Let Windows PowerShell build its own compatible module search path.
set "PSModulePath="
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\Install-Godot.ps1" %*
set "installExit=%errorlevel%"
if not "%installExit%"=="0" pause
exit /b %installExit%
