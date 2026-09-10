@echo off
setlocal
REM Double-clickable Windows bootstrap for RemarkableMyscriptLocal v0.3.3
title RemarkableMyscriptLocal v0.3.3 installer
echo ============================================================
echo  RemarkableMyscriptLocal one-liner install (v0.3.3)
echo ============================================================
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/schraederbr/RemarkableMyscriptLocal/v0.3.3/scripts/install-from-web.ps1 | iex"
set ERR=%ERRORLEVEL%
echo.
if not "%ERR%"=="0" (
  echo ERROR: installer exited with code %ERR%
  pause
  exit /b %ERR%
)
echo OK  Finished
pause