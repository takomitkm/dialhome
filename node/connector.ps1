# connector.ps1
# Magpie reverse SSH tunnel connector - Windows entry point.
# Subcommands: run | status | discover | verify | install | uninstall | selftest
# PowerShell 5.1 compatible. ASCII-only source.
param(
    [Parameter(Position = 0, Mandatory = $false)]
    [ValidateSet('run', 'status', 'discover', 'verify', 'install', 'uninstall', 'selftest')]
    [string]$Command = 'run',
    [string]$Root = '',
    [string]$ConfigPath = '',
    [switch]$NoTask,
    [switch]$DryRun,
    [string]$SshHost = '',
    [int]$SshPort = 0,
    [string]$SshUser = '',
    [string]$IdentityFile = '',
    [string]$KnownHostsFile = '',
    [string]$RemoteBindAddress = '',
    [int]$RemotePort = 0,
    [int]$DefaultPort = 0,
    [switch]$Purge
)
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Global log plumbing (also reachable from event actions spawned by TunnelManager)
# ---------------------------------------------------------------------------
$global:ConnectorLogPath = ''
$global:ConnectorLogMaxBytes = 1048576
$global:ConnectorLogKeep = 2
$global:ConnectorConsoleMirror = $false
$global:ConnectorMutex = $null
$global:McSelftestFail = 0
$global:McSelftestTotal = 0

function global:Protect-LogText {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $t = [regex]::Replace($Text, 'sk-magpie-[A-Za-z0-9._\-]+', 'sk-magpie-***')
    $t = [regex]::Replace($t, '(?i)(lan[_-]?key|gateway[_-]?key|api[_-]?key|secret|token|password|passphrase)\s*[:=]\s*\S+', '$1=***')
    $t = [regex]::Replace($t, '(?i)-----BEGIN[A-Z ]+PRIVATE KEY-----', '-----BEGIN PRIVATE KEY (redacted)-----')
    $t = [regex]::Replace($t, '(?i)Authorization:\s*Bearer\s+\S+', 'Authorization: Bearer ***')
    return $t
}

function global:Add-ConnectorLogLine {
    param([string]$Path, [string]$Line)
    try {
        $enc = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::AppendAllText($Path, $Line + [Environment]::NewLine, $enc)
    } catch { }
}

function global:Rotate-ConnectorLog {
    param([string]$Path, [int]$Keep = 2)
    try {
        for ($i = $Keep; $i -ge 1; $i--) {
            $dst = if ($i -eq 1) { $Path + '.1' } else { $Path + '.' + $i }
            $src = if ($i -eq 1) { $Path } else { $Path + '.' + ($i - 1) }
            if (Test-Path -LiteralPath $src) {
                if (Test-Path -LiteralPath $dst) { [System.IO.File]::Delete($dst) }
                [System.IO.File]::Move($src, $dst)
            }
        }
    } catch { }
}

function global:Write-ConnectorLog {
    param([ValidateSet('INFO', 'WARN', 'ERROR', 'SSH', 'DEBUG')][string]$Level = 'INFO', [string]$Message = '')
    $u = [datetime]::UtcNow
    $utcStr = $u.ToString('yyyy-MM-ddTHH:mm:ss.fff') + 'Z'
    $locStr = $u.ToLocalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffzzz')
    $line = ('[{0} {1}] [{2}] {3}' -f $utcStr, $locStr, $Level, (Protect-LogText -Text $Message))
    if ($global:ConnectorLogPath -ne '') {
        try {
            $info = Get-Item -LiteralPath $global:ConnectorLogPath -ErrorAction SilentlyContinue
            if ($null -ne $info -and $info.Length -gt $global:ConnectorLogMaxBytes) {
                Rotate-ConnectorLog -Path $global:ConnectorLogPath -Keep $global:ConnectorLogKeep
            }
        } catch { }
        Add-ConnectorLogLine -Path $global:ConnectorLogPath -Line $line
    }
    if ($global:ConnectorConsoleMirror) {
        $c = switch ($Level) { 'ERROR' { 'Red' } 'WARN' { 'Yellow' } 'SSH' { 'DarkGray' } default { 'Gray' } }
        Write-Host -Object $line -ForegroundColor $c
    }
}

# ---------------------------------------------------------------------------
# Config / state helpers
# ---------------------------------------------------------------------------
function Get-DefaultConfig {
    return @{
        ssh       = @{ host = ''; port = 22; user = ''; identityFile = ''; knownHostsFile = '' }
        tunnel    = @{ remoteBindAddress = '127.0.0.1'; remotePort = 13425 }
        magpie    = @{ defaultPort = 3425; healthPath = '/api/hello'; extraCandidatePorts = @() }
        reconnect = @{ initialDelaySeconds = 5; maxDelaySeconds = 60; discoverEverySeconds = 30 }
        log       = @{ maxBytes = 1048576; keep = 2 }
    }
}

function Get-ConnectorConfig {
    param([string]$ConfigPath, [string]$RootPath)
    $cfg = Get-DefaultConfig
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        return @{ Found = $false; Config = $cfg; Path = $ConfigPath }
    }
    $raw = Get-Content -LiteralPath $ConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if ($raw.PSObject.Properties['ssh']) {
        foreach ($k in @('host', 'port', 'user', 'identityFile', 'knownHostsFile')) {
            if ($raw.ssh.PSObject.Properties[$k]) { $cfg.ssh[$k] = $raw.ssh.$k }
        }
    }
    if ($raw.PSObject.Properties['tunnel']) {
        foreach ($k in @('remoteBindAddress', 'remotePort')) {
            if ($raw.tunnel.PSObject.Properties[$k]) { $cfg.tunnel[$k] = $raw.tunnel.$k }
        }
    }
    if ($raw.PSObject.Properties['magpie']) {
        foreach ($k in @('defaultPort', 'healthPath')) {
            if ($raw.magpie.PSObject.Properties[$k]) { $cfg.magpie[$k] = $raw.magpie.$k }
        }
        if ($raw.magpie.PSObject.Properties['extraCandidatePorts']) {
            $cfg.magpie['extraCandidatePorts'] = @($raw.magpie.extraCandidatePorts)
        }
    }
    if ($raw.PSObject.Properties['reconnect']) {
        foreach ($k in @('initialDelaySeconds', 'maxDelaySeconds', 'discoverEverySeconds')) {
            if ($raw.reconnect.PSObject.Properties[$k]) { $cfg.reconnect[$k] = $raw.reconnect.$k }
        }
    }
    if ($raw.PSObject.Properties['log']) {
        foreach ($k in @('maxBytes', 'keep')) {
            if ($raw.log.PSObject.Properties[$k]) { $cfg.log[$k] = $raw.log.$k }
        }
    }
    $cfg.ssh.identityFile = [Environment]::ExpandEnvironmentVariables($cfg.ssh.identityFile)
    if ([string]::IsNullOrWhiteSpace($cfg.ssh.knownHostsFile)) {
        $cfg.ssh.knownHostsFile = (Join-Path $RootPath 'secrets\known_hosts')
    }
    $cfg.ssh.knownHostsFile = [Environment]::ExpandEnvironmentVariables($cfg.ssh.knownHostsFile)
    return @{ Found = $true; Config = $cfg; Path = $ConfigPath }
}

function Test-ConnectorConfig {
    param([hashtable]$Config, [switch]$RequireIdentity)
    $errs = @()
    if ([string]::IsNullOrWhiteSpace($Config.ssh.host)) { $errs += 'ssh.host is empty' }
    if ([string]::IsNullOrWhiteSpace($Config.ssh.user)) { $errs += 'ssh.user is empty' }
    # ConvertFrom-Json in Windows PowerShell 5.1 returns Int64 for JSON integers,
    # so -is [int] would wrongly reject valid ports read back from connector.json.
    $sp = $Config.ssh.port
    if (-not ($sp -is [int] -or $sp -is [long]) -or [int]$sp -lt 1 -or [int]$sp -gt 65535) { $errs += 'ssh.port out of range' }
    $rp = $Config.tunnel.remotePort
    if (-not ($rp -is [int] -or $rp -is [long]) -or [int]$rp -lt 1 -or [int]$rp -gt 65535) { $errs += 'tunnel.remotePort out of range' }
    if ($RequireIdentity) {
        if ([string]::IsNullOrWhiteSpace($Config.ssh.identityFile)) { $errs += 'ssh.identityFile is empty' }
        elseif (-not (Test-Path -LiteralPath $Config.ssh.identityFile)) { $errs += ('ssh.identityFile not found: ' + $Config.ssh.identityFile) }
    }
    return $errs
}

function Get-ConnectorState {
    param([string]$StatePath)
    if (-not (Test-Path -LiteralPath $StatePath)) { return $null }
    try {
        $o = Get-Content -LiteralPath $StatePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        return $o
    } catch { return $null }
}

function Set-ConnectorState {
    param(
        [string]$StatePath,
        [int]$ConnectorPid = 0,
        [string]$StartedAt = '',
        [int]$MagpiePort = 0,
        [string]$MagpieVersion = '',
        [int]$SshPid = 0,
        [bool]$Online = $false,
        [string]$LastProbeAt = '',
        [string]$LastError = '',
        [int]$Reconnects = 0
    )
    $o = [pscustomobject]@{
        pid           = $ConnectorPid
        startedAt     = $StartedAt
        magpiePort    = $MagpiePort
        magpieVersion = $MagpieVersion
        sshPid        = $SshPid
        online        = $Online
        lastProbeAt   = $LastProbeAt
        lastError     = $LastError
        reconnects    = $Reconnects
        updatedAt     = (Get-Date).ToString('o')
    }
    $tmp = $StatePath + '.tmp'
    try {
        $json = $o | ConvertTo-Json -Depth 5 -Compress
        $json | Out-File -LiteralPath $tmp -Encoding ASCII -ErrorAction Stop
        Move-Item -LiteralPath $tmp -Destination $StatePath -Force -ErrorAction Stop
    } catch {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

function Test-ConnectorSingleInstance {
    param([int]$RemotePort)
    $name = ('Local\MagpieTunnelConnector.{0}' -f $RemotePort)
    $m = New-Object System.Threading.Mutex($false, $name)
    $owned = $false
    try { $owned = $m.WaitOne(0) }
    catch [System.Threading.AbandonedMutexException] { $owned = $true }
    if (-not $owned) {
        try { $m.Close() } catch { }
        return $false
    }
    $global:ConnectorMutex = $m
    return $true
}

function New-ConnectorBackoff {
    param([int]$Current, [int]$Max = 60, [int]$Initial = 5)
    $steps = @(10, 20, 30, 60)
    $next = $Initial
    if ($Current -le $Initial) {
        $next = $steps[0]
    } else {
        $i = [array]::IndexOf($steps, $Current)
        if ($i -lt 0) { $next = $Initial }
        elseif ($i -eq $steps.Count - 1) { $next = $steps[$i] }
        else { $next = $steps[$i + 1] }
    }
    if ($next -gt $Max) { $next = $Max }
    return $next
}

function Resolve-ConnectorPaths {
    $root = $Root
    if ([string]::IsNullOrWhiteSpace($root)) { $root = (Join-Path $env:LOCALAPPDATA 'magpie-connector') }
    $root = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($root)
    $config = $ConfigPath
    if ([string]::IsNullOrWhiteSpace($config)) { $config = (Join-Path $root 'connector.json') }
    return @{ Root = $root; Config = $config }
}

# ---------------------------------------------------------------------------
# Dot-source modules (after helpers so their Write-McLog resolves Write-ConnectorLog)
# ---------------------------------------------------------------------------
. (Join-Path $PSScriptRoot 'MagpieDiscovery.ps1')
. (Join-Path $PSScriptRoot 'TunnelManager.ps1')

# ---------------------------------------------------------------------------
# Subcommands
# ---------------------------------------------------------------------------
function Invoke-ConnectorDiscover {
    $paths = Resolve-ConnectorPaths
    $cfgResult = Get-ConnectorConfig -ConfigPath $paths.Config -RootPath $paths.Root
    $cfg = $cfgResult.Config
    $g = Get-MagpieGateway -DefaultPort $cfg.magpie.defaultPort -HealthPath $cfg.magpie.healthPath -ExtraCandidatePorts $cfg.magpie.extraCandidatePorts
    if ($null -eq $g) {
        Write-Host 'Magpie gateway not found on any candidate port.'
        exit 4
    }
    Write-Host 'Magpie gateway discovered:'
    Write-Host ('  Port:     {0}' -f $g.Port)
    Write-Host ('  BaseUri:  {0}' -f $g.BaseUri)
    Write-Host ('  Version:  {0}' -f $g.Version)
    Write-Host ('  Source:   {0}' -f $g.Source)
    exit 0
}

function Invoke-ConnectorVerify {
    $global:ConnectorConsoleMirror = $true
    $paths = Resolve-ConnectorPaths
    if (-not (Test-Path -LiteralPath $paths.Config)) {
        Write-Host ('CONFIG MISSING: {0}' -f $paths.Config) -ForegroundColor Red
        exit 2
    }
    $cfg = (Get-ConnectorConfig -ConfigPath $paths.Config -RootPath $paths.Root).Config
    $errs = Test-ConnectorConfig -Config $cfg -RequireIdentity
    if ($errs.Count -gt 0) {
        Write-Host 'CONFIG INVALID:' -ForegroundColor Red
        foreach ($e in $errs) { Write-Host ('  - {0}' -f $e) -ForegroundColor Red }
        exit 2
    }
    $ssh = Find-SshExecutable
    if ([string]::IsNullOrEmpty($ssh)) {
        Write-Host 'SSH MISSING: ssh.exe not found (OpenSSH for Windows required)' -ForegroundColor Red
        exit 3
    }
    Write-Host ('ssh.exe: {0}' -f $ssh) -ForegroundColor Gray
    $g = Get-MagpieGateway -DefaultPort $cfg.magpie.defaultPort -HealthPath $cfg.magpie.healthPath -ExtraCandidatePorts $cfg.magpie.extraCandidatePorts
    if ($null -eq $g) {
        Write-Host 'MAGPIE NOT FOUND: local gateway is not reachable' -ForegroundColor Red
        exit 4
    }
    Write-Host ('magpie: {0} v{1} (source={2})' -f $g.BaseUri, $g.Version, $g.Source) -ForegroundColor Gray
    $probe = Test-TunnelOnline -Config $cfg -SshPath $ssh
    if ($probe.Online) {
        Write-Host ('TUNNEL OK: online=true version={0}' -f $probe.Payload.version) -ForegroundColor Green
        exit 0
    }
    Write-Host ('TUNNEL FAILED: reason={0} raw={1}' -f $probe.Reason, $probe.Raw) -ForegroundColor Red
    exit 5
}

function Invoke-ConnectorStatus {
    $global:ConnectorConsoleMirror = $true
    $paths = Resolve-ConnectorPaths
    Write-Host ('Root:    {0}' -f $paths.Root)
    Write-Host ('Config:  {0}' -f $paths.Config)
    if (-not (Test-Path -LiteralPath $paths.Config)) {
        Write-Host 'Config: NOT INSTALLED (connector.json missing)' -ForegroundColor Yellow
        Write-Host 'Status: not running'
        exit 0
    }
    $cfg = (Get-ConnectorConfig -ConfigPath $paths.Config -RootPath $paths.Root).Config
    $errs = Test-ConnectorConfig -Config $cfg -RequireIdentity
    if ($errs.Count -gt 0) {
        Write-Host 'Config: INVALID' -ForegroundColor Red
        foreach ($e in $errs) { Write-Host ('  - {0}' -f $e) -ForegroundColor Red }
    } else {
        Write-Host 'Config: valid' -ForegroundColor Green
    }
    $statePath = (Join-Path $paths.Root 'state\connector.json')
    $state = Get-ConnectorState -StatePath $statePath
    if ($null -eq $state) {
        Write-Host 'State:  no state file (has not run yet)'
    } else {
        $running = $false
        if ($state.pid -and $state.pid -gt 0) {
            try { $p = Get-Process -Id $state.pid -ErrorAction SilentlyContinue; if ($p) { $running = $true } } catch { }
        }
        Write-Host 'State file:'
        Write-Host ('  pid:            {0}' -f $state.pid)
        Write-Host ('  startedAt:      {0}' -f $state.startedAt)
        Write-Host ('  magpiePort:     {0}' -f $state.magpiePort)
        Write-Host ('  magpieVersion:  {0}' -f $state.magpieVersion)
        Write-Host ('  sshPid:         {0}' -f $state.sshPid)
        Write-Host ('  online:         {0}' -f $state.online)
        Write-Host ('  lastProbeAt:    {0}' -f $state.lastProbeAt)
        Write-Host ('  lastError:      {0}' -f $state.lastError)
        Write-Host ('  reconnects:     {0}' -f $state.reconnects)
        Write-Host ('  connector proc: {0}' -f $(if ($running) { 'alive' } else { 'not running' }))
    }
    $mtx = $null
    try { $mtx = [System.Threading.Mutex]::OpenExisting(('Local\MagpieTunnelConnector.{0}' -f $cfg.tunnel.remotePort)) } catch { }
    if ($null -ne $mtx) {
        Write-Host 'Single-instance mutex: HELD by this service' -ForegroundColor Green
        try { $mtx.Close() } catch { }
    } else {
        Write-Host 'Single-instance mutex: free'
    }
    try {
        $st = Get-ScheduledTask -TaskName 'MagpieTunnelConnector' -ErrorAction SilentlyContinue
        if ($null -ne $st) { Write-Host 'Scheduled task: registered' -ForegroundColor Green } else { Write-Host 'Scheduled task: not registered' }
    } catch {
        Write-Host 'Scheduled task: (Get-ScheduledTask unavailable)'
    }
    exit 0
}

function Invoke-ConnectorInstall {
    $installScript = (Join-Path $PSScriptRoot 'install.ps1')
    if (-not (Test-Path -LiteralPath $installScript)) {
        Write-Host ('install.ps1 not found at {0}' -f $installScript) -ForegroundColor Red
        exit 1
    }
    $params = @{}
    if (-not ([string]::IsNullOrWhiteSpace($Root))) { $params['Root'] = $Root }
    if (-not ([string]::IsNullOrWhiteSpace($SshHost))) { $params['SshHost'] = $SshHost }
    if ($SshPort -gt 0) { $params['SshPort'] = $SshPort }
    if (-not ([string]::IsNullOrWhiteSpace($SshUser))) { $params['SshUser'] = $SshUser }
    if (-not ([string]::IsNullOrWhiteSpace($IdentityFile))) { $params['IdentityFile'] = $IdentityFile }
    if (-not ([string]::IsNullOrWhiteSpace($KnownHostsFile))) { $params['KnownHostsFile'] = $KnownHostsFile }
    if (-not ([string]::IsNullOrWhiteSpace($RemoteBindAddress))) { $params['RemoteBindAddress'] = $RemoteBindAddress }
    if ($RemotePort -gt 0) { $params['RemotePort'] = $RemotePort }
    if ($DefaultPort -gt 0) { $params['DefaultPort'] = $DefaultPort }
    if ($NoTask) { $params['NoTask'] = $true }
    if ($DryRun) { $params['DryRun'] = $true }
    & $installScript @params
    exit $LASTEXITCODE
}

function Invoke-ConnectorUninstall {
    $uninstallScript = (Join-Path $PSScriptRoot 'uninstall.ps1')
    if (-not (Test-Path -LiteralPath $uninstallScript)) {
        Write-Host ('uninstall.ps1 not found at {0}' -f $uninstallScript) -ForegroundColor Red
        exit 1
    }
    $params = @{}
    if (-not ([string]::IsNullOrWhiteSpace($Root))) { $params['Root'] = $Root }
    if ($Purge) { $params['Purge'] = $true }
    if ($DryRun) { $params['DryRun'] = $true }
    & $uninstallScript @params
    exit $LASTEXITCODE
}

function Invoke-ConnectorRun {
    $paths = Resolve-ConnectorPaths
    $root = $paths.Root
    $configPath = $paths.Config
    if (-not (Test-Path -LiteralPath $configPath)) {
        Write-ConnectorLog -Level 'ERROR' ('config missing: {0}' -f $configPath)
        Write-Host ('CONFIG MISSING: {0}' -f $configPath) -ForegroundColor Red
        exit 2
    }
    foreach ($d in @('logs', 'state', 'secrets')) {
        $dd = (Join-Path $root $d)
        if (-not (Test-Path -LiteralPath $dd)) { New-Item -ItemType Directory -Path $dd -Force -ErrorAction Stop | Out-Null }
    }
    $global:ConnectorLogPath = (Join-Path $root 'logs\connector.log')
    $global:ConnectorConsoleMirror = $false
    $statePath = (Join-Path $root 'state\connector.json')

    $cfg = (Get-ConnectorConfig -ConfigPath $configPath -RootPath $root).Config
    $errs = Test-ConnectorConfig -Config $cfg -RequireIdentity
    if ($errs.Count -gt 0) {
        Write-ConnectorLog -Level 'ERROR' ('config invalid: ' + ($errs -join '; '))
        Write-Host 'CONFIG INVALID:' -ForegroundColor Red
        foreach ($e in $errs) { Write-Host ('  - {0}' -f $e) -ForegroundColor Red }
        exit 2
    }
    $global:ConnectorLogMaxBytes = $cfg.log.maxBytes
    $global:ConnectorLogKeep = $cfg.log.keep

    $ssh = Find-SshExecutable
    if ([string]::IsNullOrEmpty($ssh)) {
        Write-ConnectorLog -Level 'ERROR' 'ssh.exe not found'
        Write-Host 'SSH MISSING: ssh.exe not found' -ForegroundColor Red
        exit 3
    }

    if (-not (Test-ConnectorSingleInstance -RemotePort $cfg.tunnel.remotePort)) {
        Write-ConnectorLog -Level 'ERROR' 'another instance is already running'
        Write-Host 'ALREADY RUNNING: another instance holds the single-instance mutex' -ForegroundColor Yellow
        exit 20
    }

    $state = Get-ConnectorState -StatePath $statePath
    if ($state -and $state.sshPid -and $state.sshPid -gt 0) {
        try {
            $p = Get-Process -Id $state.sshPid -ErrorAction SilentlyContinue
            if ($p -and $p.Name -eq 'ssh') {
                & taskkill.exe /PID $state.sshPid /T /F 2>$null
                Write-ConnectorLog -Level 'WARN' ('killed stale ssh from previous run (pid {0})' -f $state.sshPid)
            }
        } catch { }
    }

    $pidVal = $pid
    Set-ConnectorState -StatePath $statePath -ConnectorPid $pidVal -StartedAt (Get-Date).ToString('o')
    Write-ConnectorLog -Level 'INFO' ('connector started (root={0}, remotePort={1}, ssh={2})' -f $root, $cfg.tunnel.remotePort, $ssh)

    try {
        $tunnel = $null
        $lastMagpie = $null
        $lastDiscoverAt = [datetime]::MinValue
        $lastHealthAt = [datetime]::MinValue
        $lastMissLogAt = [datetime]::MinValue
        $backoff = $cfg.reconnect.initialDelaySeconds
        $reconnects = 0
        $lastOnline = $false

        while ($true) {
            $now = Get-Date
            $needDiscover = ($null -eq $tunnel) -or ($null -eq $lastMagpie) -or (($now - $lastDiscoverAt).TotalSeconds -ge $cfg.reconnect.discoverEverySeconds)
            $magpie = $null
            if ($needDiscover) {
                $magpie = Get-MagpieGateway -DefaultPort $cfg.magpie.defaultPort -HealthPath $cfg.magpie.healthPath -ExtraCandidatePorts $cfg.magpie.extraCandidatePorts
                $lastDiscoverAt = $now
                if ($null -ne $magpie) {
                    if ($null -eq $lastMagpie -or $lastMagpie.Port -ne $magpie.Port -or $lastMagpie.Version -ne $magpie.Version) {
                        Write-ConnectorLog -Level 'INFO' ('discovered magpie at port {0} v{1} (source={2})' -f $magpie.Port, $magpie.Version, $magpie.Source)
                    }
                    $lastMagpie = $magpie
                } else {
                    if (($now - $lastMissLogAt).TotalSeconds -ge 60) {
                        Write-ConnectorLog -Level 'WARN' 'magpie gateway not found; will keep retrying'
                        $lastMissLogAt = $now
                    }
                    $lastMagpie = $null
                }
            }
            if ($null -eq $magpie) { $magpie = $lastMagpie }

            if ($null -eq $magpie) {
                Start-Sleep -Seconds 5
                continue
            }

            $portChanged = ($null -ne $tunnel -and $tunnel.MagpiePort -ne $magpie.Port)

            if ($null -eq $tunnel -or $portChanged) {
                if ($portChanged) {
                    Write-ConnectorLog -Level 'INFO' ('magpie port changed {0} -> {1}; rebuilding tunnel' -f $tunnel.MagpiePort, $magpie.Port)
                    Stop-Tunnel -Tunnel $tunnel
                    $tunnel = $null
                }
                try {
                    $tunnel = Start-Tunnel -Config $cfg -SshPath $ssh -MagpiePort $magpie.Port
                    Write-ConnectorLog -Level 'INFO' ('ssh launched (pid {0}); waiting 2s then probe' -f $tunnel.Pid)
                    Start-Sleep -Seconds 2
                    $probe = Test-TunnelOnline -Config $cfg -SshPath $ssh
                    $lastProbeAt = Get-Date
                    if ($probe.Online) {
                        $backoff = $cfg.reconnect.initialDelaySeconds
                        $reconnects = 0
                        $lastOnline = $true
                        Write-ConnectorLog -Level 'INFO' ('tunnel online (version={0})' -f $probe.Payload.version)
                        Set-ConnectorState -StatePath $statePath -ConnectorPid $pidVal -StartedAt (Get-Date).ToString('o') -MagpiePort $magpie.Port -MagpieVersion $magpie.Version -SshPid $tunnel.Pid -Online $true -LastProbeAt $lastProbeAt.ToString('o') -LastError '' -Reconnects $reconnects
                    } else {
                        $reconnects++
                        $err = if ($probe.Reason) { $probe.Reason } else { 'probe-failed' }
                        $backoff = New-ConnectorBackoff -Current $backoff -Max $cfg.reconnect.maxDelaySeconds
                        Write-ConnectorLog -Level 'WARN' ('tunnel not online (reason={0}); wait {1}s (#{2})' -f $err, $backoff, $reconnects)
                        Set-ConnectorState -StatePath $statePath -ConnectorPid $pidVal -StartedAt (Get-Date).ToString('o') -MagpiePort $magpie.Port -MagpieVersion $magpie.Version -SshPid $tunnel.Pid -Online $false -LastProbeAt $lastProbeAt.ToString('o') -LastError $err -Reconnects $reconnects
                        Stop-Tunnel -Tunnel $tunnel
                        $tunnel = $null
                        Start-Sleep -Seconds $backoff
                        continue
                    }
                } catch {
                    Write-ConnectorLog -Level 'ERROR' ('failed to start tunnel: {0}' -f $_.Exception.Message)
                    $reconnects++
                    Set-ConnectorState -StatePath $statePath -ConnectorPid $pidVal -StartedAt (Get-Date).ToString('o') -MagpiePort $magpie.Port -MagpieVersion $magpie.Version -Online $false -LastProbeAt (Get-Date).ToString('o') -LastError $_.Exception.Message -Reconnects $reconnects
                    $tunnel = $null
                    $backoff = New-ConnectorBackoff -Current $backoff -Max $cfg.reconnect.maxDelaySeconds
                    Start-Sleep -Seconds $backoff
                    continue
                }
            } else {
                if (($now - $lastHealthAt).TotalSeconds -ge 15) {
                    $lastHealthAt = $now
                    $alive = ($null -ne $tunnel.Process -and -not $tunnel.Process.HasExited)
                    if (-not $alive) {
                        Write-ConnectorLog -Level 'WARN' 'ssh process died; rebuilding'
                        $reconnects++
                        Set-ConnectorState -StatePath $statePath -ConnectorPid $pidVal -StartedAt (Get-Date).ToString('o') -MagpiePort $magpie.Port -MagpieVersion $magpie.Version -Online $false -LastProbeAt (Get-Date).ToString('o') -LastError 'ssh-exited' -Reconnects $reconnects
                        $tunnel = $null
                        continue
                    }
                    $probe = Test-TunnelOnline -Config $cfg -SshPath $ssh
                    $lastProbeAt = Get-Date
                    if (-not $probe.Online) {
                        $err = if ($probe.Reason) { $probe.Reason } else { 'probe-failed' }
                        Write-ConnectorLog -Level 'WARN' ('probe failed (reason={0}); rebuilding' -f $err)
                        $reconnects++
                        Set-ConnectorState -StatePath $statePath -ConnectorPid $pidVal -StartedAt (Get-Date).ToString('o') -MagpiePort $magpie.Port -MagpieVersion $magpie.Version -SshPid $tunnel.Pid -Online $false -LastProbeAt $lastProbeAt.ToString('o') -LastError $err -Reconnects $reconnects
                        Stop-Tunnel -Tunnel $tunnel
                        $tunnel = $null
                        $backoff = $cfg.reconnect.initialDelaySeconds
                        continue
                    } else {
                        if (-not $lastOnline) {
                            Write-ConnectorLog -Level 'INFO' ('tunnel healthy (version={0})' -f $probe.Payload.version)
                        }
                        $lastOnline = $true
                        Set-ConnectorState -StatePath $statePath -ConnectorPid $pidVal -StartedAt (Get-Date).ToString('o') -MagpiePort $magpie.Port -MagpieVersion $magpie.Version -SshPid $tunnel.Pid -Online $true -LastProbeAt $lastProbeAt.ToString('o') -LastError '' -Reconnects $reconnects
                    }
                }
            }
            Start-Sleep -Seconds 1
        }
    } finally {
        if ($null -ne $tunnel) { Stop-Tunnel -Tunnel $tunnel }
        try { if ($null -ne $global:ConnectorMutex) { $global:ConnectorMutex.ReleaseMutex(); $global:ConnectorMutex.Close() } } catch { }
        Write-ConnectorLog -Level 'INFO' 'connector stopped'
        Set-ConnectorState -StatePath $statePath -ConnectorPid $pidVal -StartedAt (Get-Date).ToString('o') -Online $false -LastError 'stopped' -Reconnects $reconnects
    }
}

function Invoke-ConnectorSelftest {
    $global:ConnectorConsoleMirror = $true
    $global:McSelftestFail = 0
    $global:McSelftestTotal = 0
    $tmp = Join-Path $env:TEMP ('mc-selftest-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp -Force -ErrorAction Stop | Out-Null
    Write-Host 'Running self-test (PowerShell ' + $PSVersionTable.PSVersion.ToString() + '):'

    # 1. PowerShell version sanity
    Test-Assert -Name 'powershell 5.x' -Ok ($PSVersionTable.PSVersion.Major -le 5)

    # 2. Template is valid JSON with expected top-level keys
    $templatePath = (Join-Path $PSScriptRoot 'connector.config.template.json')
    $ok = $false
    try {
        $t = Get-Content -LiteralPath $templatePath -Raw | ConvertFrom-Json
        $ok = ($t.PSObject.Properties['ssh'] -and $t.PSObject.Properties['tunnel'] -and $t.PSObject.Properties['magpie'] -and $t.PSObject.Properties['reconnect'] -and $t.PSObject.Properties['log'])
    } catch { }
    Test-Assert -Name 'config template valid + schema' -Ok $ok

    # 3. Default config shape
    $dc = Get-DefaultConfig
    Test-Assert -Name 'default config shape' -Ok ($dc.ssh -and $dc.tunnel.remotePort -eq 13425 -and $dc.magpie.defaultPort -eq 3425)

    # 4. Argument quoting round-trip (spaces, quotes, no backslash/quote corner issues)
    $quoted = ConvertTo-McCommandLine -Arguments @('ssh', '-i', 'C:\Users\Test User\key', '-R', '127.0.0.1:13425:127.0.0.1:3425', 'user@host')
    $expected = 'ssh -i "C:\Users\Test User\key" -R 127.0.0.1:13425:127.0.0.1:3425 user@host'
    Test-Assert -Name 'argv quoting (spaces)' -Ok ($quoted -eq $expected) -Detail ('got: ' + $quoted)
    $quoted2 = ConvertTo-McCommandLine -Arguments @('prog', 'he said "hi"')
    Test-Assert -Name 'argv quoting (embedded quote)' -Ok ($quoted2 -eq 'prog "he said \"hi\""') -Detail ('got: ' + $quoted2)

    # 5. Log redaction (no secrets in logs)
    $safe = Protect-LogText -Text 'key sk-magpie-abcDEF123 and lanKey="xyz789" and -----BEGIN OPENSSH PRIVATE KEY-----'
    Test-Assert -Name 'redact sk-magpie-*' -Ok ($safe -like '*sk-magpie-***' -and $safe -notlike '*sk-magpie-abcDEF123*')
    Test-Assert -Name 'redact lanKey value' -Ok ($safe -like '*lanKey=***' -and $safe -notlike '*xyz789*')
    Test-Assert -Name 'redact private key banner' -Ok ($safe -like '*redacted*')

    # 6. Log rotation
    $logFile = Join-Path $tmp 'connector.log'
    $global:ConnectorLogPath = $logFile
    $global:ConnectorLogMaxBytes = 20
    $global:ConnectorLogKeep = 2
    $global:ConnectorConsoleMirror = $false
    1..5 | ForEach-Object { Write-ConnectorLog -Level 'INFO' ('line number {0} with some text to exceed size' -f $_) }
    $rotated = Test-Path -LiteralPath ($logFile + '.1')
    Test-Assert -Name 'log rotates past maxBytes' -Ok $rotated
    $global:ConnectorLogPath = ''

    # 7. State round-trip
    $statePath = Join-Path $tmp 'state.json'
    Set-ConnectorState -StatePath $statePath -ConnectorPid 1234 -MagpiePort 3425 -MagpieVersion '0.1.3493' -SshPid 5678 -Online $true -Reconnects 2
    $st = Get-ConnectorState -StatePath $statePath
    Test-Assert -Name 'state round-trip' -Ok ($st -and $st.pid -eq 1234 -and $st.magpiePort -eq 3425 -and $st.online -eq $true -and $st.reconnects -eq 2)

    # 8. Probe parsing (no ssh needed)
    $p1 = Parse-TunnelProbe -Raw '{"ok":true,"listen":"127.0.0.1:13425","magpie":true,"version":"0.1.3206"}'
    Test-Assert -Name 'probe parse ok=true' -Ok ($p1.Online -eq $true -and $p1.Payload.version -eq '0.1.3206')
    $p2 = Parse-TunnelProbe -Raw '{"ok":false,"reason":"no-listener","port":13425}'
    Test-Assert -Name 'probe parse ok=false reason' -Ok ($p2.Online -eq $false -and $p2.Reason -eq 'no-listener')
    $p3 = Parse-TunnelProbe -Raw 'garbage'
    Test-Assert -Name 'probe parse garbage -> not online' -Ok ($p3.Online -eq $false -and $p3.Reason -eq 'parse-error')
    $p4 = Parse-TunnelProbe -Raw ''
    Test-Assert -Name 'probe parse empty -> not online' -Ok ($p4.Online -eq $false)

    # 9. Discovery against the real local Magpie (if present)
    $g = Get-MagpieGateway -DefaultPort 3425 -HealthPath '/api/hello'
    if ($null -ne $g) {
        Test-Assert -Name 'discover real magpie' -Ok ($g.Version -eq '0.1.3493') -Detail ('port={0} version={1}' -f $g.Port, $g.Version)
    } else {
        Test-Assert -Name 'discover real magpie' -Ok $true -Detail '(magpie not running; skipped)'
    }

    # 10. Fake-ssh process management (stderr capture + clean kill)
    $fakeSsh = Join-Path $tmp 'fake-ssh.cmd'
    $dummyKey = Join-Path $tmp 'dummykey'
    Set-Content -LiteralPath $dummyKey -Value 'dummy' -Encoding ASCII
    $fakeCmd = "@echo off`r`necho FAKE-SSH-STDERR-LINE 1>&2`r`nping -n 9 127.0.0.1 >nul 2>&1`r`nexit /b 0`r`n"
    Set-Content -LiteralPath $fakeSsh -Value $fakeCmd -Encoding ASCII
    $fakeLog = Join-Path $tmp 'fake-connector.log'
    $global:ConnectorLogPath = $fakeLog
    $fakeCfg = @{ ssh = @{ knownHostsFile = (Join-Path $tmp 'kh'); identityFile = $dummyKey; port = 22; user = 'u'; host = 'h' }; tunnel = @{ remoteBindAddress = '127.0.0.1'; remotePort = 13425 } }
    $fakeTunnel = $null
    try {
        $fakeTunnel = Start-Tunnel -Config $fakeCfg -SshPath $fakeSsh -MagpiePort 3425
        $captured = $false
        for ($i = 0; $i -lt 30; $i++) {
            Start-Sleep -Milliseconds 200
            if (Test-Path -LiteralPath $fakeLog) {
                $txt = Get-Content -LiteralPath $fakeLog -Raw -ErrorAction SilentlyContinue
                if ($txt -like '*FAKE-SSH-STDERR-LINE*') { $captured = $true; break }
            }
        }
        Test-Assert -Name 'fake-ssh stderr captured to log' -Ok $captured
    } catch {
        Test-Assert -Name 'fake-ssh start' -Ok $false -Detail $_.Exception.Message
    } finally {
        if ($null -ne $fakeTunnel) { Stop-Tunnel -Tunnel $fakeTunnel }
        Start-Sleep -Milliseconds 500
    }
    $stillAlive = $false
    try { $pp = Get-Process -Id $fakeTunnel.Pid -ErrorAction SilentlyContinue; if ($pp) { $stillAlive = $true } } catch { }
    Test-Assert -Name 'fake-ssh killed on Stop-Tunnel' -Ok (-not $stillAlive)
    $global:ConnectorLogPath = ''

    # 11. Single-instance mutex (cross-process: a second process must NOT acquire
    # while the first holds it; Windows mutex is recursive per-thread so this must
    # be checked across processes, not handles in the same thread).
    $mxName = 'Local\MagpieTunnelConnector.59998'
    $mxChild = Join-Path $tmp ('mx-child-' + [Guid]::NewGuid().ToString('N') + '.ps1')
    Set-Content -LiteralPath $mxChild -Value ('try { $m = New-Object System.Threading.Mutex($false,"Local\MagpieTunnelConnector.59998"); $o = $m.WaitOne(0); Write-Output ("CHILD_OWNED=" + $o); if ($o) { try { $m.ReleaseMutex() } catch { } }; $m.Close() } catch { Write-Output ("CHILD_ERR=" + $_.Exception.Message) }') -Encoding ASCII
    $mxParent = New-Object System.Threading.Mutex($false, $mxName)
    $mxParentOwned = $mxParent.WaitOne(0)
    $mxOut = Join-Path $tmp ('mx-out-' + [Guid]::NewGuid().ToString('N') + '.txt')
    $null = Start-Process -FilePath powershell.exe -ArgumentList ('-NoProfile -File "' + $mxChild + '"') -Wait -PassThru -RedirectStandardOutput $mxOut -WindowStyle Hidden
    $mxChildOut = Get-Content -LiteralPath $mxOut -Raw -ErrorAction SilentlyContinue
    $mxChildOwned = ($mxChildOut -match 'CHILD_OWNED=True')
    if ($mxParentOwned) { try { $mxParent.ReleaseMutex(); $mxParent.Close() } catch { } }
    Test-Assert -Name 'single-instance mutex (cross-process)' -Ok ($mxParentOwned -and -not $mxChildOwned) -Detail ($mxChildOut.Trim())

    Write-Host ''
    Write-Host (('Self-test: {0} passed, {1} failed (total {2})' -f ($global:McSelftestTotal - $global:McSelftestFail), $global:McSelftestFail, $global:McSelftestTotal))
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    if ($global:McSelftestFail -gt 0) { exit 1 }
    exit 0
}

function Test-Assert {
    param([string]$Name, [bool]$Ok, [string]$Detail = '')
    if (-not $Ok) { $global:McSelftestFail++ }
    $global:McSelftestTotal++
    $mark = if ($Ok) { 'PASS' } else { 'FAIL' }
    $col = if ($Ok) { 'Green' } else { 'Red' }
    Write-Host ('  [{0}] {1} {2}' -f $mark, $Name, $Detail) -ForegroundColor $col
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
switch ($Command) {
    'run'       { Invoke-ConnectorRun }
    'status'    { Invoke-ConnectorStatus }
    'discover'  { Invoke-ConnectorDiscover }
    'verify'    { Invoke-ConnectorVerify }
    'install'   { Invoke-ConnectorInstall }
    'uninstall' { Invoke-ConnectorUninstall }
    'selftest'  { Invoke-ConnectorSelftest }
}
