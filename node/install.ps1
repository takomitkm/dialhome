# install.ps1
# Installs the Magpie tunnel connector: copies bundle, copies + hardens the SSH
# private key, writes connector.json, and registers login autostart.
# PowerShell 5.1 compatible. ASCII-only source.
param(
    [string]$Root = '',
    [string]$SourceDir = '',
    [string]$SshHost = '',
    [int]$SshPort = 22,
    [string]$SshUser = '',
    [string]$IdentityFile = '',
    [string]$KnownHostsFile = '',
    [string]$RemoteBindAddress = '127.0.0.1',
    [int]$RemotePort = 13425,
    [int]$DefaultPort = 3425,
    [ValidateSet('auto', 'task', 'runkey', 'startup', 'none')]
    [string]$Autostart = 'auto',
    [switch]$NoTask,
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'

function Write-InstallLog {
    param([string]$Level = 'INFO', [string]$Message = '')
    Write-Host ('[{0}] {1}' -f $Level, $Message)
}

function Set-RestrictedAcl {
    # Removes inherited ACLs and grants only the current user Full Control.
    # Windows OpenSSH rejects world-readable private keys, so this is mandatory.
    param([string]$Path)
    $account = if ($env:USERDOMAIN -and $env:USERDOMAIN.Trim() -ne '') { ('{0}\{1}' -f $env:USERDOMAIN, $env:USERNAME) } else { $env:USERNAME }
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & icacls.exe $Path /inheritance:r /grant:r ('{0}:F' -f $account)
        if ($LASTEXITCODE -eq 0) { return $true }
        & icacls.exe $Path /inheritance:r /grant:r ('{0}:F' -f $env:USERNAME)
        if ($LASTEXITCODE -eq 0) { return $true }
    } finally {
        $ErrorActionPreference = $prev
    }
    return $false
}

function Register-ConnectorAutostart {
    param([string]$Root)
    $rootAbs = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Root)
    $taskName = 'MagpieTunnelConnector'
    $entry = Join-Path $rootAbs 'connector.ps1'
    $argStr = ('-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" run' -f $entry)
    try {
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argStr
        $user = & whoami.exe
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Seconds 0) -MultipleInstances IgnoreNew -Hidden
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -RunLevel Limited -Force -ErrorAction Stop
        return 'task'
    } catch {
        Write-InstallLog -Level 'WARN' ('Register-ScheduledTask failed: {0}; trying schtasks.exe' -f $_.Exception.Message)
        $inner = ('\"powershell.exe\" -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File \"' + $rootAbs + '\connector.ps1\" run')
        $trArg = ('/TR "' + $inner + '"')
        try {
            & schtasks.exe /Create /TN $taskName /SC ONLOGON $trArg /F
            if ($LASTEXITCODE -eq 0) { return 'schtasks' }
        } catch { }
        return $null
    }
}

function Register-ConnectorRunKey {
    # HKCU Run: needs no elevation at all, survives as long as the user profile exists.
    param([string]$Root)
    $rootAbs = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Root)
    $cmd = ('powershell.exe -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" run' -f (Join-Path $rootAbs 'connector.ps1'))
    try {
        New-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'MagpieTunnelConnector' `
            -Value $cmd -PropertyType String -Force -ErrorAction Stop | Out-Null
        return 'runkey'
    } catch {
        Write-InstallLog -Level 'WARN' ('HKCU Run registration failed: ' + $_.Exception.Message)
        return $null
    }
}

function Register-ConnectorStartupShortcut {
    param([string]$Root)
    $rootAbs = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Root)
    $startup = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'
    if (-not (Test-Path -LiteralPath $startup)) { New-Item -ItemType Directory -Path $startup -Force | Out-Null }
    $lnk = Join-Path $startup 'MagpieTunnelConnector.lnk'
    try {
        $ws = New-Object -ComObject WScript.Shell
        $sc = $ws.CreateShortcut($lnk)
        $sc.TargetPath = 'powershell.exe'
        $sc.Arguments = ('-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" run' -f (Join-Path $rootAbs 'connector.ps1'))
        $sc.WindowStyle = 7
        $sc.Save()
        return $true
    } catch {
        Write-InstallLog -Level 'WARN' ('startup shortcut failed: {0}' -f $_.Exception.Message)
        return $false
    }
}

if ([string]::IsNullOrWhiteSpace($SourceDir)) { $SourceDir = $PSScriptRoot }
if ([string]::IsNullOrWhiteSpace($Root)) { $Root = (Join-Path $env:LOCALAPPDATA 'magpie-connector') }
$rootAbs = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Root)

if ([string]::IsNullOrWhiteSpace($SshHost)) { Write-InstallLog -Level 'ERROR' 'ssh host is required (-SshHost)'; exit 2 }
if ([string]::IsNullOrWhiteSpace($SshUser)) { Write-InstallLog -Level 'ERROR' 'ssh user is required (-SshUser)'; exit 2 }
if ([string]::IsNullOrWhiteSpace($IdentityFile)) { Write-InstallLog -Level 'ERROR' 'identity file is required (-IdentityFile)'; exit 2 }
if (-not (Test-Path -LiteralPath $IdentityFile)) { Write-InstallLog -Level 'ERROR' ('identity file not found: ' + $IdentityFile); exit 2 }

if ($DryRun) {
    Write-InstallLog -Level 'INFO' ('[DRY-RUN] would install to: ' + $rootAbs)
    Write-InstallLog -Level 'INFO' ('[DRY-RUN] ssh: ' + $SshUser + '@' + $SshHost + ':' + $SshPort)
    Write-InstallLog -Level 'INFO' ('[DRY-RUN] identity: ' + $IdentityFile)
    Write-InstallLog -Level 'INFO' ('[DRY-RUN] remotePort: ' + $RemotePort)
    Write-InstallLog -Level 'INFO' ('[DRY-RUN] NoTask: ' + $NoTask)
    exit 0
}

foreach ($d in @($rootAbs, (Join-Path $rootAbs 'secrets'), (Join-Path $rootAbs 'logs'), (Join-Path $rootAbs 'state'))) {
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force -ErrorAction Stop | Out-Null }
}

$bundle = @('connector.ps1', 'MagpieDiscovery.ps1', 'TunnelManager.ps1', 'install.ps1', 'uninstall.ps1', 'bootstrap.ps1', 'ensure-magpie.ps1', 'migrate-to-D.ps1', 'connector.config.template.json')
foreach ($f in $bundle) {
    $src = Join-Path $SourceDir $f
    $dst = Join-Path $rootAbs $f
    if (-not (Test-Path -LiteralPath $src)) { continue }
    # When -SourceDir equals -Root (e.g. bootstrap expands payload straight into Root),
    # the source IS the destination already -- skip the self-copy instead of erroring.
    $sp = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($src)
    $dp = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($dst)
    if ($sp -eq $dp) { continue }
    Copy-Item -LiteralPath $src -Destination $dst -Force -ErrorAction Stop
}

$secDir = (Join-Path $rootAbs 'secrets')
$copiedKey = (Join-Path $secDir ([System.IO.Path]::GetFileName($IdentityFile)))
if ($copiedKey -ne $IdentityFile) { Copy-Item -LiteralPath $IdentityFile -Destination $copiedKey -Force -ErrorAction Stop }
$okKey = Set-RestrictedAcl -Path $copiedKey
if (-not $okKey) {
    Write-InstallLog -Level 'ERROR' ('FATAL: could not restrict ACL on private key (icacls failed): ' + $copiedKey)
    Write-InstallLog -Level 'ERROR' 'Windows OpenSSH will reject a too-permissive key; aborting install.'
    exit 1
}
# Second pass: Windows OpenSSH also rejects LogonSessionId_* ACEs left behind by
# processes that wrote the file inside an active logon session (common in CI/agent
# sandboxes). /reset rebuilds the ACL from the parent (which is now restricted),
# removing stale S-1-5-5-* ACEs.
try {
    & icacls.exe $copiedKey /reset 2>$null
    & icacls.exe $copiedKey /inheritance:r /grant:r ('{0}:F' -f $env:USERNAME) 2>$null
    if ($LASTEXITCODE -ne 0) { Write-InstallLog -Level 'WARN' ('second-pass icacls returned exit code ' + $LASTEXITCODE) }
} catch { }
Write-InstallLog -Level 'INFO' ('private key copied + hardened: ' + $copiedKey)

if (-not [string]::IsNullOrWhiteSpace($KnownHostsFile)) {
    if (Test-Path -LiteralPath $KnownHostsFile) {
        $khDest = (Join-Path $secDir 'known_hosts')
        # self-copy guard (SourceDir == Root case): the file is already in place
        $sp = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($KnownHostsFile)
        $dp = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($khDest)
        if ($sp -eq $dp) {
            Write-InstallLog -Level 'INFO' ('known_hosts already in place: ' + $khDest)
        } else {
            if (Test-Path -LiteralPath $khDest) {
                Remove-Item -LiteralPath $khDest -Force -ErrorAction SilentlyContinue
                if (Test-Path -LiteralPath $khDest) {
                    & icacls.exe $khDest /grant:r ('{0}:F' -f $env:USERNAME) 2>$null
                    Remove-Item -LiteralPath $khDest -Force -ErrorAction SilentlyContinue
                }
            }
            Copy-Item -LiteralPath $KnownHostsFile -Destination $khDest -Force -ErrorAction Stop
        }
    } else {
        Write-InstallLog -Level 'WARN' ('known_hosts not found, creating empty: ' + $KnownHostsFile)
        '' | Out-File -LiteralPath (Join-Path $secDir 'known_hosts') -Encoding ASCII
    }
} else {
    '' | Out-File -LiteralPath (Join-Path $secDir 'known_hosts') -Encoding ASCII
}

$okDir = Set-RestrictedAcl -Path $secDir
if (-not $okDir) { Write-InstallLog -Level 'WARN' ('could not restrict ACL on secrets dir: ' + $secDir) }

# ssh writes new host keys into this file (StrictHostKeyChecking=accept-new). Make sure the
# current user can write it -- tightening the secrets directory must not lock it out.
$khFinal = Join-Path $secDir 'known_hosts'
if (-not (Test-Path -LiteralPath $khFinal)) { '' | Out-File -LiteralPath $khFinal -Encoding ASCII }
& icacls.exe $khFinal /inheritance:r /grant:r ('{0}:F' -f $env:USERNAME) 2>$null | Out-Null
if (-not (Test-Path -LiteralPath $khFinal)) { Write-InstallLog -Level 'WARN' 'known_hosts missing after ACL pass' }

$configPath = (Join-Path $rootAbs 'connector.json')
$template = Get-Content -LiteralPath (Join-Path $SourceDir 'connector.config.template.json') -Raw | ConvertFrom-Json
$template.ssh.host = $SshHost
$template.ssh.port = $SshPort
$template.ssh.user = $SshUser
$template.ssh.identityFile = $copiedKey
$template.ssh.knownHostsFile = (Join-Path $secDir 'known_hosts')
$template.tunnel.remoteBindAddress = $RemoteBindAddress
$template.tunnel.remotePort = $RemotePort
$template.magpie.defaultPort = $DefaultPort
$template | ConvertTo-Json -Depth 5 | Out-File -LiteralPath $configPath -Encoding ASCII
Write-InstallLog -Level 'INFO' ('config written: ' + $configPath)

Write-InstallLog -Level 'INFO' ('installed to: ' + $rootAbs)

$method = $Autostart
if ($NoTask) { $method = 'none' }

if ($method -eq 'none') {
    Write-InstallLog -Level 'INFO' 'autostart skipped; run connector.ps1 manually or register it yourself'
} else {
    $done = $null
    if ($method -eq 'auto' -or $method -eq 'task') { $done = Register-ConnectorAutostart -Root $rootAbs }
    if (($method -eq 'auto' -or $method -eq 'runkey') -and -not $done) { $done = Register-ConnectorRunKey -Root $rootAbs }
    if (($method -eq 'auto' -or $method -eq 'startup') -and -not $done) {
        Write-InstallLog -Level 'WARN' 'trying startup-folder shortcut'
        if (Register-ConnectorStartupShortcut -Root $rootAbs) { $done = 'startup' }
    }
    if ($done) {
        Write-InstallLog -Level 'INFO' ('autostart registered (' + $done + ') -- user scope, no elevation needed')
    } else {
        Write-InstallLog -Level 'WARN' 'autostart failed at all levels; run connector.ps1 manually'
    }
}
exit 0
