# C:\SocintAI\scripts\S5_point_gateway_to_next.ps1  (PS7-safe; no ternaries)
param()

$ErrorActionPreference = 'Stop'
$reqId = [guid]::NewGuid().ToString()
$start = Get-Date

$repoRoot     = 'C:\SocintAI'
$logDir       = Join-Path $repoRoot 'logs'
$gatewayRoot  = 'C:\inetpub\SocintGateway'
$siteName     = 'SocintGateway'
$appcmd       = Join-Path $env:WINDIR 'System32\inetsrv\appcmd.exe'
$upstreamPort = 3001

if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
$stepLog = Join-Path $logDir ("S5_point_gateway_to_next_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))

function J { param($level,$op,$msg,$data=@{}) 
  $o=[ordered]@{ ts=(Get-Date).ToString('o'); level=$level; step='S5.point_gateway_to_next'; req_id=$reqId; op=$op; msg=$msg; data=$data }
  $json=$o|ConvertTo-Json -Compress -Depth 20
  Write-Host $json
  Add-Content -LiteralPath $stepLog -Value $json
}

J 'info' 'start' 'Pointing gateway to Next upstream :3001 and verifying' @{ user=$env:UserName; machine=$env:COMPUTERNAME }

# Elevate for IIS ops
$IsElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $IsElevated) {
  $pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue).Source; if (-not $pwsh) { $pwsh = 'C:\Program Files\PowerShell\7\pwsh.exe' }
  Start-Process -FilePath $pwsh -Verb RunAs -ArgumentList @('-NoLogo','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"")
  exit
}

if (-not (Test-Path $appcmd)) { throw "Missing $appcmd" }
if (-not (Test-Path $gatewayRoot)) { New-Item -ItemType Directory -Force -Path $gatewayRoot | Out-Null }

# Write gateway config (keep /healthz local; proxy everything else to port 3001)
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
        <rule name="ProxyToNext" stopProcessing="true">
          <match url="(.*)" />
          <conditions logicalGrouping="MatchAll">
            <add input="{REQUEST_URI}" pattern="^/healthz$" negate="true" />
          </conditions>
          <action type="Rewrite" url="http://127.0.0.1:$upstreamPort/{R:1}" />
        </rule>
      </rules>
      <outboundRules>
        <rule name="FixLocationHeader" preCondition="HasLocation">
          <match serverVariable="RESPONSE_Location" pattern="^http(s)?://127\.0\.0\.1:$upstreamPort/(.*)" />
          <action type="Rewrite" value="https://{HTTP_HOST}/{R:2}" />
        </rule>
        <preConditions>
          <preCondition name="HasLocation">
            <add input="{RESPONSE_Location}" pattern=".+"/>
          </preCondition>
        </preConditions>
      </outboundRules>
    </rewrite>
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
Set-Content -LiteralPath (Join-Path $gatewayRoot 'web.config') -Value $wc -Encoding UTF8
if (-not (Test-Path (Join-Path $gatewayRoot 'healthz.txt'))) {
  Set-Content -LiteralPath (Join-Path $gatewayRoot 'healthz.txt') -Value 'OK-GATEWAY' -Encoding ASCII
}
J 'info' 'write.config' 'Wrote gateway web.config to proxy :3001' @{ root=$gatewayRoot; upstreamPort=$upstreamPort }

# Restart IIS site
try { & $appcmd stop site /site.name:"$siteName" | Out-Null } catch {}
Start-Sleep -Milliseconds 250
& $appcmd start site /site.name:"$siteName" | Out-Null

# Verify https binding on :8443
$bindings = & $appcmd list site "$siteName" /text:bindings 2>&1
$httpsOk = ($bindings -match 'https.*:8443:')
$bindLevel = if ($httpsOk) { 'info' } else { 'warn' }
J $bindLevel 'https.bind' 'IIS https binding check' @{ ok=$httpsOk; bindings=$bindings }

# Probes over HTTPS (no SkipCertificateCheck — cert is trusted)
$rootOk=$false; $apiOk=$false; $rootCode=0; $apiCode=0; $why1=''; $why2=''
try {
  $r = Invoke-WebRequest -Uri 'https://localhost:8443/' -TimeoutSec 8
  $rootOk = ($r.StatusCode -eq 200)
  $rootCode = [int]$r.StatusCode
} catch { $rootOk=$false; $rootCode=-1; $why1="$($_.Exception.Message)" }

try {
  $a = Invoke-WebRequest -Uri 'https://localhost:8443/api/health' -TimeoutSec 8
  $apiOk = ($a.StatusCode -eq 200)
  $apiCode = [int]$a.StatusCode
} catch { $apiOk=$false; $apiCode=-1; $why2="$($_.Exception.Message)" }

# Summary
$ready = ($httpsOk -and $rootOk -and $apiOk)
$sumLevel = if ($ready) { 'info' } else { 'warn' }
$summary = [ordered]@{
  updated_gateway      = $true
  upstream_port        = $upstreamPort
  https_binding_ok     = $httpsOk
  gateway_root_ok      = $rootOk
  gateway_root_code    = $rootCode
  gateway_api_ok       = $apiOk
  gateway_api_code     = $apiCode
  root_err             = $why1
  api_err              = $why2
  log_file             = $stepLog
  duration_ms          = [int]((Get-Date) - $start).TotalMilliseconds
  ready_for_S5_2       = $ready
}
J $sumLevel 'summary' 'S5.2 gateway→Next summary' $summary

Write-Host ("`n== S5.2 Health: {0} (see {1})" -f ($(if($ready){'READY'}else{'NEEDS_ACTION'}), $stepLog))
