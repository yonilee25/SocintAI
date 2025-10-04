param()

$ErrorActionPreference = 'Stop'
$reqId  = [guid]::NewGuid().ToString()
$start  = Get-Date

# paths
$repoRoot = Split-Path $PSScriptRoot -Parent
if (-not $repoRoot) { $repoRoot = 'C:\SocintAI' }
$logDir = Join-Path $repoRoot 'logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
$logFile = Join-Path $logDir ("S3_fix_mimemap_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))

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
    step   = 'S3.fix_mimemap'
    req_id = $reqId
    op     = $op
    msg    = $msg
    data   = $data
  }
  $json = $o | ConvertTo-Json -Compress -Depth 10
  Write-Host $json
  Add-Content -LiteralPath $logFile -Value $json
}

Write-Log 'info' 'start' 'Starting S3 hotfix v2 (no WebAdministration; using appcmd)' @{ user=$env:UserName; machine=$env:COMPUTERNAME }

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

# read ports from S3 state file
$envDir = Join-Path $repoRoot 'env'
$bgFile = Join-Path $envDir 'bg_ports.json'
if (-not (Test-Path $bgFile)) { throw "Missing $bgFile. Run S3_blue_green_sites.ps1 first." }
$ports = Get-Content $bgFile | ConvertFrom-Json
$portA = [int]$ports.A.port
$portB = [int]$ports.B.port
Write-Log 'info' 'state' 'Loaded A/B ports' @{ portA=$portA; portB=$portB; state_file=$bgFile }

function Write-WebConfig {
  param([string]$path,[string]$slot)
  if (-not (Test-Path $path)) { New-Item -ItemType Directory -Force -Path $path | Out-Null }
  # ensure healthz.txt present
  Set-Content -LiteralPath (Join-Path $path 'healthz.txt') -Value 'OK' -Encoding ASCII

  # web.config WITHOUT duplicate .txt mimeMap
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

function Restart-Site([string]$name) {
  try { & $appcmd stop site /site.name:"$name" | Out-Null } catch {}
  Start-Sleep -Milliseconds 200
  try { & $appcmd start site /site.name:"$name" | Out-Null } catch {}
  Write-Log 'info' 'site.restart' "Restarted site $name" @{}
}

function Check-Health([int]$port) {
  try {
    $r = Invoke-WebRequest -Uri ("http://127.0.0.1:{0}/healthz" -f $port) -TimeoutSec 5
    return ($r.StatusCode -eq 200 -and $r.Content.Trim() -eq 'OK')
  } catch {
    Write-Log 'warn' 'health.req' 'Health probe failed' @{ port=$port; err="$_" }
    return $false
  }
}

# update web.config on both slots
Write-WebConfig -path $rootA -slot 'A'
Write-WebConfig -path $rootB -slot 'B'

# restart sites (reload config)
Restart-Site -name $siteA
Restart-Site -name $siteB

# health probes
$hA = Check-Health -port $portA
$hB = Check-Health -port $portB
Write-Log 'info' 'health' 'Health after hotfix' @{ A=$hA; B=$hB; portA=$portA; portB=$portB }

# summary
$summary = [ordered]@{
  sites = @{
    A = @{ port=$portA; healthz_ok=$hA; path=$rootA; name=$siteA }
    B = @{ port=$portB; healthz_ok=$hB; path=$rootB; name=$siteB }
  }
  log_file     = $logFile
  duration_ms  = [int]((Get-Date) - $start).TotalMilliseconds
  ready_for_S4 = ($hA -and $hB)
}
Write-Log (($summary.ready_for_S4) ? 'info' : 'warn') 'summary' 'S3 hotfix summary' $summary

$banner = if ($summary.ready_for_S4) { 'READY' } else { 'NEEDS_ACTION' }
Write-Host ("`n== S3.fix Health: {0} (see {1})" -f $banner, $logFile)
