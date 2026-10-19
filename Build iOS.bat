@echo off
rem Build PDF Editor for iPhone and install it with xtool (runs ios/build-ios.sh inside WSL).
rem Run it as  "Build iOS.bat" --ipa  to only produce a .ipa file.
cd /d "%~dp0"
wsl --cd "%~dp0." bash ios/build-ios.sh %*
echo.
pause
