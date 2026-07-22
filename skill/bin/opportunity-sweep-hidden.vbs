' opportunity-sweep-hidden.vbs - launches check-opportunities.ps1 with NO console flash.
' Same trick as telegram-bot-hidden.vbs: WScript.Shell.Run with window style 0. Self-locates its
' sibling .ps1 so the installed copy runs, not a repo checkout.
Set fso = CreateObject("Scripting.FileSystemObject")
here = fso.GetParentFolderName(WScript.ScriptFullName)
ps1 = fso.BuildPath(here, "check-opportunities.ps1")
Set sh = CreateObject("WScript.Shell")
sh.Run "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File """ & ps1 & """", 0, False
