@echo off
title Fix Telegram (Windhawk + font cache)

net session >nul 2>&1
if not %errorlevel%==0 (
    echo.
    echo   Administrator rights required - relaunching elevated...
    echo.
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Fix-Telegram-Windhawk.ps1" %*
echo.
echo   Done. You can close this window.
timeout /t 6 >nul
exit /b