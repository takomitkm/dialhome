# migrate-to-D.ps1
# Relocates the connector to D:\zc on the campus Windows box and refreshes it with the
# current payload from the relay (so it also picks up fixes to install.ps1 etc.).
# Everything is user-scope: no admin, no UAC.
#   1. stop + unregister the connector running from the old root
#   2. fetch the current payload from 102 and extract it into D:\zc\magpie-connector
#   3. install there (rewrites absolute paths, re-registers autostart, hardens the key)
#   4. start it hidden and show the first log lines
#   5. optionally relocate the magpie exe to D:\zc\magpie (stop old -> start new -> verify, else roll back)
#   6. delete the old root
# PowerShell 5.1 compatible. ASCII-only source. Never elevates.
param(
    [string]$Root = '',
    [string]$TargetRoot = 'D:\zc\magpie-connector',
    [string]$MagpieDir = 'D:\zc\magpie',
    [string]$RelayHost = '10.101.54.192',
    [int]$RelayPort = 18322,
    [string]$RelayUser = 'user',
    [string]$PayloadLocal = '',
    [int]$RemotePort = 13425,
    [int]$GatewayPort = 3425,
    [switch]$NoMagpie,
    [switch]$KeepOld,
    [switch]$NoAutostart,
    [switch]$NoStart,
    [switch]$DryRun
)
$ErrorActionPreference = 'Continue'

function Say([string]$Level, [string]$Message) { Write-Host ('[{0}] {1}' -f $Level, $Message) }

if ([string]::IsNullOrWhiteSpace($Root)) { $Root = (Join-Path $env:LOCALAPPDATA 'magpie-connector') }
$oldRoot = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Root)
$elevated = (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Say 'INFO' ('user=' + $env:USERNAME + '  elevated=' + $elevated + '  (user-scope only)')
Say 'INFO' ('old root : ' + $oldRoot)
Say 'INFO' ('new root : ' + $TargetRoot)

# ---- preflight -------------------------------------------------------------
$driveRoot = [IO.Path]::GetPathRoot($TargetRoot)
if (-not (Test-Path -LiteralPath $driveRoot)) { Say 'ERROR' ('drive does not exist: ' + $driveRoot + '; nothing changed.'); exit 2 }
if ($TargetRoot -eq $oldRoot) { Say 'ERROR' 'target equals source; nothing to do.'; exit 0 }
if ($DryRun) {
    Say 'INFO' '[DRY-RUN] steps: stop old connector -> fetch payload -> extract to target -> install -> start -> (magpie move) -> delete old root'
    exit 0
}

# ---- 1. stop + unregister the old install ---------------------------------
if (Test-Path -LiteralPath $oldRoot) {
    Say 'INFO' 'stopping + unregistering the old connector...'
    $un = Join-Path $oldRoot 'uninstall.ps1'
    if (Test-Path -LiteralPath $un) { & $un -Root $oldRoot 2>&1 | ForEach-Object { Say 'INFO' ('  ' + $_) } }
    else {
        $procs = Get-CimInstance -ClassName Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like '*connector.ps1*run*' }
        foreach ($p in $procs) { & taskkill.exe /PID $p.ProcessId /T /F 2>$null | Out-Null }
    }
    Start-Sleep -Seconds 2
} else { Say 'WARN' ('old root not found (' + $oldRoot + '); continuing with a fresh install') }

# ---- 2. fetch the current payload and extract into the target --------------
Say 'INFO' 'fetching the current payload from the relay...'
$b64File = Join-Path $env:TEMP 'mc.b64'
$zipFile = Join-Path $env:TEMP 'mc.zip'
if ($PayloadLocal -and (Test-Path -LiteralPath $PayloadLocal)) {
    Copy-Item -LiteralPath $PayloadLocal -Destination $b64File -Force
    Say 'INFO' ('using local payload: ' + $PayloadLocal)
} else {
    ssh -p $RelayPort ('{0}@{1}' -f $RelayUser, $RelayHost) 'cat ~/.magpie-connector/payload.b64' > $b64File
    if ($LASTEXITCODE -ne 0) { Say 'ERROR' 'ssh fetch failed (check the 102 password / reachability); nothing changed.'; exit 3 }
}
$raw = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($b64File)) -replace '[^A-Za-z0-9+/=]', ''
try { [IO.File]::WriteAllBytes($zipFile, [Convert]::FromBase64String($raw)) }
catch { Say 'ERROR' 'payload did not decode; nothing changed.'; exit 3 }

if (Test-Path -LiteralPath $TargetRoot) {
    Say 'INFO' ('clearing an existing ' + $TargetRoot)
    & takeown.exe /f $TargetRoot /r /d n 2>$null | Out-Null
    & icacls.exe  $TargetRoot /reset /t /c /q 2>$null | Out-Null
    Remove-Item -LiteralPath $TargetRoot -Recurse -Force -ErrorAction SilentlyContinue
}
New-Item -ItemType Directory -Path $TargetRoot -Force -ErrorAction Stop | Out-Null
Expand-Archive -Force $zipFile $TargetRoot
$need = @('install.ps1', 'connector.ps1', ('secrets\id_ed25519_campus-win_{0}' -f $RemotePort))
$miss = @($need | Where-Object { -not (Test-Path -LiteralPath (Join-Path $TargetRoot $_)) })
if ($miss.Count -gt 0) { Say 'ERROR' ('payload incomplete, missing: ' + ($miss -join ', ')); exit 3 }
Say 'INFO' 'extracted (includes the newest install.ps1)'

# ---- 3. install into the target ------------------------------------------
$autoMode = 'auto'
if ($NoAutostart) { $autoMode = 'none' }
Say 'INFO' 'installing at the new location...'
& (Join-Path $TargetRoot 'install.ps1') -Root $TargetRoot -SourceDir $TargetRoot `
    -SshHost $RelayHost -SshPort $RelayPort -SshUser $RelayUser `
    -IdentityFile (Join-Path $TargetRoot ('secrets\id_ed25519_campus-win_{0}' -f $RemotePort)) `
    -KnownHostsFile (Join-Path $TargetRoot 'secrets\known_hosts') `
    -RemotePort $RemotePort -DefaultPort $GatewayPort -Autostart $autoMode 2>&1 | ForEach-Object { Say 'INFO' ('  ' + $_) }

$lnk = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup\MagpieTunnelConnector.lnk'
if ((Get-ScheduledTask -TaskName 'MagpieTunnelConnector' -ErrorAction SilentlyContinue) -and (Test-Path -LiteralPath $lnk)) {
    Remove-Item -LiteralPath $lnk -Force -ErrorAction SilentlyContinue
    Say 'INFO' 'removed stale startup shortcut (the scheduled task is authoritative)'
}

# ---- 4. start from the new root ------------------------------------------
if ($NoStart) { Say 'INFO' 'not starting (-NoStart)' }
else {
    Say 'INFO' 'starting the connector from the new root (hidden)...'
    $arg = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + (Join-Path $TargetRoot 'connector.ps1') + '" run'
    Start-Process -FilePath 'powershell.exe' -ArgumentList $arg -WindowStyle Hidden | Out-Null
    Start-Sleep -Seconds 8
    $logNew = Join-Path $TargetRoot 'logs\connector.log'
    if (Test-Path -LiteralPath $logNew) {
        Say 'INFO' 'new log tail:'
        Get-Content -LiteralPath $logNew -Tail 6 | ForEach-Object { Say 'INFO' ('  ' + $_) }
    }
}

# ---- 5. optionally relocate the magpie binary ----------------------------
if ($NoMagpie) { Say 'INFO' 'skipping magpie relocation (-NoMagpie)' }
else {
    Say 'INFO' 'relocating the magpie binary...'
    $owner = $null
    try {
        $c = Get-NetTCPConnection -LocalPort $GatewayPort -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($c -and $c.OwningProcess -gt 0) { $owner = Get-Process -Id $c.OwningProcess -ErrorAction SilentlyContinue }
    } catch { }
    $oldExe = $null
    if ($owner -and $owner.Path) { $oldExe = $owner.Path }
    if (-not $oldExe) {
        foreach ($cand in @((Join-Path $env:LOCALAPPDATA 'magpie\magpie-windows-amd64.exe'), (Join-Path $env:USERPROFILE 'Downloads\magpie-windows-amd64.exe'))) {
            if (Test-Path -LiteralPath $cand) { $oldExe = $cand; break }
        }
    }
    if (-not $oldExe) { Say 'WARN' 'could not locate the magpie exe; leaving it alone' }
    elseif ($oldExe -like 'D:\zc\*') { Say 'INFO' ('magpie already on D: (' + $oldExe + ')') }
    else {
        New-Item -ItemType Directory -Path $MagpieDir -Force | Out-Null
        $newExe = Join-Path $MagpieDir ([System.IO.Path]::GetFileName($oldExe))
        Say 'INFO' ('copying ' + $oldExe + ' -> ' + $newExe)
        Copy-Item -LiteralPath $oldExe -Destination $newExe -Force -ErrorAction Stop
        $wasRunning = [bool]$owner
        if ($wasRunning) {
            Say 'INFO' ('stopping magpie pid ' + $owner.Id + ' (the gateway blips ~20s; the connector reconnects)')
            & taskkill.exe /PID $owner.Id /T /F 2>$null | Out-Null
            Start-Sleep -Seconds 3
        }
        Say 'INFO' 'starting magpie from D: (tray, hidden)'
        Start-Process -FilePath $newExe -ArgumentList 'tray' -WindowStyle Hidden | Out-Null
        $up = $false
        for ($i = 0; $i -lt 24; $i++) {
            Start-Sleep -Milliseconds 750
            try { $r = Invoke-WebRequest -Uri ('http://127.0.0.1:{0}/api/hello' -f $GatewayPort) -UseBasicParsing -TimeoutSec 4; if ($r.StatusCode -eq 200) { $up = $true; break } } catch { }
        }
        if ($up) {
            Say 'INFO' 'magpie is up from D:'
            & $newExe autostart on 2>&1 | ForEach-Object { Say 'INFO' ('  autostart: ' + $_) }
        } else {
            Say 'ERROR' 'magpie did not answer from D: in ~18s; rolling back to the old exe'
            if ($wasRunning) { Start-Process -FilePath $oldExe -ArgumentList 'tray' -WindowStyle Hidden | Out-Null; Say 'WARN' 'old magpie restarted from its original path' }
        }
    }
}

# ---- 6. remove the old root ---------------------------------------------
if (-not (Test-Path -LiteralPath $oldRoot)) { Say 'INFO' 'old root already gone' }
elseif ($KeepOld) { Say 'INFO' ('keeping old root (-KeepOld): ' + $oldRoot) }
else {
    Say 'INFO' 'removing the old root...'
    & takeown.exe /f $oldRoot /r /d n 2>$null | Out-Null
    & icacls.exe  $oldRoot /reset /t /c /q 2>$null | Out-Null
    Remove-Item -LiteralPath $oldRoot -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $oldRoot) { Say 'WARN' ('could not fully remove ' + $oldRoot + '; delete it by hand (nothing depends on it)') }
    else { Say 'INFO' 'old root removed' }
}

Say 'INFO' ('DONE. connector root: ' + $TargetRoot)
Say 'INFO' ('       log: ' + (Join-Path $TargetRoot 'logs\connector.log'))
Say 'INFO' '       relay-side check: bash ~/.magpie-connector/verify-tunnel.sh 13425'
