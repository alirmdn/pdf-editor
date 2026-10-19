@echo off
title PDF Editor for iPhone
rem Builds the engine and the app in WSL and installs it on the connected iPhone with xtool.
rem Other modes:  "Build iOS.bat" build   (compile only)   ipa   engine   xcode
rem Log: ios\build-ios.log  (send it to Claude if something fails)
set MODE=%1
if "%MODE%"=="" set MODE=dev
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ios\build-ios.ps1" %MODE%
echo.
pause
