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
$logFile = Join-Path $logDir ("S4_proxy_minimal_fix_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))

$gatewayRoot = 'C:\inetpub\SocintGateway'
$siteName    = 'SocintGateway'
$appcmd      = Join-Path $env:WINDIR 'System32\inetsrv\appcmd.exe'
$stateFile   = Join-Path $envDir 'bg_ports.json'

function J ($lvl,$op,$msg,$data=@{}) {
  $o=[ordered]@{ts=(Get-Date).ToString('o');level=$lvl;step='S4.proxy_minimal_fix';req_id=$reqId;op=$op;msg=$msg;data=$data}
  $json=$o|ConvertTo-Json -Compress -Depth 15
  Write-Host $json
  Add-Content -LiteralPath $logFile -Value $json
}

J 'info' 'start' 'Minimal ARR proxy to slot A (fix)' @{ user=$env:UserName; machine=$env:COMPUTERNAME }

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

# 1) verify modules
$mods = & $appcmd list modules 2>&1
$hasRewrite = ($mods -match 'RewriteModule')
$hasProxy   = ($mods -match 'ProxyModule')
J 'info' 'mods' 'Module presence' @{ rewrite=$hasRewrite; proxy=$hasProxy }

# 2) enable ARR proxy at server level (capture errors)
$proxySet = & $appcmd set config -section:system.webServer/proxy /enabled:"True" /preserveHostHeader:"True" /reverseRewriteHostInResponseHeaders:"True" /commit:apphost 2>&1
$rcSet    = $LASTEXITCODE
$proxyGet = & $appcmd list config -section:system.webServer/proxy 2>&1
$rcGet    = $LASTEXITCODE

$proxyEnabled  = ($proxyGet -match 'enabled.*True') -or ($rcSet -eq 0)
$preserveHost  = ($proxyGet -match 'preserveHostHeader.*True')
J ($proxyEnabled ? 'info' : 'warn') 'proxy.section' 'ARR proxy settings' @{ rcSet=$rcSet; rcGet=$rcGet; enabled=$proxyEnabled; preserveHost=$preserveHost; set_out=$proxySet; get_out=$proxyGet }

# 3) write a MINIMAL gateway web.config: keep /healthz local, proxy everything else to A (no outbound rules)
if (-not (Test-Path $gatewayRoot)) { New-Item -ItemType Directory -Force -Path $gatewayRoot | Out-Null }
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
"@
$wc = $wc.Replace('__UP_PORT__', "$portA")
Set-Content -LiteralPath (Join-Path $gatewayRoot 'web.config') -Value $wc -Encoding UTF8
# ensure health file exists
if (-not (Test-Path (Join-Path $gatewayRoot 'healthz.txt'))) {
  Set-Content -LiteralPath (Join-Path $gatewayRoot 'healthz.txt') -Value 'OK-GATEWAY' -Encoding ASCII
}
J 'info' 'webconfig.write' 'Wrote minimal proxy web.config' @{ root=$gatewayRoot; upstream=$portA }

# 4) restart site
try { & $appcmd stop site /site.name:"$siteName" | Out-Null } catch {}
Start-Sleep -Milliseconds 200
& $appcmd start site /site.name:"$siteName" | Out-Null

# 5) probes
$healthOk = $false
$rootOk   = $false
$slotHint = ''
try {
  $h = Invoke-WebRequest -Uri "https://localhost:8443/healthz" -SkipCertificateCheck -TimeoutSec 8
  $healthOk = ($h.StatusCode -eq 200 -and $h.Content.Trim() -eq 'OK-GATEWAY')
} catch { J 'warn' 'probe.health' 'Gateway /healthz failed' @{ err="$_" } }

try {
  $r = Invoke-WebRequest -Uri "https://localhost:8443/" -SkipCertificateCheck -TimeoutSec 8
  $rootOk = ($r.StatusCode -eq 200 -and ($r.Headers['X-BlueGreen'] -eq 'A' -or $r.Content -match '\[A\]'))
  if ($r.Headers['X-BlueGreen']) { $slotHint = $r.Headers['X-BlueGreen'] }
} catch { J 'warn' 'probe.root' 'Gateway root failed' @{ err="$_" } }

# summary
$summary = [ordered]@{
  arr_proxy_enabled         = $proxyEnabled
  preserve_host_enabled     = $preserveHost
  upstream_port             = $portA
  active_slot               = 'A'
  gateway_health_ok         = $healthOk
  probe_root_via_gateway_ok = $rootOk
  slot_hint_header          = $slotHint
  log_file                  = $logFile
  duration_ms               = [int]((Get-Date) - $start).TotalMilliseconds
  ready_for_S4_3            = ($proxyEnabled -and $healthOk -and $rootOk)
}
J (($summary.ready_for_S4_3) ? 'info' : 'warn') 'summary' 'S4.2a minimal proxy summary' $summary

$banner = if ($summary.ready_for_S4_3) { 'READY' } else { 'NEEDS_ACTION' }
Write-Host ("`n== S4.2a Health: {0} (see {1})" -f $banner, $logFile)
