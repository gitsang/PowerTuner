' ============================================================
'  PowerTuner launcher
'  Starts the PowerShell/WPF UI without showing a console window
' ============================================================
Dim fso, sh, baseDir, ps1, cmd
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")

baseDir = fso.GetParentFolderName(WScript.ScriptFullName)
ps1 = baseDir & "\PowerTuner.ps1"

If Not fso.FileExists(ps1) Then
    MsgBox "PowerTuner.ps1 not found in:" & vbCrLf & baseDir, 16, "PowerTuner"
    WScript.Quit 1
End If

cmd = "powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & ps1 & """"
sh.Run cmd, 0, False
