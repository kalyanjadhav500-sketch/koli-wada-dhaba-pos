@echo off
cd /d "%~dp0"
"C:\Program Files\nodejs\node.exe" scripts\reset-owner-password.cjs
if errorlevel 1 pause
