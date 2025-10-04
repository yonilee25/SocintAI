param()

$ErrorActionPreference = 'Stop'
$reqId  = [guid]::NewGuid().ToString()
$start  = Get-Date

# paths
$repoRoot = Split-Path $PSScriptRoot -Parent
if (-not $repoRoot) { $repoRoot = 'C:\SocintAI' }
$logDir  = Join-Path $repoRoot 'logs'
$depsDir = Join-Path $repoRoot 'deps'
if (-not (Test-Path $logDir))  { New-Item -ItemType Directory -Force -Path $logDir  | Out-Null }
if (-not (Test-Path $depsDir)) { New-Item -ItemType Directory -Force -Path $depsDir | Out-Null }
$logFile = Join-Path $logDir ("S4_trust_localhost_cert2_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))

function J { param($level,$op,$msg,$data=@{}) 
  $o=[ordered]@{ts=(Get-Date).ToString('o');level=$level;step='S4.trust_localhost_cert2';req_id=$reqId;op=$op;msg=$msg;data=$data}
  $json=$o|ConvertTo-Json -Compress -Depth 15; Write-Host $json; Add-Content -LiteralPath $logFile -Value $json
}

J 'info' 'start' 'Export + import cert into Trusted Root (LM + CU) and prove trust' @{ user=$env:UserName; machine=$env:COMPUTERNAME }

# elevation for LocalMachine root import
$IsElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $IsElevated) {
  $pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
  if (-not $pwsh) { $pwsh = 'C:\Program Files\PowerShell\7\pwsh.exe' }
  Start-Process -FilePath $pwsh -Verb RunAs -ArgumentList @('-NoLogo','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"")
  exit
}

# 1) locate or create self-signed cert in LM\My
$friendly = 'SocintAI Local Dev 8443'
$cert = Get-ChildItem Cert:\LocalMachine\My |
        Where-Object { $_.FriendlyName -eq $friendly -and $_.Subject -match 'CN=localhost' } |
        Sort-Object NotAfter -Descending | Select-Object -First 1
if (-not $cert) {
  J 'warn' 'cert.create' 'Creating self-signed CN=localhost' @{ friendly=$friendly }
  $cert = New-SelfSignedCertificate -DnsName 'localhost' -FriendlyName $friendly `
    -CertStoreLocation 'Cert:\LocalMachine\My' -KeyAlgorithm RSA -KeyLength 2048 -HashAlgorithm SHA256 `
    -KeyExportPolicy Exportable -NotAfter (Get-Date).AddYears(2)
}
$thumb = $cert.Thumbprint
J 'info' 'cert' 'Using certificate' @{ thumb=$thumb; notAfter=$cert.NotAfter }

# 2) export cert (no private key) to .cer
$cerPath = Join-Path $depsDir 'localhost_8443.cer'
Export-Certificate -Cert $cert -FilePath $cerPath -Force | Out-Null
J 'info' 'export' 'Exported DER .cer' @{ file=$cerPath }

# 3) import to LocalMachine Root and CurrentUser Root with certutil
$lmOut = & certutil -f -addstore Root "$cerPath" 2>&1
J 'info' 'import.lm' 'certutil LM Root output' @{ output=$lmOut }
$cuOut = & certutil -user -f -addstore Root "$cerPath" 2>&1
J 'info' 'import.cu' 'certutil CU Root output' @{ output=$cuOut }

# 4) verify presence in both stores
$lmHas = (Get-ChildItem Cert:\LocalMachine\Root | Where-Object { $_.Thumbprint -eq $thumb }) -ne $null
$cuHas = $false
try { $cuHas = (Get-ChildItem Cert:\CurrentUser\Root | Where-Object { $_.Thumbprint -eq $thumb }) -ne $null } catch {}
$level = if ($lmHas) { 'info' } else { 'warn' }; J $level 'verify.lm' 'LocalMachine Root has cert' @{ present=$lmHas }
$level = if ($cuHas) { 'info' } else { 'warn' }; J $level 'verify.cu' 'CurrentUser Root has cert'   @{ present=$cuHas }

# 5) verify http.sys bindings (IPv4 + IPv6) still point to thumb
$binds = @('0.0.0.0:8443','[::]:8443')
$bound = @{}
foreach ($ip in $binds) {
  $show = & netsh http show sslcert "ipport=$ip" 2>&1
  $ok = ($LASTEXITCODE -eq 0 -and ($show -replace '\s','') -match ($thumb -replace '\s',''))
  $bound[$ip] = $ok
  $level = if ($ok) { 'info' } else { 'warn' }
  J $level 'verify.bind' 'http.sys sslcert' @{ ipport=$ip; ok=$ok }
}
$okV4 = [bool]$bound['0.0.0.0:8443']; $okV6 = [bool]$bound['[::]:8443']

# 6) verify IIS binding
$appcmd = Join-Path $env:WINDIR 'System32\inetsrv\appcmd.exe'
$bindings = & $appcmd list site "SocintGateway" /text:bindings 2>&1
$httpsBindingOk = ($bindings -match 'https.*:8443:')
$level = if ($httpsBindingOk) { 'info' } else { 'warn' }
J $level 'site.bind' 'IIS https binding check' @{ ok=$httpsBindingOk; bindings=$bindings }

# 7) PROVE browser trust (no SkipCertificateCheck)
$trustOk = $false; $code = 0; $why=''
try {
  $r = Invoke-WebRequest -Uri "https://localhost:8443/healthz" -TimeoutSec 8
  $trustOk = ($r.StatusCode -eq 200 -and $r.Content.Trim() -eq 'OK-GATEWAY')
  $code = $r.StatusCode
} catch { $trustOk = $false; $code=-1; $why="$_" }
$level = if ($trustOk) { 'info' } else { 'warn' }
J $level 'probe.browser' 'No-skip TLS probe to /healthz' @{ ok=$trustOk; status=$code; err=$why }

# 8) summary
$ready = ($lmHas -and $cuHas -and $okV4 -and $okV6 -and $httpsBindingOk -and $trustOk)
$summary = [ordered]@{
  cert_thumbprint        = $thumb
  lm_root_has_thumb      = $lmHas
  cu_root_has_thumb      = $cuHas
  cert_bound_ok_v4       = $okV4
  cert_bound_ok_v6       = $okV6
  https_binding_ok       = $httpsBindingOk
  browser_trust_probe_ok = $trustOk
  http_status            = $code
  log_file               = $logFile
  duration_ms            = [int]((Get-Date) - $start).TotalMilliseconds
  ready_trusted_tls      = $ready
}
$level = if ($ready) { 'info' } else { 'warn' }
J $level 'summary' 'S4.T2 trust summary' $summary

Write-Host ("`n== S4.T2 Health: {0} (see {1})" -f ($(if($ready){'READY'}else{'NEEDS_ACTION'}), $logFile))
