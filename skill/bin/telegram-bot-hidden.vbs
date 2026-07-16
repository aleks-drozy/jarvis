' Hidden launcher for telegram-bot.ps1, invoked by the "Jarvis Telegram Poller" scheduled task.
' Task Scheduler briefly flashes a console window when it launches powershell.exe directly, even with
' -WindowStyle Hidden. Routing through WScript.Shell.Run with window style 0 avoids that flash entirely.
Set objShell = CreateObject("WScript.Shell")
objShell.Run "powershell.exe -NoProfile -WindowStyle Hidden -File ""C:\Users\Alex\Projects\jarvis\skill\bin\telegram-bot.ps1"" -Once", 0, True
