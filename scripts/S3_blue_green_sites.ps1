param()

$ErrorActionPreference = 'Stop'
$reqId  = [guid]::NewGuid().ToString()
$start  = Get-Date

# --- paths ---
$repoRoot = Split-Path $PSScriptRoot -Parent
if (-not $repoRoot) { $repoRoot = 'C:\SocintAI' }
$logDir = Join-Path $repoRoot 'logs'
$envDir = Join-Path $repoRoot 'env'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
if (-not (Test-Path $envDir)) { New-Item -ItemType Directory -Force -Path $envDir | Out-Null }
$logFile = Join-Path $logDir ("S3_blue_green_sites_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))

$rootA  = 'C:\inetpub\SocintFrontend_A'
$rootB  = 'C:\inetpub\SocintFrontend_B'
$poolA  = 'SocintFrontend_A_AppPool'
$poolB  = 'SocintFrontend_B_AppPool'
$siteA  = 'SocintFrontend_A'
$siteB  = 'SocintFrontend_B'

# --- logging ---
function Write-Log {
  param([string]$level,[string]$op,[string]$msg,[hashtable]$data=@{})
  $o = [ordered]@{
    ts     = (Get-Date).ToString('o')
    level  = $level
    step   = 'S3.blue_green_sites'
    req_id = $reqId
    op     = $op
    msg    = $msg
    data   = $data
  }
  $json = $o | ConvertTo-Json -Compress -Depth 10
  Write-Host $json
  Add-Content -LiteralPath $logFile -Value $json
}

Write-Log 'info' 'start' 'Starting S3: create blue/green IIS sites and health endpoints' @{ user=$env:UserName; machine=$env:COMPUTERNAME }

# --- ensure admin (self-elevate) ---
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

# --- helpers ---
Import-Module WebAdministration -ErrorAction Stop

function Test-PortFree([int]$port) {
  try {
    $c = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
    return ($null -eq $c)
  } catch { return $true }
}

function Choose-PortPair {
  param([int]$prefA=8081,[int]$prefB=8082)
  $a=$prefA; $b=$prefB
  $tries = @(0,10,20,100,1000) # offsets
  foreach ($off in $tries) {
    $pa = $a + $off
    $pb = $b + $off
    if (Test-PortFree $pa -and Test-PortFree $pb) {
      return @{A=$pa;B=$pb}
    }
  }
  # ultimate fallback
  return @{A=18081;B=18082}
}

function Ensure-DirAndFiles([string]$path,[string]$slot) {
  if (-not (Test-Path $path)) { New-Item -ItemType Directory -Force -Path $path | Out-Null }
  # index.html
  $idx = @"
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>Socint $slot</title></head>
<body style="font-family:system-ui; padding:24px;">
  <h1>Socint Frontend [$slot]</h1>
  <p>This is the $slot slot static shell.</p>
  <p>ReqId: $reqId</p>
</body></html>
"@
  Set-Content -LiteralPath (Join-Path $path 'index.html') -Value $idx -Encoding UTF8

  # healthz.txt
  Set-Content -LiteralPath (Join-Path $path 'healthz.txt') -Value 'OK' -Encoding ASCII

  # web.config (rewrite /healthz -> healthz.txt)
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
        <add name="X-BlueGreen" value="$slot"/>
      </customHeaders>
    </httpProtocol>
    <staticContent>
      <mimeMap fileExtension=".txt" mimeType="text/plain" />
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
  $exists = Test-Path "IIS:\AppPools\$name"
  if (-not $exists) {
    New-WebAppPool -Name $name | Out-Null
    Write-Log 'info' 'apppool.create' "Created app pool $name" @{}
  } else {
    Write-Log 'info' 'apppool.exists' "App pool exists $name" @{}
  }
  # No Managed Code
  Set-ItemProperty "IIS:\AppPools\$name" -Name managedRuntimeVersion -Value "" -ErrorAction SilentlyContinue
  # Integrated pipeline (default)
  Set-ItemProperty "IIS:\AppPools\$name" -Name managedPipelineMode -Value 'Integrated' -ErrorAction SilentlyContinue
}

function Ensure-Website([string]$name,[string]$path,[string]$pool,[int]$port) {
  $siteExists = (Get-Website -Name $name -ErrorAction SilentlyContinue)
  if (-not $siteExists) {
    New-Website -Name $name -Port $port -IPAddress "*" -HostHeader "" -PhysicalPath $path -ApplicationPool $pool | Out-Null
    Write-Log 'info' 'site.create' "Created site $name" @{ port=$port; path=$path; pool=$pool }
  } else {
    # ensure binding
    $binding = Get-WebBinding -Name $name -Protocol "http" -ErrorAction SilentlyContinue | Where-Object { $_.bindingInformation -match ":${port}:" }
    if (-not $binding) {
      New-WebBinding -Name $name -Protocol http -Port $port -IPAddress "*" -HostHeader "" | Out-Null
      Write-Log 'info' 'site.bind.add' "Added binding for $name" @{ port=$port }
    }
    # ensure path & pool
    Set-ItemProperty "IIS:\Sites\$name" -Name physicalPath -Value $path -ErrorAction SilentlyContinue
    Set-ItemProperty "IIS:\Sites\$name" -Name applicationPool -Value $pool -ErrorAction SilentlyContinue
    Write-Log 'info' 'site.update' "Updated site $name" @{ port=$port; path=$path; pool=$pool }
  }
  Start-Website -Name $name -ErrorAction SilentlyContinue
}

function Check-Health([int]$port) {
  try {
    $r = Invoke-WebRequest -Uri ("http://127.0.0.1:{0}/healthz" -f $port) -UseBasicParsing -TimeoutSec 5
    return ($r.StatusCode -eq 200 -and $r.Content.Trim() -eq 'OK')
  } catch { return $false }
}

# --- main ---
# ports
$ports = Choose-PortPair -prefA 8081 -prefB 8082
Write-Log 'info' 'ports' 'Chosen ports for A/B' @{ A=$ports.A; B=$ports.B }

# content
Ensure-DirAndFiles -path $rootA -slot 'A'
Ensure-DirAndFiles -path $rootB -slot 'B'

# app pools
Ensure-AppPool -name $poolA
Ensure-AppPool -name $poolB

# sites
Ensure-Website -name $siteA -path $rootA -pool $poolA -port $ports.A
Ensure-Website -name $s
