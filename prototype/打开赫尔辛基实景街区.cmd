@echo off
setlocal
set "PSModulePath="
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\Start-DelftPilot.ps1" -Directory "%~dp0runtime\helsinki-kamppi-v3" -Manifest "%~dp0fixtures\geodata\helsinki-kamppi-textured\manifest.json" -Label Helsinki -Port 20820 %*
set "result=%errorlevel%"
if not "%result%"=="0" pause
exit /b %result%
