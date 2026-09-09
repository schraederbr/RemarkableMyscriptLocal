<#
.SYNOPSIS
  Host-side installer for rm2hwr + jonobones on reMarkable 2.

.DESCRIPTION
  Collects ALL credentials up front, deploys binaries/scripts, then runs the
  long on-device job under nohup so a dropped SSH session does not abort it.

  Required from each person (prompted if missing):
    - Tablet host (USB 10.11.99.1 or Wi-Fi IP)
    - reMarkable SSH password (auto-installs your PC SSH key once)
    - MyScript APP_KEY (HMAC_KEY optional); https://developer.myscript.com/
    - Joplin upload mode (text / SVG / both; default both)
    - Periodic sync interval hours (default 6; 0 disables cron)
    - Joplin Cloud email + password (or other sync target fields)
    - Optional E2EE master password
#>
[CmdletBinding()]
param(
  [string]$HostName = "",
  [string]$User = "root",
  [string]$RepoRoot = "",
  [string]$SecretsFile = "",
  [switch]$SkipBuild,
  [switch]$SkipJonobones,
  [switch]$SkipInit,
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

function AskSecret([string]$prompt) {
  if ($NonInteractive) { throw "NonInteractive requires $prompt in secrets file" }
  $s = Read-Host $prompt -AsSecureString
  $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)
  try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
  finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Info($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Ok($msg) { Write-Host "OK  $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "!!  $msg" -ForegroundColor Yellow }

function Read-DotEnv([string]$path) {
  $map = @{}
  if (-not (Test-Path $path)) { return $map }
  Get-Content $path | ForEach-Object {
    $line = $_.Trim()
    if (-not $line -or $line.StartsWith("#")) { return }
    $i = $line.IndexOf("=")
    if ($i -lt 1) { return }
    $k = $line.Substring(0, $i).Trim()
    $v = $line.Substring($i + 1)
    if (($v.StartsWith('"') -and $v.EndsWith('"')) -or ($v.StartsWith("'") -and $v.EndsWith("'"))) {
      $v = $v.Substring(1, $v.Length - 2)
    }
    $map[$k] = $v
  }
  return $map
}

if (-not $RepoRoot) { $RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..") }
$RepoRoot = (Resolve-Path $RepoRoot).Path
Info "Repo: $RepoRoot"

Write-Host ""
Write-Host "What this installer will ask for (have these ready):"
Write-Host "  1) Tablet IP (USB default 10.11.99.1) + reMarkable SSH password"
Write-Host "  2) MyScript APP_KEY (HMAC_KEY optional) - https://developer.myscript.com/"
Write-Host "  3) Joplin upload mode: text / SVG / both (default both)"
Write-Host "  4) Periodic sync interval hours (default 6; 0=disable cron)"
Write-Host "  5) Joplin Cloud email + password"
Write-Host "  6) Optional: Joplin E2EE master password"
Write-Host "  7) Tablet on Wi-Fi with internet (Joplin Cloud; npm only if offline bundle missing)"
Write-Host "  See docs/install-checklist.md"
Write-Host ""

# --- load optional secrets file ---
if (-not $SecretsFile) {
  $candidate = Join-Path $RepoRoot "conf\install.secrets"
  if (Test-Path $candidate) { $SecretsFile = $candidate }
}
$sec = @{}
if ($SecretsFile -and (Test-Path $SecretsFile)) {
  Info "Loading $SecretsFile"
  $sec = Read-DotEnv $SecretsFile
}

# --- collect connection ---
if (-not $HostName) {
  if ($sec["HOST"]) { $HostName = $sec["HOST"] }
  else {
    Write-Host "How is the tablet connected?"
    Write-Host "  1) USB  (10.11.99.1)"
    Write-Host "  2) Wi-Fi (enter IP)"
    $choice = Ask "Choice" "1"
    if ($choice -eq "2") { $HostName = Ask "Tablet IP" } else { $HostName = "10.11.99.1" }
  }
}
if ($sec["SSH_USER"]) { $User = $sec["SSH_USER"] }
Info "Target ${User}@${HostName}"

# --- collect credentials UP FRONT ---
Info "Collecting credentials (all of them, before any long step)"

$sshPassword = $sec["SSH_PASSWORD"]
if (-not $sshPassword) {
  # Empty allowed only if key auth already works (checked later)
  if (-not $NonInteractive) {
    $sshPassword = AskSecret "reMarkable SSH password (blank if key auth already works)"
  } else {
    $sshPassword = ""
  }
}

$appKey = $sec["APP_KEY"]
$hmacKey = $sec["HMAC_KEY"]
$lang = if ($sec["LANG"]) { $sec["LANG"] } else { "en_US" }
if (-not $appKey) {
  Write-Host ""
  Write-Host "MyScript Cloud â€” create a free app and copy keys:"
  Write-Host "  https://developer.myscript.com/"
  Write-Host ""
  $appKey = Ask "MyScript APP_KEY"
}
if (-not $sec.ContainsKey("HMAC_KEY") -and -not $hmacKey) {
  Write-Host "HMAC_KEY is optional (leave blank if HMAC is disabled in the MyScript dashboard)."
  $hmacKey = Ask "MyScript HMAC_KEY (optional, blank OK)"
}

$uploadMode = if ($sec["UPLOAD_MODE"]) { $sec["UPLOAD_MODE"].Trim().ToLowerInvariant() } else { "" }
if ($uploadMode -notin @("text","svg","both")) {
  if ($NonInteractive) {
    $uploadMode = "both"
  } else {
    Write-Host ""
    Write-Host "What should rm2hwr upload to Joplin?"
    Write-Host "  1) MyScript text only"
    Write-Host "  2) Page SVG images only"
    Write-Host "  3) Both text and SVG  [default]"
    $umChoice = Ask "Choice" "3"
    switch ($umChoice) {
      "1" { $uploadMode = "text" }
      "2" { $uploadMode = "svg" }
      default { $uploadMode = "both" }
    }
  }
}

$syncIntervalHours = if ($sec["SYNC_INTERVAL_HOURS"]) { $sec["SYNC_INTERVAL_HOURS"].Trim() } else { "" }
if ($syncIntervalHours -notmatch '^\d+$') {
  if ($NonInteractive) {
    $syncIntervalHours = "6"
  } else {
    Write-Host ""
    Write-Host "How often should the tablet auto-sync recent notebooks to Joplin?"
    Write-Host "  Enter hours between runs (default 6). Use 0 to skip installing cron."
    $syncIntervalHours = Ask "SYNC_INTERVAL_HOURS" "6"
    if ($syncIntervalHours -notmatch '^\d+$') { $syncIntervalHours = "6" }
  }
}

$syncTarget = if ($sec["SYNC_TARGET"]) { $sec["SYNC_TARGET"] } else { "joplinCloud" }
if (-not $NonInteractive -and -not $sec["SYNC_TARGET"]) {
  $syncTarget = Ask "Sync target (joplinCloud/webdav/nextcloud/joplinServer)" "joplinCloud"
}

$joplinEmail = $sec["JOPLIN_EMAIL"]
$joplinPass = $sec["JOPLIN_PASSWORD"]
$syncUrl = $sec["SYNC_URL"]
$syncUser = $sec["SYNC_USERNAME"]
$syncPass = $sec["SYNC_PASSWORD"]
$e2ee = $sec["E2EE_MASTER_PASSWORD"]
if ($null -eq $e2ee) { $e2ee = "" }

if ($syncTarget -eq "joplinCloud") {
  if (-not $joplinEmail) { $joplinEmail = Ask "Joplin Cloud email" }
  if (-not $joplinPass) { $joplinPass = AskSecret "Joplin Cloud password" }
} elseif ($syncTarget -in @("webdav","nextcloud","joplinServer")) {
  if (-not $syncUrl) { $syncUrl = Ask "Sync server URL" }
  if (-not $syncUser) { $syncUser = Ask "Sync username" }
  if (-not $syncPass) { $syncPass = AskSecret "Sync password" }
} else {
  throw "Automated init does not support SYNC_TARGET=$syncTarget yet. Use joplinCloud/webdav/nextcloud/joplinServer."
}

if (-not $sec.ContainsKey("E2EE_MASTER_PASSWORD") -and -not $NonInteractive) {
  if (AskYes "Does this Joplin vault use E2EE (master password)?" $false) {
    $e2ee = AskSecret "E2EE master password"
  }
}

$overwrite = if ($sec["OVERWRITE_JONOBONES_CONFIG"]) { $sec["OVERWRITE_JONOBONES_CONFIG"] } else { "y" }
if (-not $sec["OVERWRITE_JONOBONES_CONFIG"] -and -not $NonInteractive) {
  if (-not (AskYes "If jonobones is already configured on the tablet, overwrite it?" $true)) { $overwrite = "n" }
}

$doInit = -not $SkipInit
if ($sec["SKIP_JONOBONES_INIT"] -eq "1") { $doInit = $false }
$startJb = $true
if ($sec["START_JONOBONES"] -eq "0") { $startJb = $false }

# persist local secrets (gitignored) for re-runs
$localSecrets = Join-Path $RepoRoot "conf\install.secrets"
$localHwr = Join-Path $RepoRoot "conf\hwr.env"
New-Item -ItemType Directory -Force -Path (Join-Path $RepoRoot "conf") | Out-Null
@(
  "HOST=$HostName"
  "SSH_USER=$User"
  "SSH_PASSWORD=$sshPassword"
  "APP_KEY=$appKey"
  "HMAC_KEY=$hmacKey"
  "LANG=$lang"
  "UPLOAD_MODE=$uploadMode"
  "SYNC_INTERVAL_HOURS=$syncIntervalHours"
  "SYNC_TARGET=$syncTarget"
  "JOPLIN_EMAIL=$joplinEmail"
  "JOPLIN_PASSWORD=$joplinPass"
  "SYNC_URL=$syncUrl"
  "SYNC_USERNAME=$syncUser"
  "SYNC_PASSWORD=$syncPass"
  "E2EE_MASTER_PASSWORD=$e2ee"
  "OVERWRITE_JONOBONES_CONFIG=$overwrite"
  "SKIP_JONOBONES_INIT=$(if ($doInit) {'0'} else {'1'})"
  "START_JONOBONES=$(if ($startJb) {'1'} else {'0'})"
) | Set-Content -Encoding utf8 $localSecrets
@(
  "APP_KEY=$appKey"
  "HMAC_KEY=$hmacKey"
  "LANG=$lang"
  "CONTENT_TYPE=Text"
  "API_URL=https://cloud.myscript.com/api/v4.0/iink/batch"
  "UPLOAD_MODE=$uploadMode"
  "SYNC_INTERVAL_HOURS=$syncIntervalHours"
) | Set-Content -Encoding utf8 $localHwr
Ok "Saved conf/install.secrets + conf/hwr.env (gitignored)"

# Build answers file for jonobones init (line-oriented; see jonobones Prompter)
$choiceMap = @{
  filesystem = 1; webdav = 2; nextcloud = 3; joplinServer = 4
  joplinCloud = 5; s3 = 6; dropbox = 7
}
$answersPath = Join-Path $RepoRoot "conf\jonobones-init-answers.txt"
$answerLines = New-Object System.Collections.Generic.List[string]
# overwrite confirm is only consumed if config already exists â€” host cannot know for sure,
# so we always prepend overwrite answer; if no config, that first line becomes the choice
# and breaks. Probe remote after SSH instead.

function Test-RmKeyAuth {
  $out = & ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new "${User}@${HostName}" "echo ok" 2>$null
  return ($LASTEXITCODE -eq 0 -and ("$out".Trim() -eq "ok"))
}

function Find-GitBash {
  $candidates = @(
    (Join-Path ${env:ProgramFiles} "Git\bin\bash.exe"),
    (Join-Path ${env:ProgramFiles(x86)} "Git\bin\bash.exe"),
    (Join-Path $env:LOCALAPPDATA "Programs\Git\bin\bash.exe")
  )
  foreach ($c in $candidates) {
    if ($c -and (Test-Path $c)) { return $c }
  }
  return $null
}

function Ensure-RmSshKey([string]$password) {
  if (Test-RmKeyAuth) {
    Ok "SSH key auth already works"
    return
  }
  if ([string]::IsNullOrEmpty($password)) {
    throw "SSH key auth failed and no SSH password was provided. Enter the reMarkable SSH password so the installer can install your PC key."
  }

  $helper = Join-Path $RepoRoot "scripts\ensure-rm-ssh-key.sh"
  if (-not (Test-Path $helper)) { throw "missing $helper" }

  # Prefer Git Bash (NOT WSL). Pass password via env to the bash helper.
  $gitBash = Find-GitBash
  if ($gitBash) {
    Info "Installing PC SSH key on tablet via Git Bash (password once)â€¦"
    $env:RM_SSH_PASSWORD = $password
    try {
      & $gitBash $helper "${User}@${HostName}"
      if ($LASTEXITCODE -ne 0) { throw "ensure-rm-ssh-key.sh failed ($LASTEXITCODE)" }
    } finally {
      Remove-Item Env:RM_SSH_PASSWORD -ErrorAction SilentlyContinue
    }
  } else {
    # Native OpenSSH ASKPASS fallback (no Python, no WSL, no Git Bash)
    Info "Git Bash not found â€” using OpenSSH ASKPASS to install keyâ€¦"
    $sshDir = Join-Path $env:USERPROFILE ".ssh"
    New-Item -ItemType Directory -Force -Path $sshDir | Out-Null
    $pub = Join-Path $sshDir "id_ed25519.pub"
    if (-not (Test-Path $pub)) {
      $rsa = Join-Path $sshDir "id_rsa.pub"
      if (Test-Path $rsa) { $pub = $rsa }
      else {
        $priv = Join-Path $sshDir "id_ed25519"
        & ssh-keygen -t ed25519 -N '""' -f $priv -C "rm2-installer" | Out-Null
      }
    }
    $pubkey = (Get-Content $pub -Raw).Trim()
    $ask = Join-Path $env:TEMP ("rm-askpass-{0}.cmd" -f [guid]::NewGuid().ToString("n"))
    # cmd askpass: echo password with care for special chars via delayed env
    $pwFile = Join-Path $env:TEMP ("rm-ssh-pw-{0}.txt" -f [guid]::NewGuid().ToString("n"))
    [IO.File]::WriteAllText($pwFile, $password)
    @"
@echo off
type "$pwFile"
"@ | Set-Content -Encoding ascii $ask
    $prevAsk = $env:SSH_ASKPASS
    $prevReq = $env:SSH_ASKPASS_REQUIRE
    $prevDisp = $env:DISPLAY
    $env:SSH_ASKPASS = $ask
    $env:SSH_ASKPASS_REQUIRE = "force"
    $env:DISPLAY = "ignored"
    try {
      $pubEsc = $pubkey.Replace("'", "'\''")
      $remote = "mkdir -p /home/root/.ssh && chmod 700 /home/root/.ssh && touch /home/root/.ssh/authorized_keys && chmod 600 /home/root/.ssh/authorized_keys && grep -Fqx '$pubEsc' /home/root/.ssh/authorized_keys 2>/dev/null || echo '$pubEsc' >> /home/root/.ssh/authorized_keys && echo installed"
      # Force password path for this one connection
      $null = & ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o PreferredAuthentications=password -o PubkeyAuthentication=no -o NumberOfPasswordPrompts=1 "${User}@${HostName}" $remote 2>&1
      if ($LASTEXITCODE -ne 0) { throw "ASKPASS key install failed ($LASTEXITCODE). Install Git for Windows (Git Bash) and re-run." }
    } finally {
      if ($null -eq $prevAsk) { Remove-Item Env:SSH_ASKPASS -ErrorAction SilentlyContinue } else { $env:SSH_ASKPASS = $prevAsk }
      if ($null -eq $prevReq) { Remove-Item Env:SSH_ASKPASS_REQUIRE -ErrorAction SilentlyContinue } else { $env:SSH_ASKPASS_REQUIRE = $prevReq }
      if ($null -eq $prevDisp) { Remove-Item Env:DISPLAY -ErrorAction SilentlyContinue } else { $env:DISPLAY = $prevDisp }
      Remove-Item $ask -Force -ErrorAction SilentlyContinue
      Remove-Item $pwFile -Force -ErrorAction SilentlyContinue
    }
  }

  if (-not (Test-RmKeyAuth)) {
    throw "SSH key install attempted but BatchMode auth still fails"
  }
  Ok "SSH key installed â€” password not needed for the rest of this install"
}

function Invoke-Remote([string]$remoteCmd) {
  $sshArgs = @("-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=4", "-o", "StrictHostKeyChecking=accept-new", "${User}@${HostName}", $remoteCmd)
  & ssh @sshArgs
  if ($LASTEXITCODE -ne 0) { throw "ssh failed ($LASTEXITCODE): $remoteCmd" }
}

function Copy-ToRemote([string]$local, [string]$remote) {
  & scp -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new $local "${User}@${HostName}:$remote"
  if ($LASTEXITCODE -ne 0) { throw "scp failed: $local -> $remote" }
}

function Invoke-RemoteCapture([string]$remoteCmd) {
  $out = & ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "${User}@${HostName}" $remoteCmd
  if ($LASTEXITCODE -ne 0) { throw "ssh failed ($LASTEXITCODE): $remoteCmd" }
  return ($out | Out-String).Trim()
}

Info "Ensuring SSH key auth (password used at most once)â€¦"
Ensure-RmSshKey $sshPassword

Info "Checking SSHâ€¦"
try {
  Invoke-Remote "uname -m"
  Ok "SSH works"
} catch {
  Warn "SSH failed after key bootstrap."
  throw
}

$arch = Invoke-RemoteCapture "uname -m"
if ($arch -ne "armv7l") { throw "Expected armv7l, got '$arch'" }

Info "Checking tablet internet (Wi-Fi required for npm + Joplin Cloud)â€¦"
$net = Invoke-RemoteCapture "ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1 && echo yes || echo no"
if ($net -ne "yes") {
  Warn "Tablet has no internet right now."
  Warn "Turn on Wi-Fi before continuing â€” npm install and Joplin Cloud sync will fail without it."
  if (-not (AskYes "Continue anyway?" $false)) { throw "Aborted: tablet needs Wi-Fi/internet" }
} else {
  Ok "Tablet can reach the internet"
}

$hasConfig = Invoke-RemoteCapture "test -f /home/root/.config/jonobones/default/config.json5 && echo yes || echo no"
$answerLines.Clear()
if ($hasConfig -eq "yes") {
  if ($overwrite -eq "y" -or $overwrite -eq "Y" -or $overwrite -eq "1") { $answerLines.Add("y") }
  else {
    Warn "Existing jonobones config will be left alone (SKIP init answers overwrite=n)"
    $doInit = $false
  }
}
if ($doInit) {
  $answerLines.Add([string]$choiceMap[$syncTarget])
  if ($syncTarget -eq "joplinCloud") {
    $answerLines.Add($joplinEmail)
    $answerLines.Add($joplinPass)
  } else {
    $answerLines.Add($syncUrl)
    $answerLines.Add($syncUser)
    $answerLines.Add($syncPass)
  }
  $answerLines.Add($e2ee)  # empty line skips E2EE if prompted
  $answerLines.Add("")     # spare
  [IO.File]::WriteAllLines($answersPath, $answerLines)
} else {
  if (Test-Path $answersPath) { Remove-Item $answersPath -Force }
}

# --- build ---
$dist = Join-Path $RepoRoot "dist\rm2hwr-linux-armv7"
if (-not $SkipBuild) {
  if (AskYes "Cross-compile rm2hwr for linux/armv7?" $true) {
    Info "Buildingâ€¦"
    $buildPs1 = Join-Path $RepoRoot "scripts\build-armv7.ps1"
    if (Test-Path $buildPs1) { & powershell -NoProfile -File $buildPs1 }
    else {
      Push-Location $RepoRoot
      $env:CGO_ENABLED = "0"; $env:GOOS = "linux"; $env:GOARCH = "arm"; $env:GOARM = "7"
      New-Item -ItemType Directory -Force -Path (Join-Path $RepoRoot "dist") | Out-Null
      try {
        go build -o $dist ./cmd/rm2hwr
      } finally {
        Remove-Item Env:GOOS -ErrorAction SilentlyContinue
        Remove-Item Env:GOARCH -ErrorAction SilentlyContinue
        Remove-Item Env:GOARM -ErrorAction SilentlyContinue
        Remove-Item Env:CGO_ENABLED -ErrorAction SilentlyContinue
      }
      Pop-Location
    }
    if (-not (Test-Path $dist)) { throw "build missing $dist" }
    Ok "Built $dist"
  }
}

# Prefetch Node tarball on the PC (tablet often lacks curl/wget; Wi-Fi still needed for npm/Joplin)
$nodeVer = "20.20.2"
$nodeTar = Join-Path $env:TEMP "node-v$nodeVer-linux-armv7l.tar.xz"
if (-not (Test-Path $nodeTar) -or (Get-Item $nodeTar).Length -lt 1000000) {
  Info "Downloading Node $nodeVer armv7l on the PC (tablet often has no curl)â€¦"
  $prevProgress = $ProgressPreference; $ProgressPreference = "SilentlyContinue"
  Invoke-WebRequest -Uri "https://nodejs.org/dist/v$nodeVer/node-v$nodeVer-linux-armv7l.tar.xz" -OutFile $nodeTar -UseBasicParsing
  $ProgressPreference = $prevProgress
}

# Offline jonobones npm bundle (GitHub Release asset, or local dist/)
$offlineName = "jonobones-rm2-npm-offline-0.1.5-joplin-3.7.1.tar.gz"
$offlineLocal = Join-Path $RepoRoot "dist\$offlineName"
if (-not (Test-Path $offlineLocal) -or (Get-Item $offlineLocal).Length -lt 1000000) {
  Info "Fetching offline npm bundle from GitHub Releasesâ€¦"
  New-Item -ItemType Directory -Force -Path (Join-Path $RepoRoot "dist") | Out-Null
  $prevProgress = $ProgressPreference; $ProgressPreference = "SilentlyContinue"
  try {
    & gh release download --repo schraederbr/RemarkableMyscriptLocal --pattern $offlineName --dir (Join-Path $RepoRoot "dist") --clobber
  } catch {
    Warn "gh release download failed â€” will try npm on-device (needs Wi-Fi): $_"
  }
  $ProgressPreference = $prevProgress
}
if (Test-Path $offlineLocal) {
  Ok "Offline npm bundle ready: $offlineLocal"
} else {
  Warn "No offline npm bundle â€” on-device npm install will need Wi-Fi"
}

Info "Deploying filesâ€¦"
Invoke-Remote "mkdir -p /home/root/hwr/bin /home/root/hwr/conf /home/root/hwr/scripts /home/root/hwr/out /home/root/hwr/state /home/root/hwr/third_party/revcord /home/root/downloads"
if (Test-Path $dist) {
  Copy-ToRemote $dist "/home/root/hwr/bin/rm2hwr"
}
Copy-ToRemote (Join-Path $RepoRoot "scripts\joplin-upsert.js") "/home/root/hwr/scripts/joplin-upsert.js"
Copy-ToRemote (Join-Path $RepoRoot "scripts\on-device\sync-recent.sh") "/home/root/hwr/scripts/sync-recent.sh"
Copy-ToRemote (Join-Path $RepoRoot "third_party\revcord\node_sqlite3.node") "/home/root/hwr/third_party/revcord/node_sqlite3.node"
Copy-ToRemote (Join-Path $RepoRoot "scripts\on-device\install-node-jonobones.sh") "/home/root/hwr/scripts/install-node-jonobones.sh"
Copy-ToRemote (Join-Path $RepoRoot "scripts\on-device\jonobones-init-cloud.sh") "/home/root/hwr/scripts/jonobones-init-cloud.sh"
Copy-ToRemote (Join-Path $RepoRoot "scripts\on-device\install-job.sh") "/home/root/hwr/scripts/install-job.sh"
Copy-ToRemote $localHwr "/home/root/hwr/conf/hwr.env"
$metaLocal = Join-Path $env:TEMP "rm2-install.meta"
@(
  "SKIP_JONOBONES_INIT=$(if ($doInit) {'0'} else {'1'})"
  "START_JONOBONES=$(if ($startJb) {'1'} else {'0'})"
) | Set-Content -Encoding ascii $metaLocal
Copy-ToRemote $metaLocal "/home/root/hwr/conf/install.meta"
if ($doInit -and (Test-Path $answersPath)) {
  Copy-ToRemote $answersPath "/home/root/hwr/conf/jonobones-init-answers.txt"
  Remove-Item $answersPath -Force -ErrorAction SilentlyContinue
}
Copy-ToRemote $nodeTar "/home/root/downloads/node-v$nodeVer-linux-armv7l.tar.xz"
if (Test-Path $offlineLocal) {
  Copy-ToRemote $offlineLocal "/home/root/downloads/$offlineName"
}
Invoke-Remote "chmod 0600 /home/root/hwr/conf/hwr.env /home/root/hwr/conf/jonobones-init-answers.txt 2>/dev/null; chmod 0755 /home/root/hwr/bin/rm2hwr /home/root/hwr/scripts/*.sh; true"
Ok "Deployed"

Info "Installing / updating BusyBox crontab for sync-recent (interval=$syncIntervalHours h)…"
# Flatten to one remote command via bash -c is risky on BusyBox ash; use a temp script.
$cronLocal = Join-Path $env:TEMP "rm2-install-cron.sh"
@(
  '#!/bin/sh'
  'set -e'
  'PATH=/home/root/.npm-global/bin:/home/root/opt/node/bin:/home/root/hwr/bin:/usr/bin:/bin'
  'HWR=/home/root/hwr'
  'MARK="# rm2hwr-sync-recent"'
  'TMP=/tmp/rm2-crontab.new'
  'crontab -l 2>/dev/null | grep -v sync-recent.sh | grep -v "rm2hwr-sync-recent" > "$TMP" || true'
  "HOURS=$syncIntervalHours"
  'if [ -n "$HOURS" ] && [ "$HOURS" -gt 0 ] 2>/dev/null; then'
  '  echo "$MARK every ${HOURS}h" >> "$TMP"'
  '  echo "17 */$HOURS * * * $HWR/scripts/sync-recent.sh >> /tmp/hwr-sync-recent.log 2>&1" >> "$TMP"'
  '  crontab "$TMP"'
  '  echo "crontab installed interval=$HOURS"'
  'else'
  '  if [ -s "$TMP" ]; then crontab "$TMP"; else crontab -r 2>/dev/null || true; fi'
  '  echo "crontab sync-recent disabled (SYNC_INTERVAL_HOURS=0)"'
  'fi'
  'rm -f "$TMP"'
  'chmod 0755 /home/root/hwr/scripts/sync-recent.sh'
) | Set-Content -Encoding ascii $cronLocal
Copy-ToRemote $cronLocal "/tmp/rm2-install-cron.sh"
Invoke-Remote "chmod 0755 /tmp/rm2-install-cron.sh; sh /tmp/rm2-install-cron.sh; rm -f /tmp/rm2-install-cron.sh"
Ok "Cron configured (SYNC_INTERVAL_HOURS=$syncIntervalHours)"

if ($SkipJonobones) {
  Ok "SkipJonobones set â€” done after deploy"
  exit 0
}

function Get-RmInstallPhase([string]$statusText) {
  $t = ("$statusText").Trim()
  if ([string]::IsNullOrWhiteSpace($t)) { return "pending" }
  foreach ($line in ($t -split "`r?`n")) {
    $line = $line.Trim()
    if ($line -match '^phase=(.+)$') { return $Matches[1].Trim() }
    if ($line -in @("ok", "fail", "running", "pending")) { return $line }
  }
  return $t
}

function Write-RmInstallHeartbeat([TimeSpan]$elapsed) {
  # BusyBox-safe one-shot snapshot for ~60s host progress lines (no here-strings)
  $remote = @(
    'phase=$(sed -n ''s/^phase=//p'' /tmp/rm2-install.status 2>/dev/null | head -n1)'
    '[ -n "$phase" ] || phase=pending'
    'du_k=$(du -sk /home/root/.config/jonobones 2>/dev/null | awk ''{print $1}'')'
    '[ -n "$du_k" ] || du_k=0'
    'free_k=$(df -k /home 2>/dev/null | tail -n1 | awk ''{print $4}'')'
    '[ -n "$free_k" ] || free_k=?'
    'echo "PHASE=$phase"'
    'echo "DU_K=$du_k"'
    'echo "FREE_K=$free_k"'
    'echo "----LOG----"'
    'tail -n 12 /tmp/rm2-install.log 2>/dev/null || true'
  ) -join "; "
  $snap = Invoke-RemoteCapture $remote
  $phase = "pending"; $duK = "0"; $freeK = "?"
  $logLines = New-Object System.Collections.Generic.List[string]
  $inLog = $false
  foreach ($line in ($snap -split "`r?`n")) {
    if ($inLog) { [void]$logLines.Add($line); continue }
    if ($line -eq "----LOG----") { $inLog = $true; continue }
    if ($line -match '^PHASE=(.+)$') { $phase = $Matches[1]; continue }
    if ($line -match '^DU_K=(.+)$') { $duK = $Matches[1]; continue }
    if ($line -match '^FREE_K=(.+)$') { $freeK = $Matches[1]; continue }
  }
  $mins = [math]::Floor($elapsed.TotalMinutes)
  $secs = $elapsed.Seconds
  $duMb = if ($duK -match '^\d+$') { "{0:N1}M" -f ([double]$duK / 1024.0) } else { $duK }
  $freeMb = if ($freeK -match '^\d+$') { "{0:N1}M" -f ([double]$freeK / 1024.0) } else { $freeK }
  Write-Host ""
  Write-Host ("-- heartbeat  phase={0}  elapsed={1}m{2:D2}s  jonobones={3}  /home free={4}" -f $phase, $mins, $secs, $duMb, $freeMb) -ForegroundColor Cyan
  if ($logLines.Count -gt 0) {
    Write-Host "   log tail:"
    foreach ($l in $logLines) {
      if (-not [string]::IsNullOrWhiteSpace($l)) { Write-Host ("   | {0}" -f $l) }
    }
  }
}

Info "Starting on-device install job under nohup (survives SSH drop)..."
# Clear prior status, start detached
Invoke-Remote "rm -f /tmp/rm2-install.status; : > /tmp/rm2-install.log; if command -v nohup >/dev/null 2>&1; then nohup sh /home/root/hwr/scripts/install-job.sh >/tmp/rm2-install.nohup.out 2>&1 & else sh /home/root/hwr/scripts/install-job.sh >/tmp/rm2-install.log 2>&1 & fi; echo started"

Info "Polling /tmp/rm2-install.status (~60s heartbeat; Ctrl+C here is safe — job keeps running on tablet)..."
$deadline = (Get-Date).AddHours(6)
$pollStarted = Get-Date
$lastHeartbeat = [datetime]::MinValue
$phase = "pending"
while ((Get-Date) -lt $deadline) {
  Start-Sleep -Seconds 5
  try {
    $st = Invoke-RemoteCapture "cat /tmp/rm2-install.status 2>/dev/null || echo phase=pending"
  } catch {
    Warn "SSH blip while polling — retrying (on-device job still running)"
    continue
  }
  $phase = Get-RmInstallPhase $st
  if ($phase -eq "ok") { Ok "On-device job finished successfully"; break }
  if ($phase -eq "fail") {
    Warn "On-device job failed — last log lines:"
    Invoke-Remote "tail -n 40 /tmp/rm2-install.log" | Out-Host
    throw "install-job failed"
  }
  $elapsed = (Get-Date) - $pollStarted
  if (((Get-Date) - $lastHeartbeat).TotalSeconds -ge 60) {
    $lastHeartbeat = Get-Date
    try {
      Write-RmInstallHeartbeat $elapsed
    } catch {
      Warn "Heartbeat SSH blip — retrying next cycle (on-device job still running)"
    }
  }
}
if ($phase -ne "ok") { throw "Timed out waiting for install-job" }

Ok "Installer finished"
Write-Host "Logs on tablet: /tmp/rm2-install.log  /tmp/jonobones-start.log"
Write-Host "MyScript env:   /home/root/hwr/conf/hwr.env"
Write-Host "API token env:  /home/root/hwr/conf/jonobones.env"
Write-Host "Sync script:    /home/root/hwr/scripts/sync-recent.sh"
Write-Host "Sync state:     /home/root/hwr/state/<doc-uuid>.json"
Write-Host "Cron interval:  $syncIntervalHours h (0=disabled). Change SYNC_INTERVAL_HOURS in hwr.env + re-run installer, or crontab -e on tablet."