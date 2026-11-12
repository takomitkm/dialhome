# ensure-magpie.ps1
# Makes sure the campus Windows box has a running magpie gateway, WITHOUT admin/UAC.
# Order of work (cheapest first, so we never pull 83 MB needlessly):
#   1. gateway already answering on 127.0.0.1:<GatewayPort>?  -> done
#   2. otherwise find a magpie exe (running process, LOCALAPPDATA, Downloads, PATH)
#   3. otherwise pull the portable exe from the 102 relay with scp (binary-safe)
#   4. start it in the menu bar (tray), turn on magpie's own per-user autostart
#   5. report ZCode plugin/sign-in state (this machine signs in with ITS OWN account)
# PowerShell 5.1 compatible. ASCII-only source. Never elevates.
param(
    [string]$RelayHost = '10.101.54.192',
    [int]$RelayPort = 18322,
    [string]$RelayUser = 'user',
    [string]$InstallDir = '',
    [int]$GatewayPort = 3425,
    [switch]$NoFetch,
    [switch]$DryRun
)
$ErrorActionPreference = 'Continue'

function Say([string]$Level, [string]$Message) { Write-Host ('[{0}] {1}' -f $Level, $Message) }

if ([string]::IsNullOrWhiteSpace($InstallDir)) { $InstallDir = (Join-Path $env:LOCALAPPDATA 'magpie') }
$exeName = 'magpie-windows-amd64.exe'
$target  = Join-Path $InstallDir $exeName

function Test-WebView2 {
    # magpie's window/tray UI needs the Edge WebView2 runtime; "serve" mode does not.
    $keys = @(
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}',
        'HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}',
        'HKCU:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
    )
    foreach ($k in $keys) {
        $p = Get-ItemProperty -Path $k -ErrorAction SilentlyContinue
        if ($p -and $p.pv -and "$($p.pv)" -ne '0.0.0.0') { return "$($p.pv)" }
    }
    return $null
}

function Start-Magpie([string]$Exe, [int]$GatewayPort, [string]$WebView2Version, [switch]$DryRun) {
    # With WebView2: the tray app serves the gateway and keeps a menu-bar icon.
    # Without WebView2: run the gateway alone -- "serve" needs no UI runtime at all.
    if ($WebView2Version) {
        $args = @('tray')
        $mode = 'tray'
    } else {
        $args = @('serve', ('--web=127.0.0.1:{0}' -f ($GatewayPort + 105)))
        $mode = 'serve'
    }
    if ($DryRun) { Say 'INFO' ('[DRY-RUN] would start: ' + $Exe + ' ' + ($args -join ' ')); return $mode }
    Say 'INFO' ('starting magpie in "{0}" mode: {1} {2}' -f $mode, $Exe, ($args -join ' '))
    Start-Process -FilePath $Exe -ArgumentList $args -WindowStyle Hidden | Out-Null
    for ($i = 0; $i -lt 24; $i++) {
        Start-Sleep -Milliseconds 750
        if (Test-Gateway $GatewayPort) { return $mode }
    }
    return $mode
}

function Set-MagpieAutostart([string]$Exe, [string]$Mode, [int]$GatewayPort, [switch]$DryRun) {
    if ($DryRun) { Say 'INFO' ('[DRY-RUN] would set autostart for mode ' + $Mode); return }
    if ($Mode -eq 'tray') {
        & $Exe autostart on 2>&1 | ForEach-Object { Say 'INFO' ('autostart: ' + $_) }
        return
    }
    # serve mode: magpie's own autostart sets up the tray app, which cannot run without
    # WebView2 -- register a plain per-user Run entry for the gateway instead.
    $cmd = ('"{0}" serve --web=127.0.0.1:{1}' -f $Exe, ($GatewayPort + 105))
    try {
        New-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'magpie' `
            -Value $cmd -PropertyType String -Force -ErrorAction Stop | Out-Null
        Say 'INFO' ('autostart (HKCU Run, serve mode): ' + $cmd)
    } catch {
        Say 'WARN' ('autostart registration failed: ' + $_.Exception.Message)
    }
}

function Test-Gateway([int]$Port) {
    try {
        $r = Invoke-WebRequest -Uri ("http://127.0.0.1:{0}/api/hello" -f $Port) -UseBasicParsing -TimeoutSec 4
        if ($r.StatusCode -eq 200) { return $r.Content }
    } catch { }
    return $null
}

function Find-MagpieRunning {
    # Best signal first: whoever owns the listening gateway port IS the magpie binary.
    try {
        $c = Get-NetTCPConnection -LocalPort $GatewayPort -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($c -and $c.OwningProcess -gt 0) {
            $pr = Get-Process -Id $c.OwningProcess -ErrorAction SilentlyContinue
            if ($pr -and $pr.Path -and (Test-Path -LiteralPath $pr.Path) -and ((Get-Item -LiteralPath $pr.Path).Length -gt 10MB)) { return $pr.Path }
        }
    } catch { }
    # Fallback: a running process literally named magpie (not the plugin host 'magpie-bun').
    $p = Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.ProcessName -in @('magpie', 'magpie-windows-amd64') -and $_.Path
    }
    foreach ($x in $p) { if ($x.Path -and (Test-Path -LiteralPath $x.Path) -and ((Get-Item -LiteralPath $x.Path).Length -gt 10MB)) { return $x.Path } }
    return $null
}

function Find-MagpieOnDisk {
    $cands = New-Object System.Collections.ArrayList
    [void]$cands.Add($target)
    [void]$cands.Add((Join-Path $env:LOCALAPPDATA "magpie\$exeName"))
    [void]$cands.Add((Join-Path $env:USERPROFILE "Downloads\$exeName"))
    [void]$cands.Add((Join-Path $env:LOCALAPPDATA 'Programs\magpie\magpie.exe'))
    foreach ($n in @('magpie.exe', 'magpie')) {
        $cmd = Get-Command $n -ErrorAction SilentlyContinue
        if ($cmd -and $cmd.Source) { [void]$cands.Add($cmd.Source) }
    }
    foreach ($c in $cands) {
        if ($c -and (Test-Path -LiteralPath $c)) {
            $it = Get-Item -LiteralPath $c
            if ($it.Length -gt 10MB) { return $it.FullName }
        }
    }
    return $null
}

$elevated = (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Say 'INFO' ('user=' + $env:USERNAME + '  elevated=' + $elevated + '  (everything below is user-scope)')

Write-Output '=== 1. gateway already up? ==='
$hello = Test-Gateway $GatewayPort
$exe = $null
if ($hello) {
    Say 'INFO' ('gateway already up on ' + $GatewayPort + ': ' + $hello)
    $exe = Find-MagpieRunning
    if (-not $exe) { $exe = Find-MagpieOnDisk }
    if ($exe) { Say 'INFO' ('magpie exe: ' + $exe) }
} else {
    Say 'WARN' ('nothing answering on 127.0.0.1:' + $GatewayPort)
    $exe = Find-MagpieRunning
    if (-not $exe) { $exe = Find-MagpieOnDisk }
    if ($exe) { Say 'INFO' ('found magpie: ' + $exe) }
    else {
        Say 'WARN' 'no magpie found on this machine'
        if ($NoFetch) { Say 'ERROR' 'NoFetch given and magpie is missing; cannot continue.'; exit 2 }
        if ($DryRun) { Say 'INFO' ('[DRY-RUN] would scp ' + $RelayUser + '@' + $RelayHost + ':.magpie-connector/' + $exeName + ' -> ' + $target) }
        else {
            New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
            Say 'INFO' 'pulling portable magpie from the relay over scp (~83 MB, one time)...'
            & scp.exe -P $RelayPort ("{0}@{1}:.magpie-connector/{2}" -f $RelayUser, $RelayHost, $exeName) $target
            if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $target) -or ((Get-Item -LiteralPath $target).Length -lt 10MB)) {
                Say 'ERROR' 'scp failed or produced a short file; copy the exe by hand from the relay.'
                exit 3
            }
            Say 'INFO' ('downloaded {0:N1} MB' -f ((Get-Item -LiteralPath $target).Length / 1MB))
            $exe = $target
        }
    }
}

Write-Output '=== 2. UI runtime (decides how magpie can run here) ==='
$wv2 = Test-WebView2
if ($wv2) { Say 'INFO' ('WebView2 present (' + $wv2 + ') -> tray mode is possible') }
else { Say 'WARN' 'WebView2 NOT installed -> tray/window UI cannot run; using "serve" (gateway only, no UI runtime needed)' }

Write-Output '=== 3. start it if needed ==='
$mode = 'tray'
if ($hello) {
    Say 'INFO' 'already serving; not starting a second copy'
    $mode = $(if ($wv2) { 'tray' } else { 'serve' })
} elseif ($exe) {
    $mode = Start-Magpie -Exe $exe -GatewayPort $GatewayPort -WebView2Version $wv2 -DryRun:$DryRun
    $hello = Test-Gateway $GatewayPort
    if ($hello) { Say 'INFO' ('gateway up: ' + $hello) }
    else { Say 'WARN' ('gateway still silent on ' + $GatewayPort + ' after ~18s; start magpie by hand and re-run.') }
} elseif ($DryRun) { Say 'INFO' '[DRY-RUN] would start magpie' }

Write-Output '=== 4. magpie per-user autostart (no elevation) ==='
if ($exe) { Set-MagpieAutostart -Exe $exe -Mode $mode -GatewayPort $GatewayPort -DryRun:$DryRun }
elseif ($DryRun) { Say 'INFO' '[DRY-RUN] would set magpie autostart' }

Write-Output '=== 5. ZCode state (this machine uses ITS OWN zcode account) ==='
$cfgd = Join-Path $env:USERPROFILE '.config\magpie'
$pp = Join-Path $cfgd 'plugin-providers.json'
$z = $null
if (Test-Path -LiteralPath $pp) {
    try { $z = (Get-Content -LiteralPath $pp -Raw | ConvertFrom-Json) | Where-Object { "$($_.id)" -match 'zcode' } } catch { }
}
if ($z) {
    Say 'INFO' ('zcode plugin present: signedIn=' + $z.signedIn + ' account=' + $z.accountId)
    if (-not $z.signedIn) { Say 'WARN' ('zcode installed but NOT signed in -> run:  "' + $exe + '" plugin login zcode') }
} else {
    Say 'WARN' 'zcode plugin not installed yet -> run:'
    Say 'WARN' ('  "' + $exe + '" plugin add @magpie-community/opencode-zcode-auth')
    Say 'WARN' ('  "' + $exe + '" plugin login zcode')
}
Write-Output '=== done ==='
exit 0
