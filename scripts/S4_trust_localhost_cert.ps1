param()

$ErrorActionPreference = 'Stop'
$reqId = [guid]::NewGuid().ToString()
$start = Get-Date

# paths
$repoRoot = Split-Path $PSScriptRoot -Parent
if (-not $repoRoot) { $repoRoot = 'C:\SocintAI' }
$logDir = Join-Path $repoRoot 'logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
$logFile = Join-Path $logDir ("S4_trust_localhost_cert_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))

$appcmd = Join-Path $env:WINDIR 'System32\inetsrv\appcmd.exe'
$siteName = 'SocintGateway'

function J { param($lvl,$op,$msg,$data=@{}) 
  $o=[ordered]@{ts=(Get-Date).ToString('o');level=$lvl;step='S4.trust_localhost_cert';req_id=$reqId;op=$op;msg=$msg;data=$data}
  $json=$o|ConvertTo-Json -Compress -Depth 15; Write-Host $json; Add-Content -LiteralPath $logFile -Value $json
}

J 'info' 'start' 'Ensure cert bound to :8443 and trusted by OS' @{ user=$env:UserName; machine=$env:COMPUTERNAME }

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

# 1) Locate (or create) self-signed cert for CN=localhost
$friendly = 'SocintAI Local Dev 8443'
$cert = Get-ChildItem Cert:\LocalMachine\My |
        Where-Object { $_.FriendlyName -eq $friendly -and $_.Subject -match 'CN=localhost' } |
        Sort-Object NotAfter -Descending | Select-Object -First 1
if (-not $cert) {
  J 'warn' 'cert.create' 'Creating self-signed certificate CN=localhost' @{ friendly=$friendly }
  $cert = New-SelfSignedCertificate -DnsName 'localhost' -FriendlyName $friendly `
    -CertStoreLocation 'Cert:\LocalMachine\My' -KeyAlgorithm RSA -KeyLength 2048 -HashAlgorithm SHA256 `
    -KeyExportPolicy Exportable -NotAfter (Get-Date).AddYears(2)
}
$thumb = $cert.Thumbprint
J 'info' 'cert' 'Using certificate' @{ thumb=$thumb; notAfter=$cert.NotAfter; hasPrivateKey=$($cert.HasPrivateKey) }

# 2) Bind cert to http.sys on IPv4 + IPv6
$ipports = @('0.0.0.0:8443','[::]:8443')
$certOk = @{}
foreach ($ip in $ipports) {
  & netsh http delete sslcert "ipport=$ip" | Out-Null
  $appid = [guid]::NewGuid().ToString()
  & netsh http add sslcert "ipport=$ip" "certhash=$thumb" "appid={$appid}" certstorename=MY | Out-Null
  $show = & netsh http show sslcert "ipport=$ip" 2>&1
  $ok = ($LASTEXITCODE -eq 0 -and ($show -replace '\s','') -match ($thumb -replace '\s',''))
  $certOk[$ip] = $ok
  J ($ok ? 'info' : 'warn') 'ssl.bind' 'Verified sslcert bind' @{ ipport=$ip; ok=$ok }
}
$okV4 = [bool]$certOk['0.0.0.0:8443']; $okV6 = [bool]$certOk['[::]:8443']

# 3) Ensure IIS site has https binding *:8443:
& $appcmd set site /site.name:"$siteName" "/-bindings.[protocol='https']" | Out-Null
& $appcmd set site /site.name:"$siteName" "/+bindings.[protocol='https',bindingInformation='*:8443:']" | Out-Null
$bindings = & $appcmd list site "$siteName" /text:bindings
$httpsBindingOk = ($bindings -match 'https.*:8443:')
J ($httpsBindingOk ? 'info' : 'warn') 'site.bind' 'IIS https binding check' @{ ok=$httpsBindingOk; bindings=$bindings }

# 4) Add certificate to Trusted Root (LocalMachine + CurrentUser)
function Ensure-Root($storePath) {
  try {
    $rootCert = Get-ChildItem $storePath | Where-Object { $_.Thumbprint -eq $thumb }
    if (-not $rootCert) {
      Copy-Item -Path ("Cert:\LocalMachine\My\$thumb") -Destination $storePath
      return $true
    }
    return $false
  } catch { J 'warn' 'root.add.err' 'Failed to add cert to root store' @{ store=$storePath; err="$_" }; return $false }
}
$addedLM  = Ensure-Root -storePath 'Cert:\LocalMachine\Root'
$addedCU  = $false; try { $addedCU = Ensure-Root -storePath 'Cert:\CurrentUser\Root' } catch {}
$trustedRootNow = (Get-ChildItem Cert:\LocalMachine\Root | Where-Object { $_.Thumbprint -eq $thumb }) -ne $null

J ($trustedRootNow ? 'info' : 'warn') 'root.trust' 'Trusted Root store status' @{ added_LM=$addedLM; added_CU=$addedCU; trusted=$trustedRootNow }

# 5) Restart site (pick up binding) and PROVE trust with a call that does NOT skip cert check
try { & $appcmd stop site /site.name:"$siteName" | Out-Null } catch {}
Start-Sleep -Milliseconds 200
& $appcmd start site /site.name:"$siteName" | Out-Null

$browserTrustOk = $false; $code = 0; $why = ''
try {
  $r = Invoke-WebRequest -Uri "https://localhost:8443/healthz" -TimeoutSec 8  # no -SkipCertificateCheck here
  $browserTrustOk = ($r.StatusCode -eq 200 -and $r.Content.Trim() -eq 'OK-GATEWAY')
  $code = $r.StatusCode
} catch { $browserTrustOk = $false; $code = -1; $why = "$_" }

# 6) Summary
$summary = [ordered]@{
  cert_thumbprint        = $thumb
  cert_bound_ok_v4       = $okV4
  cert_bound_ok_v6       = $okV6
  https_binding_ok       = $httpsBindingOk
  trusted_root_added     = $trustedRootNow
  browser_trust_probe_ok = $browserTrustOk
  http_status            = $code
  log_file               = $logFile
  duration_ms            = [int]((Get-Date) - $start).TotalMilliseconds
  ready_trusted_tls      = ($okV4 -and $okV6 -and $httpsBindingOk -and $trustedRootNow -and $browserTrustOk)
}
J (($summary.ready_trusted_tls)?'info':'warn') 'summary' 'S4.T trust summary' $summary

Write-Host ("`n== S4.T Health: {0} (see {1})" -f ($(if($summary.ready_trusted_tls){'READY'}else{'NEEDS_ACTION'}), $logFile))
