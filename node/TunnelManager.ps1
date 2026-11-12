# TunnelManager.ps1
# Reverse-SSH tunnel lifecycle on Windows. Dot-sourced by connector.ps1.
# PowerShell 5.1 compatible. ASCII-only source.
$ErrorActionPreference = 'Stop'

function Write-McLog {
    param([string]$Level = 'INFO', [string]$Message = '')
    $cmd = Get-Command -Name 'Write-ConnectorLog' -ErrorAction SilentlyContinue
    if ($null -ne $cmd) { & $cmd -Level $Level -Message $Message }
}

function ConvertTo-McCommandLine {
    # Build a single Windows command line from an argument array using the
    # MS CRT quoting rules so paths with spaces/quotes/backslashes are safe.
    param([string[]]$Arguments)
    $parts = @()
    foreach ($arg in $Arguments) {
        if ($null -eq $arg) { $arg = '' }
        if ($arg -eq '' -or $arg -match '[ \t"]') {
            $sb = New-Object System.Text.StringBuilder
            $null = $sb.Append('"')
            $numBs = 0
            for ($i = 0; $i -lt $arg.Length; $i++) {
                $c = $arg[$i]
                if ($c -eq '\') {
                    $numBs++
                } elseif ($c -eq '"') {
                    for ($k = 0; $k -lt $numBs * 2; $k++) { $null = $sb.Append('\') }
                    $null = $sb.Append('\"')
                    $numBs = 0
                } else {
                    for ($k = 0; $k -lt $numBs; $k++) { $null = $sb.Append('\') }
                    $null = $sb.Append($c)
                    $numBs = 0
                }
            }
            for ($k = 0; $k -lt $numBs * 2; $k++) { $null = $sb.Append('\') }
            $null = $sb.Append('"')
            $parts += $sb.ToString()
        } else {
            $parts += $arg
        }
    }
    return ($parts -join ' ')
}

function Find-SshExecutable {
    # Returns the full path to ssh.exe or $null.
    $candidates = @(
        [Environment]::ExpandEnvironmentVariables('%SystemRoot%\System32\OpenSSH\ssh.exe'),
        'C:\Windows\System32\OpenSSH\ssh.exe'
    )
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c) { return $c }
    }
    $cmd = Get-Command -Name 'ssh.exe' -ErrorAction SilentlyContinue
    if ($null -ne $cmd) { return $cmd.Source }
    return $null
}

function Start-Tunnel {
    # Launches ssh.exe -N -R ... as a hidden background process.
    # Returns a [pscustomobject] with the process, pid, and an event id used for cleanup.
    param(
        [Parameter(Mandatory = $true)] [hashtable]$Config,
        [Parameter(Mandatory = $true)] [string]$SshPath,
        [Parameter(Mandatory = $true)] [int]$MagpiePort
    )

    $sshArgs = @()
    $sshArgs += '-F'; $sshArgs += 'none'
    $sshArgs += '-N'
    $sshArgs += '-o'; $sshArgs += 'BatchMode=yes'
    $sshArgs += '-o'; $sshArgs += 'ExitOnForwardFailure=yes'
    $sshArgs += '-o'; $sshArgs += 'ServerAliveInterval=30'
    $sshArgs += '-o'; $sshArgs += 'ServerAliveCountMax=3'
    $sshArgs += '-o'; $sshArgs += 'StrictHostKeyChecking=accept-new'
    $sshArgs += '-o'; $sshArgs += ('UserKnownHostsFile=' + $Config.ssh.knownHostsFile)
    $sshArgs += '-i'; $sshArgs += $Config.ssh.identityFile
    $sshArgs += '-p'; $sshArgs += [string]$Config.ssh.port
    $remote = ('{0}:{1}:127.0.0.1:{2}' -f $Config.tunnel.remoteBindAddress, $Config.tunnel.remotePort, $MagpiePort)
    $sshArgs += '-R'; $sshArgs += $remote
    $sshArgs += ($Config.ssh.user + '@' + $Config.ssh.host)

    $cmdLine = ConvertTo-McCommandLine -Arguments $sshArgs

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $SshPath
    $psi.Arguments = $cmdLine
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardError = $true

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi

    $srcId = ('MagpieTunnelStderr-{0}-{1}' -f $proc.Id, [Guid]::NewGuid().ToString('N'))
    # The event action writes captured ssh stderr into the shared connector log.
    $null = Register-ObjectEvent -InputObject $proc -EventName 'ErrorDataReceived' -SourceIdentifier $srcId -Action {
        $d = $Event.SourceEventArgs.Data
        if ($null -eq $d -or [string]::IsNullOrEmpty($d)) { return }
        $logger = Get-Command -Name 'Write-ConnectorLog' -ErrorAction SilentlyContinue
        if ($null -ne $logger) { & $logger -Level 'SSH' -Message $d }
    }

    $null = $proc.Start()
    $proc.BeginErrorReadLine()

    return [pscustomobject]@{
        Process       = $proc
        Pid           = $proc.Id
        MagpiePort    = $MagpiePort
        RemotePort    = $Config.tunnel.remotePort
        StartedAt     = (Get-Date).ToString('o')
        SrcId         = $srcId
    }
}

function Stop-Tunnel {
    # Kills the ssh process (and its tree) and releases the stderr event.
    param([Parameter(Mandatory = $true)] [pscustomobject]$Tunnel)
    if ($Tunnel.SrcId) {
        try { Unregister-Event -SourceIdentifier $Tunnel.SrcId -ErrorAction SilentlyContinue } catch { }
    }
    $p = $Tunnel.Process
    if ($null -ne $p) {
        try {
            if (-not $p.HasExited) {
                try { $p.Kill() } catch { }
                # Backstop: kill the whole tree (covers any conhost/child).
                try { & taskkill.exe /PID $p.Id /T /F 2>$null } catch { }
                try { $p.WaitForExit(4000) } catch { }
            }
        } catch { }
        try { $p.Dispose() } catch { }
    }
}

function Parse-TunnelProbe {
    # Parses the single JSON line printed by the remote forced command.
    # Returns [pscustomobject]@{ Online; Reason; Payload; Raw }.
    param([string]$Raw)
    if ([string]::IsNullOrWhiteSpace($Raw)) {
        return [pscustomobject]@{ Online = $false; Reason = 'no-json'; Payload = $null; Raw = '' }
    }
    try {
        $obj = $Raw | ConvertFrom-Json
        if ($obj.ok -eq $true) {
            return [pscustomobject]@{ Online = $true; Reason = ''; Payload = $obj; Raw = $Raw }
        }
        $reason = ''
        if ($obj.PSObject.Properties['reason']) { $reason = [string]$obj.reason }
        return [pscustomobject]@{ Online = $false; Reason = $reason; Payload = $obj; Raw = $Raw }
    } catch {
        return [pscustomobject]@{ Online = $false; Reason = 'parse-error'; Payload = $null; Raw = $Raw }
    }
}

function Test-TunnelOnline {
    # Runs a short ssh (NO -N) so the remote forced command prints one JSON line
    # on stdout. Only 'ok -eq $true' counts as online. Stderr (e.g. PTY warning)
    # is ignored. Returns [pscustomobject]@{ Online; Reason; Payload; Raw }.
    param(
        [Parameter(Mandatory = $true)] [hashtable]$Config,
        [Parameter(Mandatory = $true)] [string]$SshPath,
        [int]$ConnectTimeout = 8
    )

    $probeArgs = @()
    $probeArgs += '-F'; $probeArgs += 'none'
    $probeArgs += '-o'; $probeArgs += 'BatchMode=yes'
    $probeArgs += '-o'; $probeArgs += ('ConnectTimeout=' + $ConnectTimeout)
    $probeArgs += '-o'; $probeArgs += 'StrictHostKeyChecking=accept-new'
    $probeArgs += '-o'; $probeArgs += ('UserKnownHostsFile=' + $Config.ssh.knownHostsFile)
    $probeArgs += '-i'; $probeArgs += $Config.ssh.identityFile
    $probeArgs += '-p'; $probeArgs += [string]$Config.ssh.port
    $probeArgs += ($Config.ssh.user + '@' + $Config.ssh.host)

    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $raw = $null
    try {
        $raw = & $SshPath @probeArgs 2>$null
    } catch {
        # NativeCommandError on redirected stderr under EAP=Stop; ignore here.
    } finally {
        $ErrorActionPreference = $prev
    }

    if ($null -eq $raw) {
        return [pscustomobject]@{ Online = $false; Reason = 'no-output'; Payload = $null; Raw = '' }
    }
    $line = ($raw | Where-Object { $_ -match '^\s*\{' } | Select-Object -First 1)
    if ([string]::IsNullOrWhiteSpace($line)) {
        return [pscustomobject]@{ Online = $false; Reason = 'no-json'; Payload = $null; Raw = ($raw -join ' ') }
    }
    return Parse-TunnelProbe -Raw $line
}
