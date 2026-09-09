<#
.SYNOPSIS
  Interactive host-side installer for rm2hwr + jonobones on reMarkable 2.

.DESCRIPTION
  Walks you through:
    1) SSH connectivity (WiFi or USB 10.11.99.1)
    2) Cross-compile / copy rm2hwr armv7 binary
    3) On-device Node 20 + Revcord sqlite3 + jonobones
    4) Deploy HWR scripts + env template
    5) Reminders for MyScript keys and jonobones init

  Run from a clone of RemarkableMyscriptLocal on Windows (DESKTOP).
#>
[CmdletBinding()]
param(
  [string]$HostName = "",
  [string]$User = "root",
  [string]$RepoRoot = "",
  [switch]$SkipBuild,
  [switch]$SkipJonobones,
  [switch]$NonInteractive
)

$ErrorActionPreference = "Stop"

function Ask([string]$prompt, [string]$default = "") {
  if ($NonInteractive) { return $default }
  if ($default) {
    $v = Read-Host "$prompt [$default]"
    if ([string]::IsNullOrWhiteSpace($v)) { return $default }
    return $v
  }
  return Read-Host $prompt
}

function AskYes([string]$prompt, [bool]$defaultYes = $true) {
  if ($NonInteractive) { return $defaultYes }
  $hint = if ($defaultYes) { "Y/n" } else { "y/N" }
  $v = (Read-Host "$prompt [$hint]").Trim().ToLowerInvariant()
  if ([string]::IsNullOrWhiteSpace($v)) { return $defaultYes }
  return ($v -eq "y" -or $v -eq "yes")
}

function Info($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Ok($msg) { Write-Host "OK  $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "!!  $msg" -ForegroundColor Yellow }

if (-not $RepoRoot) {
  $RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
}
$RepoRoot = (Resolve-Path $RepoRoot).Path
Info "Repo: $RepoRoot"

if (-not $HostName) {
  Write-Host ""
  Write-Host "How is the tablet connected?"
  Write-Host "  1) USB  (default gateway 10.11.99.1)"
  Write-Host "  2) Wi‑Fi (you enter the IP)"
  $choice = Ask "Choice" "1"
  if ($choice -eq "2") {
    $HostName = Ask "Tablet IP"
  } else {
    $HostName = "10.11.99.1"
  }
}

Info "Target ${User}@${HostName}"
if (-not (AskYes "Continue with this host?" $true)) { exit 0 }

# Prefer OpenSSH; password auth may need key already set up
function Invoke-Remote([string]$remoteCmd) {
  $sshArgs = @("-o", "ConnectTimeout=10", "-o", "StrictHostKeyChecking=accept-new", "${User}@${HostName}", $remoteCmd)
  & ssh @sshArgs
  if ($LASTEXITCODE -ne 0) { throw "ssh failed ($LASTEXITCODE): $remoteCmd" }
}

function Copy-ToRemote([string]$local, [string]$remote) {
  & scp -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new $local "${User}@${HostName}:$remote"
  if ($LASTEXITCODE -ne 0) { throw "scp failed: $local -> $remote" }
}

Info "Checking SSH…"
try {
  Invoke-Remote "uname -m && cat /etc/os-release | head -n 5"
  Ok "SSH works"
} catch {
  Warn "SSH failed. Fix connectivity or set up keys (ssh-copy-id / existing key)."
  Warn "USB tip: enable USB ethernet on the tablet; host IP is often 10.11.99.1"
  throw
}

$arch = (& ssh "${User}@${HostName}" "uname -m").Trim()
if ($arch -ne "armv7l") {
  throw "Expected armv7l, got '$arch' — this installer is for reMarkable 2 only."
}

# --- build rm2hwr ---
$dist = Join-Path $RepoRoot "dist\rm2hwr-linux-armv7"
if (-not $SkipBuild) {
  if (AskYes "Cross-compile rm2hwr for linux/armv7?" $true) {
    Info "Building…"
    $buildPs1 = Join-Path $RepoRoot "scripts\build-armv7.ps1"
    if (Test-Path $buildPs1) {
      & powershell -NoProfile -File $buildPs1
    } else {
      Push-Location $RepoRoot
      $env:CGO_ENABLED = "0"
      $env:GOOS = "linux"
      $env:GOARCH = "arm"
      $env:GOARM = "7"
      New-Item -ItemType Directory -Force -Path (Join-Path $RepoRoot "dist") | Out-Null
      go build -o $dist ./cmd/rm2hwr
      Pop-Location
    }
    if (-not (Test-Path $dist)) { throw "build missing $dist" }
    Ok "Built $dist"
  }
}

if (Test-Path $dist) {
  Info "Deploying rm2hwr binary + scripts…"
  Invoke-Remote "mkdir -p /home/root/hwr/bin /home/root/hwr/conf /home/root/hwr/scripts /home/root/hwr/out"
  Copy-ToRemote $dist "/home/root/hwr/bin/rm2hwr"
  Copy-ToRemote (Join-Path $RepoRoot "scripts\joplin-upsert.js") "/home/root/hwr/scripts/joplin-upsert.js"
  Copy-ToRemote (Join-Path $RepoRoot "scripts\on-device\install-node-jonobones.sh") "/home/root/hwr/scripts/install-node-jonobones.sh"
  $envExample = Join-Path $RepoRoot "conf\hwr.env.example"
  Invoke-Remote "test -f /home/root/hwr/conf/hwr.env || cp /dev/null /home/root/hwr/conf/hwr.env"
  # only seed example if missing keys file empty
  if (Test-Path $envExample) {
    $hasEnv = (& ssh "${User}@${HostName}" "test -s /home/root/hwr/conf/hwr.env && echo yes || echo no").Trim()
    if ($hasEnv -eq "no") {
      Copy-ToRemote $envExample "/home/root/hwr/conf/hwr.env"
      Invoke-Remote "chmod 0600 /home/root/hwr/conf/hwr.env"
      Warn "Seeded /home/root/hwr/conf/hwr.env — edit APP_KEY and HMAC_KEY"
    }
  }
  Invoke-Remote "chmod 0755 /home/root/hwr/bin/rm2hwr /home/root/hwr/scripts/*.sh /home/root/hwr/scripts/*.js 2>/dev/null; true"
  Ok "HWR binary + scripts deployed"
}

# --- Node + jonobones ---
if (-not $SkipJonobones) {
  if (AskYes "Install/upgrade Node 20 + jonobones + sqlite drop-in on the tablet?" $true) {
    Info "Running on-device installer (needs network on the tablet for wget/curl)…"
    Invoke-Remote "chmod +x /home/root/hwr/scripts/install-node-jonobones.sh && sh /home/root/hwr/scripts/install-node-jonobones.sh"
    Ok "Node/jonobones step finished"
  }
}

Write-Host ""
Info "Manual steps (interactive — do these on the tablet SSH session):"
Write-Host @"

  export PATH=/home/root/.npm-global/bin:/home/root/opt/node/bin:`$PATH

  # 1) MyScript credentials
  vi /home/root/hwr/conf/hwr.env   # APP_KEY, HMAC_KEY, chmod 0600

  # 2) Dry-run HWR
  /home/root/hwr/bin/rm2hwr --name `"9-8`" --dry-run

  # 3) Live HWR (writes NOTE.md + HANDOFF.json)
  /home/root/hwr/bin/rm2hwr --name `"9-8`"

  # 4) Joplin Cloud / sync target
  jonobones init
  nohup jonobones start > /tmp/jonobones-start.log 2>&1 &

  # 5) Upsert recognized note into Joplin
  /home/root/hwr/bin/rm2hwr --name `"9-8`" --joplin-upsert
  # or: node /home/root/hwr/scripts/joplin-upsert.js /home/root/hwr/out/<doc-uuid>

Docs: docs/jonobones-rm2.md  docs/joplin-sync.md
"@

if (AskYes "Open an SSH session now?" $true) {
  & ssh "${User}@${HostName}"
}

Ok "Installer finished"
