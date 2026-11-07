@echo off
setlocal
cd /d "%~dp0launcher\payload"
where powershell.exe >nul 2>&1 || (echo Windows PowerShell 5.1 is required.& pause & exit /b 1)
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%CD%\Caelocord.ps1"
if errorlevel 1 pause
