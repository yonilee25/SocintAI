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
$logFile = Join-Path $logDir ("S4_gateway_proxy_to_A_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))

$gatewayRoot = 'C:\inetpub\SocintGateway'
$siteName    = 'SocintGateway'
$appcmd      = Join-Path $env:WINDIR 'System32\inetsrv\appcmd.exe'
$stateFile   = Join-Path $envDir 'bg_ports.json'

function J {[CmdletBinding()] param([string]$lvl,[string]$op,[string]$msg,[hashtable]$data=@{}) 
  $o=[ordered]@{ts=(Get-Date).ToString('o');level=$lvl;step='S4.gateway_proxy_to_A';req_id=$reqId;op=$op;msg=$msg;data=$data}
  $json=$o|ConvertTo-Json -Compress -Depth 15; Write-Host $json; Add-Content -LiteralPath $logFile -Value $json
}

J 'info' 'start' 'Enabling ARR reverse-proxy to slot A' @{ user=$env:UserName; machine=$env:COMPUTERNAME; repoRoot=$repoRoot }

# ensure admin (self-elevate)
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
if (-not (Test-Path $stateFile)) { throw "Missing $stateFile (run S3 first)" }

# read A/B ports
$ports = Get-Content $stateFile | ConvertFrom-Json
$portA = [int]$ports.A.port
$portB = [int]$ports.B.port
J 'info' 'state' 'Loaded bg ports' @{ portA=$portA; portB=$portB; state_file=$stateFile }

# 1) enable ARR proxy globally (server level)
& $appcmd set config -section:system.webServer/proxy /enabled:"True" /preserveHostHeader:"True" /reverseRewriteHostInResponseHeaders:"False" /commit:apphost | Out-Null
$proxyTxt = & $appcmd list config -section:system.webServer/proxy 2>$null
$proxyEnabled  = ($proxyTxt -match 'enabled:"True"')
$proxyPresHost = ($proxyTxt -match 'preserveHostHeader:"True"')
J ($proxyEnabled ? 'info' : 'warn') 'proxy.section' 'ARR proxy settings' @{ enabled=$proxyEnabled; preserveHostHeader=$proxyPresHost; raw=$proxyTxt }

# 2) write gateway web.config with reverse-proxy to A; keep /healthz local
if (-not (Test-Path $gatewayRoot)) { New-Item -ItemType Directory -Force -Path $gatewayRoot | Out-Null }
$wc = @'
<?xml version="1.0" encoding="UTF-8"?>
<configuration>
  <system.webServer>
    <rewrite>
      <rules>
        <!-- Keep local gateway health -->
        <rule name="GatewayHealthz" stopProcessing="true">
          <match url="^healthz$" />
          <action type="Rewrite" url="healthz.txt" />
        </rule>
        <!-- Proxy everything else to active slot A -->
        <rule name="ReverseProxyToA" stopProcessing="true">
          <match url="(.*)" />
          <conditions logicalGrouping="MatchAll">
            <add input="{REQUEST_URI}" pattern="^/healthz$" negate="true" />
          </conditions>
          <action type="Rewrite" url="http://127.0.0.1:__UP_PORT__/{R:1}" logRewrittenUrl="true" />
          <serverVariables>
            <set name="HTTP_X_FORWARDED_FOR"   value="{REMOTE_ADDR}" />
            <set name="HTTP_X_FORWARDED_PROTO" value="https" />
            <set name="HTTP_X_FORWARDED_HOST"  value="{HTTP_HOST}" />
          </serverVariables>
        </rule>
      </rules>
      <outboundRules>
        <!-- Rewrite upstream Location header pointing to 127.0.0.1 back to our host -->
        <rule name="FixLocationHeader" preCondition="HasLocation">
          <match serverVariable="RESPONSE_Location" pattern="^http(s)?://127\.0\.0\.1:__UP_PORT__/(.*)" />
          <action type="Rewrite" value="https://{HTTP_HOST}/{R:2}" />
        </rule>
        <preConditions>
          <preCondition name="HasLocation">
            <add input="{RESPONSE_Location}" pattern=".+"/>
          </preCondition>
        </preConditions>
      </outboundRules>
    </rewrite>
    <webSocket enabled="true" />
    <httpProtocol>
      <customHeaders>
        <remove name="X-Gateway" />
        <add name="X-Gateway" value="SocintGateway" />
      </customHeaders>
    </httpProtocol>
    <defaultDocument>
      <files><add value="index.html" /></files>
    </defaultDocument>
  </system.webServer>
</configuration>
'@
$wc = $wc.Replace('__UP_PORT__', "$portA")
Set-Content -LiteralPath (Join-Path $gatewayRoot 'web.config') -Value $wc -Encoding UTF8
J 'info' 'webconfig.write' 'Wrote gateway reverse-proxy web.config (to A)' @{ root=$gatewayRoot; upstreamPort=$portA }

# ensure healthz file exists (kept local)
if (-not (Test-Path (Join-Path $gatewayRoot 'healthz.txt'))) {
  Set-Content -LiteralPath (Join-Path $gatewayRoot 'healthz.txt') -Value 'OK-GATEWAY' -Encoding ASCII
}

# 3) restart site
try { & $appcmd stop site /site.name:"$siteName" | Out-Null } catch {}
Start-Sleep -Milliseconds 200
& $appcmd start site /site.name:"$siteName" | Out-Null

# 4) probes: /healthz should be local, / should be proxied to A and carry X-BlueGreen:A header/content
$healthOk = $false
$rootOk   = $false
$slotHint = ''
try {
  $h = Invoke-WebRequest -Uri "https://localhost:8443/healthz" -SkipCertificateCheck -TimeoutSec 8
  $healthOk = ($h.StatusCode -eq 200 -and $h.Content.Trim() -eq 'OK-GATEWAY')
} catch { J 'warn' 'probe.health' 'Gateway /healthz probe failed' @{ err="$_" } }

try {
  $r = Invoke-WebRequest -Uri "https://localhost:8443/" -SkipCertificateCheck -TimeoutSec 8
  $rootOk = ($r.StatusCode -eq 200 -and ($r.RawContent -match 'Socint Frontend \[A\]' -or $r.Headers['X-BlueGreen'] -eq 'A'))
  if ($r.Headers['X-BlueGreen']) { $slotHint = $r.Headers['X-BlueGreen'] }
} catch { J 'warn' 'probe.root' 'Gateway root probe failed' @{ err="$_" } }

# summary
$summary = [ordered]@{
  arr_proxy_enabled        = $proxyEnabled
  preserve_host_enabled    = $proxyPresHost
  upstream_port            = $portA
  active_slot              = 'A'
  gateway_health_ok        = $healthOk
  probe_root_via_gateway_ok= $rootOk
  slot_hint_header         = $slotHint
  log_file                 = $logFile
  duration_ms              = [int]((Get-Date) - $start).TotalMilliseconds
  ready_for_S4_3           = ($proxyEnabled -and $healthOk -and $rootOk)
}
J (($summary.ready_for_S4_3) ? 'info' : 'warn') 'summary' 'S4.2 proxy-to-A summary' $summary

$banner = if ($summary.ready_for_S4_3) { 'READY' } else { 'NEEDS_ACTION' }
Write-Host ("`n== S4.2 Health: {0} (see {1})" -f $banner, $logFile)
