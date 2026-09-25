@echo off
setlocal
set "PSModulePath="
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\Start-DelftPilot.ps1" -Directory "%~dp0runtime\helsinki-kamppi-v7-250m" -Manifest "%~dp0fixtures\geodata\helsinki-kamppi-250m\manifest.json" -Label "Helsinki 250m" -Port 20830 %*
set "result=%errorlevel%"
if not "%result%"=="0" pause
exit /b %result%
