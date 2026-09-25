@echo off
setlocal
REM Double-clickable Windows bootstrap for RemarkableMyscriptLocal v1.0.1
title RemarkableMyscriptLocal v1.0.1 installer
echo ============================================================
echo  RemarkableMyscriptLocal one-liner install (v1.0.1)
echo ============================================================
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$f=$env:TEMP+'\install-from-web.ps1'; Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/schraederbr/RemarkableMyscriptLocal/v1.0.1/scripts/install-from-web.ps1' -OutFile $f -UseBasicParsing; powershell.exe -NoProfile -ExecutionPolicy Bypass -File $f"
set ERR=%ERRORLEVEL%
echo.
if not "%ERR%"=="0" (
  echo ERROR: installer exited with code %ERR%
  pause
  exit /b %ERR%
)
echo OK  Finished
pause
