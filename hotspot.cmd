@echo off
setlocal
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0hotspot.ps1" %*
set "hotspot_exit=%errorlevel%"
if "%~1"=="" pause
exit /b %hotspot_exit%
