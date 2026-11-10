@echo off
setlocal
cd /d "%~dp0"

echo ================================================
echo   PowerTuner  -  build single-file exe
echo ================================================
echo.

set "CSC=%SystemRoot%\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if not exist "%CSC%" set "CSC=%SystemRoot%\Microsoft.NET\Framework\v4.0.30319\csc.exe"
if not exist "%CSC%" goto nocsc

if exist "build\app.ico" goto haveicon
echo [*] generating icon ...
powershell -NoProfile -ExecutionPolicy Bypass -File "build\Make-Icon.ps1"
:haveicon

echo [*] compiling PowerTuner.exe ...
"%CSC%" /nologo /target:winexe /platform:anycpu /optimize+ /out:PowerTuner.exe /win32icon:build\app.ico /resource:PowerTuner.ps1,PowerTuner.ps1 /resource:PowerTuner.Core.ps1,PowerTuner.Core.ps1 /resource:MainWindow.xaml,MainWindow.xaml /resource:Theme.xaml,Theme.xaml /resource:Unhide-PowerSettings.ps1,Unhide-PowerSettings.ps1 build\Launcher.cs

if errorlevel 1 goto buildfail
if not exist "PowerTuner.exe" goto buildfail

echo.
echo [OK] Built: %~dp0PowerTuner.exe
echo.
echo From now on just double-click PowerTuner.exe.
echo The .vbs launcher is no longer needed (but still works).
echo If you edit the scripts later, run this file again to rebuild.
echo.
pause
exit /b 0

:nocsc
echo [ERROR] .NET Framework 4.x compiler not found.
echo         Looked for csc.exe under Microsoft.NET\Framework64 and Framework.
echo         Normal Windows 10/11 includes it; trimmed images may not.
echo         You can still start the app with Start-PowerTuner.vbs
echo.
pause
exit /b 1

:buildfail
echo.
echo [ERROR] Build failed. Please copy the messages above.
echo         Meanwhile you can still use Start-PowerTuner.vbs
echo.
pause
exit /b 1
