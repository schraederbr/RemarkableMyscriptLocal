<#
.SYNOPSIS
  Build jonobones offline npm tarball for RM2 release assets.
#>
$ErrorActionPreference = "Stop"
$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$work = Join-Path $env:TEMP "rm2-offline-pack"
$nodeWin = Join-Path $work "node-win"
$npm = Join-Path $nodeWin "npm.cmd"
if (-not (Test-Path $npm)) {
  throw "Run once: download portable Node 20 win-x64 into $nodeWin (see docs) or install Node."
}
# Delegate: documented in docs/offline-npm-bundle.md - keep installer download URL stable.
Write-Host "Use the packaging steps in docs/offline-npm-bundle.md (or re-run the release workflow)."
Write-Host "Expected output: dist/jonobones-rm2-npm-offline-0.1.5-joplin-3.7.1.tar.gz"