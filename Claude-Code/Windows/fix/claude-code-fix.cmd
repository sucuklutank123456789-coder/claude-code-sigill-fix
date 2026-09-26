@echo off
rem Runs claude-code-fix.ps1 without changing the PowerShell execution policy.
rem Double-click it for the menu, or pass the same arguments as to the .ps1:
rem   claude-code-fix.cmd 5
rem   claude-code-fix.cmd -Restore 5
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0claude-code-fix.ps1" %*
set "rc=%errorlevel%"
if "%~1"=="" pause
exit /b %rc%
