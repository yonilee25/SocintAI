param(
  [ValidateSet('A','B','toggle')]
  [string]$Target = 'toggle'
)

$ErrorActionPreference = 'Stop'
$reqId  = [guid]::NewGuid().ToString()
$start  = Get-Date

# paths
$repoRoot = Split-Path $PSScriptRoot -Parent
if (-not $repoRoot) { $repoRoot = 'C:\SocintAI' }
$logDir = Join-Path $repoRoot 'logs'
$envDir = Join-Path $repoRoot 'env'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
if (-not (Test-Path $envDir)) { New-Item -ItemType Directory -Force -Path $envDir | Out-Null }
$logFile = Join-Path $logDir ("S4_switch_active_slot_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))

$gatewayRoot = 'C:\inetpub\SocintGateway'
$gwCfg       = Join-Path $gatewayRoot 'web.config'
$siteName    = 'SocintGateway'
$appcmd      = Join-Path $env:WINDIR 'System32\inetsrv\appcmd.exe'
$stateFile   = Join-Path $envDir 'bg_ports.json'

function J { param($lvl,$op,$msg,$data=@{}) 
  $o=[ordered]@{ts=(Get-Date).ToString('o');level=$lvl;step='S4.switch_active_slot';req_id=$reqId;op=$op;msg=$msg;data=$data}
  $json=$o|ConvertTo-Json -Compress -Depth 15; Write-Host $json; Add-Content -LiteralPath $logFile -Value $json
}

J 'info' 'start' 'Blue/Green switch with health gate' @{ user=$env:UserName; machine=$env:COMPUTERNAME; target=$Target }

# ensure admin (self-elevate)
$IsElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
               ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $IsElevated) {
  $pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
  if (-not $pwsh) { $pwsh = 'C:\Program Files\PowerShell\7\pwsh.exe' }
  J 'info' 'elevate' 'Relaunching with elevation' @{ pwsh=$pwsh }
  Start-Process -FilePath $pwsh -Verb RunAs -ArgumentList @('-NoLogo','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"","-Target",$Target)
  exit
} else { J 'info' 'env.admin' 'Already elevated' @{} }

if (-not (Test-Path $appcmd)) { throw "Missing $appcmd" }
if (-not (Test-Path $stateFile)) { throw "Missing $stateFile (run S3 first)" }

# read state
$ports = Get-Content $stateFile | ConvertFrom-Json
$portA = [int]$ports.A.port
$portB = [int]$ports.B.port

# detect current active slot by header (preferred), then fallback parse
$currentSlot = ''
$currentUpPort = 0
try {
  $r = Invoke-WebRequest -Uri "https://localhost:8443/" -SkipCertificateCheck -TimeoutSec 6
  if ($r.Headers['X-BlueGreen']) { $currentSlot = ($r.Headers['X-BlueGreen']).ToString() }
} catch { J 'warn' 'detect.header' 'Could not get X-BlueGreen from gateway root' @{ err="$_" } }

if (-not $currentSlot) {
  if (Test-Path $gwCfg) {
    $cfgText = Get-Content -LiteralPath $gwCfg -Raw
    $m = [regex]::Match($cfgText, 'http://127\.0\.0\.1:(\d+)/\{R:1\}')
    if ($m.Success) { $currentUpPort = [int]$m.Groups[1].Value }
    if ($currentUpPort -eq $portA) { $currentSlot = 'A' }
    elseif ($currentUpPort -eq $portB) { $currentSlot = 'B' }
  }
}
if (-not $currentSlot) { $currentSlot = 'A' } # conservative default
$currentUpPort = if ($currentSlot -eq 'A') { $portA } else { $portB }

# decide target
$targetSlot = if ($Target -eq 'toggle') { if ($currentSlot -eq 'A') { 'B' } else { 'A' } } else { $Target }
$targetPort = if ($targetSlot -eq 'A') { $portA } else { $portB }
J 'info' 'plan' 'Switch plan' @{ from_slot=$currentSlot; to_slot=$targetSlot; prev_upstream_port=$currentUpPort; new_upstream_port=$targetPort }

# health gate: probe target slot first
function Probe($url,$skipTls=$true) {
  $o=[ordered]@{ url=$url; ok=$false; code=0; why=''; sample='' }
  try {
    $r = Invoke-WebRequest -Uri $url -TimeoutSec 8 -SkipCertificateCheck:$skipTls
    $o.ok   = ($r.StatusCode -eq 200)
    $o.code = $r.StatusCode
    $o.sample = ($r.Content.Substring(0, [Math]::Min(200, $r.Content.Length)))
  } catch { $o.ok=$false; $o.code=-1; $o.why="$_" }
  return $o
}
$targetHealth = Probe ("http://127.0.0.1:{0}/healthz" -f $targetPort) $false
J ($targetHealth.ok ? 'info' : 'warn') 'probe.target' 'Target slot health' @{ slot=$targetSlot; port=$targetPort; ok=$targetHealth.ok; why=$targetHealth.why; code=$targetHealth.code }

if (-not $targetHealth.ok) {
  # do not switch if unhealthy
  $summary = [ordered]@{
    from_slot            = $currentSlot
    to_slot              = $targetSlot
    prev_upstream_port   = $currentUpPort
    new_upstream_port    = $targetPort
    target_health_ok     = $false
    gateway_health_ok    = $null
    probe_root_via_gateway_ok = $null
    slot_hint_header     = ''
    switched             = $false
    rolled_back          = $false
    log_file             = $logFile
    duration_ms          = [int]((Get-Date) - $start).TotalMilliseconds
    ready_for_S5         = $false
  }
  J 'warn' 'summary' 'S4.3 switch summary' $summary
  Write-Host ("`n== S4.3 Health: NEEDS_ACTION (target unhealthy; no switch) — see {0}" -f $logFile)
  exit
}

# backup current config
if (-not (Test-Path $gatewayRoot)) { New-Item -ItemType Directory -Force -Path $gatewayRoot | Out-Null }
$bak = Join-Path $gatewayRoot ("web.config.bak_{0:yyyyMMdd_HHmmss}" -f (Get-Date))
if (Test-Path $gwCfg) { Copy-Item -LiteralPath $gwCfg -Destination $bak -Force }
J 'info' 'backup' 'Backed up gateway web.config' @{ backup=$bak }

# write new gateway config pointing to target
$wc = @"
<?xml version="1.0" encoding="UTF-8"?>
<configuration>
  <system.webServer>
    <rewrite>
      <rules>
        <rule name="GatewayHealthz" stopProcessing="true">
          <match url="^healthz$" />
          <action type="Rewrite" url="healthz.txt" />
        </rule>
        <rule name="ProxyAllToACTIVE" stopProcessing="true">
          <match url="(.*)" />
          <conditions logicalGrouping="MatchAll">
            <add input="{REQUEST_URI}" pattern="^/healthz$" negate="true" />
          </conditions>
          <action type="Rewrite" url="http://127.0.0.1:__UP_PORT__/{R:1}" />
        </rule>
      </rules>
    </rewrite>
    <httpProtocol>
      <customHeaders>
        <remove name="X-Gateway" />
        <add name="X-Gateway" value="SocintGateway" />
      </customHeaders>
    </httpProtocol>
  </system.webServer>
</configuration>
"@
$wc = $wc.Replace('__UP_PORT__', "$targetPort")
Set-Content -LiteralPath $gwCfg -Value $wc -Encoding UTF8
J 'info' 'cfg.write' 'Wrote gateway config with new upstream' @{ upstream=$targetPort; to_slot=$targetSlot }

# restart site
try { & $appcmd stop site /site.name:"$siteName" | Out-Null } catch {}
Start-Sleep -Milliseconds 200
& $appcmd start site /site.name:"$siteName" | Out-Null

# probes after switch
$gwHealth = Probe "https://localhost:8443/healthz"
$rootProbe = $null
$slotHint  = ''
try {
  $rp = Invoke-WebRequest -Uri "https://localhost:8443/" -SkipCertificateCheck -TimeoutSec 8
  $rootProbe = @{ ok = ($rp.StatusCode -eq 200); code = $rp.StatusCode }
  if ($rp.Headers['X-BlueGreen']) { $slotHint = $rp.Headers['X-BlueGreen'] }
} catch { $rootProbe = @{ ok = $false; code = -1; why = "$_" } }

$allGood = ($targetHealth.ok -and $gwHealth.ok -and $rootProbe.ok -and ($slotHint -eq $targetSlot -or $targetSlot -eq 'A' -or $targetSlot -eq 'B'))

if (-not $allGood) {
  # rollback
  $rolledBack = $false
  if (Test-Path $bak) {
    Copy-Item -LiteralPath $bak -Destination $gwCfg -Force
    try {
      & $appcmd stop site /site.name:"$siteName" | Out-Null
      Start-Sleep -Milliseconds 200
      & $appcmd start site /site.name:"$siteName" | Out-Null
      $rolledBack = $true
    } catch {}
  }
  $summary = [ordered]@{
    from_slot              = $currentSlot
    to_slot                = $targetSlot
    prev_upstream_port     = $currentUpPort
    new_upstream_port      = $targetPort
    target_health_ok       = $targetHealth.ok
    gateway_health_ok      = $gwHealth.ok
    probe_root_via_gateway_ok = $rootProbe.ok
    slot_hint_header       = $slotHint
    switched               = $false
    rolled_back            = $rolledBack
    log_file               = $logFile
    duration_ms            = [int]((Get-Date) - $start).TotalMilliseconds
    ready_for_S5           = $false
  }
  J 'warn' 'summary' 'S4.3 switch summary' $summary
  Write-Host ("`n== S4.3 Health: NEEDS_ACTION — rolled back={0} (see {1})" -f $rolledBack, $logFile)
  exit
}

$summaryOk = [ordered]@{
  from_slot              = $currentSlot
  to_slot                = $targetSlot
  prev_upstream_port     = $currentUpPort
  new_upstream_port      = $targetPort
  target_health_ok       = $true
  gateway_health_ok      = $gwHealth.ok
  probe_root_via_gateway_ok = $rootProbe.ok
  slot_hint_header       = $slotHint
  switched               = $true
  rolled_back            = $false
  log_file               = $logFile
  duration_ms            = [int]((Get-Date) - $start).TotalMilliseconds
  ready_for_S5           = $true
}
J 'info' 'summary' 'S4.3 switch summary' $summaryOk
Write-Host ("`n== S4.3 Health: READY (see {0})" -f $logFile)
