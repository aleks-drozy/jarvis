' app-hidden.vbs - launches the Electron desktop app with NO console flash.
' Same trick as telegram-bot-hidden.vbs: WScript.Shell.Run with window style 0.
' Arg 0 = the app directory (baked in by scripts/register-app-autostart.ps1 from config.app_dir);
' taking it as an argument keeps this launcher personal-value-free on a stranger's clone.
If WScript.Arguments.Count < 1 Then WScript.Quit 1
Set sh = CreateObject("WScript.Shell")
sh.CurrentDirectory = WScript.Arguments(0)
sh.Run "cmd /c npm start", 0, False
