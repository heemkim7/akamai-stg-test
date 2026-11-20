@echo off
if "%~1"=="" (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Test-AkamaiStaging.ps1" -OpenReport
) else (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Test-AkamaiStaging.ps1" %*
)
set ERR=%ERRORLEVEL%
echo.
pause
exit /b %ERR%
