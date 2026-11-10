@echo off
setlocal
set "DIR=%~dp0"
if "%DIR:~-1%"=="\" set "DIR=%DIR:~0,-1%"

if exist "%DIR%\PowerTuner.exe" goto useexe
if exist "%DIR%\Start-PowerTuner.vbs" goto usevbs
echo [ERROR] Neither PowerTuner.exe nor Start-PowerTuner.vbs found.
echo         Directory: %DIR%
echo.
pause
exit /b 1

:useexe
set "TARGET=%DIR%\PowerTuner.exe"
set "ICON=%DIR%\PowerTuner.exe,0"
goto make

:usevbs
set "TARGET=%DIR%\Start-PowerTuner.vbs"
set "ICON=%SystemRoot%\System32\powercpl.dll,0"

:make
echo Target: %TARGET%
powershell -NoProfile -ExecutionPolicy Bypass -Command "$d=[Environment]::GetFolderPath('Desktop'); $p=Join-Path $d 'PowerTuner.lnk'; $s=(New-Object -ComObject WScript.Shell).CreateShortcut($p); $s.TargetPath='%TARGET%'; $s.WorkingDirectory='%DIR%'; $s.IconLocation='%ICON%'; $s.Description='PowerTuner'; $s.Save(); Write-Host ''; Write-Host ('Shortcut created on Desktop: ' + $p)"
echo.
pause
exit /b 0
