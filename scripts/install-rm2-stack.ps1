<#
.SYNOPSIS
  Host-side installer for rm2hwr + jonobones on reMarkable 2.

.DESCRIPTION
  Collects ALL credentials up front, deploys binaries/scripts, then runs the
  long on-device job under nohup so a dropped SSH session does not abort it.

  Required from each person (prompted if missing):
    - Tablet host (USB 10.11.99.1 or Wi-Fi IP)
    - MyScript APP_KEY + HMAC_KEY
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
Write-Host "  1) Tablet IP (USB default 10.11.99.1) + working SSH as root"
Write-Host "  2) MyScript APP_KEY and HMAC_KEY"
Write-Host "  3) Joplin Cloud email + password"
Write-Host "  4) Optional: Joplin E2EE master password"
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

$appKey = $sec["APP_KEY"]
$hmacKey = $sec["HMAC_KEY"]
$lang = if ($sec["LANG"]) { $sec["LANG"] } else { "en_US" }
if (-not $appKey) { $appKey = Ask "MyScript APP_KEY" }
if (-not $hmacKey) { $hmacKey = AskSecret "MyScript HMAC_KEY" }

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
  "APP_KEY=$appKey"
  "HMAC_KEY=$hmacKey"
  "LANG=$lang"
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
) | Set-Content -Encoding utf8 $localHwr
Ok "Saved conf/install.secrets + conf/hwr.env (gitignored)"

# Build answers file for jonobones init (line-oriented; see jonobones Prompter)
$choiceMap = @{
  filesystem = 1; webdav = 2; nextcloud = 3; joplinServer = 4
  joplinCloud = 5; s3 = 6; dropbox = 7
}
$answersPath = Join-Path $RepoRoot "conf\jonobones-init-answers.txt"
$answerLines = New-Object System.Collections.Generic.List[string]
# overwrite confirm is only consumed if config already exists — host cannot know for sure,
# so we always prepend overwrite answer; if no config, that first line becomes the choice
# and breaks. Probe remote after SSH instead.

function Invoke-Remote([string]$remoteCmd) {
  $sshArgs = @("-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=4", "-o", "StrictHostKeyChecking=accept-new", "${User}@${HostName}", $remoteCmd)
  & ssh @sshArgs
  if ($LASTEXITCODE -ne 0) { throw "ssh failed ($LASTEXITCODE): $remoteCmd" }
}

function Copy-ToRemote([string]$local, [string]$remote) {
  & scp -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new $local "${User}@${HostName}:$remote"
  if ($LASTEXITCODE -ne 0) { throw "scp failed: $local -> $remote" }
}

function Invoke-RemoteCapture([string]$remoteCmd) {
  $out = & ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "${User}@${HostName}" $remoteCmd
  if ($LASTEXITCODE -ne 0) { throw "ssh failed ($LASTEXITCODE): $remoteCmd" }
  return ($out | Out-String).Trim()
}

Info "Checking SSH…"
try {
  Invoke-Remote "uname -m"
  Ok "SSH works"
} catch {
  Warn "SSH failed. Set up keys or use USB ethernet (10.11.99.1)."
  throw
}

$arch = Invoke-RemoteCapture "uname -m"
if ($arch -ne "armv7l") { throw "Expected armv7l, got '$arch'" }

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
    Info "Building…"
    $buildPs1 = Join-Path $RepoRoot "scripts\build-armv7.ps1"
    if (Test-Path $buildPs1) { & powershell -NoProfile -File $buildPs1 }
    else {
      Push-Location $RepoRoot
      $env:CGO_ENABLED = "0"; $env:GOOS = "linux"; $env:GOARCH = "arm"; $env:GOARM = "7"
      New-Item -ItemType Directory -Force -Path (Join-Path $RepoRoot "dist") | Out-Null
      go build -o $dist ./cmd/rm2hwr
      Pop-Location
    }
    if (-not (Test-Path $dist)) { throw "build missing $dist" }
    Ok "Built $dist"
  }
}

# Ensure Node tarball available on host for offline tablet
$nodeVer = "20.20.2"
$nodeTar = Join-Path $env:TEMP "node-v$nodeVer-linux-armv7l.tar.xz"
if (-not (Test-Path $nodeTar) -or (Get-Item $nodeTar).Length -lt 1000000) {
  Info "Downloading Node $nodeVer armv7l on the PC (tablet often has no curl)…"
  $prevProgress = $ProgressPreference; $ProgressPreference = "SilentlyContinue"
  Invoke-WebRequest -Uri "https://nodejs.org/dist/v$nodeVer/node-v$nodeVer-linux-armv7l.tar.xz" -OutFile $nodeTar -UseBasicParsing
  $ProgressPreference = $prevProgress
}

Info "Deploying files…"
Invoke-Remote "mkdir -p /home/root/hwr/bin /home/root/hwr/conf /home/root/hwr/scripts /home/root/hwr/out /home/root/hwr/third_party/revcord /home/root/downloads"
if (Test-Path $dist) {
  Copy-ToRemote $dist "/home/root/hwr/bin/rm2hwr"
}
Copy-ToRemote (Join-Path $RepoRoot "scripts\joplin-upsert.js") "/home/root/hwr/scripts/joplin-upsert.js"
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
Invoke-Remote "chmod 0600 /home/root/hwr/conf/hwr.env /home/root/hwr/conf/jonobones-init-answers.txt 2>/dev/null; chmod 0755 /home/root/hwr/bin/rm2hwr /home/root/hwr/scripts/*.sh; true"
Ok "Deployed"

if ($SkipJonobones) {
  Ok "SkipJonobones set — done after deploy"
  exit 0
}

Info "Starting on-device install job under nohup (survives SSH drop)…"
# Clear prior status, start detached
Invoke-Remote "rm -f /tmp/rm2-install.status; : > /tmp/rm2-install.log; if command -v nohup >/dev/null 2>&1; then nohup sh /home/root/hwr/scripts/install-job.sh >/tmp/rm2-install.nohup.out 2>&1 & else sh /home/root/hwr/scripts/install-job.sh >/tmp/rm2-install.log 2>&1 & fi; echo started"

Info "Polling /tmp/rm2-install.status (Ctrl+C here is safe — job keeps running on tablet)…"
$deadline = (Get-Date).AddHours(6)
while ((Get-Date) -lt $deadline) {
  Start-Sleep -Seconds 8
  try {
    $st = Invoke-RemoteCapture "cat /tmp/rm2-install.status 2>/dev/null || echo pending"
  } catch {
    Warn "SSH blip while polling — retrying (on-device job still running)"
    continue
  }
  if ($st -eq "ok") { Ok "On-device job finished successfully"; break }
  if ($st -eq "fail") {
    Warn "On-device job failed — last log lines:"
    Invoke-Remote "tail -n 40 /tmp/rm2-install.log" | Out-Host
    throw "install-job failed"
  }
  Write-Host ("  status={0}  {1:u}" -f $st, (Get-Date))
}
if ($st -ne "ok") { throw "Timed out waiting for install-job" }

Ok "Installer finished"
Write-Host "Logs on tablet: /tmp/rm2-install.log  /tmp/jonobones-start.log"
Write-Host "MyScript env:   /home/root/hwr/conf/hwr.env"
Write-Host "API token env:  /home/root/hwr/conf/jonobones.env"