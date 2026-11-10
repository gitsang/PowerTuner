@echo off
setlocal
cd /d "%~dp0"

echo ================================================
echo   PowerTuner  -  build (requires .NET SDK 8+)
echo ================================================
echo.

where dotnet >nul 2>nul
if errorlevel 1 goto nodotnet

dotnet build src\PowerTuner\PowerTuner.csproj -c Release -o dist
if errorlevel 1 goto buildfail

echo.
echo [OK] Output: %~dp0dist\PowerTuner.exe
echo.
pause
exit /b 0

:nodotnet
echo [ERROR] .NET SDK not found.
echo.
echo   This project targets net48 WPF and needs the .NET SDK to compile
echo   (the SDK supplies the MSBuild targets that compile XAML).
echo.
echo   Install with one command:
echo       winget install Microsoft.DotNet.SDK.8
echo.
echo   Then reopen this window and run this file again.
echo   Alternatively, just push to GitHub: the Actions workflow builds it.
echo.
pause
exit /b 1

:buildfail
echo.
echo [ERROR] Build failed. See messages above.
echo.
pause
exit /b 1
