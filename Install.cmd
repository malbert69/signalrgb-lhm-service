@echo off
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-Service.ps1" -Elevate %*
set "installExitCode=%ERRORLEVEL%"
if "%installExitCode%"=="0" (
  echo Installation succeeded. Restart SignalRGB to load the temperature provider.
) else (
  echo Installation failed. Check installation-error.txt and installation.log in this folder.
)
exit /b %installExitCode%
