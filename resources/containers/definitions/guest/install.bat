@echo off
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File C:\OEM\Install-WindowsBase.ps1
exit /b %ERRORLEVEL%
