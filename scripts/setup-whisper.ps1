# scripts/setup-whisper.ps1 - one-time fetch of whisper.cpp (local STT: no cloud, no keys).
# Installs CLI + model into app/vendor/whisper (gitignored). Re-run safe; skips what exists.
param([string]$Model = 'base.en')
$ErrorActionPreference = 'Stop'
$dest = Join-Path $PSScriptRoot '..\app\vendor\whisper'
New-Item -ItemType Directory -Force $dest | Out-Null
$dest = (Resolve-Path $dest).Path
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# 1) CLI binary from the latest GitHub release (asset *bin-x64*.zip)
$existing = Get-ChildItem $dest -Recurse -Include 'whisper-cli.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($existing) {
  "CLI already present: $($existing.FullName)"
} else {
  $rel = Invoke-RestMethod 'https://api.github.com/repos/ggerganov/whisper.cpp/releases/latest' -Headers @{ 'User-Agent' = 'jarvis-setup' }
  $asset = $rel.assets | Where-Object { $_.name -match 'bin-x64\.zip$' } | Select-Object -First 1
  if (-not $asset) { throw "no bin-x64 asset in release $($rel.tag_name)" }
  $zip = Join-Path $env:TEMP $asset.name
  Invoke-WebRequest $asset.browser_download_url -OutFile $zip
  Expand-Archive $zip -DestinationPath $dest -Force
  Remove-Item $zip
  $exe = Get-ChildItem $dest -Recurse -Include 'whisper-cli.exe' | Select-Object -First 1
  if (-not $exe) { throw 'no whisper CLI exe found in the release zip' }
  "CLI: $($exe.FullName) (release $($rel.tag_name))"
}

# 2) model (ggml-base.en ~142 MB: right accuracy/speed for short spoken commands on CPU)
$modelFile = Join-Path $dest "ggml-$Model.bin"
if (-not (Test-Path $modelFile)) {
  Invoke-WebRequest "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-$Model.bin" -OutFile $modelFile
}
"Model: $modelFile ($([math]::Round((Get-Item $modelFile).Length/1MB)) MB)"

# 3) known-good sample so the pipeline is testable without a microphone
$sample = Join-Path $dest 'jfk.wav'
if (-not (Test-Path $sample)) {
  Invoke-WebRequest 'https://github.com/ggerganov/whisper.cpp/raw/master/samples/jfk.wav' -OutFile $sample
}
"Sample: $sample"
"Done. Voice input is ready once the Jarvis app restarts."
