@echo off
cd /d "%~dp0"
"C:\Program Files\nodejs\node.exe" scripts\configure-gmail-smtp.cjs
if errorlevel 1 pause
