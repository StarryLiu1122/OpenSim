@echo off
setlocal
set "PSModulePath="
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\Start-DelftPilot.ps1" -Directory "%~dp0runtime\polyhaven-urban-apartment-v2" -Manifest "%~dp0fixtures\geodata\polyhaven-urban-apartment\manifest.json" -Label "Poly Haven Apartment" -Port 20840 %*
set "result=%errorlevel%"
if not "%result%"=="0" pause
exit /b %result%
