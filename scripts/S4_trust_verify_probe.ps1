param()

$ErrorActionPreference = 'Stop'
$reqId = [guid]::NewGuid().ToString()
$start = Get-Date

# Paths
$repoRoot = Split-Path $PSScriptRoot -Parent
if (-not $repoRoot) { $repoRoot = 'C:\SocintAI' }
$logDir = Join-Path $repoRoot 'logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
$logFile = Join-Path $logDir ("S4_trust_verify_probe_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))

$appcmd   = Join-Path $env:WINDIR 'System32\inetsrv\appcmd.exe'
$siteName = 'SocintGateway'
$friendly = 'SocintAI Local Dev 8443'

function J { param($level,$op,$msg,$data=@{}) 
  $o=[ordered]@{ ts=(Get-Date).ToString('o'); level=$level; step='S4.trust_verify_probe'; req_id=$reqId; op=$op; msg=$msg; data=$data }
  $json=$o|ConvertTo-Json -Compress -Depth 15; Write-Host $json; Add-Content -LiteralPath $logFile -Value $json
}

J 'info' 'start' 'Read-only TLS trust & binding verification' @{ user=$env:UserName; machine=$env:COMPUTERNAME }

# Elevation (read-only, but appcmd may require admin for some infos)
$IsElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
               ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $IsElevated) {
  $pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
  if (-not $pwsh) { $pwsh = 'C:\Program Files\PowerShell\7\pwsh.exe' }
  Start-Process -FilePath $pwsh -Verb RunAs -ArgumentList @('-NoLogo','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"")
  exit
} else { J 'info' 'env.admin' 'Already elevated' @{} }

if (-not (Test-Path $appcmd)) { throw "Missing $appcmd" }

# 1) Locate cert by friendly name (fallback to any CN=localhost in LM\My)
$cert = Get-ChildItem Cert:\LocalMachine\My |
        Where-Object { ($_.FriendlyName -eq $friendly -or $_.Subject -match 'CN=localhost') } |
        Sort-Object NotAfter -Descending | Select-Object -First 1
if (-not $cert) { throw "No CN=localhost certificate found in LocalMachine\My" }
$thumb = $cert.Thumbprint
J 'info' 'cert' 'Using certificate' @{ thumb=$thumb; notAfter=$cert.NotAfter; friendly=$cert.FriendlyName }

# 2) Trust store checks
$lmHas = (Get-ChildItem Cert:\LocalMachine\Root | Where-Object { $_.Thumbprint -eq $thumb }) -ne $null
$cuHas = $false
try { $cuHas = (Get-ChildItem Cert:\CurrentUser\Root | Where-Object { $_.Thumbprint -eq $thumb }) -ne $null } catch {}
J ($lmHas ? 'info' : 'warn') 'trust.lm' 'LocalMachine Root contains cert' @{ present=$lmHas }
J ($cuHas ? 'info' : 'warn') 'trust.cu' 'CurrentUser Root contains cert'  @{ present=$cuHas }

# 3) http.sys bindings
$boundV4 = $false; $boundV6 = $false
try {
  $s4 = & netsh http show sslcert "ipport=0.0.0.0:8443" 2>&1
  $boundV4 = ($LASTEXITCODE -eq 0 -and ($s4 -replace '\s','') -match ($thumb -replace '\s',''))
} catch {}
try {
  $s6 = & netsh http show sslcert "ipport=[::]:8443" 2>&1
  $boundV6 = ($LASTEXITCODE -eq 0 -and ($s6 -replace '\s','') -match ($thumb -replace '\s',''))
} catch {}
J ($boundV4 ? 'info' : 'warn') 'bind.v4' 'http.sys v4 bound to thumb' @{ ok=$boundV4 }
J ($boundV6 ? 'info' : 'warn') 'bind.v6' 'http.sys v6 bound to thumb' @{ ok=$boundV6 }

# 4) IIS binding
$bindings = & $appcmd list site "$siteName" /text:bindings 2>&1
$httpsBindingOk = ($bindings -match 'https.*:8443:')
J ($httpsBindingOk ? 'info' : 'warn') 'iis.binding' 'IIS site binding check' @{ ok=$httpsBindingOk; bindings=$bindings }

# 5) No-skip TLS probe (proof of browser trust)
$trustOk = $false; $code = 0; $err = ''
try {
  $resp = Invoke-WebRequest -Uri "https://localhost:8443/healthz" -TimeoutSec 8
  $trustOk = ($resp.StatusCode -eq 200 -and $resp.Content.Trim() -eq 'OK-GATEWAY')
  $code = $resp.StatusCode
} catch { $trustOk=$false; $code=-1; $err="$_" }
J ($trustOk ? 'info' : 'warn') 'probe.browser' 'No-skip TLS probe to /healthz' @{ ok=$trustOk; status=$code; err=$err }

# 6) Summary
$ready = ($lmHas -and $boundV4 -and $boundV6 -and $httpsBindingOk -and $trustOk)
$summary = [ordered]@{
  cert_thumbprint        = $thumb
  lm_root_has_thumb      = $lmHas
  cu_root_has_thumb      = $cuHas
  cert_bound_ok_v4       = $boundV4
  cert_bound_ok_v6       = $boundV6
  https_binding_ok       = $httpsBindingOk
  browser_trust_probe_ok = $trustOk
  http_status            = $code
  log_file               = $logFile
  duration_ms            = [int]((Get-Date) - $start).TotalMilliseconds
  ready_trusted_tls      = $ready
}
$level = if ($ready) { 'info' } else { 'warn' }
J $level 'summary' 'S4.T3 verify summary' $summary

Write-Host ("`n== S4.T3 Health: {0} (see {1})" -f ($(if($ready){'READY'}else{'NEEDS_ACTION'}), $logFile))
