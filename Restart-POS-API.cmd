@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\restart-pos-api.ps1"
if errorlevel 1 pause
