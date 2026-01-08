@echo off
REM Stoplight Control Launcher - Pure BAT solution

REM Use PowerShell to start the GUI script hidden without showing console
powershell.exe -WindowStyle Hidden -Command "& {Start-Process powershell.exe -ArgumentList '-WindowStyle Hidden -ExecutionPolicy Bypass -File \"%~dp0Stoplight-Control.ps1\"' -WindowStyle Hidden}"
exit

