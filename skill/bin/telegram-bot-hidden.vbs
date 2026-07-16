' Hidden launcher for telegram-bot.ps1, invoked by the "Jarvis Telegram Poller" scheduled task.
' Task Scheduler briefly flashes a console window when it launches powershell.exe directly, even with
' -WindowStyle Hidden. Routing through WScript.Shell.Run with window style 0 avoids that flash entirely.
' SELF-LOCATING: telegram-bot.ps1 lives in the same directory as this launcher (wherever the skill is
' installed), so no path is hardcoded and a fork works unchanged.
Set objShell = CreateObject("WScript.Shell")
Set objFSO = CreateObject("Scripting.FileSystemObject")
botPath = objFSO.GetParentFolderName(WScript.ScriptFullName) & "\telegram-bot.ps1"
objShell.Run "powershell.exe -NoProfile -WindowStyle Hidden -File """ & botPath & """ -Once", 0, True
