@echo off
rem Media Info Report - double-click to start it.
rem Each time, this makes (or refreshes) the Media Info Report shortcut in this folder and in the Start menu,
rem then starts Media Info Report from it. After the first run you can use the shortcut, the Start menu or
rem a pinned taskbar button instead: they start Media Info Report without a console window.
rem The execution-policy bypass applies to Media Info Report's own run only; no Windows settings are changed.
rem If Media Info Report doesn't open, run   "Media Info Report.cmd" debug   to start it in this window and see any errors.
setlocal
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if /i "%~1"=="debug" (
    "%PS%" -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0Media-Info-Report.ps1"
    pause
    exit /b
)
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0New-MediaInfoReportShortcut.ps1" -Launch
if errorlevel 1 pause
