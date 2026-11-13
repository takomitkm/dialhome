# sshserver.ps1 -- portable (rootless) sshd on this Windows box + reverse channels to a Linux relay.
#
#   sshd      : portable OpenSSH from the Win32-OpenSSH zip, 127.0.0.1:<LocalPort> only, key-only
#   ssh chan  : a SEPARATE ssh connection carrying -R 127.0.0.1:<RemotePort> on the relay -> this box
#   magpie    : optional SECOND channel -R 127.0.0.1:<MagpiePort> -> this box 3425 (gateway)
#   autostart : Startup-folder shortcuts (user scope; schtasks /SC ONLOGON would need admin)
#   retry     : fast at first, then exactly one attempt per hour, forever
#
# No admin, no UAC, no service, no system sshd needed. Safe to re-run: every step is guarded.
#
# Normally you do NOT run this by hand: relay/enroll.sh mints a per-node key + ports and emits a
# caller that invokes this script with -KeyB64 / -RemotePort / -MagicPort / -KeyRel.
param(
    [string]$Root = '',
    [string]$RelayHost = '10.101.54.192',
    [int]$RelayPort = 18322,
    [string]$RelayUser = 'user',
    [int]$LocalPort = 19022,
    [int]$RemotePort = 13437,
    [int]$MagpiePort = 0,
    [string]$IdentityFile = '',
    [string]$KeyB64 = '',
    [string]$KeyRel = '',
    [string]$EnrollKeyB64 = '',
    [string]$LoginPubKey = '',
    [switch]$NoAutostart
)
$ErrorActionPreference = 'Continue'

if ([string]::IsNullOrWhiteSpace($Root)) {
    $Root = if (Test-Path 'D:\') { 'D:\zc\sshd' } else { Join-Path $env:USERPROFILE 'sshserver' }
}
$Bin         = Join-Path $Root 'OpenSSH-Win64'
$Zip         = Join-Path $Root 'OpenSSH-Win64.zip'
$Sha         = '23f50f3458c4c5d0b12217c6a5ddfde0137210a30fa870e98b29827f7b43aba5'
$Url         = 'https://github.com/PowerShell/Win32-OpenSSH/releases/download/10.0.0.0p2-Preview/OpenSSH-Win64.zip'
# The relay's login key (private half stays on the relay). Full shell: no command= restriction.
if ([string]::IsNullOrWhiteSpace($LoginPubKey)) {
    $LoginPubKey = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPq5SH7C8YfxCoECXFaBpGNsgJLd2buefJ6cYO5CKGkF win-ssh-from-102'
}
$AkOpt       = 'no-agent-forwarding,no-X11-forwarding,no-user-rc '
$idKey       = if ($IdentityFile) { $IdentityFile } else { Join-Path $Root 'node_key' }

function P($k, $v) { Write-Output (([string]$k) + ' = ' + ([string]$v)) }
$me = $env:USERNAME
$meFull = if ($env:USERDOMAIN) { $env:USERDOMAIN + '\' + $me } else { $me }

New-Item -ItemType Directory -Force -Path $Root | Out-Null
P 'NODE' ($env:COMPUTERNAME + '\' + $me)
P 'ROOT' $Root
P 'RELAY' ($RelayUser + '@' + $RelayHost + ':' + $RelayPort)
P 'SSHD' ('127.0.0.1:' + $LocalPort)
P 'SSH-CHAN' ('relay 127.0.0.1:' + $RemotePort)
if ($MagpiePort -gt 0) { P 'MAGPIE-CHAN' ('relay 127.0.0.1:' + $MagpiePort) }

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
            # passwordless fallback: pull the pinned zip through the enroll gate. The gate only
            # serves three public files, so this key stays useless for anything else.
            $ek = Join-Path $Root 'enroll_key'
            if (-not (Test-Path -LiteralPath $ek)) {
                if ($EnrollKeyB64) {
                    [IO.File]::WriteAllBytes($ek, [Convert]::FromBase64String($EnrollKeyB64))
                    & (Join-Path $env:SystemRoot 'System32\icacls.exe') $ek '/inheritance:r' '/grant:r' ($meFull + ':F') 2>$null | Out-Null
                }
            }
            if (Test-Path -LiteralPath $ek) {
                P 'FALLBACK' 'pulling the zip through the enroll gate (no password)'
                # OS-level redirection via Start-Process: raw bytes, no cmd quoting, no PS re-encoding
                $p = Start-Process -FilePath "$env:SystemRoot\System32\OpenSSH\ssh.exe" -PassThru -WindowStyle Hidden `
                    -RedirectStandardOutput $Zip -RedirectStandardError ($Zip + '.err') -Wait -ArgumentList @(
                    '-p', "$RelayPort", '-i', ('"{0}"' -f $ek), '-o', 'BatchMode=yes',
                    '-o', 'StrictHostKeyChecking=accept-new', ('{0}@{1}' -f $RelayUser, $RelayHost), 'get', 'openssh')
                if ((Test-Path -LiteralPath $Zip) -and ((Get-Item -LiteralPath $Zip).Length -gt 1MB)) { P 'GATE-PULL' ('OK ' + (Get-Item -LiteralPath $Zip).Length + ' bytes') }
                else { P 'GATE-PULL' ('FAIL rc=' + $p.ExitCode + ' ' + (((Get-Content ($Zip + '.err') -EA 0) -join ' | '))); Remove-Item -LiteralPath $Zip -Force -EA 0 }
            } else { P 'FALLBACK' 'no enroll key available - download by hand or add -EnrollKeyB64' }
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

# ---------- 6) the node key (enroll hands it over inline; otherwise pull it from the relay) ----------
if (-not (Test-Path $idKey)) {
    if ($KeyB64) {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $idKey) | Out-Null
        [IO.File]::WriteAllBytes($idKey, [Convert]::FromBase64String($KeyB64))
        P 'KEY' 'written from -KeyB64 (enroll mode)'
    } elseif ($KeyRel) {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $idKey) | Out-Null
        & scp.exe -P $RelayPort ('{0}@{1}:{2}' -f $RelayUser, $RelayHost, $KeyRel) $idKey
        if (Test-Path $idKey) { P 'KEY' 'pulled from the relay (password asked once)' } else { P 'KEY' 'FAIL' }
    } else {
        P 'KEY' 'MISSING - pass -KeyB64 or -KeyRel'
    }
} else { P 'KEY' 'already present' }
if (Test-Path $idKey) {
    & (Join-Path $env:SystemRoot 'System32\icacls.exe') $idKey '/inheritance:r' '/grant:r' ($meFull + ':F') 2>$null | Out-Null
    P 'KEY-USABLE' ((& (Join-Path $Bin 'ssh-keygen.exe') -y -P '""' -f $idKey 2>&1) -match 'ssh-ed25519')
}

# ---------- 7) one supervisor per channel: separate ssh connections, hourly retry after 5 fails ----------
$knownHosts = Join-Path $Root 'known_hosts'
if (-not (Test-Path $knownHosts)) { Set-Content -LiteralPath $knownHosts -Value '' -Encoding ascii }
# channels: sshd first, then (optionally) the magpie gateway. One connection each, so a refused
# port can never take the other channel down.
$channels = @(
    [pscustomobject]@{ Name = 'ssh'; Remote = $RemotePort; Target = $LocalPort },
    [pscustomobject]@{ Name = 'magpie'; Remote = $MagpiePort; Target = 3425 }
) | Where-Object { $_.Remote -gt 0 }

$tun = Join-Path $Root 'start-tunnel.ps1'
$t = @(
    '$ErrorActionPreference = ''Continue'''
    '$ring = ' + "'" + ($idKey -replace '\\', '\\') + "'"
    '$kh = ' + "'" + ($knownHosts -replace '\\', '\\') + "'"
    '$root = ' + "'" + ($Root -replace '\\', '\\') + "'"
    '$relay = ' + "'" + ($RelayUser + '@' + $RelayHost) + "'"
    '$relayPort = ' + $RelayPort
    '$ssh = "$env:SystemRoot\System32\OpenSSH\ssh.exe"'
    '$chans = @('
    ($channels | ForEach-Object { '  @{ Name = ''' + $_.Name + '''; Remote = ' + $_.Remote + '; Target = ' + $_.Target + ' }' })
    ')'
    '$state = @{}'
    'foreach ($c in $chans) { $state[$c.Name] = @{ Proc = $null; Wait = 5; Fails = 0 } }'
    'while ($true) {'
    '  foreach ($c in $chans) {'
    '    $s = $state[$c.Name]'
    '    if ($s.Proc -and -not $s.Proc.HasExited) { continue }'
    '    if ($s.Proc) {'
    '      $err = Join-Path $root ("tunnel-" + $c.Name + ".err")'
    '      Add-Content -LiteralPath $err -Value ("exited rc=" + $s.Proc.ExitCode + " at " + (Get-Date -Format s) + " (attempt #" + $s.Fails + ")")'
    '    }'
    '    Start-Sleep -Seconds $s.Wait'
    '    $s.Fails++'
    '    $err = Join-Path $root ("tunnel-" + $c.Name + ".err")'
    '    $s.Proc = Start-Process -FilePath $ssh -PassThru -WindowStyle Hidden -RedirectStandardError $err -ArgumentList @('
    '      "-N", "-R", ("127.0.0.1:" + $c.Remote + ":127.0.0.1:" + $c.Target),'
    '      "-p", "$relayPort", "-i", $ring,'
    '      "-o", "BatchMode=yes", "-o", "ExitOnForwardFailure=yes", "-o", "ConnectTimeout=10",'
    '      "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3",'
    '      "-o", "StrictHostKeyChecking=accept-new", "-o", "UserKnownHostsFile=$kh", $relay)'
    '    if ($s.Proc.HasExited) {'
    '      $s.Wait = if ($s.Fails -ge 5) { 3600 } else { [Math]::Min(60, $s.Wait * 2) }'
    '      Add-Content -LiteralPath $err -Value ("retry in " + $s.Wait + "s")'
    '    } else {'
    '      $s.Wait = 5; $s.Fails = 0'
    '      Add-Content -LiteralPath $err -Value ("connected " + (Get-Date -Format s) + " -> " + $c.Name + " on relay 127.0.0.1:" + $c.Remote)'
    '    }'
    '  }'
    '  Start-Sleep -Seconds 10'
    '}'
)
Set-Content -LiteralPath $tun -Value $t -Encoding ascii
Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', $tun -WindowStyle Hidden
Start-Sleep -Seconds 6
foreach ($c in $channels) {
    $errFile = Join-Path $Root ('tunnel-' + $c.Name + '.err')
    P ('CHAN-' + $c.Name + '-ERR') (((Get-Content -LiteralPath $errFile -Tail 2 -ErrorAction SilentlyContinue) -join ' // ') -replace '\s+', ' ')
}

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