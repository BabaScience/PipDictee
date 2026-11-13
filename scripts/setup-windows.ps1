# Pip Dictée — Windows setup: downloads whisper.cpp and the Whisper model, and checks every file's SHA-256
# before using it. Nothing is run from the download until its hash matches.
#   powershell -ExecutionPolicy Bypass -File scripts\setup-windows.ps1            (CPU build)
#   powershell -ExecutionPolicy Bypass -File scripts\setup-windows.ps1 -Cuda      (NVIDIA GPU, much faster)
param([switch]$Cuda)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$WhisperVersion = 'v1.8.4'
$Bins = if ($Cuda) {
  @{ Name = 'whisper-cublas-12.4.0-bin-x64.zip'; Sha = 'b07cff4e59831b227896018facbb6334907bf324a342c84597c44f087823d252' }
} else {
  @{ Name = 'whisper-bin-x64.zip'; Sha = '74f973345cb52ef5ba3ec9e7e7af8e48cc8c71722d1528603b80588a11f82e3e' }
}
$Models = @(
  @{ Name = 'ggml-large-v3-turbo.bin'; Url = 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin'
     Sha = '1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69' },
  @{ Name = 'ggml-silero-v5.1.2.bin'; Url = 'https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin'
     Sha = '29940d98d42b91fbd05ce489f3ecf7c72f0a42f027e4875919a28fb4c04ea2cf' }
)

$Root = Join-Path $env:LOCALAPPDATA 'Pip Dictée'
$BinDir = Join-Path $Root 'bin'
$ModelDir = Join-Path $Root 'models'
New-Item -ItemType Directory -Force -Path $BinDir, $ModelDir | Out-Null

function Get-Verified([string]$Url, [string]$Dest, [string]$Sha) {
  if ((Test-Path $Dest) -and ((Get-FileHash $Dest -Algorithm SHA256).Hash -eq $Sha.ToUpper())) {
    Write-Host "OK (already there): $(Split-Path $Dest -Leaf)"; return
  }
  $tmp = "$Dest.part"
  Write-Host "Downloading $(Split-Path $Dest -Leaf)…"
  Invoke-WebRequest -Uri $Url -OutFile $tmp -UseBasicParsing
  $got = (Get-FileHash $tmp -Algorithm SHA256).Hash
  if ($got -ne $Sha.ToUpper()) {
    Remove-Item $tmp -Force
    throw "SHA-256 mismatch for $Url`n expected $Sha`n got      $got`nThe file was deleted. Do not use it."
  }
  Move-Item -Force $tmp $Dest
  Write-Host "OK (verified): $(Split-Path $Dest -Leaf)"
}

# whisper.cpp executables
$zip = Join-Path $env:TEMP $Bins.Name
Get-Verified "https://github.com/ggml-org/whisper.cpp/releases/download/$WhisperVersion/$($Bins.Name)" $zip $Bins.Sha
$unz = Join-Path $env:TEMP 'pip-dictee-whisper'
Remove-Item -Recurse -Force $unz -ErrorAction SilentlyContinue
Expand-Archive $zip -DestinationPath $unz
Get-ChildItem $unz -Recurse -Include *.exe, *.dll | Copy-Item -Destination $BinDir -Force
Remove-Item -Recurse -Force $unz, $zip
if (-not (Test-Path (Join-Path $BinDir 'whisper-server.exe'))) { throw 'whisper-server.exe not found in the archive.' }

# Models
foreach ($m in $Models) { Get-Verified $m.Url (Join-Path $ModelDir $m.Name) $m.Sha }

Write-Host "`nReady. whisper.cpp: $BinDir`nModels:    $ModelDir`nStart PipDictee.exe."
