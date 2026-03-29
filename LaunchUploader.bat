@echo off
TITLE Mod.io Multipart Uploader
echo Starting Mod.io PowerShell Uploader...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0UploadMods.ps1"
echo.
pause