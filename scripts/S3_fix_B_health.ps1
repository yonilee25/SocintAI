param()

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
$logFile = Join-Path $logDir ("S3_fix_B_health_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))

$siteA  = 'SocintFrontend_A'
$siteB  = 'SocintFrontend_B'
$poolB  = 'SocintFrontend_B_AppPool'
$rootA  = 'C:\inetpub\SocintFrontend_A'
$rootB  = 'C:\inetpub\SocintFrontend_B'
$appcmd = Join-Path $env:WINDIR 'System32\inetsrv\appcmd.exe'

function Write-Log {
  param([string]$level,[string]$op,[string]$msg,[hashtable]$data=@{})
  $o = [ordered]@{
    ts     = (Get-Date).ToString('o')
    level  = $level
    step   = 'S3.fix_B_health'
    req_id = $reqId
    op     = $op
    msg    = $msg
    data   = $data
  }
  $json = $o | ConvertTo-Json -Compress -Depth 12
  Write-Host $json
  Add-Content -LiteralPath $logFile -Value $json
}

Write-Log 'info' 'start' 'Repairing B slot health (bindings, files, restart, probe)' @{ user=$env:UserName; machine=$env:COMPUTERNAME }

# ensure admin (self-elevate)
$IsElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
               ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $IsElevated) {
  $pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
  if (-not $pwsh) { $pwsh = 'C:\Program Files\PowerShell\7\pwsh.exe' }
  Write-Log 'info' 'elevate' 'Relaunching with elevation' @{ pwsh=$pwsh }
  Start-Process -FilePath $pwsh -Verb RunAs -ArgumentList @('-NoLogo','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"")
  exit
} else {
  Write-Log 'info' 'env.admin' 'Already elevated' @{}
}

if (-not (Test-Path $appcmd)) { throw "Missing $appcmd" }

# helpers
function Test-PortFree([int]$port) {
  try { $c = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue; return ($null -eq $c) }
  catch { return $true }
}

function Get-SitePort([string]$name) {
  try {
    $b = & $appcmd list site "$name" /text:bindings 2>$null
    if ([string]::IsNullOrWhiteSpace($b)) { return $null }
    $m = [regex]::Match($b, ':(\d+):')
    if ($m.Success) { return [int]$m.Groups[1].Value }
    return $null
  } catch { return $null }
}

function Ensure-Files([string]$path,[string]$slot) {
  if (-not (Test-Path $path)) { New-Item -ItemType Directory -Force -Path $path | Out-Null }
  $idx = @"
<!doctype html>
<html><head><meta charset="utf-8"><title>Socint $slot</title></head>
<body style="font-family:system-ui;padding:24px"><h1>Socint [$slot]</h1><p>ReqId: $reqId</p></body></html>
"@
  Set-Content -LiteralPath (Join-Path $path 'index.html') -Value $idx -Encoding UTF8
  Set-Content -LiteralPath (Join-Path $path 'healthz.txt') -Value 'OK' -Encoding ASCII
  $wc = @"
<?xml version="1.0" encoding="UTF-8"?>
<configuration>
  <system.webServer>
    <rewrite>
      <rules>
        <rule name="Healthz" stopProcessing="true">
          <match url="^healthz$" />
          <action type="Rewrite" url="healthz.txt" />
        </rule>
      </rules>
    </rewrite>
    <httpProtocol>
      <customHeaders>
        <remove name="X-BlueGreen" />
        <add name="X-BlueGreen" value="$slot" />
      </customHeaders>
    </httpProtocol>
    <staticContent>
      <clientCache cacheControlMode="DisableCache" />
    </staticContent>
    <defaultDocument>
      <files><add value="index.html" /></files>
    </defaultDocument>
  </system.webServer>
</configuration>
"@
  Set-Content -LiteralPath (Join-Path $path 'web.config') -Value $wc -Encoding UTF8
}

function Ensure-AppPool([string]$name) {
  $out = & $appcmd list apppool /name:"$name" 2>$null
  if ([string]::IsNullOrWhiteSpace($out)) {
    & $appcmd add apppool /name:"$name" /managedRuntimeVersion:"" | Out-Null
    Write-Log 'info' 'apppool.create' "Created app pool $name" @{}
  } else {
    Write-Log 'info' 'apppool.exists' "App pool exists $name" @{}
  }
}

function Ensure-Site([string]$name,[string]$path,[string]$pool,[int]$port) {
  $exists = & $appcmd list site "$name" 2>$null
  $bindHttp = ('http/*:{0}:' -f $port)
  if ([string]::IsNullOrWhiteSpace($exists)) {
    & $appcmd add site /name:"$name" /bindings:"$bindHttp" /physicalPath:"$path" | Out-Null
    Write-Log 'info' 'site.create' "Created site $name" @{ port=$port; path=$path }
  }
  # point root app to pool
  & $appcmd set app "$name/" /applicationPool:"$pool" | Out-Null

  # ensure binding has our port
  $bindings = & $appcmd list site "$name" /text:bindings 2>$null
  $needle = (":{0}:" -f $port)
  if ($bindings -notmatch [regex]::Escape($needle)) {
    # remove existing http bindings then add ours cleanly
    & $appcmd set site /site.name:"$name" "/-bindings.[protocol='http']" | Out-Null
    $bindStar = ('*:{0}:' -f $port)
    $addArg   = "/+bindings.[protocol='http',bindingInformation='$bindStar']"
    & $appcmd set site /site.name:"$name" $addArg | Out-Null
    Write-Log 'info' 'site.bind' 'Updated http binding' @{ name=$name; port=$port }
  }
}

function Restart-Site([string]$name) {
  try { & $appcmd stop site /site.name:"$name" | Out-Null } catch {}
  Start-Sleep -Milliseconds 200
  try { & $appcmd start site /site.name:"$name" | Out-Null } catch {}
  Write-Log 'info' 'site.restart' "Restarted site $name" @{}
}

function Check-Health([int]$port,[ref]$status,[ref]$body) {
  try {
    $r = Invoke-WebRequest -Uri ("http://127.0.0.1:{0}/healthz" -f $port) -TimeoutSec 5
    $status.Value = $r.StatusCode
    $body.Value   = ($r.Content.Substring(0, [Math]::Min(200, $r.Content.Length)))
    return ($r.StatusCode -eq 200 -and $r.Content.Trim() -eq 'OK')
  } catch {
    $status.Value = -1
    $body.Value   = "$_"
    return $false
  }
}

# 1) load state or discover
$bgFile = Join-Path $envDir 'bg_ports.json'
$portA = $null; $portB = $null
if (Test-Path $bgFile) {
  $bg = Get-Content $bgFile | ConvertFrom-Json
  $portA = [int]$bg.A.port
  $portB = [int]$bg.B.port
} else {
  $portA = Get-SitePort -name $siteA; if (-not $portA) { $portA = 8081 }
  $portB = Get-SitePort -name $siteB; if (-not $portB) { $portB = 8082 }
}
Write-Log 'info' 'state' 'Current A/B ports' @{ portA=$portA; portB=$portB; state_file=$bgFile }

# 2) Ensure B files and site basics
Ensure-Files -path $rootB -slot 'B'
Ensure-AppPool -name $poolB

# 3) If portB is occupied by someone else, pick a fallback
$free = Test-PortFree $portB
if (-not $free) {
  $current = Get-SitePort -name $siteB
  if ($current -ne $portB) {
    $old = $portB
    $candidates = @(8082, 18082, 28082, 38082)
    foreach ($p in $candidates) { if (Test-PortFree $p) { $portB = $p; break } }
    Write-Log 'warn' 'port.conflict' 'Port conflict detected; switching B port' @{ old=$old; new=$portB }
  }
}

# 4) Ensure site + binding
Ensure-Site -name $siteB -path $rootB -pool $poolB -port $portB

# 5) Restart and probe
Restart-Site -name $siteB
$status = 0; $body = ''
$okB = Check-Health -port $portB -status ([ref]$status) -body ([ref]$body)
Write-Log ($okB ? 'info' : 'warn') 'health' 'B health probe' @{ port=$portB; status=$status; sample=$body }

# 6) persist state file (keep A as-is)
$final = @{ A = @{ port = $portA }; B = @{ port = $portB } } | ConvertTo-Json -Compress
Set-Content -LiteralPath $bgFile -Value $final -Encoding UTF8
Write-Log 'info' 'state.write' 'Wrote BG ports state' @{ file=$bgFile; json=$final }

# 7) also probe A quickly so the step can declare readiness for S4
$statusA = 0; $bodyA = ''
$okA = Check-Health -port $portA -status ([ref]$statusA) -body ([ref]$bodyA)
Write-Log ($okA ? 'info' : 'warn') 'health.A' 'A health probe' @{ port=$portA; status=$statusA; sample=$bodyA }

# 8) summary
$summary = [ordered]@{
  sites = @{
    A = @{ name=$siteA; port=$portA; healthz_ok=$okA; path=$rootA }
    B = @{ name=$siteB; port=$portB; healthz_ok=$okB; path=$rootB }
  }
  state_file   = $bgFile
  log_file     = $logFile
  duration_ms  = [int]((Get-Date) - $start).TotalMilliseconds
  ready_for_S4 = ($okA -and $okB)
}
Write-Log (($summary.ready_for_S4) ? 'info' : 'warn') 'summary' 'S3.B repair summary' $summary

$banner = if ($summary.ready_for_S4) { 'READY' } else { 'NEEDS_ACTION' }
Write-Host ("`n== S3.B Health: {0} (see {1})" -f $banner, $logFile)
