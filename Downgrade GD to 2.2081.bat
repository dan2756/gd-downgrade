@echo off
setlocal
title GD Downgrade
set "GDD_DIR=%~dp0"
rem PowerShell 7's module path breaks Windows PowerShell 5.1 when inherited; let 5.1 use its own.
set "PSModulePath="
if not exist "%GDD_DIR%gd-downgrade.ps1" goto notextracted
if not exist "%GDD_DIR%geode-sync.ps1" goto notextracted

rem Files from a downloaded zip are marked as "from the internet"; unblock them so PowerShell runs them.
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -LiteralPath $env:GDD_DIR -File | Unblock-File" >nul 2>&1

"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%GDD_DIR%gd-downgrade.ps1"
set "GDD_CODE=%errorlevel%"
if "%GDD_CODE%"=="0" exit /b 0
if "%GDD_CODE%"=="10" exit /b 10
echo.
echo GD Downgrade stopped unexpectedly (code %GDD_CODE%).
echo Take a screenshot of this window and open an issue at:
echo https://github.com/dan2756/gd-downgrade/issues
echo.
pause
exit /b %GDD_CODE%

:notextracted
echo GD Downgrade can't find its other files.
echo.
echo Unzip the whole download first (right-click the zip, Extract All),
echo then double-click this file from inside the unzipped folder.
echo.
pause
exit /b 1