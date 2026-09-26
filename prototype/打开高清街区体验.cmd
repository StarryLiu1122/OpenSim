@echo off
setlocal
set "PSModulePath="
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\Start-DelftPilot.ps1" -Directory "%~dp0runtime\polyhaven-street-v4" -Manifest "%~dp0fixtures\geodata\polyhaven-urban-apartment\street-manifest.json" -Label "Poly Haven 80m Street" -Port 20870 %*
set "result=%errorlevel%"
if not "%result%"=="0" pause
exit /b %result%
