<#
.SYNOPSIS
  Detect an npm Codex whose binaries are not the patched builds, and rebuild it.

.DESCRIPTION
  `npm i -g @openai/codex` (by hand, by T3's updater or by Codex's own update
  prompt) replaces the patched binaries with upstream ones, and the Windows
  sandbox hang comes back. codex-repatch.ps1 records the hash of every binary it
  installs in <binary>.patched; this check compares those markers with the
  installed files.

  When a binary does not match, it starts codex-repatch.ps1 in the background
  (hidden, logged under ~/.local/state/codex-repatch) and returns at once, so
  own-tools-sync does not wait out a build that can take most of an hour. The
  rebuild is started through Win32_Process.Create so it inherits none of this
  script's handles, including the caller's output pipe.

  A rebuild that finished without leaving the binaries patched is not retried
  for the same installed codex.exe: the check fails and names the log. Delete
  ~/.local/state/codex-repatch/attempt.json to retry.

  Running app-servers (T3, CLI sessions) keep the old binary until restarted.
#>
[CmdletBinding()]
param(
    # Overrides for tests; the defaults are the real install.
    [string]$NpmPkg  = (Join-Path $env:APPDATA 'npm\node_modules\@openai\codex'),
    [string]$State   = (Join-Path $HOME '.local\state\codex-repatch'),
    [string]$Repatch = (Join-Path $PSScriptRoot 'codex-repatch.ps1')
)

$ErrorActionPreference = 'Stop'

$Vendor  = Join-Path $NpmPkg 'node_modules\@openai\codex-win32-x64\vendor\x86_64-pc-windows-msvc'
$Attempt = Join-Path $State 'attempt.json'
$Binaries = @(
    Join-Path $Vendor 'bin\codex.exe'
    Join-Path $Vendor 'codex-resources\codex-windows-sandbox-setup.exe'
    Join-Path $Vendor 'codex-resources\codex-command-runner.exe'
)

if (-not (Test-Path (Join-Path $Vendor 'bin\codex.exe'))) {
    Write-Output 'npm Codex is not installed; nothing to check.'
    exit 0
}

$version = (Get-Content (Join-Path $NpmPkg 'package.json') -Raw | ConvertFrom-Json).version
$unpatched = @(foreach ($dest in $Binaries) {
    $marker = "$dest.patched"
    $isPatched = (Test-Path $dest) -and (Test-Path $marker) -and
        ((Get-Content $marker -Raw).Trim() -eq (Get-FileHash $dest).Hash)
    if (-not $isPatched) { Split-Path $dest -Leaf }
})

if ($unpatched.Count -eq 0) {
    Write-Output "Codex $version is patched."
    exit 0
}

$key = "$version $((Get-FileHash $Binaries[0]).Hash)"
if (Test-Path $Attempt) {
    $last = Get-Content $Attempt -Raw | ConvertFrom-Json
    $proc = Get-Process -Id $last.pid -ErrorAction SilentlyContinue
    if ($proc -and $proc.StartTime.ToUniversalTime().Ticks -eq [int64]$last.started) {
        Write-Output "Rebuild for Codex $($last.version) is still running (pid $($last.pid)); log $($last.log)."
        exit 0
    }
    if ($last.key -eq $key) {
        Write-Output "Codex $version is unpatched ($($unpatched -join ', ')) after a finished rebuild; see $($last.log). Delete $Attempt to retry."
        exit 1
    }
}

New-Item -ItemType Directory -Force $State | Out-Null
$log = Join-Path $State "repatch-$(Get-Date -Format yyyyMMdd-HHmmss).log"
$pwsh = (Get-Process -Id $PID).Path
$commandLine = "`"$pwsh`" -NoProfile -NonInteractive -Command `"& '$Repatch' *> '$log'; 'EXIT ' + `$LASTEXITCODE | Add-Content '$log'`""
$startup = New-CimInstance -ClassName Win32_ProcessStartup -ClientOnly -Property @{ ShowWindow = [uint16]0 }
$created = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
    CommandLine                = $commandLine
    CurrentDirectory           = $HOME
    ProcessStartupInformation  = $startup
}
if ($created.ReturnValue -ne 0) {
    Write-Output "Could not start codex-repatch.ps1 (Win32_Process.Create returned $($created.ReturnValue))."
    exit 1
}
$started = (Get-Process -Id $created.ProcessId).StartTime.ToUniversalTime().Ticks
@{ key = $key; version = $version; pid = $created.ProcessId; started = $started; log = $log } |
    ConvertTo-Json | Set-Content $Attempt

Write-Output "Codex $version is unpatched ($($unpatched -join ', ')); started codex-repatch.ps1 (pid $($created.ProcessId)), log $log."
Write-Output 'Restart T3 and other Codex app-servers once the rebuild installs.'
Write-Output 'own-tools-sync: updated'
