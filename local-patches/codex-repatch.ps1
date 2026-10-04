<#
.SYNOPSIS
  Rebuild the npm-installed Codex CLI with local patches and swap the binaries in.

.DESCRIPTION
  Codex's elevated Windows sandbox hangs when a thread starts from the user
  profile root (openai/codex#50699). The fixes live on a branch of the
  royalaid/codex fork in ~/git/codex:
    - skip the broad AppData roots as write roots;
    - give children of the cwd the cwd's capability SID, so deny carveouts
      such as ~/.codex get one ACE instead of one per profile child.
  Run this after every `npm i -g @openai/codex` upgrade, because npm replaces
  the binaries.

  Steps: read the installed version, cherry-pick the patch commits onto the
  matching upstream tag (rust-v<version>), build the release binaries, then
  rename each shipped binary to <name>.upstream and copy the patched one in.
  Renaming works while app-servers still run the old binary; restart them
  (T3, Codex CLI sessions) to pick the patch up.

.PARAMETER Version
  Codex version to patch. Defaults to the installed npm package version.

.PARAMETER SkipBuild
  Install already-built target\release binaries without rebuilding.

.PARAMETER Restore
  Put the upstream binaries back.

.EXAMPLE
  codex-repatch.ps1            # after npm i -g @openai/codex
  codex-repatch.ps1 -Restore   # undo
#>
[CmdletBinding()]
param(
    [string]$Version,
    [switch]$SkipBuild,
    [switch]$Restore
)

$ErrorActionPreference = 'Stop'

$Repo        = Join-Path $HOME 'git\codex'
$PatchBranch = 'fix/windows-sandbox-skip-broad-appdata-write-roots'
$NpmPkg      = Join-Path $env:APPDATA 'npm\node_modules\@openai\codex'
$Vendor      = Join-Path $NpmPkg 'node_modules\@openai\codex-win32-x64\vendor\x86_64-pc-windows-msvc'
$Release     = Join-Path $Repo 'codex-rs\target\release'

# Every shipped binary that links codex-windows-sandbox; they must agree on capability SIDs.
$Binaries = @(
    @{ Bin = 'codex';                       Dest = Join-Path $Vendor 'bin\codex.exe' }
    @{ Bin = 'codex-windows-sandbox-setup'; Dest = Join-Path $Vendor 'codex-resources\codex-windows-sandbox-setup.exe' }
    @{ Bin = 'codex-command-runner';        Dest = Join-Path $Vendor 'codex-resources\codex-command-runner.exe' }
)

function Invoke-Git {
    $out = & git -C $Repo @args
    if ($LASTEXITCODE -ne 0) { throw "git $($args -join ' ') failed ($LASTEXITCODE)" }
    $out
}

function Remove-ParkedCopies([string]$dest) {
    $dir  = Split-Path $dest
    $leaf = Split-Path $dest -Leaf
    # Copies still loaded by a running process stay until the next run.
    Get-ChildItem $dir -Filter "$leaf.old-*" | Remove-Item -ErrorAction SilentlyContinue
}

function Set-Parked([string]$dest) {
    # A running process may hold the file, so rename it instead of overwriting.
    Move-Item $dest "$dest.old-$(Get-Date -Format yyyyMMddHHmmss)"
}

foreach ($b in $Binaries) {
    if (-not (Test-Path $b.Dest)) { throw "Shipped binary not found: $($b.Dest)" }
}

if ($Restore) {
    foreach ($b in $Binaries) {
        $upstream = "$($b.Dest).upstream"
        if (-not (Test-Path $upstream)) { Write-Warning "No $upstream; leaving $($b.Dest)"; continue }
        Set-Parked $b.Dest
        Move-Item $upstream $b.Dest
        Remove-Item "$($b.Dest).patched" -ErrorAction SilentlyContinue
        Remove-ParkedCopies $b.Dest
    }
    Write-Host "Restored upstream binaries."
    return
}

if (-not $Version) {
    $Version = (Get-Content (Join-Path $NpmPkg 'package.json') -Raw | ConvertFrom-Json).version
}
$Tag    = "rust-v$Version"
$Branch = "local/$Tag-patched"
Write-Host "Patching Codex $Version ($Tag -> $Branch)"

if (-not $SkipBuild) {
    if (Invoke-Git status --porcelain) { throw "$Repo has uncommitted changes; commit or stash them first." }
    $previous = Invoke-Git rev-parse --abbrev-ref HEAD

    Invoke-Git fetch upstream tag $Tag --no-tags
    Invoke-Git fetch upstream main

    # Patch commits: what the local patch branch adds on top of upstream main.
    $base    = Invoke-Git merge-base $PatchBranch upstream/main
    $commits = @(Invoke-Git rev-list --reverse --no-merges "$base..$PatchBranch")
    if ($commits.Count -eq 0) { throw "No patch commits found on $PatchBranch." }

    & git -C $Repo rev-parse --verify --quiet "refs/heads/$Branch" | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Reusing existing $Branch; delete it to re-cherry-pick."
        Invoke-Git switch $Branch
    } else {
        Invoke-Git switch -c $Branch $Tag
        foreach ($c in $commits) {
            & git -C $Repo cherry-pick $c
            if ($LASTEXITCODE -ne 0) {
                & git -C $Repo cherry-pick --abort
                & git -C $Repo switch $previous
                & git -C $Repo branch -D $Branch
                throw "Patch commit $c does not apply to $Tag. Rebase $PatchBranch onto upstream/main, then rerun."
            }
        }
    }

    # Match the release workflow (.github/workflows/rust-release-windows.yml).
    $env:LIBSQLITE3_FLAGS  = 'SQLITE_DISABLE_INTRINSIC'
    $env:STABLE_GIT_COMMIT = Invoke-Git rev-parse HEAD
    $cargoArgs = @('build', '--release') + ($Binaries | ForEach-Object { '--bin', $_.Bin })
    Push-Location (Join-Path $Repo 'codex-rs')
    try {
        $p = Start-Process cargo -ArgumentList $cargoArgs -NoNewWindow -PassThru
        $p.PriorityClass = 'BelowNormal'
        $p.WaitForExit()
        if ($p.ExitCode -ne 0) { throw "cargo build failed ($($p.ExitCode))" }
    } finally {
        Pop-Location
        # Release tags stamp the version into Cargo.toml but not Cargo.lock, so cargo rewrites it.
        # Keep that on the local build branch so the checkout stays clean.
        if (& git -C $Repo status --porcelain -- codex-rs/Cargo.lock) {
            & git -C $Repo commit -q -m "Cargo.lock version stamp for $Tag" -- codex-rs/Cargo.lock
        }
        & git -C $Repo switch $previous | Out-Null
    }
}

$codexBuilt = Join-Path $Release 'codex.exe'
$reported = (& $codexBuilt --version).Trim()
if ($reported -ne "codex-cli $Version") { throw "Built binary reports '$reported', expected 'codex-cli $Version'." }

foreach ($b in $Binaries) {
    $built  = Join-Path $Release "$($b.Bin).exe"
    $marker = "$($b.Dest).patched"
    if (-not (Test-Path $built)) { throw "No build at $built" }

    # Keep the shipped copy once; a re-patch must not overwrite it with an earlier patched build.
    $isPatched = (Test-Path $marker) -and ((Get-Content $marker -Raw).Trim() -eq (Get-FileHash $b.Dest).Hash)
    if ($isPatched) { Set-Parked $b.Dest } else { Move-Item $b.Dest "$($b.Dest).upstream" -Force }
    Copy-Item $built $b.Dest
    (Get-FileHash $b.Dest).Hash | Set-Content $marker
    Remove-ParkedCopies $b.Dest
    Write-Host "Installed $($b.Dest)"
}

Write-Host "Patched Codex $Version ($reported). Upstream copies saved as *.upstream."
Write-Host "Restart running Codex app-servers (T3, CLI sessions) to load it."
