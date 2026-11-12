# sshserver-102.ps1 -- portable (rootless) sshd on this Windows box + a separate reverse tunnel to 102.
#
# Same shape as the school-box installer in S:\apps\llm\agentwork\tunnel\server_sshd_setup.ps1,
# re-pointed at the 102 relay:
#   sshd      : portable OpenSSH from the Win32-OpenSSH zip, 127.0.0.1:19022 only, key-only login
#   tunnel    : a SECOND, separate connection carrying -R 127.0.0.1:13437 on 102 -> this box 19022
#   autostart : Startup-folder shortcuts (user scope; schtasks /SC ONLOGON would need admin)
#   retry     : fast at first, then exactly one attempt per hour, forever
#
# No admin, no UAC, no service, no system sshd needed. Safe to re-run: every step is guarded.
$ErrorActionPreference = 'Continue'

$Root        = if (Test-Path 'D:\') { 'D:\zc\sshd' } else { Join-Path $env:USERPROFILE 'sshserver' }
$Bin         = Join-Path $Root 'OpenSSH-Win64'
$Zip         = Join-Path $Root 'OpenSSH-Win64.zip'
$Sha         = '23f50f3458c4c5d0b12217c6a5ddfde0137210a30fa870e98b29827f7b43aba5'
$Url         = 'https://github.com/PowerShell/Win32-OpenSSH/releases/download/10.0.0.0p2-Preview/OpenSSH-Win64.zip'
$RelayHost   = '10.101.54.192'
$RelayPort   = '18322'
$RelayUser   = 'user'
$LocalPort   = '19022'
$RemotePort  = '13437'
# 102's login key (private half stays on 102). Full shell: no command= restriction.
$LoginPubKey = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPq5SH7C8YfxCoECXFaBpGNsgJLd2buefJ6cYO5CKGkF win-ssh-from-102'
$AkOpt       = 'no-agent-forwarding,no-X11-forwarding,no-user-rc '
$KeyRel      = '.magpie-connector/nodes/win2/id_ed25519_win2_13435'

function P($k, $v) { Write-Output (([string]$k) + ' = ' + ([string]$v)) }
$me = $env:USERNAME
$meFull = if ($env:USERDOMAIN) { $env:USERDOMAIN + '\' + $me } else { $me }

New-Item -ItemType Directory -Force -Path $Root | Out-Null
P 'ROOT' $Root
P 'ACCOUNT' $meFull
P 'RELAY' ($RelayUser + '@' + $RelayHost + ':' + $RelayPort)
P 'LISTEN' ('127.0.0.1:' + $LocalPort)
P 'REMOTE-ON-102' ('127.0.0.1:' + $RemotePort)

# ---------- 1) portable binaries ----------
if (-not (Test-Path (Join-Path $Bin 'sshd.exe'))) {
    $need = $true
    if (Test-Path $Zip) {
        $h = (Get-FileHash -LiteralPath $Zip -Algorithm SHA256).Hash.ToLower()
        if ($h -eq $Sha) { $need = $false; P 'ZIP' 'already here, sha OK' } else { P 'ZIP' ('sha mismatch ' + $h); Remove-Item -LiteralPath $Zip -Force }
    }
    if ($need) {
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri $Url -OutFile $Zip -UseBasicParsing -TimeoutSec 300 -ErrorAction Stop
            P 'DOWNLOAD' ('OK ' + (Get-Item -LiteralPath $Zip).Length + ' bytes')
        } catch {
            P 'DOWNLOAD' ('FAIL ' + $_.Exception.Message)
            P 'FALLBACK' 'pulling the same zip from 102 over scp (asks the 102 password once)'
            & scp.exe -P $RelayPort ('{0}@{1}:.magpie-connector/OpenSSH-Win64.zip' -f $RelayUser, $RelayHost) $Zip
            if (Test-Path $Zip) { P 'SCP' ('OK ' + (Get-Item -LiteralPath $Zip).Length + ' bytes') } else { P 'SCP' 'FAIL' }
        }
    }
    if (Test-Path $Zip) {
        $h2 = (Get-FileHash -LiteralPath $Zip -Algorithm SHA256).Hash.ToLower()
        if ($h2 -eq $Sha) { P 'SHA256' 'MATCH'; Expand-Archive -LiteralPath $Zip -DestinationPath $Root -Force; P 'EXTRACTED' (Test-Path (Join-Path $Bin 'sshd.exe')) }
        else { P 'SHA256' ('MISMATCH ' + $h2 + ' - STOP'); }
    }
} else { P 'BINARIES' 'already installed' }
if (-not (Test-Path (Join-Path $Bin 'sshd.exe'))) { P 'ABORT' 'no sshd.exe - nothing below works'; return }
P 'SSHD-VERSION' ((& (Join-Path $Bin 'sshd.exe') -V 2>&1 | Out-String) -replace '\s+', ' ')

# ---------- 2) host key ----------
$hostKey = Join-Path $Root 'ssh_host_ed25519_key'
if (-not (Test-Path $hostKey)) {
    & (Join-Path $Bin 'ssh-keygen.exe') -q -t ed25519 -f $hostKey -N '""' -C ('sshd-' + $me) | Out-Null
}
P 'HOSTKEY' ((Test-Path $hostKey) -and (Test-Path ($hostKey + '.pub')))

# ---------- 3) authorized_keys: 102's login key only ----------
$ak = Join-Path $Root 'authorized_keys'
$tag = 'AAAAIPq5SH7C8YfxCoEC'
if (-not ((Test-Path $ak) -and ((Get-Content -LiteralPath $ak -Raw) -match $tag))) {
    Set-Content -LiteralPath $ak -Value ($AkOpt + $LoginPubKey) -Encoding ascii
    P 'AUTHORIZED-KEYS' 'written (102 login key, shell only)'
} else { P 'AUTHORIZED-KEYS' 'already present, left untouched' }
& (Join-Path $env:SystemRoot 'System32\icacls.exe') $ak '/inheritance:r' '/grant:r' ($meFull + ':F') 2>$null | Out-Null

# ---------- 4) sshd_config ----------
$cfg = Join-Path $Root 'sshd_config'
$lines = @(
    'Port ' + $LocalPort
    'ListenAddress 127.0.0.1'
    'HostKey ' + ($hostKey -replace '\\', '/')
    'PidFile ' + ((Join-Path $Root 'sshd.pid') -replace '\\', '/')
    'AuthorizedKeysFile ' + ($ak -replace '\\', '/')
    'PubkeyAuthentication yes'
    'PasswordAuthentication no'
    'PermitEmptyPasswords no'
    'PermitRootLogin no'
    'StrictModes no'
    'MaxAuthTries 3'
    'LoginGraceTime 20'
    'X11Forwarding no'
    'AllowAgentForwarding no'
    'PermitTunnel no'
    'AllowUsers ' + $me
    'ClientAliveInterval 60'
    'ClientAliveCountMax 5'
    'Subsystem sftp ' + ((Join-Path $Bin 'sftp-server.exe') -replace '\\', '/')
    'LogLevel INFO'
)
Set-Content -LiteralPath $cfg -Value $lines -Encoding ascii
P 'CONFIG-TEST' (((& (Join-Path $Bin 'sshd.exe') -t -f $cfg 2>&1 | Out-String) -replace '\s+', ' ') + ' rc=' + $LASTEXITCODE)

# ---------- 5) start sshd (skips if 19022 already listening) ----------
$starter = Join-Path $Root 'start-sshd.ps1'
$s = @(
    '$ErrorActionPreference = ''Continue'''
    '$b = ' + "'" + ($Bin -replace '\\', '\\') + "'"
    '$c = ' + "'" + ($cfg -replace '\\', '\\') + "'"
    '$lg = ' + "'" + ((Join-Path $Root 'sshd.log') -replace '\\', '\\') + "'"
    '$l = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, ' + $LocalPort + ')'
    'try { $l.Start(); $l.Stop() } catch { exit 0 }'
    'Start-Process -FilePath (Join-Path $b ''sshd.exe'') -ArgumentList ''-f'', $c, ''-E'', $lg -WindowStyle Hidden'
)
Set-Content -LiteralPath $starter -Value $s -Encoding ascii
Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', $starter -WindowStyle Hidden
Start-Sleep -Seconds 3
P 'BANNER' (& {
    $tc = New-Object Net.Sockets.TcpClient
    try {
        $tc.Connect('127.0.0.1', [int]$LocalPort)
        $st = $tc.GetStream(); $buf = New-Object byte[] 120
        $n = $st.Read($buf, 0, 120)
        ([Text.Encoding]::ASCII.GetString($buf, 0, $n)).Trim()
    } catch { 'CONNECT FAIL ' + $_.Exception.Message } finally { $tc.Close() }
})

# ---------- 6) tunnel identity (the restricted key we already distribute) ----------
$keyDir = Join-Path $env:LOCALAPPDATA 'magpie-connector\secrets'
$idKey = Join-Path $keyDir 'id_ed25519_win2_13435'
if (-not (Test-Path $idKey)) {
    New-Item -ItemType Directory -Force -Path $keyDir | Out-Null
    & scp.exe -P $RelayPort ('{0}@{1}:{2}' -f $RelayUser, $RelayHost, $KeyRel) $idKey
    if (Test-Path $idKey) { P 'KEY-FETCH' 'pulled from 102 (102 password was asked once)' } else { P 'KEY-FETCH' 'FAIL' }
} else { P 'KEY-FETCH' 'already present' }
if (Test-Path $idKey) {
    & (Join-Path $env:SystemRoot 'System32\icacls.exe') $idKey '/inheritance:r' '/grant:r' ($meFull + ':F') 2>$null | Out-Null
    P 'KEY-USABLE' ((& (Join-Path $Bin 'ssh-keygen.exe') -y -P '""' -f $idKey 2>&1) -match 'ssh-ed25519')
}

# ---------- 7) separate tunnel connection, hourly retry after the first few tries ----------
$knownHosts = Join-Path $keyDir 'known_hosts'
if (-not (Test-Path $knownHosts)) { Set-Content -LiteralPath $knownHosts -Value '' -Encoding ascii }
$tun = Join-Path $Root 'start-tunnel.ps1'
$t = @(
    '$ErrorActionPreference = ''Continue'''
    '$ring = ' + "'" + ($idKey -replace '\\', '\\') + "'"
    '$kh = ' + "'" + ($knownHosts -replace '\\', '\\') + "'"
    '$err = ' + "'" + ((Join-Path $Root 'tunnel.err') -replace '\\', '\\') + "'"
    '$pidfile = ' + "'" + ((Join-Path $Root 'tunnel.pid') -replace '\\', '\\') + "'"
    'if (Test-Path $pidfile) { $old = Get-Content -LiteralPath $pidfile -First 1; if ($old -and $old -ne "$PID") { $p = Get-Process -Id ([int]$old) -ErrorAction SilentlyContinue; if ($p -and $p.ProcessName -match "^p") { exit 0 } } }'
    'Set-Content -LiteralPath $pidfile -Value $PID -Encoding ascii'
    '$wait = 5; $fails = 0'
    'while ($true) {'
    '  Start-Sleep -Seconds $wait'
    '  & "$env:SystemRoot\System32\OpenSSH\ssh.exe" -N -R 127.0.0.1:' + ($RemotePort + ':127.0.0.1:' + $LocalPort) + ' -p ' + $RelayPort + ' -i $ring -o BatchMode=yes -o ExitOnForwardFailure=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$kh ' + ($RelayUser + '@' + $RelayHost) + ' 2>> $err'
    '  $rc = $LASTEXITCODE; $fails++'
    '  Add-Content -LiteralPath $err -Value ("tunnel exited rc=" + $rc + " at " + (Get-Date -Format s) + " (attempt #" + $fails + ")")'
    '  if ($rc -eq 0) { $wait = 5 }'
    '  elseif ($fails -ge 5) { $wait = 3600; Add-Content -LiteralPath $err -Value "5 failures -> one retry per hour from now on" }'
    '  else { $wait = [Math]::Min(60, $wait * 2) }'
    '}'
)
Set-Content -LiteralPath $tun -Value $t -Encoding ascii
Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', $tun -WindowStyle Hidden
Start-Sleep -Seconds 5
P 'TUNNEL-ERR-LAST' (((Get-Content -LiteralPath (Join-Path $Root 'tunnel.err') -Tail 2 -ErrorAction SilentlyContinue) -join ' // ') -replace '\s+', ' ')

# ---------- 8) autostart at logon (Startup folder; no admin needed) ----------
$sm = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'
$ws = New-Object -ComObject WScript.Shell
foreach ($pair in @(@(('sshd-' + $me + '.lnk'), $starter), @(('sshtunnel-' + $me + '.lnk'), $tun))) {
    $lnk = Join-Path $sm $pair[0]
    $sc = $ws.CreateShortcut($lnk)
    $sc.TargetPath = (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
    $sc.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $pair[1] + '"'
    $sc.WorkingDirectory = $Root
    $sc.Save()
    P ('STARTUP-LNK ' + $pair[0]) ((Test-Path $lnk) -and ((Get-Item -LiteralPath $lnk).Length -gt 600))
}

Write-Output ''
P 'TEST-FROM-102' ('ssh -p ' + $RemotePort + ' ' + $me + '@127.0.0.1')
P 'DONE' 'paste the KEY = value lines above back if anything looks false'