param()

$ErrorActionPreference = 'Stop'
$reqId = [guid]::NewGuid().ToString()
$start = Get-Date

$repoRoot = Split-Path $PSScriptRoot -Parent
if (-not $repoRoot) { $repoRoot = 'C:\SocintAI' }
$logDir = Join-Path $repoRoot 'logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
$logFile = Join-Path $logDir ("S4_fix_https_binding_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))

$siteName = 'SocintGateway'
$appcmd   = Join-Path $env:WINDIR 'System32\inetsrv\appcmd.exe'
$ipport   = '0.0.0.0:8443'

function Write-Log {
  param([string]$level,[string]$op,[string]$msg,[hashtable]$data=@{})
  $o = [ordered]@{
    ts=(Get-Date).ToString('o'); level=$level; step='S4.fix_https_binding'
    req_id=$reqId; op=$op; msg=$msg; data=$data
  }
  $json = $o | ConvertTo-Json -Compress -Depth 12
  Write-Host $json
  Add-Content -LiteralPath $logFile -Value $json
}

Write-Log 'info' 'start' 'Fixing IIS https binding and verifying' @{ user=$env:UserName; machine=$env:COMPUTERNAME }

# Elevate if needed
$IsElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
  ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $IsElevated) {
  $pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
  if (-not $pwsh) { $pwsh = 'C:\Program Files\PowerShell\7\pwsh.exe' }
  Start-Process -FilePath $pwsh -Verb RunAs -ArgumentList @('-NoLogo','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"")
  exit
}

if (-not (Test-Path $appcmd)) { throw "Missing $appcmd" }

# 1) Re-bind cert to http.sys (just to be sure)
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

& netsh http delete sslcert ipport=$ipport | Out-Null
& netsh http add sslcert    ipport=$ipport certhash=$thumb appid="{${([guid]::NewGuid().ToString())}}" certstorename=MY | Out-Null

$show = & netsh http show sslcert ipport=$ipport 2>$null
$certBoundOk = ($LASTEXITCODE -eq 0 -and $show -match $thumb)
Write-Log ($certBoundOk ? 'info' : 'warn') 'ssl.verify' 'http.sys binding verified' @{ ipport=$ipport; ok=$certBoundOk }

# 2) Force IIS site to have an https binding on *:8443:
$exists = & $appcmd list site "$siteName" 2>$null
if ([string]::IsNullOrWhiteSpace($exists)) {
  # Safeguard: create minimal site pointing to gateway root if somehow missing
  $gwRoot = 'C:\inetpub\SocintGateway'
  if (-not (Test-Path $gwRoot)) { New-Item -ItemType Directory -Force -Path $gwRoot | Out-Null }
  & $appcmd add site /name:"$siteName" /bindings:"https/*:8443:" /physicalPath:"$gwRoot" | Out-Null
  Write-Log 'warn' 'site.create' 'SocintGateway did not exist; created fresh' @{ name=$siteName; port=8443; root=$gwRoot }
} else {
  # Remove all https bindings; add our canonical one
  & $appcmd set site /site.name:"$siteName" "/-bindings.[protocol='https']" | Out-Null
  $bindArg = "/+bindings.[protocol='https',bindingInformation='*:8443:']"
  & $appcmd set site /site.name:"$siteName" $bindArg | Out-Null
  Write-Log 'info' 'site.bind' 'Ensured https binding *:8443:' @{ name=$siteName }
}

# Restart site
try { & $appcmd stop site /site.name:"$siteName" | Out-Null } catch {}
Start-Sleep -Milliseconds 200
& $appcmd start site /site.name:"$siteName" | Out-Null

# 3) Verify IIS binding robustly
$bindings = & $appcmd list site "$siteName" /text:bindings 2>$null
$httpsBindingOk = ($bindings -match 'https.*:8443:')
Write-Log ($httpsBindingOk ? 'info' : 'warn') 'site.verify' 'Checked https binding presence' @{ bindings=$bindings; ok=$httpsBindingOk }

# 4) Probe gateway health
$ok = $false
try {
  $r = Invoke-WebRequest -Uri "https://localhost:8443/healthz" -SkipCertificateCheck -TimeoutSec 8
  $ok = ($r.StatusCode -eq 200 -and $r.Content.Trim() -eq 'OK-GATEWAY')
} catch {
  Write-Log 'warn' 'health.req' 'Gateway health probe failed' @{ err="$_" }
}

# Summary
$summary = [ordered]@{
  cert_bound_ok     = $certBoundOk
  https_binding_ok  = $httpsBindingOk
  gateway_health_ok = $ok
  ipport            = $ipport
  cert_thumbprint   = $thumb
  bindings_text     = $bindings
  log_file          = $logFile
  duration_ms       = [int]((Get-Date) - $start).TotalMilliseconds
  ready_for_S4_2    = ($certBoundOk -and $httpsBindingOk -and $ok)
}
Write-Log (($summary.ready_for_S4_2) ? 'info' : 'warn') 'summary' 'S4.1.fix summary' $summary

$banner = if ($summary.ready_for_S4_2) { 'READY' } else { 'NEEDS_ACTION' }
Write-Host ("`n== S4.1.fix Health: {0} (see {1})" -f $banner, $logFile)
