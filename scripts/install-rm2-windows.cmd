@echo off
setlocal
REM Double-clickable Windows bootstrap for RemarkableMyscriptLocal v0.3.9
title RemarkableMyscriptLocal v0.3.9 installer
echo ============================================================
echo  RemarkableMyscriptLocal one-liner install (v0.3.9)
echo ============================================================
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$f=$env:TEMP+'\install-from-web.ps1'; Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/schraederbr/RemarkableMyscriptLocal/v0.3.9/scripts/install-from-web.ps1' -OutFile $f -UseBasicParsing; powershell.exe -NoProfile -ExecutionPolicy Bypass -File $f"
set ERR=%ERRORLEVEL%
echo.
if not "%ERR%"=="0" (
  echo ERROR: installer exited with code %ERR%
  pause
  exit /b %ERR%
)
echo OK  Finished
pause
