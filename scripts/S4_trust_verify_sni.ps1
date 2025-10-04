param()

$ErrorActionPreference = 'Stop'
$reqId = [guid]::NewGuid().ToString()
$start = Get-Date

$repoRoot = Split-Path $PSScriptRoot -Parent
if (-not $repoRoot) { $repoRoot = 'C:\SocintAI' }
$logDir = Join-Path $repoRoot 'logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
$logFile = Join-Path $logDir ("S4_trust_verify_sni_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))

$appcmd   = Join-Path $env:WINDIR 'System32\inetsrv\appcmd.exe'
$siteName = 'SocintGateway'

function J { param($lvl,$op,$msg,$data=@{}) 
  $o=[ordered]@{ ts=(Get-Date).ToString('o'); level=$lvl; step='S4.trust_verify_sni'; req_id=$reqId; op=$op; msg=$msg; data=$data }
  $json=$o|ConvertTo-Json -Compress -Depth 15; Write-Host $json; Add-Content -LiteralPath $logFile -Value $json
}

J 'info' 'start' 'SNI-aware TLS verification (read-only)' @{ user=$env:UserName; machine=$env:COMPUTERNAME }

# Elevation (for netsh/appcmd reads)
$IsElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
  ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $IsElevated) {
  $pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
  if (-not $pwsh) { $pwsh = 'C:\Program Files\PowerShell\7\pwsh.exe' }
  Start-Process -FilePath $pwsh -Verb RunAs -ArgumentList @('-NoLogo','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"")
  exit
} else { J 'info' 'env.admin' 'Already elevated' @{} }

if (-not (Test-Path $appcmd)) { throw "Missing $appcmd" }

# 1) IIS https binding present?
$bindings = & $appcmd list site "$siteName" /text:bindings 2>&1
$httpsBindingOk = ($bindings -match 'https.*:8443:')
J ($httpsBindingOk ? 'info' : 'warn') 'iis.binding' 'IIS site binding check' @{ ok=$httpsBindingOk; bindings=$bindings }

# 2) netsh http SNI hostname binding
$sniHash = ''; $sniBindingOk = $false
try {
  $hn = & netsh http show sslcert "hostnameport=localhost:8443" 2>&1
  if ($LASTEXITCODE -eq 0 -and $hn -match 'Certificate Hash') {
    $m = [regex]::Match($hn, 'Certificate Hash\s*:\s*([0-9A-F]+)', 'IgnoreCase')
    if ($m.Success) { $sniHash = $m.Groups[1].Value; $sniBindingOk = $true }
  }
} catch {}
J ($sniBindingOk ? 'info' : 'warn') 'bind.sni' 'SNI hostname binding' @{ ok=$sniBindingOk; hash=$sniHash }

# 3) netsh http ip:port bindings (optional, many IIS setups won’t use these when SNI is in play)
$ipBindingOkV4 = $false; $ipBindingOkV6 = $false
try {
  $s4 = & netsh http show sslcert "ipport=0.0.0.0:8443" 2>&1
  $ipBindingOkV4 = ($LASTEXITCODE -eq 0 -and $s4 -match 'Certificate Hash')
} catch {}
try {
  $s6 = & netsh http show sslcert "ipport=[::]:8443" 2>&1
  $ipBindingOkV6 = ($LASTEXITCODE -eq 0 -and $s6 -match 'Certificate Hash')
} catch {}
$ipBindingOk = ($ipBindingOkV4 -or $ipBindingOkV6)
J ($ipBindingOk ? 'info' : 'warn') 'bind.ip' 'IP:port binding (optional)' @{ v4=$ipBindingOkV4; v6=$ipBindingOkV6 }

# 4) No-skip TLS probe (proof browser will trust)
$trustOk = $false; $code = 0; $err = ''
try {
  $r = Invoke-WebRequest -Uri "https://localhost:8443/healthz" -TimeoutSec 8
  $trustOk = ($r.StatusCode -eq 200 -and $r.Content.Trim() -eq 'OK-GATEWAY')
  $code = $r.StatusCode
} catch { $trustOk=$false; $code=-1; $err="$_" }
J ($trustOk ? 'info' : 'warn') 'probe.browser' 'No-skip TLS probe to /healthz' @{ ok=$trustOk; status=$code; err=$err }

# 5) Summary (runtime-first readiness)
$ready = ($httpsBindingOk -and ($sniBindingOk -or $ipBindingOk) -and $trustOk)
$summary = [ordered]@{
  https_binding_ok        = $httpsBindingOk
  sni_binding_ok          = $sniBindingOk
  sni_hash                = $sniHash
  ip_binding_ok           = $ipBindingOk
  browser_trust_probe_ok  = $trustOk
  http_status             = $code
  log_file                = $logFile
  duration_ms             = [int]((Get-Date) - $start).TotalMilliseconds
  ready_trusted_tls       = $ready
}
$level = if ($ready) { 'info' } else { 'warn' }
J $level 'summary' 'S4.T4 SNI verify summary' $summary

Write-Host ("`n== S4.T4 Health: {0} (see {1})" -f ($(if($ready){'READY'}else{'NEEDS_ACTION'}), $logFile))
