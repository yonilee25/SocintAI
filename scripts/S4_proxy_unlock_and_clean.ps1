param()

$ErrorActionPreference = 'Stop'
$reqId  = [guid]::NewGuid().ToString()
$start  = Get-Date

# paths
$repoRoot = Split-Path $PSScriptRoot -Parent
if (-not $repoRoot) { $repoRoot = 'C:\SocintAI' }
$logDir = Join-Path $repoRoot 'logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
$logFile = Join-Path $logDir ("S4_proxy_unlock_and_clean_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))

$gwSite   = 'SocintGateway'
$gwRoot   = 'C:\inetpub\SocintGateway'
$gwCfg    = Join-Path $gwRoot 'web.config'
$siteA    = 'SocintFrontend_A'
$rootA    = 'C:\inetpub\SocintFrontend_A'
$cfgA     = Join-Path $rootA 'web.config'
$siteB    = 'SocintFrontend_B'
$rootB    = 'C:\inetpub\SocintFrontend_B'
$cfgB     = Join-Path $rootB 'web.config'
$appcmd   = Join-Path $env:WINDIR 'System32\inetsrv\appcmd.exe'
$state    = Join-Path (Join-Path $repoRoot 'env') 'bg_ports.json'

function J { param($lvl,$op,$msg,$data=@{}) 
  $o=[ordered]@{ts=(Get-Date).ToString('o');level=$lvl;step='S4.proxy_unlock_and_clean';req_id=$reqId;op=$op;msg=$msg;data=$data}
  $json=$o|ConvertTo-Json -Compress -Depth 15; Write-Host $json; Add-Content -LiteralPath $logFile -Value $json
}

J 'info' 'start' 'Removing locked/duplicate sections and re-probing' @{ user=$env:UserName; machine=$env:COMPUTERNAME }

# elevation
$IsElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
               ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $IsElevated) {
  $pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
  if (-not $pwsh) { $pwsh = 'C:\Program Files\PowerShell\7\pwsh.exe' }
  J 'info' 'elevate' 'Relaunching with elevation' @{ pwsh=$pwsh }
  Start-Process -FilePath $pwsh -Verb RunAs -ArgumentList @('-NoLogo','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"")
  exit
} else { J 'info' 'env.admin' 'Already elevated' @{} }

if (-not (Test-Path $appcmd)) { throw "Missing $appcmd" }
if (-not (Test-Path $state))  { throw "Missing $state (run S3 first)" }
$ports = Get-Content $state | ConvertFrom-Json
$portA = [int]$ports.A.port

# helper: remove specific section(s) from web.config (if present)
function Remove-Sections {
  param([string]$file,[string[]]$sections)
  if (-not (Test-Path $file)) { return @{ changed=$false; missing=$true; file=$file } }
  try {
    [xml]$xml = Get-Content -LiteralPath $file -Raw
    $changed = $false
    $sw = $xml.configuration.'system.webServer'
    if (-not $sw) { return @{ changed=$false; file=$file; msg='no system.webServer node' } }

    foreach ($s in $sections) {
      $node = $sw.SelectSingleNode($s)
      if ($node -ne $null) {
        [void]$sw.RemoveChild($node)
        $changed = $true
      }
    }
    if ($changed) { $xml.Save($file) }
    return @{ changed=$changed; file=$file }
  } catch {
    # fallback: regex strip simple blocks/lines
    $raw = Get-Content -LiteralPath $file -Raw
    $orig = $raw
    if ($sections -contains 'defaultDocument') {
      $raw = [regex]::Replace($raw, '<defaultDocument>.*?</defaultDocument>', '', 'Singleline')
    }
    if ($sections -contains 'webSocket') {
      $raw = $raw -replace '<webSocket[^>]*?/>',''
      $raw = [regex]::Replace($raw,'<webSocket>.*?</webSocket>','', 'Singleline')
    }
    if ($raw -ne $orig) { Set-Content -LiteralPath $file -Value $raw -Encoding UTF8; return @{ changed=$true; file=$file; fallback='regex' } }
    return @{ changed=$false; file=$file; fallback='none'; err="$_" }
  }
}

# 1) Clean configs
$r1 = Remove-Sections -file $gwCfg -sections @('webSocket','defaultDocument')
$r2 = Remove-Sections -file $cfgA  -sections @('defaultDocument')
$r3 = Remove-Sections -file $cfgB  -sections @('defaultDocument')
J 'info' 'cfg.clean' 'Config cleanup results' @{ gateway=$r1; A=$r2; B=$r3 }

# 2) Ensure gateway has minimal health/proxy rewrite (re-write if missing)
if (-not (Test-Path $gwRoot)) { New-Item -ItemType Directory -Force -Path $gwRoot | Out-Null }
if (-not (Test-Path (Join-Path $gwRoot 'healthz.txt'))) {
  Set-Content -LiteralPath (Join-Path $gwRoot 'healthz.txt') -Value 'OK-GATEWAY' -Encoding ASCII
}
# ensure rewrite block exists and points to A
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
        <rule name="ProxyAllToA" stopProcessing="true">
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
$wc = $wc.Replace('__UP_PORT__', "$portA")
Set-Content -LiteralPath $gwCfg -Value $wc -Encoding UTF8
J 'info' 'cfg.write' 'Wrote clean gateway web.config (no webSocket/defaultDocument)' @{ file=$gwCfg; upstream=$portA }

# 3) restart sites to pick up config
foreach ($s in @($gwSite,$siteA,$siteB)) {
  try { & $appcmd stop site /site.name:"$s" | Out-Null } catch {}
}
Start-Sleep -Milliseconds 200
foreach ($s in @($gwSite,$siteA,$siteB)) { & $appcmd start site /site.name:"$s" | Out-Null; J 'info' 'site.restart' "Restarted $s" @{} }

# 4) validate rewrite section and probe
$rwTxt = & $appcmd list config "$gwSite/" -section:system.webServer/rewrite 2>&1
$rwOk  = ($LASTEXITCODE -eq 0)

function Probe($url,$skipTls=$true) {
  $o = [ordered]@{ url=$url; ok=$false; code=0; why=''; sample='' }
  try {
    $r = Invoke-WebRequest -Uri $url -TimeoutSec 8 -SkipCertificateCheck:$skipTls
    $o.ok   = ($r.StatusCode -eq 200)
    $o.code = $r.StatusCode
    $o.sample = ($r.Content.Substring(0, [Math]::Min(200, $r.Content.Length)))
    if ($r.Headers['X-BlueGreen']) { $o.sample = "X-BlueGreen=" + $r.Headers['X-BlueGreen'] + '; ' + $o.sample }
  } catch { $o.ok=$false; $o.code=-1; $o.why="$_" }
  return $o
}

$pHealthGw = Probe "https://localhost:8443/healthz"
$pRootGw   = Probe "https://localhost:8443/"
$pRootA    = Probe ("http://127.0.0.1:{0}/" -f $portA) $false

# summary
$summary = [ordered]@{
  rewrite_section_ok          = $rwOk
  gateway_health_ok           = $pHealthGw.ok
  probe_root_via_gateway_ok   = $pRootGw.ok
  directA_ok                  = $pRootA.ok
  upstream_port               = $portA
  log_file                    = $logFile
  duration_ms                 = [int]((Get-Date) - $start).TotalMilliseconds
  ready_for_S4_3              = ($rwOk -and $pHealthGw.ok -and $pRootGw.ok -and $pRootA.ok)
}
J (($summary.ready_for_S4_3) ? 'info' : 'warn') 'summary' 'S4.2c unlock-clean summary' $summary

$banner = if ($summary.ready_for_S4_3) { 'READY' } else { 'NEEDS_ACTION' }
Write-Host ("`n== S4.2c Health: {0} (see {1})" -f $banner, $logFile)
