param()

$ErrorActionPreference = 'Stop'
$reqId = [guid]::NewGuid().ToString()
$start = Get-Date

# paths
$repoRoot = Split-Path $PSScriptRoot -Parent
if (-not $repoRoot) { $repoRoot = 'C:\SocintAI' }
$logDir = Join-Path $repoRoot 'logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
$logFile = Join-Path $logDir ("S4_fix_sslcert_binding_strict_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))

$siteName = 'SocintGateway'
$appcmd   = Join-Path $env:WINDIR 'System32\inetsrv\appcmd.exe'

function JLog([string]$level,[string]$op,[string]$msg,[hashtable]$data=@{}) {
  $o = [ordered]@{
    ts=(Get-Date).ToString('o'); level=$level; step='S4.fix_sslcert_binding_strict'
    req_id=$reqId; op=$op; msg=$msg; data=$data
  }
  $json = $o | ConvertTo-Json -Compress -Depth 12
  Write-Host $json
  Add-Content -LiteralPath $logFile -Value $json
}

JLog 'info' 'start' 'Force-binding cert on http.sys (v4+v6) and verifying gateway' @{ user=$env:UserName; machine=$env:COMPUTERNAME }

# elevate if needed
$IsElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
  ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $IsElevated) {
  $pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
  if (-not $pwsh) { $pwsh = 'C:\Program Files\PowerShell\7\pwsh.exe' }
  Start-Process -FilePath $pwsh -Verb RunAs -ArgumentList @('-NoLogo','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"")
  exit
}

if (-not (Test-Path $appcmd)) { throw "Missing $appcmd" }

# 1) ensure cert in LocalMachine\My for CN=localhost
$certFriendly = 'SocintAI Local Dev 8443'
$cert = Get-ChildItem Cert:\LocalMachine\My |
        Where-Object { $_.FriendlyName -eq $certFriendly -and $_.Subject -match 'CN=localhost' } |
        Sort-Object NotAfter -Descending | Select-Object -First 1
if (-not $cert) {
  $cert = New-SelfSignedCertificate -DnsName 'localhost' -FriendlyName $certFriendly `
          -CertStoreLocation 'Cert:\LocalMachine\My' -KeyAlgorithm RSA -KeyLength 2048 -HashAlgorithm SHA256 `
          -KeyExportPolicy Exportable -NotAfter (Get-Date).AddYears(2)
}
$thumb = $cert.Thumbprint
JLog 'info' 'cert' 'Using certificate' @{ thumb=$thumb; notAfter=$cert.NotAfter; hasPrivateKey=$($cert.HasPrivateKey) }

# 2) ensure IIS https binding exists on *:8443:
$exists = & $appcmd list site "$siteName" 2>$null
$gwRoot = 'C:\inetpub\SocintGateway'
if ([string]::IsNullOrWhiteSpace($exists)) {
  if (-not (Test-Path $gwRoot)) { New-Item -ItemType Directory -Force -Path $gwRoot | Out-Null }
  & $appcmd add site /name:"$siteName" /bindings:"https/*:8443:" /physicalPath:"$gwRoot" | Out-Null
  JLog 'warn' 'site.create' 'Created site with https binding' @{ name=$siteName; root=$gwRoot }
} else {
  # normalize binding to *:8443:
  & $appcmd set site /site.name:"$siteName" "/-bindings.[protocol='https']" | Out-Null
  & $appcmd set site /site.name:"$siteName" "/+bindings.[protocol='https',bindingInformation='*:8443:']" | Out-Null
  JLog 'info' 'site.bind' 'Ensured https binding *:8443:' @{ name=$siteName }
}

# restart site
try { & $appcmd stop site /site.name:"$siteName" | Out-Null } catch {}
Start-Sleep -Milliseconds 200
& $appcmd start site /site.name:"$siteName" | Out-Null

$bindings = & $appcmd list site "$siteName" /text:bindings 2>$null
$httpsBindingOk = ($bindings -match 'https.*:8443:')
JLog ($httpsBindingOk ? 'info' : 'warn') 'site.verify' 'Checked https binding on IIS' @{ bindings=$bindings; ok=$httpsBindingOk }

# 3) http.sys binding: apply to IPv4 and IPv6
$ipports = @('0.0.0.0:8443','[::]:8443')
$certOk = @{}
foreach ($ip in $ipports) {
  # delete existing, ignore errors
  & netsh http delete sslcert "ipport=$ip" | ForEach-Object { JLog 'info' 'ssl.del' 'netsh delete' @{ ipport=$ip; line=$_ } }

  $appid = [guid]::NewGuid().ToString()
  $args = @(
    'http','add','sslcert',
    "ipport=$ip",
    "certhash=$thumb",
    "appid={$appid}",
    'certstorename=MY'
  )
  $out = & netsh @args 2>&1
  $rc  = $LASTEXITCODE
  foreach($line in $out){ JLog 'info' 'ssl.add.out' 'netsh add output' @{ ipport=$ip; line=$line } }
  JLog ($rc -eq 0 ? 'info' : 'warn') 'ssl.add.rc' 'netsh add return code' @{ ipport=$ip; rc=$rc }

  # verify
  $show = & netsh http show sslcert "ipport=$ip" 2>&1
  $ok = ($LASTEXITCODE -eq 0 -and ($show -replace '\s','') -match ($thumb -replace '\s',''))
  $certOk[$ip] = $ok
  JLog ($ok ? 'info' : 'warn') 'ssl.show' 'Verified sslcert' @{ ipport=$ip; ok=$ok }
}

$certV4 = [bool]$certOk['0.0.0.0:8443']
$certV6 = [bool]$certOk['[::]:8443']

# 4) probe gateway over HTTPS (skip cert check)
$ok = $false
try {
  $r = Invoke-WebRequest -Uri "https://localhost:8443/healthz" -SkipCertificateCheck -TimeoutSec 8
  $ok = ($r.StatusCode -eq 200 -and $r.Content.Trim() -eq 'OK-GATEWAY')
} catch {
  JLog 'warn' 'health.req' 'Gateway health probe failed' @{ err="$_" }
}

# summary
$summary = [ordered]@{
  cert_bound_ok_v4  = $certV4
  cert_bound_ok_v6  = $certV6
  https_binding_ok  = $httpsBindingOk
  gateway_health_ok = $ok
  cert_thumbprint   = $thumb
  log_file          = $logFile
  duration_ms       = [int]((Get-Date) - $start).TotalMilliseconds
  ready_for_S4_2    = ($certV4 -and $certV6 -and $httpsBindingOk -and $ok)
}
JLog (($summary.ready_for_S4_2) ? 'info' : 'warn') 'summary' 'S4.1.strict summary' $summary

$banner = if ($summary.ready_for_S4_2) { 'READY' } else { 'NEEDS_ACTION' }
Write-Host ("`n== S4.1.strict Health: {0} (see {1})" -f $banner, $logFile)
