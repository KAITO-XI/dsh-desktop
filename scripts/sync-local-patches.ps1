#Requires -Version 5.1
<#
.SYNOPSIS
  Carry the local patch stack onto the upstream tag that matches the installed DSH Desktop release.

.DESCRIPTION
  Implements the policy in docs/local-branch-strategy.md:
    1. Compare manifest baseline vs installed app version (installedAppProbe).
    2. Fetch the matching tag (origin, then mirror fallback).
    3. Create/switch to local/v<X.Y.Z>-patches and cherry-pick all patch commits.
    4. yarn install + build (registry via company Nexus by default).
    5. Verify rules from local-patches.json.
    6. Rewrite the manifest and commit.

.PARAMETER TargetVersion
  Explicit target tag (e.g. v2.0.14). Default: detected from the installed app.

.PARAMETER Check
  Report drift only; exit 1 when out of sync, 0 when in sync.

.PARAMETER SkipBuild
  Stop after cherry-pick (use when resuming after conflict resolution).

.PARAMETER YarnJs
  Path to the Yarn 4 bundle (yarn.js). Default: $env:DSH_YARN_JS, then the corepack
  cache glob, then plain "corepack yarn" as a last resort (corepack can hang on this
  machine - prefer the cached bundle).

.EXAMPLE
  scripts/sync-local-patches.ps1 -Check
  scripts/sync-local-patches.ps1
#>
param(
  [string]$TargetVersion,
  [switch]$Check,
  [switch]$SkipBuild,
  [switch]$SkipMachineSetup,
  [string]$YarnJs,
  [string]$Registry = 'https://nexus.uihcloud.cn/repository/npm-group/'
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Set-Location $repo

$manifestPath = Join-Path $repo 'local-patches.json'
if (!(Test-Path $manifestPath)) { throw "manifest not found: $manifestPath" }
$manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json

# --- 0. machine-local setup (always, independent of drift) ----------------------
# A fresh machine starts already "in sync" (baseline == installed version), so this must
# run before the drift check or provisioning would silently never happen.
if ($manifest.machineSetup) {
  if ($SkipMachineSetup) {
    "SkipMachineSetup set - skipped $($manifest.machineSetup.Count) machine setup step(s)"
  } else {
    foreach ($step in $manifest.machineSetup) {
      $scriptPath = Join-Path $repo $step.script
      if (!(Test-Path $scriptPath)) { throw "machine setup script missing: $($step.script)" }
      "machine setup: $($step.name)"
      $stepArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath)
      if ($Check -and $step.checkFlag) { $stepArgs += $step.checkFlag }
      & powershell.exe @stepArgs
      if ($LASTEXITCODE -ne 0) { throw "machine setup failed: $($step.name)" }
    }
  }
}

# --- 1. resolve target version -------------------------------------------------
if (-not $TargetVersion) {
  $probe = $manifest.installedAppProbe
  if (!(Test-Path $probe)) { throw "installed app probe missing: $probe (is DSH Desktop installed?)" }
  $TargetVersion = 'v' + (Get-Content $probe -Raw | ConvertFrom-Json).version
}
$baseline = $manifest.baseline
"manifest baseline : $baseline"
"target version    : $TargetVersion"

if ($TargetVersion -eq $baseline) {
  "in sync - nothing to do."
  if ($Check) { exit 0 } else { return }
}
if ($Check) {
  "DRIFT detected: rerun without -Check to sync (fetch tag, cherry-pick $($manifest.patches.Count) patch topic(s), build, verify)."
  exit 1
}

# --- 2. fetch the target tag ---------------------------------------------------
$remotes = @('origin')
$allRemotes = git remote
foreach ($r in @('mirror')) { if ($allRemotes -contains $r) { $remotes += $r } }
$fetched = $false
foreach ($r in $remotes) {
  foreach ($attempt in 1..3) {
    git -c http.version=HTTP/1.1 fetch $r --depth=1 "refs/tags/${TargetVersion}:refs/tags/${TargetVersion}"
    if ($LASTEXITCODE -eq 0) { "fetched $TargetVersion via $r (attempt $attempt)"; $fetched = $true; break }
    Start-Sleep -Seconds 3
  }
  if ($fetched) { break }
}
if (!$fetched) { throw "could not fetch tag $TargetVersion from: $($remotes -join ', ')" }

# --- 3. branch -----------------------------------------------------------------
$sourceBranch = git branch --show-current
$newBranch = "local/$TargetVersion-patches"
$existing = git branch --list $newBranch
if ($existing) {
  git switch $newBranch
  if ($LASTEXITCODE -ne 0) { throw "switch to existing $newBranch failed" }
  git reset --hard $TargetVersion
} else {
  git switch -c $newBranch $TargetVersion
  if ($LASTEXITCODE -ne 0) { throw "could not create $newBranch at $TargetVersion" }
}

# --- 4. cherry-pick the patch stack --------------------------------------------
$commits = @(git rev-list --reverse "$baseline..$sourceBranch")
if ($commits.Count -eq 0) { throw "no patch commits found in $baseline..$sourceBranch - nothing to carry" }
"replaying $($commits.Count) commit(s):"
$commits | ForEach-Object { "  $(git log -1 --format='%h %s' $_)" }
foreach ($c in $commits) {
  git cherry-pick $c
  if ($LASTEXITCODE -ne 0) {
    throw @"
cherry-pick $c conflicted.
Resolve, run 'git cherry-pick --continue', then re-run this script with:
  -TargetVersion $TargetVersion -SkipBuild
"@
  }
}

if ($SkipBuild) { "SkipBuild set - stopping before install/build. Re-run with -TargetVersion $TargetVersion -SkipBuild to resume after conflicts are resolved."; return }

# --- 5. install + build --------------------------------------------------------
if (-not $YarnJs) { $YarnJs = $env:DSH_YARN_JS }
if (-not $YarnJs) {
  $cached = Get-ChildItem "$env:LOCALAPPDATA\node\corepack\v1\yarn\*\yarn.js" -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if ($cached) { $YarnJs = $cached.FullName }
}
$env:YARN_NPM_REGISTRY_SERVER = $Registry
if ($YarnJs) {
  "using yarn bundle: $YarnJs"
  node $YarnJs install
  if ($LASTEXITCODE -ne 0) { throw 'yarn install failed' }
  node $YarnJs workspace dsh-plugin-desktop run build
  if ($LASTEXITCODE -ne 0) { throw 'build failed' }
} else {
  'no cached yarn bundle found; trying corepack (may hang - set -YarnJs or DSH_YARN_JS if it stalls)'
  corepack yarn install
  if ($LASTEXITCODE -ne 0) { throw 'yarn install failed' }
  corepack yarn workspace dsh-plugin-desktop run build
  if ($LASTEXITCODE -ne 0) { throw 'build failed' }
}

# --- 6. verify -----------------------------------------------------------------
$failed = @()
foreach ($rule in $manifest.verify) {
  $raw = [string]$rule.file
  if ($raw.StartsWith('~')) { $raw = $env:USERPROFILE + $raw.Substring(1) }
  $file = if ([IO.Path]::IsPathRooted($raw)) { $raw } else { Join-Path $repo $raw }
  if (!(Test-Path $file)) { $failed += "$($rule.name): file missing $($rule.file)"; continue }
  $content = Get-Content $file -Raw
  $ok = $true
  if ($rule.mustContain -and $content.IndexOf([string]$rule.mustContain) -lt 0) { $ok = $false }
  if ($rule.mustMatch -and $content -notmatch [string]$rule.mustMatch) { $ok = $false }
  if ($ok) { "verify OK: $($rule.name)" } else { $failed += "$($rule.name): rule not satisfied" }
}
if ($failed.Count -gt 0) { $failed | ForEach-Object { "verify FAILED: $_" }; throw 'verification failed' }

# --- 7. update manifest + commit ------------------------------------------------
$manifest.baseline = $TargetVersion
$manifest.branch = $newBranch
$manifest | ConvertTo-Json -Depth 10 | Set-Content $manifestPath -Encoding utf8
git add local-patches.json
git -c user.name='KAITO-XI' -c user.email='KAITO-XI@users.noreply.github.com' commit -m "chore(local): sync patches onto $TargetVersion"
if ($LASTEXITCODE -ne 0) { throw 'manifest commit failed' }

# --- 8. push (fork first, then the private backup) ------------------------------
$targets = @()
if ($manifest.pushRemote) { $targets += $manifest.pushRemote }
if ($manifest.backupRemote -and ($manifest.backupRemote -ne $manifest.pushRemote)) { $targets += $manifest.backupRemote }
foreach ($remoteName in $targets) {
  if ((git remote) -notcontains $remoteName) {
    "remote '$remoteName' not configured - push manually: git push $remoteName $newBranch"
    continue
  }
  $pushed = $false
  foreach ($attempt in 1..3) {
    git push $remoteName $newBranch
    if ($LASTEXITCODE -eq 0) { "pushed $newBranch to $remoteName"; $pushed = $true; break }
    Start-Sleep -Seconds 5
  }
  if (-not $pushed) { "WARNING: push to '$remoteName' failed after 3 attempts" }
}
"done: $newBranch @ $TargetVersion"
