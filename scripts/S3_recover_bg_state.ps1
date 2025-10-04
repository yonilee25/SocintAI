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
$logFile = Join-Path $logDir ("S3_recover_bg_state_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))

$rootA  = 'C:\inetpub\SocintFrontend_A'
$rootB  = 'C:\inetpub\SocintFrontend_B'
$siteA  = 'SocintFrontend_A'
$siteB  = 'SocintFrontend_B'
$appcmd = Join-Path $env:WINDIR 'System32\inetsrv\appcmd.exe'

function Write-Log {
  param([string]$level,[string]$op,[string]$msg,[hashtable]$data=@{})
  $o = [ordered]@{
    ts     = (Get-Date).ToString('o')
    level  = $level
    step   = 'S3.recover_bg_state'
    req_id = $reqId
    op     = $op
    msg    = $msg
    data   = $data
  }
  $json = $o | ConvertTo-Json -Compress -Depth 10
  Write-Host $json
  Add-Content -LiteralPath $logFile -Value $json
}

Write-Log 'info' 'start' 'Recovering BG state & reapplying hotfix (no WebAdministration)' @{ user=$env:UserName; machine=$env:COMPUTERNAME }

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

if (-not (Test-Path $appcmd)) {
  Write-Log 'error' 'deps' 'appcmd.exe not found; IIS may be incomplete' @{ path=$appcmd }
  throw "Missing $appcmd"
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

# discover ports from IIS
$portA = Get-SitePort -name $siteA
$portB = Get-SitePort -name $siteB
Write-Log 'info' 'discover.ports' 'Discovered ports from IIS' @{ portA=$portA; portB=$portB }

# sanity fallback if null
if (-not $portA) { $portA = 8081; Write-Log 'warn' 'discover.fallback' 'Falling back to default portA=8081' @{} }
if (-not $portB) { $portB = 8082; Write-Log 'warn' 'discover.fallback' 'Falling back to default portB=8082' @{} }

# write state file (bg_ports.json)
$bg = @{ A = @{ port = $portA }; B = @{ port = $portB } } | ConvertTo-Json -Compress
$bgFile = Join-Path $envDir 'bg_ports.json'
Set-Content -LiteralPath $bgFile -Value $bg -Encoding UTF8
Write-Log 'info' 'state.write' 'Wrote BG ports state' @{ file=$bgFile; json=$bg }

# write minimal web.config without duplicate .txt mimeMap
function Write-WebConfig {
  param([string]$path,[string]$slot)
  if (-not (Test-Path $path)) { New-Item -ItemType Directory -Force -Path $path | Out-Null }
  # ensure healthz.txt exists
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
  Write-Log 'info' 'webconfig.write' 'Wrote web.config (no .txt mimeMap)' @{ path=$path; slot=$slot }
}
Write-WebConfig -path $rootA -slot 'A'
Write-WebConfig -path $rootB -slot 'B'

# restart both sites via appcmd
function Restart-Site([string]$name) {
  try { & $appcmd stop site /site.name:"$name" | Out-Null } catch {}
  Start-Sleep -Milliseconds 200
  try { & $appcmd start site /site.name:"$name" | Out-Null } catch {}
  Write-Log 'info' 'site.restart' "Restarted site $name" @{}
}
Restart-Site -name $siteA
Restart-Site -name $siteB

# probe health
function Check-Health([int]$port) {
  try {
    $r = Invoke-WebRequest -Uri ("http://127.0.0.1:{0}/healthz" -f $port) -UseBasicParsing -TimeoutSec 5
    return ($r.StatusCode -eq 200 -and $r.Content.Trim() -eq 'OK')
  } catch {
    Write-Log 'warn' 'health.req' 'Health probe failed' @{ port=$port; err="$_" }
    return $false
  }
}
$hA = Check-Health -port $portA
$hB = Check-Health -port $portB
Write-Log 'info' 'health' 'Post-recover health' @{ A=$hA; B=$hB; portA=$portA; portB=$portB }

# summary
$summary = [ordered]@{
  sites = @{
    A = @{ name=$siteA; port=$portA; healthz_ok=$hA; path=$rootA }
    B = @{ name=$siteB; port=$portB; healthz_ok=$hB; path=$rootB }
  }
  state_file   = $bgFile
  log_file     = $logFile
  duration_ms  = [int]((Get-Date) - $start).TotalMilliseconds
  ready_for_S4 = ($hA -and $hB)
}
Write-Log (($summary.ready_for_S4) ? 'info' : 'warn') 'summary' 'S3 recover summary' $summary

$banner = if ($summary.ready_for_S4) { 'READY' } else { 'NEEDS_ACTION' }
Write-Host ("`n== S3.recover Health: {0} (see {1})" -f $banner, $logFile)
