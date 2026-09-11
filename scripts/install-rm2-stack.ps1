# Host-side installer for rm2hwr + jonobones on reMarkable 2.
#
# Collects ALL credentials up front, deploys binaries/scripts, then runs the
# long on-device job under nohup so a dropped SSH session does not abort it.
#
# Required from each person (prompted if missing):
# - Tablet host (USB 10.11.99.1 or Wi-Fi IP)
# - reMarkable SSH password (auto-installs your PC SSH key once)
# - Joplin upload mode (text / SVG / both; default both)
# - MyScript APP_KEY (HMAC_KEY optional) only if mode is text or both
# - Periodic sync interval hours (default 6; 0 disables systemd timer)
# - Joplin notebook for NEW notes (blank=auto most notes; or title / 32-hex id)
# - Joplin Cloud email + password (or other sync target fields)
# - Optional E2EE master password
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

function Test-RmKeyAuth {
  $out = & ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new "${User}@${HostName}" "echo ok" 2>$null
  return ($LASTEXITCODE -eq 0 -and ("$out".Trim() -eq "ok"))
}

function Test-RmSshHostReachable {
  # Reachable if key auth works OR the SSH daemon answers with an auth failure.
  $errFile = Join-Path $env:TEMP ("rm-ssh-probe-{0}.txt" -f [guid]::NewGuid().ToString("n"))
  try {
    $out = & ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new -o NumberOfPasswordPrompts=0 "${User}@${HostName}" "echo ok" 2>$errFile
    if ($LASTEXITCODE -eq 0 -and ("$out".Trim() -eq "ok")) { return $true }
    $err = ""
    if (Test-Path $errFile) { $err = (Get-Content $errFile -Raw -ErrorAction SilentlyContinue) }
    if ($err -match '(?i)Permission denied|Authentication failed|Too many authentication|Host key verification failed') {
      return $true
    }
    return $false
  } catch {
    return $false
  } finally {
    Remove-Item $errFile -Force -ErrorAction SilentlyContinue
  }
}

function Update-RmSecretsHost([string]$newHost) {
  $secPath = Join-Path $RepoRoot "conf\install.secrets"
  if (-not (Test-Path $secPath)) { return }
  $lines = @(Get-Content $secPath)
  $found = $false
  $newLines = foreach ($line in $lines) {
    if ($line -match '^HOST=') { $found = $true; "HOST=$newHost" } else { $line }
  }
  if (-not $found) { $newLines = @("HOST=$newHost") + $newLines }
  $newLines | Set-Content -Encoding utf8 $secPath
}

function Update-RmSecretsPassword([string]$newPassword) {
  $secPath = Join-Path $RepoRoot "conf\install.secrets"
  if (-not (Test-Path $secPath)) { return }
  $lines = @(Get-Content $secPath)
  $found = $false
  $newLines = foreach ($line in $lines) {
    if ($line -match '^SSH_PASSWORD=') { $found = $true; "SSH_PASSWORD=$newPassword" } else { $line }
  }
  if (-not $found) { $newLines = @("SSH_PASSWORD=$newPassword") + $newLines }
  $newLines | Set-Content -Encoding utf8 $secPath
}

function Show-RmSshRecoveryMenu {
  Write-Host ""
  Write-Host "SSH connection failed. What do you want to do?"
  Write-Host "  1) Check USB / enable USB networking / plug in tablet, then retry  [default]"
  Write-Host "  2) Enter the tablet Wi-Fi IP address / change HOST and retry"
  Write-Host "  3) Re-enter SSH password (password changes after factory reset)"
  Write-Host "  4) Abort"
  $choice = Ask "Choice" "1"
  if ($choice -eq "4" -or $choice -match '^(?i)a(bort)?$') {
    throw "Aborted: could not SSH to tablet at $HostName"
  }
  if ($choice -eq "2" -or $choice -match '^(?i)w') {
    $newIp = (Ask "Tablet Wi-Fi IP").Trim()
    if ([string]::IsNullOrWhiteSpace($newIp)) {
      Warn "No IP entered - keeping $HostName"
    } else {
      $script:HostName = $newIp
      Update-RmSecretsHost $script:HostName
      Info "Updated target ${User}@${script:HostName}"
    }
  } elseif ($choice -eq "3" -or $choice -match '^(?i)p') {
    $script:sshPassword = AskSecret "reMarkable SSH password"
    Update-RmSecretsPassword $script:sshPassword
    Ok "Updated stored SSH password"
  } else {
    Write-Host "Plug in the tablet, unlock it, and enable USB networking if needed; then retry."
    $null = Ask "Press Enter to retry USB/default host ($HostName)"
  }
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
    Info "Installing PC SSH key on tablet via Git Bash (password once)..."
    $env:RM_SSH_PASSWORD = $password
    try {
      & $gitBash $helper "${User}@${HostName}"
      if ($LASTEXITCODE -ne 0) { throw "ensure-rm-ssh-key.sh failed ($LASTEXITCODE)" }
    } finally {
      Remove-Item Env:RM_SSH_PASSWORD -ErrorAction SilentlyContinue
    }
  } else {
    # Native OpenSSH ASKPASS fallback (no Python, no WSL, no Git Bash)
    Info "Git Bash not found - using OpenSSH ASKPASS to install key..."
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
  Ok "SSH key installed - password not needed for the rest of this install"
}

function Wait-RmSshReady {
  while ($true) {
    Info "Probing SSH to ${User}@${HostName}..."
    if (-not (Test-RmSshHostReachable)) {
      Warn "Cannot reach reMarkable over SSH at ${User}@${HostName}."
      if ($NonInteractive) {
        throw "SSH to ${User}@${HostName} failed (NonInteractive). Enable USB networking (plug in the tablet; default 10.11.99.1) or set -HostName / HOST to the tablet Wi-Fi IP, then re-run."
      }
      Show-RmSshRecoveryMenu
      continue
    }
    Ok "SSH host reachable at $HostName"

    Info "Ensuring SSH key auth (password used at most once per success)..."
    try {
      Ensure-RmSshKey $script:sshPassword
      if (Test-RmKeyAuth) {
        Ok "SSH ready at ${User}@${HostName}"
        return
      }
      Warn "SSH key auth still failing after key bootstrap."
    } catch {
      Warn "SSH auth/key install failed: $($_.Exception.Message)"
    }
    if ($NonInteractive) {
      throw "SSH auth to ${User}@${HostName} failed (NonInteractive). Fix SSH password / HOST and re-run."
    }
    Show-RmSshRecoveryMenu
  }
}

if (-not $RepoRoot) { $RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..") }
$RepoRoot = (Resolve-Path $RepoRoot).Path
Info "Repo: $RepoRoot"

Write-Host ""
Write-Host "What this installer will ask for (have these ready):"
Write-Host "  1) Tablet IP (USB default 10.11.99.1) + reMarkable SSH password"
Write-Host "  2) Joplin upload mode: SVG only / handwriting text / both (default both)"
Write-Host "  3) MyScript APP_KEY (HMAC optional) - only if you want handwriting text (text or both)"
Write-Host "  4) Periodic sync interval hours (default 6; 0=disable systemd timer)"
Write-Host "  5) Joplin notebook for NEW notes (blank=auto most notes; or title/id)"
Write-Host "  6) Joplin Cloud email + password"
Write-Host "  7) Optional: Joplin E2EE master password"
Write-Host "  8) Tablet on Wi-Fi with internet (Joplin Cloud; MyScript only if text/HWR; npm if offline bundle missing)"
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
  # Empty allowed only if key auth already works (checked immediately below)
  if (-not $NonInteractive) {
    $sshPassword = AskSecret "reMarkable SSH password (blank if key auth already works)"
  } else {
    $sshPassword = ""
  }
}
$script:sshPassword = $sshPassword

# Early SSH check (before long credential / download / deploy steps)
Info "Checking SSH now (before long install steps)..."
Wait-RmSshReady
$sshPassword = $script:sshPassword

$lang = if ($sec["LANG"]) { $sec["LANG"] } else { "en_US" }

# Upload mode first - MyScript keys only needed for handwriting text (text|both)
$uploadMode = if ($sec["UPLOAD_MODE"]) { $sec["UPLOAD_MODE"].Trim().ToLowerInvariant() } else { "" }
if ($uploadMode -notin @("text","svg","both")) {
  if ($NonInteractive) {
    $uploadMode = "both"
  } else {
    Write-Host ""
    Write-Host "What should rm2hwr upload to Joplin?"
    Write-Host "  1) Handwriting text only (MyScript HWR - needs APP_KEY)"
    Write-Host "  2) SVG only (page images - no MyScript keys)"
    Write-Host "  3) Both text and SVG  [default]"
    $umChoice = Ask "Choice" "3"
    switch ($umChoice) {
      "1" { $uploadMode = "text" }
      "2" { $uploadMode = "svg" }
      default { $uploadMode = "both" }
    }
  }
}

$appKey = $sec["APP_KEY"]
$hmacKey = $sec["HMAC_KEY"]
if ($null -eq $appKey) { $appKey = "" }
if ($null -eq $hmacKey) { $hmacKey = "" }
if ($uploadMode -eq "svg") {
  # SVG-only: skip MyScript prompts; leave keys empty (or keep secrets if already set)
  if (-not $appKey) { $appKey = "" }
  if (-not $hmacKey) { $hmacKey = "" }
  Ok "UPLOAD_MODE=svg - skipping MyScript APP_KEY/HMAC_KEY prompts"
} else {
  if (-not $appKey) {
    if ($NonInteractive) {
      throw "NonInteractive requires APP_KEY in secrets file when UPLOAD_MODE is text or both"
    }
    Write-Host ""
    Write-Host "MyScript Cloud - create a free app and copy keys (needed for handwriting text):"
    Write-Host "  https://developer.myscript.com/"
    Write-Host ""
    $appKey = Ask "MyScript APP_KEY"
    if (-not $appKey) { throw "MyScript APP_KEY is required when UPLOAD_MODE is $uploadMode" }
  }
  if (-not $sec.ContainsKey("HMAC_KEY") -and -not $hmacKey) {
    Write-Host "HMAC_KEY is optional (leave blank if HMAC is disabled in the MyScript dashboard)."
    $hmacKey = Ask "MyScript HMAC_KEY (optional, blank OK)"
  }
}

$syncIntervalHours = if ($sec["SYNC_INTERVAL_HOURS"]) { $sec["SYNC_INTERVAL_HOURS"].Trim() } else { "" }
if ($syncIntervalHours -notmatch '^\d+$') {
  if ($NonInteractive) {
    $syncIntervalHours = "6"
  } else {
    Write-Host ""
    Write-Host "How often should the tablet auto-sync recent notebooks to Joplin?"
    Write-Host "  Enter hours between runs (default 6). Use 0 to skip installing systemd timer."
    $syncIntervalHours = Ask "SYNC_INTERVAL_HOURS" "6"
    if ($syncIntervalHours -notmatch '^\d+$') { $syncIntervalHours = "6" }
  }
}

# Joplin target notebook for NEW notes (creates only; updates match by title anywhere)
$parentId = if ($sec["JONOBONES_PARENT_ID"]) { $sec["JONOBONES_PARENT_ID"].Trim() } else { "" }
$parentTitle = if ($sec["JONOBONES_PARENT_TITLE"]) { $sec["JONOBONES_PARENT_TITLE"].Trim() } else { "" }
if (-not $parentId -and -not $parentTitle -and -not $NonInteractive -and -not $sec.ContainsKey("JONOBONES_PARENT_ID") -and -not $sec.ContainsKey("JONOBONES_PARENT_TITLE")) {
  Write-Host ""
  Write-Host "Joplin notebook for NEW notes [auto=most notes]"
  Write-Host "  Blank = auto-pick notebook with the most notes at create time."
  Write-Host "  Or enter a notebook title (exact match) or a 32-hex notebook id."
  $nbChoice = Ask "Joplin notebook for NEW notes [auto=most notes]" ""
  if ($nbChoice) {
    if ($nbChoice -match '^[0-9a-fA-F]{32}$') {
      $parentId = $nbChoice.ToLowerInvariant()
    } else {
      $parentTitle = $nbChoice
    }
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

function Test-JoplinCloudLogin([string]$email, [string]$password) {
  $uri = "https://api.joplincloud.com/api/sessions"
  $payload = @{ email = $email; password = $password } | ConvertTo-Json -Compress
  try {
    $prev = $ProgressPreference; $ProgressPreference = "SilentlyContinue"
    try {
      $r = Invoke-WebRequest -Uri $uri -Method POST -Body $payload -ContentType "application/json; charset=utf-8" -UseBasicParsing -TimeoutSec 30
    } finally { $ProgressPreference = $prev }
    if ($r.StatusCode -lt 200 -or $r.StatusCode -ge 300) { return @{ Ok = $false; Status = [int]$r.StatusCode; Error = "HTTP $($r.StatusCode)" } }
    $j = $r.Content | ConvertFrom-Json
    if (-not $j.id) { return @{ Ok = $false; Status = [int]$r.StatusCode; Error = "no session id in response" } }
    return @{ Ok = $true; Status = [int]$r.StatusCode; Error = "" }
  } catch {
    $resp = $_.Exception.Response
    if ($resp) {
      return @{ Ok = $false; Status = [int]$resp.StatusCode; Error = "HTTP $([int]$resp.StatusCode)" }
    }
    return @{ Ok = $false; Status = 0; Error = $_.Exception.Message }
  }
}

function Test-JoplinServerLogin([string]$baseUrl, [string]$email, [string]$password) {
  $base = $baseUrl.TrimEnd("/")
  $uri = "$base/api/sessions"
  $payload = @{ email = $email; password = $password } | ConvertTo-Json -Compress
  try {
    $prev = $ProgressPreference; $ProgressPreference = "SilentlyContinue"
    try {
      $r = Invoke-WebRequest -Uri $uri -Method POST -Body $payload -ContentType "application/json; charset=utf-8" -UseBasicParsing -TimeoutSec 30
    } finally { $ProgressPreference = $prev }
    if ($r.StatusCode -lt 200 -or $r.StatusCode -ge 300) { return @{ Ok = $false; Status = [int]$r.StatusCode; Error = "HTTP $($r.StatusCode)" } }
    $j = $r.Content | ConvertFrom-Json
    if (-not $j.id) { return @{ Ok = $false; Status = [int]$r.StatusCode; Error = "no session id" } }
    return @{ Ok = $true; Status = [int]$r.StatusCode; Error = "" }
  } catch {
    $resp = $_.Exception.Response
    if ($resp) { return @{ Ok = $false; Status = [int]$resp.StatusCode; Error = "HTTP $([int]$resp.StatusCode)" } }
    return @{ Ok = $false; Status = 0; Error = $_.Exception.Message }
  }
}

function Test-WebDavBasic([string]$url, [string]$username, [string]$password) {
  try {
    $pair = "{0}:{1}" -f $username, $password
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pair))
    $headers = @{ Authorization = "Basic $b64"; Depth = "0" }
    $prev = $ProgressPreference; $ProgressPreference = "SilentlyContinue"
    try {
      try {
        $r = Invoke-WebRequest -Uri $url -Method PROPFIND -Headers $headers -UseBasicParsing -TimeoutSec 30
      } catch {
        $r = Invoke-WebRequest -Uri $url -Method GET -Headers @{ Authorization = "Basic $b64" } -UseBasicParsing -TimeoutSec 30
      }
    } finally { $ProgressPreference = $prev }
    $code = [int]$r.StatusCode
    if ($code -ge 200 -and $code -lt 500 -and $code -ne 401 -and $code -ne 403) {
      return @{ Ok = $true; Status = $code; Error = "" }
    }
    return @{ Ok = $false; Status = $code; Error = "HTTP $code" }
  } catch {
    $resp = $_.Exception.Response
    if ($resp) {
      $code = [int]$resp.StatusCode
      if ($code -eq 401 -or $code -eq 403) { return @{ Ok = $false; Status = $code; Error = "HTTP $code (auth rejected)" } }
      return @{ Ok = $false; Status = $code; Error = "HTTP $code (best-effort inconclusive)" }
    }
    return @{ Ok = $false; Status = 0; Error = $_.Exception.Message }
  }
}

# --- verify sync credentials early (before long on-device work) ---
if ($syncTarget -eq "joplinCloud") {
  while ($true) {
    Info "Verifying Joplin Cloud password for $joplinEmail..."
    $vr = Test-JoplinCloudLogin $joplinEmail $joplinPass
    if ($vr.Ok) {
      Ok "Joplin Cloud credentials verified"
      break
    }
    if ($vr.Status -eq 403 -or $vr.Status -eq 401) {
      Warn "Joplin Cloud rejected email/password ($($vr.Error))."
    } else {
      Warn "Joplin Cloud verify failed: $($vr.Error)"
    }
    if ($NonInteractive) {
      throw "NonInteractive: Joplin Cloud login failed for $joplinEmail ($($vr.Error)). Fix JOPLIN_EMAIL/JOPLIN_PASSWORD and re-run."
    }
    Write-Host "  1) Re-enter email/password and retry  [default]"
    Write-Host "  2) Abort"
    $c = Ask "Choice" "1"
    if ($c -eq "2" -or $c -match '^(?i)a') { throw "Aborted: Joplin Cloud credentials not verified" }
    $joplinEmail = Ask "Joplin Cloud email" $joplinEmail
    $joplinPass = AskSecret "Joplin Cloud password"
  }
} elseif ($syncTarget -eq "joplinServer") {
  while ($true) {
    Info "Verifying Joplin Server login at $syncUrl ..."
    $vr = Test-JoplinServerLogin $syncUrl $syncUser $syncPass
    if ($vr.Ok) {
      Ok "Joplin Server credentials verified"
      break
    }
    Warn "Joplin Server verify failed: $($vr.Error)"
    if ($NonInteractive) {
      throw "NonInteractive: Joplin Server login failed ($($vr.Error))."
    }
    if (-not (AskYes "Re-enter Joplin Server URL/username/password?" $true)) {
      throw "Aborted: Joplin Server credentials not verified"
    }
    $syncUrl = Ask "Sync server URL" $syncUrl
    $syncUser = Ask "Sync username" $syncUser
    $syncPass = AskSecret "Sync password"
  }
} elseif ($syncTarget -in @("webdav","nextcloud")) {
  Info "Best-effort verify of $syncTarget credentials (not all servers support the same probe)..."
  $vr = Test-WebDavBasic $syncUrl $syncUser $syncPass
  if ($vr.Ok) {
    Ok "$syncTarget credentials look OK (HTTP $($vr.Status))"
  } else {
    Warn "$syncTarget verify inconclusive or failed: $($vr.Error)"
    Warn "Installer will continue; fix URL/username/password if jonobones init fails later."
    if ($NonInteractive) {
      Warn "NonInteractive: continuing despite $syncTarget verify result (best-effort only)."
    } elseif (-not (AskYes "Continue with these $syncTarget credentials anyway?" $true)) {
      throw "Aborted: $syncTarget credentials not accepted"
    }
  }
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
  "JONOBONES_PARENT_ID=$parentId"
  "JONOBONES_PARENT_TITLE=$parentTitle"
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
# overwrite confirm is only consumed if config already exists - host cannot know for sure,
# so we always prepend overwrite answer; if no config, that first line becomes the choice
# and breaks. Probe remote after SSH instead.

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

# SSH already verified early (after password); re-check in case HOST/password changed mid-run
Info "Re-checking SSH before deploy..."
Wait-RmSshReady
$sshPassword = $script:sshPassword
try {
  Invoke-Remote "uname -m"
  Ok "SSH works"
} catch {
  Warn "SSH failed after earlier bootstrap."
  throw
}

$arch = Invoke-RemoteCapture "uname -m"
if ($arch -ne "armv7l") { throw "Expected armv7l, got '$arch'" }

Info "Checking tablet internet (Wi-Fi required for npm + Joplin Cloud)..."
$net = Invoke-RemoteCapture "ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1 && echo yes || echo no"
if ($net -ne "yes") {
  Warn "Tablet has no internet right now."
  Warn "Turn on Wi-Fi before continuing - npm install and Joplin Cloud sync will fail without it."
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

# --- binary (prefer dist/, else HTTPS release download; Go optional) ---
$distDir = Join-Path $RepoRoot "dist"
New-Item -ItemType Directory -Force -Path $distDir | Out-Null
$dist = Join-Path $distDir "rm2hwr-linux-armv7"
$releaseTag = $env:RM2_RELEASE_TAG
if (-not $releaseTag) { $releaseTag = $env:RELEASE_TAG }
if (-not $releaseTag) { $releaseTag = "v0.3.8" }
$releaseAssetBase = "https://github.com/schraederbr/RemarkableMyscriptLocal/releases/download/$releaseTag"

function Get-ReleaseAssetHttps([string]$Name, [string]$OutFile, [int]$MinSize = 100000) {
  $url = "$releaseAssetBase/$Name"
  Info "Downloading release asset via HTTPS: $Name ($releaseTag)"
  $prevProgress = $ProgressPreference; $ProgressPreference = "SilentlyContinue"
  try {
    Invoke-WebRequest -Uri $url -OutFile $OutFile -UseBasicParsing
  } finally {
    $ProgressPreference = $prevProgress
  }
  if (-not (Test-Path $OutFile) -or (Get-Item $OutFile).Length -lt $MinSize) {
    throw "HTTPS download failed or too small: $OutFile from $url"
  }
  Ok ("Downloaded {0} ({1:N0} bytes)" -f $OutFile, (Get-Item $OutFile).Length)
}

function Test-GoAvailable {
  try {
    $null = & go version 2>$null
    return ($LASTEXITCODE -eq 0)
  } catch {
    return $false
  }
}

$haveBinary = (Test-Path $dist) -and ((Get-Item $dist).Length -gt 100000)
if ($haveBinary) {
  Ok "Using existing binary $dist"
} else {
  # Prefer HTTPS release download (one-liner / no Go path)
  try {
    Get-ReleaseAssetHttps "rm2hwr-linux-armv7" $dist 100000
    $haveBinary = $true
  } catch {
    Warn "Release binary download failed: $_"
  }
}

if (-not $haveBinary) {
  $goOk = Test-GoAvailable
  $wantBuild = $false
  if ($SkipBuild) {
    throw "dist/rm2hwr-linux-armv7 missing and -SkipBuild set. Download release assets or omit -SkipBuild with Go installed."
  }
  if ($goOk) {
    # Default NO for one-liner-friendly path; only build when user opts in
    $wantBuild = AskYes "dist/rm2hwr-linux-armv7 missing. Cross-compile with local Go?" $false
  } else {
    throw "dist/rm2hwr-linux-armv7 missing, HTTPS release download failed, and Go is not available. Install Go or place the release binary in dist/."
  }
  if ($wantBuild) {
    Info "Building rm2hwr for linux/armv7..."
    $buildPs1 = Join-Path $RepoRoot "scripts\build-armv7.ps1"
    if (Test-Path $buildPs1) { & powershell -NoProfile -File $buildPs1 }
    else {
      Push-Location $RepoRoot
      $env:CGO_ENABLED = "0"; $env:GOOS = "linux"; $env:GOARCH = "arm"; $env:GOARM = "7"
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
    if (-not (Test-Path $dist) -or (Get-Item $dist).Length -lt 100000) { throw "build missing $dist" }
    Ok "Built $dist"
    $haveBinary = $true
  } else {
    throw "No rm2hwr binary available. Re-run and allow download/build, or copy rm2hwr-linux-armv7 into dist/."
  }
}

# Prefetch Node tarball: prefer dist/, then TEMP, else nodejs.org
$nodeVer = "20.20.2"
$nodeTarName = "node-v$nodeVer-linux-armv7l.tar.xz"
$nodeTarDist = Join-Path $distDir $nodeTarName
$nodeTar = Join-Path $env:TEMP $nodeTarName
if ((Test-Path $nodeTarDist) -and ((Get-Item $nodeTarDist).Length -ge 1000000)) {
  $nodeTar = $nodeTarDist
  Ok "Using Node tarball from dist/: $nodeTar"
} elseif (-not (Test-Path $nodeTar) -or (Get-Item $nodeTar).Length -lt 1000000) {
  # Try release asset first (same offline-friendly path as one-liner)
  try {
    Get-ReleaseAssetHttps $nodeTarName $nodeTarDist 1000000
    $nodeTar = $nodeTarDist
  } catch {
    Warn "Release Node tarball unavailable; falling back to nodejs.org: $_"
    Info "Downloading Node $nodeVer armv7l on the PC (tablet often has no curl)..."
    $prevProgress = $ProgressPreference; $ProgressPreference = "SilentlyContinue"
    try {
      Invoke-WebRequest -Uri "https://nodejs.org/dist/v$nodeVer/$nodeTarName" -OutFile $nodeTar -UseBasicParsing
    } finally {
      $ProgressPreference = $prevProgress
    }
  }
} else {
  Ok "Using Node tarball from TEMP: $nodeTar"
}

# Offline jonobones npm bundle (local dist/, else gh, else HTTPS release)
$offlineName = "jonobones-rm2-npm-offline-0.1.5-joplin-3.7.1.tar.gz"
$offlineLocal = Join-Path $distDir $offlineName
if (-not (Test-Path $offlineLocal) -or (Get-Item $offlineLocal).Length -lt 1000000) {
  Info "Fetching offline npm bundle from GitHub Releases..."
  $prevProgress = $ProgressPreference; $ProgressPreference = "SilentlyContinue"
  $ghOk = $false
  try {
    & gh release download --repo schraederbr/RemarkableMyscriptLocal --pattern $offlineName --dir $distDir --clobber
    if ((Test-Path $offlineLocal) -and ((Get-Item $offlineLocal).Length -ge 1000000)) { $ghOk = $true }
  } catch {
    Warn "gh release download failed: $_"
  }
  $ProgressPreference = $prevProgress
  if (-not $ghOk) {
    try {
      Get-ReleaseAssetHttps $offlineName $offlineLocal 1000000
    } catch {
      Warn "HTTPS release download of offline npm bundle failed - will try npm on-device (needs Wi-Fi): $_"
    }
  }
}
if ((Test-Path $offlineLocal) -and ((Get-Item $offlineLocal).Length -ge 1000000)) {
  Ok "Offline npm bundle ready: $offlineLocal"
} else {
  Warn "No offline npm bundle - on-device npm install will need Wi-Fi"
}

# Ensure sqlite binding exists where deployer expects it
$sqliteDist = Join-Path $distDir "node_sqlite3.node"
$sqliteRev = Join-Path $RepoRoot "third_party\revcord\node_sqlite3.node"
if (-not (Test-Path $sqliteRev) -or (Get-Item $sqliteRev).Length -lt 100000) {
  if ((Test-Path $sqliteDist) -and ((Get-Item $sqliteDist).Length -ge 100000)) {
    New-Item -ItemType Directory -Force -Path (Split-Path $sqliteRev) | Out-Null
    Copy-Item -Force $sqliteDist $sqliteRev
    Ok "Copied node_sqlite3.node from dist/ into third_party/revcord"
  } else {
    try {
      Get-ReleaseAssetHttps "node_sqlite3.node" $sqliteDist 100000
      New-Item -ItemType Directory -Force -Path (Split-Path $sqliteRev) | Out-Null
      Copy-Item -Force $sqliteDist $sqliteRev
    } catch {
      throw "Missing third_party/revcord/node_sqlite3.node and could not download it: $_"
    }
  }
}

Info "Deploying files..."
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
  "JONOBONES_PARENT_ID=$parentId"
  "JONOBONES_PARENT_TITLE=$parentTitle"
) | Set-Content -Encoding ascii $metaLocal
Copy-ToRemote $metaLocal "/home/root/hwr/conf/install.meta"
# Keep PARENT_* next to token in jonobones.env (create or patch; init also writes these from install.meta)
$patchParentSh = Join-Path $env:TEMP "rm2-patch-parent.sh"
@"
JB=/home/root/hwr/conf/jonobones.env
mkdir -p /home/root/hwr/conf
touch "`$JB"
tmp=`$(mktemp)
grep -v -E '^JONOBONES_PARENT_(ID|TITLE)=' "`$JB" > "`$tmp" 2>/dev/null || true
PARENT_ID='$parentId'
PARENT_TITLE='$parentTitle'
if [ -n "`$PARENT_ID" ]; then echo "JONOBONES_PARENT_ID=`$PARENT_ID" >> "`$tmp"; fi
if [ -n "`$PARENT_TITLE" ]; then echo "JONOBONES_PARENT_TITLE=`$PARENT_TITLE" >> "`$tmp"; fi
mv "`$tmp" "`$JB"
chmod 0600 "`$JB"
"@ | Set-Content -Encoding ascii $patchParentSh
Copy-ToRemote $patchParentSh "/tmp/rm2-patch-parent.sh"
Invoke-Remote "sh /tmp/rm2-patch-parent.sh; rm -f /tmp/rm2-patch-parent.sh"
Remove-Item $patchParentSh -Force -ErrorAction SilentlyContinue
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

Info "Installing systemd timer for sync-recent (interval=$syncIntervalHours h)..."
# RM2 has systemctl but no crond; BusyBox crontab is a no-op on real hardware.
Copy-ToRemote (Join-Path $RepoRoot "scripts\on-device\hwr-sync-recent.service") "/tmp/hwr-sync-recent.service"
Copy-ToRemote (Join-Path $RepoRoot "scripts\on-device\hwr-sync-recent.timer") "/tmp/hwr-sync-recent.timer"
$timerLocal = Join-Path $env:TEMP "rm2-install-timer.sh"
@(
  '#!/bin/sh'
  'set -e'
  'HOURS=' + $syncIntervalHours
  'UNIT_DIR=/etc/systemd/system'
  'chmod 0755 /home/root/hwr/scripts/sync-recent.sh'
  'cp /tmp/hwr-sync-recent.service "$UNIT_DIR/hwr-sync-recent.service"'
  'cp /tmp/hwr-sync-recent.timer "$UNIT_DIR/hwr-sync-recent.timer"'
  '# Drop any leftover sync-recent crontab line from older installers (harmless if no crontab)'
  'if command -v crontab >/dev/null 2>&1; then'
  '  TMP=/tmp/rm2-crontab.new'
  '  crontab -l 2>/dev/null | grep -v sync-recent.sh | grep -v rm2hwr-sync-recent > "$TMP" || true'
  '  if [ -s "$TMP" ]; then crontab "$TMP" 2>/dev/null || true; else crontab -r 2>/dev/null || true; fi'
  '  rm -f "$TMP"'
  'fi'
  'if [ -n "$HOURS" ] && [ "$HOURS" -gt 0 ] 2>/dev/null; then'
  '  # Rewrite OnUnitActiveSec from SYNC_INTERVAL_HOURS (OnBootSec stays 5min)'
  '  sed -i "s/^OnUnitActiveSec=.*/OnUnitActiveSec=${HOURS}h/" "$UNIT_DIR/hwr-sync-recent.timer"'
  '  systemctl daemon-reload'
  '  systemctl enable hwr-sync-recent.timer'
  '  systemctl start hwr-sync-recent.timer'
  '  echo "systemd timer enabled interval=${HOURS}h"'
  '  systemctl list-timers --all 2>/dev/null | grep -E "hwr-sync|NEXT|UNIT" || systemctl status hwr-sync-recent.timer --no-pager || true'
  'else'
  '  systemctl daemon-reload'
  '  systemctl stop hwr-sync-recent.timer 2>/dev/null || true'
  '  systemctl disable hwr-sync-recent.timer 2>/dev/null || true'
  '  echo "systemd timer disabled (SYNC_INTERVAL_HOURS=0)"'
  'fi'
  'rm -f /tmp/hwr-sync-recent.service /tmp/hwr-sync-recent.timer'
) | Set-Content -Encoding ascii $timerLocal
Copy-ToRemote $timerLocal "/tmp/rm2-install-timer.sh"
Invoke-Remote "chmod 0755 /tmp/rm2-install-timer.sh; sh /tmp/rm2-install-timer.sh; rm -f /tmp/rm2-install-timer.sh"
Ok "Systemd timer configured (SYNC_INTERVAL_HOURS=$syncIntervalHours)"

if ($SkipJonobones) {
  Ok "SkipJonobones set - done after deploy"
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

Info "Polling /tmp/rm2-install.status (~60s heartbeat; Ctrl+C here is safe - job keeps running on tablet)..."
$deadline = (Get-Date).AddHours(6)
$pollStarted = Get-Date
$lastHeartbeat = [datetime]::MinValue
$phase = "pending"
while ((Get-Date) -lt $deadline) {
  Start-Sleep -Seconds 5
  try {
    $st = Invoke-RemoteCapture "cat /tmp/rm2-install.status 2>/dev/null || echo phase=pending"
  } catch {
    Warn "SSH blip while polling - retrying (on-device job still running)"
    continue
  }
  $phase = Get-RmInstallPhase $st
  if ($phase -eq "ok") { Ok "On-device job finished successfully"; break }
  if ($phase -eq "fail") {
    Warn "On-device job failed - last log lines:"
    Invoke-Remote "tail -n 40 /tmp/rm2-install.log" | Out-Host
    throw "install-job failed"
  }
  $elapsed = (Get-Date) - $pollStarted
  if (((Get-Date) - $lastHeartbeat).TotalSeconds -ge 60) {
    $lastHeartbeat = Get-Date
    try {
      Write-RmInstallHeartbeat $elapsed
    } catch {
      Warn "Heartbeat SSH blip - retrying next cycle (on-device job still running)"
    }
  }
}
if ($phase -ne "ok") { throw "Timed out waiting for install-job" }

Ok "Installer finished"
Write-Host ""
Warn "First jonobones <-> Joplin Cloud sync may take a LONG time (large vaults / many attachments: tens of minutes or more)."
Warn "Keep Wi-Fi on. Do NOT unplug / do NOT assume install failed while jonobones is still syncing."
Warn "Watch: /tmp/jonobones-start.log and install heartbeat du of the jonobones profile."
Write-Host ""
Write-Host "Logs on tablet: /tmp/rm2-install.log  /tmp/jonobones-start.log"
Write-Host "MyScript env:   /home/root/hwr/conf/hwr.env"
Write-Host "API token env:  /home/root/hwr/conf/jonobones.env"
Write-Host "Sync script:    /home/root/hwr/scripts/sync-recent.sh"
Write-Host "Sync state:     /home/root/hwr/state/<doc-uuid>.json"
Write-Host "Timer interval: $syncIntervalHours h (0=disabled). Change SYNC_INTERVAL_HOURS in hwr.env + re-run installer, or systemctl edit hwr-sync-recent.timer."