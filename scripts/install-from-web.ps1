<#
.SYNOPSIS
  One-liner Windows bootstrap: download RemarkableMyscriptLocal release + assets, then run install-rm2-stack.ps1.

.DESCRIPTION
  Intended for:
    powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/schraederbr/RemarkableMyscriptLocal/v0.3.0/scripts/install-from-web.ps1 | iex"

  Defaults (override via env):
    RELEASE_TAG / RM2_RELEASE_TAG = v0.3.0
    HOST                           = 10.11.99.1

  Prerequisites (printed up front):
    - USB cable (or set HOST to Wi-Fi IP)
    - reMarkable SSH password
    - MyScript APP_KEY (HMAC_KEY optional)
    - Joplin Cloud email + password
    - Tablet Wi-Fi with internet (Joplin Cloud + MyScript)
#>
$ErrorActionPreference = "Stop"

function Info($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Ok($msg) { Write-Host "OK  $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "!!  $msg" -ForegroundColor Yellow }

$ReleaseTag = $env:RELEASE_TAG
if (-not $ReleaseTag) { $ReleaseTag = $env:RM2_RELEASE_TAG }
if (-not $ReleaseTag) { $ReleaseTag = "v0.3.0" }

$HostName = $env:HOST
if (-not $HostName) { $HostName = "10.11.99.1" }

$RepoOwner = "schraederbr"
$RepoName = "RemarkableMyscriptLocal"
$ReleaseBase = "https://github.com/$RepoOwner/$RepoName/releases/download/$ReleaseTag"
$ZipUrl = "https://github.com/$RepoOwner/$RepoName/archive/refs/tags/$ReleaseTag.zip"

$OfflineName = "jonobones-rm2-npm-offline-0.1.5-joplin-3.7.1.tar.gz"
$NodeTarName = "node-v20.20.2-linux-armv7l.tar.xz"
$BinaryName = "rm2hwr-linux-armv7"
$SqliteName = "node_sqlite3.node"

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " RemarkableMyscriptLocal one-liner install ($ReleaseTag)" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Have these ready BEFORE continuing:"
Write-Host "  1) USB cable to the reMarkable 2 (default host $HostName)"
Write-Host "     Or set env HOST=<tablet-wifi-ip> before running."
Write-Host "  2) reMarkable SSH password (Settings -> Help -> Copyrights and licenses)"
Write-Host "  3) MyScript APP_KEY (HMAC_KEY optional) from https://developer.myscript.com/"
Write-Host "  4) Joplin Cloud email + password"
Write-Host "  5) Tablet Wi-Fi ON with internet (Joplin Cloud sync + MyScript)"
Write-Host ""
Write-Host "This script downloads release source + assets over HTTPS (no gh CLI required),"
Write-Host "then runs install-rm2-stack.ps1 -SkipBuild so Go is not required."
Write-Host ""

$destRoot = Join-Path $env:USERPROFILE "RemarkableMyscriptLocal-$ReleaseTag"
$zipPath = Join-Path $env:TEMP "RemarkableMyscriptLocal-$ReleaseTag.zip"
$extractParent = Join-Path $env:TEMP "RemarkableMyscriptLocal-extract-$ReleaseTag"

function Get-HttpsFile([string]$Url, [string]$OutFile) {
  $dir = Split-Path -Parent $OutFile
  if ($dir -and -not (Test-Path $dir)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
  }
  Info "Downloading $Url"
  $prev = $ProgressPreference
  $ProgressPreference = "SilentlyContinue"
  try {
    Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing
  } finally {
    $ProgressPreference = $prev
  }
  if (-not (Test-Path $OutFile) -or (Get-Item $OutFile).Length -lt 100) {
    throw "Download failed or too small: $OutFile from $Url"
  }
  Ok ("Saved {0} ({1:N0} bytes)" -f $OutFile, (Get-Item $OutFile).Length)
}

# --- source zip ---
Info "Fetching source zip for $ReleaseTag"
if (Test-Path $extractParent) { Remove-Item -Recurse -Force $extractParent }
New-Item -ItemType Directory -Force -Path $extractParent | Out-Null
Get-HttpsFile $ZipUrl $zipPath

Info "Expanding source to $destRoot"
if (Test-Path $destRoot) {
  Warn "Removing existing $destRoot"
  Remove-Item -Recurse -Force $destRoot
}
Expand-Archive -Path $zipPath -DestinationPath $extractParent -Force
# GitHub zip layout: RemarkableMyscriptLocal-<tag-without-v-or-with>/
$inner = Get-ChildItem $extractParent -Directory | Select-Object -First 1
if (-not $inner) { throw "Zip expand produced no directory under $extractParent" }
Move-Item -Path $inner.FullName -Destination $destRoot
Ok "Source ready at $destRoot"

$distDir = Join-Path $destRoot "dist"
New-Item -ItemType Directory -Force -Path $distDir | Out-Null
$revcordDir = Join-Path $destRoot "third_party\revcord"
New-Item -ItemType Directory -Force -Path $revcordDir | Out-Null

# --- release assets (HTTPS; no gh) ---
$assets = @(
  @{ Name = $BinaryName;  MinSize = 100000 }
  @{ Name = $OfflineName; MinSize = 1000000 }
  @{ Name = $NodeTarName; MinSize = 1000000 }
  @{ Name = $SqliteName;  MinSize = 100000 }
)

foreach ($a in $assets) {
  $out = Join-Path $distDir $a.Name
  Get-HttpsFile "$ReleaseBase/$($a.Name)" $out
  if ((Get-Item $out).Length -lt $a.MinSize) {
    throw "Asset too small: $out (expected >= $($a.MinSize) bytes)"
  }
}

# sqlite also needed under third_party/revcord for installer scp path
$sqliteDist = Join-Path $distDir $SqliteName
$sqliteRev = Join-Path $revcordDir $SqliteName
Copy-Item -Force $sqliteDist $sqliteRev
Ok "Copied $SqliteName into third_party/revcord"

# Ensure installer prefers release binary / dist node tarball
$env:RM2_RELEASE_TAG = $ReleaseTag
$env:HOST = $HostName

$installPs1 = Join-Path $destRoot "scripts\install-rm2-stack.ps1"
if (-not (Test-Path $installPs1)) {
  throw "Missing installer after extract: $installPs1"
}

Info "Launching install-rm2-stack.ps1 -SkipBuild (Go not required)"
Write-Host "  Repo: $destRoot"
Write-Host "  Host: $HostName"
Write-Host ""

& powershell -NoProfile -ExecutionPolicy Bypass -File $installPs1 -RepoRoot $destRoot -HostName $HostName -SkipBuild
$code = $LASTEXITCODE
if ($code -ne 0) {
  throw "install-rm2-stack.ps1 exited with code $code"
}
Ok "One-liner install finished"
