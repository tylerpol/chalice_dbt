@echo off
setlocal
REM Double-clickable installer for Chalice Chat.
REM
REM Windows will not run a .ps1 file on double-click -- the default action for
REM .ps1 is "open in Notepad", deliberately. A .bat does run, so this wrapper
REM exists purely to hand off to scripts\install_windows.ps1.
REM
REM -ExecutionPolicy Bypass applies to this one invocation only and changes
REM nothing permanently on the machine.

cd /d "%~dp0"

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\install_windows.ps1" %*
set RC=%ERRORLEVEL%

echo.
if not "%RC%"=="0" (
    echo   Did not finish ^(exit code %RC%^). The messages above say why.
) else (
    echo   Finished. Double-click Start_Windows.bat to run the app.
)
echo.
pause
endlocal
