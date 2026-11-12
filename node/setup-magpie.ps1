# setup-magpie.ps1 -- fixed flow for the magpie side of a node (item 1 of the checklist).
#
#   -Acquire   find magpie (or pull the portable exe from the relay), make the gateway run
#              persistently via a user scheduled task ("serve" mode: no WebView2 needed)
#   -Plugin    install the zcode plugin *in a scheduled task with cmd redirection*, so a slow
#              Bun download cannot be killed by an SSH session ending (that is what broke it)
#   -Login     print/launch the zcode login (browser OAuth - only the account owner can finish it)
#   (default)  all of the above, reporting KEY = value lines
#
# No admin, no UAC. Safe to re-run: every step is guarded.
param(
    [switch]$Acquire,
    [switch]$Plugin,
    [switch]$Login,
    [switch]$Status,
    [string]$RelayHost = '10.101.54.192',
    [int]$RelayPort = 18322,
    [string]$RelayUser = 'user',
    [string]$PluginSpec = '@magpie-community/opencode-zcode-auth',
    [int]$GatewayPort = 3425,
    [int]$WebPort = 3430,
    [int]$PluginWaitSeconds = 240
)
$ErrorActionPreference = 'Continue'
if (-not ($Acquire -or $Plugin -or $Login -or $Status)) { $Acquire = $true; $Plugin = $true; $Status = $true }

function P($k, $v) { Write-Output (([string]$k) + ' = ' + ([string]$v)) }
function Tcp([int]$p) {
    $t = New-Object System.Net.Sockets.TcpClient
    try { $t.Connect('127.0.0.1', $p); return $t.Connected } catch { return $false } finally { $t.Close() }
}
function Find-Magpie {
    $cands = @(
        (Join-Path $env:LOCALAPPDATA 'magpie\magpie-windows-amd64.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\magpie\magpie-windows-amd64.exe'),
        'C:\Users\Public\app\鹊\magpie-windows-amd64.exe',
        'C:\Users\Public\app\magpie\magpie-windows-amd64.exe'
    )
    foreach ($c in $cands) { if (Test-Path -LiteralPath $c) { return $c } }
    $hit = Get-ChildItem (Join-Path $env:LOCALAPPDATA 'magpie') -Filter 'magpie*.exe' -EA 0 | Select-Object -First 1
    if ($hit) { return $hit.FullName }
    return $null
}

# ---------------- 1) acquire the binary ----------------
$exe = Find-Magpie
if (-not $exe) {
    P 'MAGPIE' 'not installed - pulling the portable exe from the relay'
    $dir = Join-Path $env:LOCALAPPDATA 'magpie'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $dst = Join-Path $dir 'magpie-windows-amd64.exe'
    & scp.exe -P $RelayPort ('{0}@{1}:.magpie-connector/magpie-windows-amd64.exe' -f $RelayUser, $RelayHost) $dst
    if (Test-Path -LiteralPath $dst) { $exe = $dst; P 'MAGPIE-FETCH' ('OK ' + [math]::Round((Get-Item $dst).Length / 1MB, 1) + ' MB') }
    else { P 'MAGPIE-FETCH' 'FAIL (relay password? relay staging? run stage-relay.sh)'; }
} else { P 'MAGPIE' $exe }

# ---------------- 2) gateway, persistently ----------------
if ($Acquire -and $exe) {
    if (-not (Tcp $GatewayPort)) {
        $arg = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command "& ''' + $exe + ''' serve --web=127.0.0.1:' + $WebPort + '"'
        $a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
        $tr = New-ScheduledTaskTrigger -AtLogOn -User (& whoami.exe)
        $st = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Seconds 0) -MultipleInstances IgnoreNew -Hidden
        try {
            Register-ScheduledTask -TaskName 'MagpieServe' -Action $a -Trigger $tr -Settings $st -RunLevel Limited -Force -EA Stop | Out-Null
            Start-ScheduledTask -TaskName 'MagpieServe' -EA Stop
            for ($i = 0; $i -lt 25; $i++) { Start-Sleep -Milliseconds 800; if (Tcp $GatewayPort) { break } }
            P 'MAGPIE-TASK' 'registered + started (serve mode, no WebView2 needed)'
        } catch { P 'MAGPIE-TASK' ('FAILED ' + $_.Exception.Message) }
    } else { P 'MAGPIE-TASK' 'gateway already listening' }
    P 'GATEWAY' ((Tcp $GatewayPort)) 
    try { P 'HELLO' ((Invoke-WebRequest ('http://127.0.0.1:' + $GatewayPort + '/api/hello') -UseBasicParsing -TimeoutSec 5).Content) } catch { P 'HELLO' 'FAIL' }
}

# ---------------- 3) zcode plugin, detached ----------------
function Get-PluginList([string]$Exe) { (& $Exe plugin list 2>&1 | Out-String).Trim() }
if ($Plugin -and $exe) {
    $before = Get-PluginList $exe
    if ($before -match 'zcode') { P 'PLUGIN' 'already installed' }
    else {
        $dir = Split-Path -Parent $exe
        $log = Join-Path $dir 'plugin-add.log'
        Set-Content -LiteralPath $log -Value ('start ' + (Get-Date -Format s)) -Encoding UTF8
        # cmd does the redirection: reliable inside a hidden task, and the task owns the process so
        # the download survives this SSH session (the mistake that killed it the first time).
        $a = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument ('/c ""' + $exe + '" plugin add "' + $PluginSpec + '" > "' + $log + '" 2>&1"')
        $tr = New-ScheduledTaskTrigger -AtLogOn -User (& whoami.exe)
        $st = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Seconds 0) -MultipleInstances IgnoreNew -Hidden
        Register-ScheduledTask -TaskName 'MagpiePluginAdd' -Action $a -Trigger $tr -Settings $st -RunLevel Limited -Force | Out-Null
        Start-ScheduledTask -TaskName 'MagpiePluginAdd'
        P 'PLUGIN' ('installing in a detached task; log: ' + $log)
        for ($i = 0; $i -lt [int]($PluginWaitSeconds / 5); $i++) {
            Start-Sleep -Seconds 5
            $now = Get-PluginList $exe
            if ($now -match 'zcode') { P 'PLUGIN' 'installed'; break }
            if ((Get-ScheduledTask -TaskName 'MagpiePluginAdd').State -ne 'Running' -and $i -gt 2) { P 'PLUGIN' 'task ended without zcode - see log'; break }
        }
        P 'PLUGIN-LIST' ((Get-PluginList $exe) -replace '\s+', ' ')
        P 'PLUGIN-LOG-TAIL' (((Get-Content -LiteralPath $log -Tail 4 -EA 0) -join ' // ') -replace '\s+', ' ')
    }
}

# ---------------- 4) login hint (only the owner can finish OAuth) ----------------
if ($Login -and $exe) {
    P 'LOGIN-STEP' ('run on the node, in a normal window:  "' + $exe + '" plugin login zcode')
    P 'LOGIN-NOTE' 'it prints/opens a URL - finish it in a browser signed in as the node''s own zcode account'
}

if ($Status) {
    P 'STATUS-GATEWAY' ((Tcp $GatewayPort))
    P 'STATUS-WEB' ((Tcp $WebPort))
    P 'STATUS-PROCS' (((Get-Process -EA 0 | Where-Object { $_.ProcessName -match 'magpie' } | ForEach-Object { $_.ProcessName + '(' + $_.Id + ')' }) -join ','))
}