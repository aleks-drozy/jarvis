# tests/stt.Tests.ps1 — voice input pipeline: local whisper must transcribe a known sample.
# Requires scripts/setup-whisper.ps1 to have run (CLI + model + jfk.wav in app/vendor/whisper).
$ErrorActionPreference = 'Stop'
function Assert($c,$m){ if(-not $c){ Write-Error "FAIL: $m"; exit 1 } }

$vendor = Join-Path $PSScriptRoot '..\app\vendor\whisper'
# whisper-cli.exe only: modern releases ship main.exe as a deprecation stub that exits 1
$exe    = Get-ChildItem $vendor -Recurse -Include 'whisper-cli.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
$model  = Get-ChildItem $vendor -Filter 'ggml-*.bin' -ErrorAction SilentlyContinue | Select-Object -First 1
$sample = Join-Path $vendor 'jfk.wav'

Assert ($null -ne $exe)    "whisper-cli.exe installed (run scripts/setup-whisper.ps1)"
Assert ($null -ne $model)  "ggml model installed (run scripts/setup-whisper.ps1)"
Assert (Test-Path $sample) "jfk.wav sample present (run scripts/setup-whisper.ps1)"

# whisper logs to stderr even on success; under -EA Stop that would read as failure. cmd /c merges it away.
$out = cmd /c "`"$($exe.FullName)`" -m `"$($model.FullName)`" -f `"$sample`" -nt -np 2>nul"
Assert (($out -join ' ') -match 'ask not what your country') "JFK sample transcribed correctly"
Write-Host "stt: ALL PASS"
