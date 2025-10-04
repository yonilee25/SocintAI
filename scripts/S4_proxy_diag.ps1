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
$logFile = Join-Path $logDir ("S4_proxy_diag_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))

$gatewayRoot = 'C:\inetpub\SocintGateway'
$siteName    = 'SocintGateway'
$appcmd      = Join-Path $env:WINDIR 'System32\inetsrv\appcmd.exe'
$stateFile   = Join-Path $envDir 'bg_ports.json'

function J ($lvl,$op,$msg,$data=@{}) {
  $o=[ordered]@{ts=(Get-Date).ToString('o');level=$lvl;step='S4.proxy_diag';req_id=$reqId;op=$op;msg=$msg;data=$data}
  $json=$o|ConvertTo-Json -Compress -Depth 15
  Write-Host $json
  Add-Content -LiteralPath $logFile -Value $json
}

J 'info' 'start' 'Diagnosing gateway rewrite/proxy & probes' @{ user=$env:UserName; machine=$env:COMPUTERNAME }

# ensure admin (self-elevate, read-only operations still need appcmd)
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
J 'info' 'state' 'Loaded bg ports' @{ portA=$portA; portB=$portB }

# quick IIS binding check
$bindings = & $appcmd list site "$siteName" /text:bindings 2>&1
$httpsBindingOk = ($bindings -match 'https.*:8443:')
J ($httpsBindingOk ? 'info' : 'warn') 'site.bind' 'IIS binding check' @{ bindings=$bindings; https_binding_ok=$httpsBindingOk }

# ARR proxy section
$proxyGet = & $appcmd list config -section:system.webServer/proxy 2>&1
$arrEnabled = ($proxyGet -match 'enabled.*True')
J ($arrEnabled ? 'info' : 'warn') 'proxy.section' 'ARR proxy section read' @{ enabled=$arrEnabled; raw=$proxyGet }

# Rewrite section validation (if invalid, appcmd will error)
$rewriteErr = $null
try {
  $rwTxt = & $appcmd list config "$siteName/" -section:system.webServer/rewrite 2>&1
  $rewriteOk = ($LASTEXITCODE -eq 0)
  J ($rewriteOk ? 'info' : 'warn') 'rewrite.section' 'Rewrite section read' @{ ok=$rewriteOk; sample=($rwTxt | Select-Object -First 1) }
} catch {
  $rewriteOk = $false
  $rewriteErr = "$_"
  J 'warn' 'rewrite.error' 'Rewrite section threw' @{ err=$rewriteErr }
}

function Probe($url,$skipTls=$true) {
  $o = [ordered]@{ url=$url; ok=$false; code=0; why=''; sample='' }
  try {
    $r = Invoke-WebRequest -Uri $url -TimeoutSec 8 -SkipCertificateCheck:$skipTls
    $o.ok   = ($r.StatusCode -eq 200)
    $o.code = $r.StatusCode
    $o.sample = ($r.Content.Substring(0, [Math]::Min(200, $r.Content.Length)))
  } catch {
    $o.ok   = $false
    $o.code = -1
    $o.why  = "$_"
  }
  return $o
}

# probes
$pHealthGw = Probe "https://localhost:8443/healthz"
$pRootGw   = Probe "https://localhost:8443/"
$pRootA    = Probe ("http://127.0.0.1:{0}/" -f $portA) $false

# Classify a quick hint
$errorHint = ''
if (-not $pHealthGw.ok -and $pHealthGw.why -match '500\.19') { $errorHint = '500.19: invalid web.config (likely rewrite section)' }
elseif (-not $pHealthGw.ok -and $pHealthGw.why -match '502\.3') { $errorHint = '502.3: proxy to upstream failing (ARR)' }
elseif (-not $pHealthGw.ok -and -not $rewriteOk) { $errorHint = 'Rewrite section invalid for this site' }
elseif ($pHealthGw.ok -and -not $pRootGw.ok) { $errorHint = 'Health local ok; proxy rule failing for root' }

# summary
$summary = [ordered]@{
  https_binding_ok = $httpsBindingOk
  arr_proxy_enabled = $arrEnabled
  rewrite_section_ok = $rewriteOk
  probe_health = @{ gateway = $pHealthGw }
  probe_root   = @{ gateway = $pRootGw; directA = $pRootA }
  error_hint = $errorHint
  log_file   = $logFile
  duration_ms= [int]((Get-Date) - $start).TotalMilliseconds
  ready_for_S4_3 = ($httpsBindingOk -and $arrEnabled -and $rewriteOk -and $pHealthGw.ok -and $pRootGw.ok)
}
J (($summary.ready_for_S4_3) ? 'info' : 'warn') 'summary' 'S4.2b diag summary' $summary

$banner = if ($summary.ready_for_S4_3) { 'READY' } else { 'NEEDS_ACTION' }
Write-Host ("`n== S4.2b Health: {0} (see {1})" -f $banner, $logFile)
