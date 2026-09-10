# Build linux/arm GOARM=7 static binary for reMarkable 2 (run on Windows).
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $Root
New-Item -ItemType Directory -Force -Path "dist" | Out-Null

$env:CGO_ENABLED = "0"
$env:GOOS = "linux"
$env:GOARCH = "arm"
$env:GOARM = "7"

go build -trimpath -ldflags "-s -w" -o "dist/rm2hwr-linux-armv7" ./cmd/rm2hwr
Write-Host "built dist/rm2hwr-linux-armv7"
Write-Host "scp dist/rm2hwr-linux-armv7 root@10.11.99.1:/home/root/hwr/bin/rm2hwr"
