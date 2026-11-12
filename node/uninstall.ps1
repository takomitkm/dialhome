# uninstall.ps1
# Removes the Magpie tunnel connector autostart, stops running processes, and
# optionally purges the install root. PowerShell 5.1 compatible. ASCII-only source.
param(
    [string]$Root = '',
    [switch]$Purge,
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'

function Write-UninstallLog {
    param([string]$Level = 'INFO', [string]$Message = '')
    Write-Host ('[{0}] {1}' -f $Level, $Message)
}

if ([string]::IsNullOrWhiteSpace($Root)) { $Root = (Join-Path $env:LOCALAPPDATA 'magpie-connector') }
$rootAbs = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Root)

if ($DryRun) {
    Write-UninstallLog -Level 'INFO' ('[DRY-RUN] would uninstall: ' + $rootAbs)
    Write-UninstallLog -Level 'INFO' ('[DRY-RUN] Purge: ' + $Purge)
    exit 0
}

# Stop running connector processes (ssh child + the connector powershell).
$statePath = (Join-Path $rootAbs 'state\connector.json')
if (Test-Path -LiteralPath $statePath) {
    try {
        $st = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
        if ($st.sshPid -and $st.sshPid -gt 0) {
            & taskkill.exe /PID $st.sshPid /T /F 2>$null
            Write-UninstallLog -Level 'INFO' ('killed ssh pid ' + $st.sshPid)
        }
    } catch { }
}
try {
    $procs = Get-CimInstance -ClassName Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like '*connector.ps1*run*' }
    foreach ($p in $procs) {
        & taskkill.exe /PID $p.ProcessId /T /F 2>$null
        Write-UninstallLog -Level 'INFO' ('killed connector pid ' + $p.ProcessId)
    }
} catch { }

# Remove scheduled task.
$taskName = 'MagpieTunnelConnector'
try {
    $t = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($t) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop
        Write-UninstallLog -Level 'INFO' 'scheduled task removed'
    } else {
        Write-UninstallLog -Level 'INFO' 'scheduled task not present'
    }
} catch {
    & schtasks.exe /Delete /TN $taskName /F 2>$null
    Write-UninstallLog -Level 'INFO' 'scheduled task removed (schtasks fallback)'
}

# Remove HKCU Run entry (install.ps1's second autostart level).
try {
    $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    $val = Get-ItemProperty -Path $runKey -Name 'MagpieTunnelConnector' -ErrorAction SilentlyContinue
    if ($val) {
        Remove-ItemProperty -Path $runKey -Name 'MagpieTunnelConnector' -ErrorAction Stop
        Write-UninstallLog -Level 'INFO' 'HKCU Run entry removed'
    }
} catch {
    Write-UninstallLog -Level 'WARN' ('could not remove HKCU Run entry: ' + $_.Exception.Message)
}

# Remove startup shortcut.
$lnk = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup\MagpieTunnelConnector.lnk'
if (Test-Path -LiteralPath $lnk) {
    Remove-Item -LiteralPath $lnk -Force -ErrorAction SilentlyContinue
    Write-UninstallLog -Level 'INFO' 'startup shortcut removed'
}

Write-UninstallLog -Level 'INFO' 'autostart and processes removed'

if ($Purge) {
    if (Test-Path -LiteralPath $rootAbs) {
        # Private keys / secrets files may carry a locked-down or empty DACL
        # (the installer hardens them; some agent sandboxes leave children with an
        # empty inherited DACL). Force-own + reset the tree so removal cannot fail.
        & takeown.exe /f $rootAbs /r /d n 2>$null | Out-Null
        & icacls.exe  $rootAbs /reset /t /c /q 2>$null | Out-Null
        & attrib.exe  -r (Join-Path $rootAbs '*') /s /d 2>$null | Out-Null
        try {
            Remove-Item -LiteralPath $rootAbs -Recurse -Force -ErrorAction Stop
        } catch {
            Write-UninstallLog -Level 'WARN' ('first removal pass failed: ' + $_.Exception.Message + '; retrying with grant')
            & takeown.exe /f $rootAbs /r /d n 2>$null | Out-Null
            & icacls.exe  $rootAbs /grant:r ('{0}:F' -f $env:USERNAME) /t /c /q 2>$null | Out-Null
            Remove-Item -LiteralPath $rootAbs -Recurse -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $rootAbs) {
            Write-UninstallLog -Level 'ERROR' ('could not fully remove: ' + $rootAbs)
            exit 1
        }
        Write-UninstallLog -Level 'INFO' ('removed install root: ' + $rootAbs)
    }
} else {
    Write-UninstallLog -Level 'INFO' ('kept files at: ' + $rootAbs + ' (use -Purge to delete)')
}
exit 0
