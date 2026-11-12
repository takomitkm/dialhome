# MagpieDiscovery.ps1
# Discovers the local Magpie gateway by probing candidate ports over HTTP.
# Dot-sourced by connector.ps1. PowerShell 5.1 compatible. ASCII-only source.
$ErrorActionPreference = 'Stop'

function Write-McLog {
    param([string]$Level = 'INFO', [string]$Message = '')
    $cmd = Get-Command -Name 'Write-ConnectorLog' -ErrorAction SilentlyContinue
    if ($null -ne $cmd) { & $cmd -Level $Level -Message $Message }
}

function Get-MagpieGateway {
    # Returns [pscustomobject]@{ Port; BaseUri; Version; Source } or $null.
    # Source is one of: 'settings-port', 'default', 'extra'.
    # Never throws; logs the reason and returns $null when not found.
    param(
        [int]$DefaultPort = 3425,
        [string]$HealthPath = '/api/hello',
        [int[]]$ExtraCandidatePorts = @(),
        [string]$ConfigFilePath = '',
        [int]$TimeoutSeconds = 3
    )

    # Resolve the Magpie settings.json (read-only; never written).
    $settingsPath = ''
    if ($ConfigFilePath -and (Test-Path -LiteralPath $ConfigFilePath)) {
        $settingsPath = $ConfigFilePath
    } else {
        $paths = @()
        $xdg = [Environment]::GetEnvironmentVariable('XDG_CONFIG_HOME')
        if ($xdg -and $xdg.Trim() -ne '') {
            $paths += (Join-Path $xdg 'magpie\settings.json')
        }
        $paths += (Join-Path $env:USERPROFILE '.config\magpie\settings.json')
        foreach ($p in $paths) {
            if (Test-Path -LiteralPath $p) { $settingsPath = $p; break }
        }
    }

    $settingsPort = $null
    if ($settingsPath -ne '') {
        try {
            $text = Get-Content -LiteralPath $settingsPath -Raw -ErrorAction Stop
            $json = $text | ConvertFrom-Json -ErrorAction Stop
            $pv = $null
            if ($json -and $json.PSObject.Properties['port']) { $pv = $json.port }
            if ($null -ne $pv) {
                $tmp = 0
                if ([int]::TryParse([string]$pv, [ref]$tmp)) { $settingsPort = $tmp }
            }
        } catch {
            Write-McLog -Level 'WARN' ('settings.json unreadable ({0}); using default port. error={1}' -f $settingsPath, $_.Exception.Message)
            $settingsPort = $null
        }
    }

    # Ordered, de-duplicated candidate port list.
    $order = @()
    if ($null -ne $settingsPort) { $order += $settingsPort }
    $order += $DefaultPort
    foreach ($e in $ExtraCandidatePorts) { $order += $e }
    $seen = @{}
    $candidates = @()
    foreach ($p in $order) {
        if ($seen.ContainsKey($p)) { continue }
        $seen[$p] = $true
        $candidates += $p
    }

    foreach ($port in $candidates) {
        $ok = $false
        $version = ''
        $baseUri = ('http://127.0.0.1:{0}' -f $port)
        try {
            $url = ($baseUri + $HealthPath)
            $resp = Invoke-WebRequest -UseBasicParsing -TimeoutSec $TimeoutSeconds -Uri $url -ErrorAction Stop
            if ($resp.StatusCode -eq 200) {
                $body = $resp.Content | ConvertFrom-Json -ErrorAction Stop
                if ($body -and ($body.name -eq 'magpie')) {
                    $ok = $true
                    if ($body.PSObject.Properties['version']) { $version = [string]$body.version }
                }
            }
        } catch {
            $ok = $false
        }
        if ($ok) {
            $src = if ($null -ne $settingsPort -and $port -eq $settingsPort) { 'settings-port' } elseif ($port -eq $DefaultPort) { 'default' } else { 'extra' }
            return [pscustomobject]@{
                Port     = $port
                BaseUri  = $baseUri
                Version  = $version
                Source   = $src
            }
        }
    }

    Write-McLog -Level 'WARN' 'no Magpie gateway found on any candidate port'
    return $null
}
