param()

$ErrorActionPreference = 'Stop'
$reqId  = [guid]::NewGuid().ToString()
$start  = Get-Date

# Paths
$repoRoot = Split-Path $PSScriptRoot -Parent
if (-not $repoRoot) { $repoRoot = 'C:\SocintAI' }
$logDir = Join-Path $repoRoot 'logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
$logFile = Join-Path $logDir ("S4_gateway_https_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))

$gatewayRoot = 'C:\inetpub\SocintGateway'
$siteName    = 'SocintGateway'
$poolName    = 'SocintGateway_AppPool'
$appcmd      = Join-Path $env:WINDIR 'System32\inetsrv\appcmd.exe'

function Write-Log {
  param([string]$level,[string]$op,[string]$msg,[hashtable]$data=@{})
  $o = [ordered]@{
    ts     = (Get-Date).ToString('o')
    level  = $level
    step   = 'S4.gateway_https'
    req_id = $reqId
    op     = $op
    msg    = $msg
    data   = $data
  }
  $json = $o | ConvertTo-Json -Compress -Depth 12
  Write-Host $json
  Add-Content -LiteralPath $logFile -Value $json
}

Write-Log 'info' 'start' 'Starting S4.1: create HTTPS gateway on :8443' @{ user=$env:UserName; machine=$env:COMPUTERNAME }

# Ensure admin (self-elevate)
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

# 1) Ensure cert for CN=localhost (friendly: SocintAI Local Dev 8443)
$certFriendly = 'SocintAI Local Dev 8443'
$cert = Get-ChildItem Cert:\LocalMachine\My |
        Where-Object { $_.FriendlyName -eq $certFriendly -and $_.Subject -match 'CN=localhost' } |
        Sort-Object NotAfter -Descending |
        Select-Object -First 1

if (-not $cert) {
  Write-Log 'warn' 'cert.missing' 'Certificate missing; creating self-signed CN=localhost' @{ friendly=$certFriendly }
  $cert = New-SelfSignedCertificate -DnsName 'localhost' -FriendlyName $certFriendly `
          -CertStoreLocation 'Cert:\LocalMachine\My' -KeyAlgorithm RSA -KeyLength 2048 -HashAlgorithm SHA256 `
          -KeyExportPolicy Exportable -NotAfter (Get-Date).AddYears(2)
}
$thumb = $cert.Thumbprint
Write-Log 'info' 'cert' 'Dev certificate ready' @{ friendly=$certFriendly; thumbprint=$thumb; notAfter=$cert.NotAfter }

# 2) Bind cert to http.sys on 0.0.0.0:8443
function Remove-SslBinding([string]$ipport) {
  $out = & netsh http show sslcert ipport=$ipport 2>$null
  if ($LASTEXITCODE -eq 0 -and $out -match 'Certificate Hash') {
    & netsh http delete sslcert ipport=$ipport | Out-Null
    Write-Log 'info' 'ssl.delete' 'Removed existing ssl binding' @{ ipport=$ipport }
  }
}
function Add-SslBinding([string]$ipport,[string]$hash,[string]$appid) {
  & netsh http add sslcert ipport=$ipport certhash=$hash appid="{$appid}" certstorename=MY | Out-Null
  Write-Log 'info' 'ssl.add' 'Added ssl binding' @{ ipport=$ipport; certhash=$hash; appid=$appid }
}
$ipport = '0.0.0.0:8443'
$appid  = [guid]::NewGuid().ToString()
Remove-SslBinding -ipport $ipport
Add-SslBinding    -ipport $ipport -hash $thumb -appid $appid

# verify binding
$show = & netsh http show sslcert ipport=$ipport 2>$null
$certBoundOk = ($LASTEXITCODE -eq 0 -and $show -match $thumb)
Write-Log ($certBoundOk ? 'info' : 'warn') 'ssl.verify' 'Verified sslcert binding' @{ ipport=$ipport; ok=$certBoundOk }

# 3) Ensure filesystem content
if (-not (Test-Path $gatewayRoot)) { New-Item -ItemType Directory -Force -Path $gatewayRoot | Out-Null }
Set-Content -LiteralPath (Join-Path $gatewayRoot 'healthz.txt') -Value 'OK-GATEWAY' -Encoding ASCII
$idx = @"
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>Socint Gateway</title></head>
<body style="font-family:system-ui;padding:24px">
  <h1>Socint Gateway (HTTPS 8443)</h1>
  <p>ReqId: $reqId</p>
</body></html>
"@
Set-Content -LiteralPath (Join-Path $gatewayRoot 'index.html') -Value $idx -Encoding UTF8

# minimal web.config with /healthz rewrite
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
      </rules>
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
Write-Log 'info' 'fs.write' 'Wrote gateway content and web.config' @{ root=$gatewayRoot }

# 4) Ensure app pool and site with HTTPS binding
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
  $bindHttps = ('https/*:{0}:' -f $port)
  if ([string]::IsNullOrWhiteSpace($exists)) {
    & $appcmd add site /name:"$name" /bindings:"$bindHttps" /physicalPath:"$path" | Out-Null
    Write-Log 'info' 'site.create' "Created site $name" @{ port=$port; path=$path }
  } else {
    # ensure our https binding is present (remove other https bindings and add ours)
    & $appcmd set site /site.name:"$name" "/-bindings.[protocol='https']" | Out-Null
    $bindStar = ('*:{0}:' -f $port)
    $addArg   = "/+bindings.[protocol='https',bindingInformation='$bindStar']"
    & $appcmd set site /site.name:"$name" $addArg | Out-Null
    Write-Log 'info' 'site.bind' 'Ensured https binding' @{ name=$name; port=$port }
  }
  # assign pool on root app
  & $appcmd set app "$name/" /applicationPool:"$pool" | Out-Null
  # (re)start
  try { & $appcmd stop site /site.name:"$name" | Out-Null } catch {}
  Start-Sleep -Milliseconds 200
  & $appcmd start site /site.name:"$name" | Out-Null
}

Ensure-AppPool -name $poolName
Ensure-Site    -name $siteName -path $gatewayRoot -pool $poolName -port 8443

# verify binding presence
$bindings = & $appcmd list site "$siteName" /text:bindings 2>$null
$httpsBindingOk = ($bindings -match "https/\*/:8443:")
Write-Log ($httpsBindingOk ? 'info' : 'warn') 'site.verify' 'Checked https binding presence' @{ bindings=$bindings; ok=$httpsBindingOk }

# 5) Probe gateway health over HTTPS (self-signed; skip cert check)
$ok = $false
try {
  $r = Invoke-WebRequest -Uri "https://localhost:8443/healthz" -SkipCertificateCheck -TimeoutSec 8
  $ok = ($r.StatusCode -eq 200 -and $r.Content.Trim() -eq 'OK-GATEWAY')
} catch { Write-Log 'warn' 'health.req' 'Gateway health probe failed' @{ err="$_" } }
Write-Log ($ok ? 'info' : 'warn') 'health' 'Gateway health probe' @{ status_ok=$ok }

# Summary
$summary = [ordered]@{
  cert_bound_ok    = $certBoundOk
  https_binding_ok = $httpsBindingOk
  gateway_health_ok= $ok
  site_name        = $siteName
  app_pool         = $poolName
  root_path        = $gatewayRoot
  ipport           = '0.0.0.0:8443'
  cert_thumbprint  = $thumb
  log_file         = $logFile
  duration_ms      = [int]((Get-Date) - $start).TotalMilliseconds
  ready_for_S4_2   = ($certBoundOk -and $httpsBindingOk -and $ok)
}
Write-Log (($summary.ready_for_S4_2) ? 'info' : 'warn') 'summary' 'S4.1 gateway summary' $summary

$banner = if ($summary.ready_for_S4_2) { 'READY' } else { 'NEEDS_ACTION' }
Write-Host ("`n== S4.1 Health: {0} (see {1})" -f $banner, $logFile)
