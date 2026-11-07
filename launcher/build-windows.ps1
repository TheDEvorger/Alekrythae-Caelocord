# Build a native single-file Windows executable from sources.
# Prerequisites: Go 1.23+, Python 3 (for regenerating icon resource).
# Default: the app and artwork are embedded, FFmpeg is consent-downloaded if missing.
# Bundled: put a licensed Windows ffmpeg.exe in payload\ and pass -BundleFFmpeg.
param([switch]$BundleFFmpeg)
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
python ..\tools\make_icon_syso.py '.\Cælōcord.ico' '.\icon_windows_amd64.syso'
$env:GOOS = 'windows'; $env:GOARCH = 'amd64'; $env:CGO_ENABLED = '0'
$tags = @()
if ($BundleFFmpeg) {
  if (!(Test-Path '.\payload\ffmpeg.exe')) { throw 'Missing payload\ffmpeg.exe. Supply a legally distributable Windows FFmpeg binary.' }
  $tags = @('-tags', 'bundled_ffmpeg')
}
New-Item -ItemType Directory -Force '..\..\Release' | Out-Null
& go build @tags -trimpath -ldflags '-H windowsgui -s -w' -o '..\..\Release\Cælōcord.exe' .
if ($LASTEXITCODE -ne 0) { throw 'Go build failed.' }
Write-Host 'Built: Release\Cælōcord.exe'
