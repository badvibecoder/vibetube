@echo off
setlocal
cd /d "%~dp0"

rem Two build flavours:
rem   build.bat        bin\vibetube.exe        shipped app, no console window
rem   build.bat dev    _dev\vibetube-dev.exe  console build for --selftest/--demo
rem
rem bin\ is production only. The dev build is a throwaway console binary and
rem lives in _dev\, which .gitignore already excludes.
rem
rem -subsystem:windows  stops Windows attaching a console window to the app.
rem -resource           embeds assets\vibetube.ico so Explorer and taskbar
rem                     pinning show the icon; the live window icon is loaded
rem                     at runtime from assets\icon*.png, embedded via #load.

if /i "%~1"=="dev" (
    if not exist _dev mkdir _dev
    odin build src -out:_dev\vibetube-dev.exe -subsystem:console -resource:assets\vibetube.rc
    if errorlevel 1 goto failed
    del assets\vibetube.res >nul 2>&1
    echo built _dev\vibetube-dev.exe
    exit /b 0
)

if not exist bin mkdir bin
odin build src -out:bin\vibetube.exe -subsystem:windows -resource:assets\vibetube.rc
if errorlevel 1 goto failed
del assets\vibetube.res >nul 2>&1
echo built bin\vibetube.exe
exit /b 0

:failed
del assets\vibetube.res >nul 2>&1
echo build failed
exit /b 1
