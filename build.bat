@echo off
setlocal
cd /d "%~dp0"

rem Two build flavours:
rem   build.bat        bin\vibetube.exe      shipped app, no console window
rem   build.bat dev    bin\vibetube-dev.exe  console build for --selftest/--demo
rem
rem -subsystem:windows  stops Windows attaching a console window to the app.
rem -resource           embeds assets\vibetube.ico so Explorer and taskbar
rem                     pinning show the icon; the live window icon is loaded
rem                     at runtime from assets\icon*.png, embedded via #load.

if not exist bin mkdir bin

if /i "%~1"=="dev" (
    odin build src -out:bin\vibetube-dev.exe -subsystem:console -resource:assets\vibetube.rc
    if errorlevel 1 goto failed
    del assets\vibetube.res >nul 2>&1
    echo built bin\vibetube-dev.exe
    exit /b 0
)

odin build src -out:bin\vibetube.exe -subsystem:windows -resource:assets\vibetube.rc
if errorlevel 1 goto failed
del assets\vibetube.res >nul 2>&1
echo built bin\vibetube.exe
exit /b 0

:failed
del assets\vibetube.res >nul 2>&1
echo build failed
exit /b 1
