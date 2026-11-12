# pack-node.ps1 — provision a NEW magpie tunnel node on the 102 relay, in one command.
#
#   .\pack-node.ps1 -Node win2 -RemotePort 13435
#
# What it does (all on the relay, as the normal user; nothing needs root):
#   1. generate a passphrase-free ed25519 key pair ON THE RELAY (Windows ssh-keygen mangles
#      empty passphrases -- that bit us), pull it back, wipe the relay copy
#   2. build the Windows payload (connector bundle + this node's key) and publish it as
#      ~/.magpie-connector/nodes/<Node>/payload.b64 (base64 of a zip)
#   3. write the restricted authorized_keys line for this node:
#        restrict,command=<checker> <port>,port-forwarding,permitlisten="127.0.0.1:<port>"
#      (idempotent: re-running replaces, never duplicates)
#   4. print the exact one-paste block for the new Windows machine
#
# Prerequisite for the new machine (only one): it must be able to `ssh` to the relay once,
# using that `user` account's password or an already-authorized key.
param(
    [Parameter(Mandatory = $true)][string]$Node,
    [Parameter(Mandatory = $true)][int]$RemotePort,
    [string]$Relay = 'deb-h61',
    [string]$RelayForWindows = '10.101.54.192',
    [int]$RelaySshPort = 18322,
    [string]$RelayUser = 'user',
    [string]$RelayBase = '.magpie-connector',
    [switch]$NoAuthorizedKeys,
    [switch]$KeepKey,
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot          # ...\magpie-tunnel
$win = Join-Path $root 'windows'
$nodesDir = Join-Path $root 'nodes'
$nodeDir = Join-Path $nodesDir $Node
Write-Output "node=$Node remotePort=$RemotePort relay=$Relay  (~$RelayForWindows`:$RelaySshPort)"

# ---------------------------------------------------------------- 1. key pair
if ($DryRun) { Write-Output '[DRY-RUN] would generate keys, build payload, patch authorized_keys' }
$keyPath = Join-Path $nodeDir ('id_ed25519_{0}_{1}' -f $Node, $RemotePort)
$keyPub = $keyPath + '.pub'
New-Item -ItemType Directory -Force -Path $nodeDir | Out-Null

Write-Output '--- generating the key pair on the relay (passphrase-free) ---'
if ($KeepKey -and (Test-Path -LiteralPath $keyPath) -and (Test-Path -LiteralPath $keyPub)) {
    Write-Output '--- reusing the existing key pair (-KeepKey) ---'
} else {
ssh $Relay 'rm -rf /tmp/mn-gen && mkdir -p /tmp/mn-gen && chmod 700 /tmp/mn-gen'
$gen = ssh $Relay ("ssh-keygen -q -t ed25519 -N '' -C '{0}-{1}-{2}' -f /tmp/mn-gen/node && echo GEN-OK" -f 'magpie-tunnel', $Node, $RemotePort)
if ($gen -notmatch 'GEN-OK') { throw "keygen failed on relay: $gen" }

foreach ($ext in @('', '.pub')) {
    $local = $keyPath + $ext
    if (Test-Path -LiteralPath $local) { Remove-Item -LiteralPath $local -Force }
    & scp -q -p ("{0}:/tmp/mn-gen/node{1}" -f $Relay, $ext) $local
    if ($LASTEXITCODE -ne 0) { throw "scp failed for node$ext" }
}
ssh $Relay 'shred -u /tmp/mn-gen/node 2>/dev/null; rm -rf /tmp/mn-gen; echo wiped'
}

# Windows OpenSSH refuses keys whose ACL is broader than the owner.
$me = "$env:USERDOMAIN\$env:USERNAME"
& icacls.exe $keyPath /inheritance:r /grant:r "${me}:F" | Out-Null
& icacls.exe $keyPath /reset | Out-Null
& icacls.exe $keyPath /inheritance:r /grant:r "${me}:F" | Out-Null
$probe = & ssh-keygen -y -P '' -f $keyPath 2>&1
if ($LASTEXITCODE -ne 0) { throw "generated key is unusable (passphrase or ACL): $probe" }
Write-Output ('--- key ok: ' + (Split-Path -Leaf $keyPath))

# ---------------------------------------------------------------- 2. payload
Write-Output '--- building payload ---'
$payload = Join-Path $nodeDir 'payload'
if (Test-Path -LiteralPath $payload) { Remove-Item -Recurse -Force -LiteralPath $payload }
New-Item -ItemType Directory -Force -Path (Join-Path $payload 'secrets') | Out-Null
foreach ($f in Get-ChildItem $win -File | Where-Object { $_.Extension -in '.ps1', '.json', '.md' }) {
    Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $payload $f.Name) -Force
}
Copy-Item -LiteralPath $keyPath -Destination (Join-Path $payload 'secrets') -Force
Copy-Item -LiteralPath $keyPub -Destination (Join-Path $payload 'secrets') -Force
# empty known_hosts: the connector uses StrictHostKeyChecking=accept-new and fills it itself
[IO.File]::WriteAllText((Join-Path $payload 'secrets\known_hosts'), '')

$zip = Join-Path $nodeDir 'payload.zip'
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
Compress-Archive -Path (Join-Path $payload '*') -DestinationPath $zip -Force
$zipHash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
Write-Output ("--- payload.zip {0} bytes, sha256 {1}" -f (Get-Item $zip).Length, $zipHash)

Write-Output '--- publishing to the relay ---'
ssh $Relay ("mkdir -p {0}/nodes/{1} && chmod 700 {0} {0}/nodes {0}/nodes/{1}" -f $RelayBase, $Node)
& scp -P 22 $zip ("{0}:{1}/nodes/{2}/payload.zip" -f $Relay, $RelayBase, $Node)
ssh $Relay ("cd {0}/nodes/{1} && base64 -w0 payload.zip > payload.b64 && rm -f payload.zip && chmod 600 payload.b64" -f $RelayBase, $Node)
$remoteHash = ssh $Relay ("python3 -c `"import base64,hashlib;print(hashlib.sha256(base64.b64decode(open('{0}/nodes/{1}/payload.b64').read().strip())).hexdigest())`"" -f $RelayBase, $Node)
if ("$remoteHash".Trim() -ne $zipHash) { throw "payload integrity mismatch: local $zipHash vs relay $remoteHash" }
Write-Output '--- integrity OK'

# ---------------------------------------------------------------- 3. authorized_keys
if (-not $NoAuthorizedKeys) {
    Write-Output '--- patching authorized_keys (idempotent) ---'
    $checker = "/home/user/.local/bin/magpie-tunnel-check"
    $pub = ([IO.File]::ReadAllText($keyPub)).Trim()
    $line = ('restrict,command="{0} {1}",port-forwarding,permitlisten="127.0.0.1:{1}" {2} magpie-tunnel-node-{1}' -f $checker, $RemotePort, $pub)
    $b64line = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($line + "`n"))
    $patch = @'
import os,sys,shutil,time
ak=os.path.expanduser('~/.ssh/authorized_keys')
new=sys.stdin.read().rstrip('\n')
marker=new.split()[-1]
lines=[l for l in open(ak,encoding='utf-8').read().splitlines() if marker not in l]
shutil.copyfile(ak, ak+'.bak-'+time.strftime('%Y%m%d-%H%M%S'))
lines.append(new)
open(ak,'w',encoding='utf-8').write('\n'.join(lines)+'\n')
os.chmod(ak,0o600)
print('  managed lines now:', sum(1 for l in lines if 'magpie-tunnel-node-' in l))
for l in lines:
    if 'magpie-tunnel-node-' in l:
        i=l.index('ssh-'); print('  ', l[:i].strip()[:90], '...')
'@
    $py = $patch -replace "`r", ''
    $b64py = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($py))
    ssh $Relay ("echo '$b64line' | base64 -d | (echo '$b64py' | base64 -d > /tmp/patch_ak.py; python3 /tmp/patch_ak.py); rm -f /tmp/patch_ak.py")
}

# ---------------------------------------------------------------- 4. paste block
$relPath = "$RelayBase/nodes/$Node/payload.b64"
$blkH = $RelayForWindows; $blkP = $RelaySshPort; $blkU = $RelayUser; $blkRP = $RemotePort; $blkNode = $Node
$block = @"
`$H='$blkH'; `$P=$blkP; `$U='$blkU'; `$RP=$blkRP; `$REL='$relPath'
`$root="`$env:LOCALAPPDATA\magpie-connector"
`$tmp="`$env:TEMP\mn.b64"
ssh -p `$P (`$U+'@'+`$H) ("cat ~/`$REL") > `$tmp
`$b=[Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes(`$tmp)) -replace '[^A-Za-z0-9+/=]',''
[IO.File]::WriteAllBytes("`$env:TEMP\mn.zip",[Convert]::FromBase64String(`$b))
if (Test-Path `$root) { Remove-Item `$root -Recurse -Force -ErrorAction SilentlyContinue }
Expand-Archive -Force "`$env:TEMP\mn.zip" `$root
& "`$root\ensure-magpie.ps1" -RelayHost `$H -RelayPort `$P -RelayUser `$U
& "`$root\install.ps1" -Root `$root -SourceDir `$root -SshHost `$H -SshPort `$P -SshUser `$U -IdentityFile "`$root\secrets\id_ed25519_$blkNode`_$blkRP" -KnownHostsFile "`$root\secrets\known_hosts" -RemotePort `$RP -DefaultPort 3425 -Autostart auto
Start-Process powershell.exe -WindowStyle Hidden -ArgumentList ('-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + `$root + '\connector.ps1" run')
Start-Sleep -Seconds 5
Get-Content "`$root\logs\connector.log" -Tail 6
"@
if ($block -match '\{\d+\}') { throw "paste block still has unsubstituted placeholders" }

# self-check: the generated block must parse as PowerShell
$errs = $null
[void][System.Management.Automation.Language.Parser]::ParseInput($block, [ref]$null, [ref]$errs)
if ($errs -and $errs.Count -gt 0) { throw ("paste block does not parse: " + ($errs[0].Message)) }

[IO.File]::WriteAllText((Join-Path $nodeDir 'paste-block.txt'), $block)
$b64block = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $nodeDir 'paste-block.txt')))
ssh $Relay ("echo '$b64block' | base64 -d > {0}/nodes/{1}/paste-block.txt" -f $RelayBase, $Node)

# ---- 4b. self-contained boot.ps1 (payload embedded: ONE command for the user) ----
$payloadB64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($zip))
$boot = @"
`$H='$blkH'; `$P=$blkP; `$U='$blkU'; `$RP=$blkRP
`$root="`$env:LOCALAPPDATA\magpie-connector"
`$b64='$payloadB64'
[IO.File]::WriteAllBytes("`$env:TEMP\mn.zip",[Convert]::FromBase64String(`$b64))
if (Test-Path `$root) { Remove-Item `$root -Recurse -Force -ErrorAction SilentlyContinue }
Expand-Archive -Force "`$env:TEMP\mn.zip" `$root
& "`$root\ensure-magpie.ps1" -RelayHost `$H -RelayPort `$P -RelayUser `$U
& "`$root\install.ps1" -Root `$root -SourceDir `$root -SshHost `$H -SshPort `$P -SshUser `$U -IdentityFile "`$root\secrets\id_ed25519_$blkNode`_$blkRP" -KnownHostsFile "`$root\secrets\known_hosts" -RemotePort `$RP -DefaultPort 3425 -Autostart auto
Start-Process powershell.exe -WindowStyle Hidden -ArgumentList ('-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + `$root + '\connector.ps1" run')
Start-Sleep -Seconds 5
Get-Content "`$root\logs\connector.log" -Tail 6
"@
$errs2 = $null
[void][System.Management.Automation.Language.Parser]::ParseInput($boot, [ref]$null, [ref]$errs2)
if ($errs2 -and $errs2.Count -gt 0) { throw ("boot.ps1 does not parse: " + $errs2[0].Message) }
[IO.File]::WriteAllText((Join-Path $nodeDir 'boot.ps1'), $boot)
& scp -P 22 (Join-Path $nodeDir 'boot.ps1') ("{0}:{1}/nodes/{2}/boot.ps1" -f $Relay, $RelayBase, $Node) | Out-Null
ssh $Relay ("chmod 644 {0}/nodes/{1}/boot.ps1 && wc -c {0}/nodes/{1}/boot.ps1" -f $RelayBase, $Node) | ForEach-Object { Write-Output ("--- boot.ps1 on relay: {0} bytes (self-contained)" -f ($_ -split '\s+')[0]) }

Write-Output ''
Write-Output '=============================================================='
Write-Output 'PASTE THIS ON THE NEW WINDOWS MACHINE (PowerShell 5.1):'
Write-Output '=============================================================='
Write-Output $block
Write-Output '=============================================================='
Write-Output ("also saved: {0}" -f (Join-Path $nodeDir 'paste-block.txt'))
Write-Output ''
Write-Output 'AFTER the machine reports online, on 102:'
Write-Output ("  bash ~/.magpie-connector/add-win-provider.sh   # or edit id/port for this node")
Write-Output ("  bash ~/.magpie-connector/verify-tunnel.sh {0}" -f $RemotePort)
