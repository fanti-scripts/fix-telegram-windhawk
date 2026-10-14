@echo off
title Diagnose - Telegram / Windhawk

net session >nul 2>&1
if not %errorlevel%==0 (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Fix-Telegram-Windhawk.ps1" -Diagnose
exit /b