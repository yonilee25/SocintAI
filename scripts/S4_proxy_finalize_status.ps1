param()

$ErrorActionPreference = 'Stop'
$reqId = [guid]::NewGuid().ToString()
$start = Get-Date

# paths
$repoRoot = Split-Path $PSScriptRoot -Parent
if (-not $repoRoot) { $repoRoot = 'C:\SocintAI' }
$logDir = Join-Path $repoRoot 'logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
$logFile = Join-Path $logDir ("S4_proxy_finalize_status_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))

$siteName = 'SocintGateway'
$gwRoot   = 'C:\inetpub\SocintGateway'
$appcmd   = Join-Path $env:WINDIR 'System32\inetsrv\appcmd.exe'
$state    = Join-Path (Join-Path $repoRoot 'env') 'bg_ports.json'

function J { param($lvl,$op,$msg,$data=@{}) 
  $o=[ordered]@{ts=(Get-Date).ToString('o');level=$lvl;step='S4.proxy_finalize_status';req_id=$reqId;op=$op;msg=$msg;data=$data}
  $json=$o|ConvertTo-Json -Compress -Depth 15; Write-Host $json; Add-Content -LiteralPath $logFile -Value $json
}

J 'info' 'start' 'Finalizing proxy status using runtime checks' @{ user=$env:UserName; machine=$env:COMPUTERNAME }

# elevation
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
if (-not (Test-Path $state))  { throw "Missing $state (run S3 first)" }

# state ports
$ports = Get-Content $state | ConvertFrom-Json
$portA = [int]$ports.A.port
$portB = [int]$ports.B.port
J 'info' 'state' 'Loaded A/B ports' @{ portA=$portA; portB=$portB; state_file=$state }

# modules present?
$mods = & $appcmd list modules 2>&1
$hasRewrite = ($mods -match 'RewriteModule')
$hasProxy   = ($mods -match 'ProxyModule')
J 'info' 'modules' 'Module presence' @{ rewrite=$hasRewrite; proxy=$hasProxy }

# binding present?
$bindings = & $appcmd list site "$siteName" /text:bindings 2>&1
$httpsBindingOk = ($bindings -match 'https.*:8443:')
J ($httpsBindingOk ? 'info' : 'warn') 'site.bind' 'HTTPS binding check' @{ ok=$httpsBindingOk; bindings=$bindings }

# ARR proxy enabled?
$proxyGet = & $appcmd list config -section:system.webServer/proxy 2>&1
$arrEnabled = ($proxyGet -match 'enabled.*True')
J ($arrEnabled ? 'info' : 'warn') 'proxy.section' 'ARR proxy section' @{ enabled=$arrEnabled; raw=$proxyGet }

# runtime probes (decide rewrite ok by behavior)
function Probe($url,$skipTls=$true) {
  $o=[ordered]@{ url=$url; ok=$false; code=0; why=''; sample=''; headers=@{} }
  try {
    $r = Invoke-WebRequest -Uri $url -TimeoutSec 8 -SkipCertificateCheck:$skipTls
    $o.ok   = ($r.StatusCode -eq 200)
    $o.code = $r.StatusCode
    $o.sample = ($r.Content.Substring(0, [Math]::Min(200, $r.Content.Length)))
    $hdr = @{}; foreach($k in $r.Headers.Keys){ $hdr[$k] = $r.Headers[$k] }
    $o.headers = $hdr
  } catch { $o.ok=$false; $o.code=-1; $o.why="$_" }
  return $o
}

$pHealthGw = Probe "https://localhost:8443/healthz"
$pRootGw   = Probe "https://localhost:8443/"
$pRootA    = Probe ("http://127.0.0.1:{0}/" -f $portA) $false

# infer rewrite working if: healthz OK AND either X-BlueGreen:A header present on / via gateway or A root ok
$slotHint = ''
if ($pRootGw.headers.ContainsKey('X-BlueGreen')) { $slotHint = $pRootGw.headers['X-BlueGreen'] }
$rewriteRuntimeOk = ($pHealthGw.ok -and $pRootGw.ok -and ($slotHint -eq 'A' -or $pRootA.ok))

# summary
$summary = [ordered]@{
  https_binding_ok          = $httpsBindingOk
  arr_proxy_enabled         = ($hasProxy -and $arrEnabled)
  rewrite_module_present    = $hasRewrite
  rewrite_runtime_ok        = $rewriteRuntimeOk
  gateway_health_ok         = $pHealthGw.ok
  probe_root_via_gateway_ok = $pRootGw.ok
  slot_hint_header          = $slotHint
  directA_ok                = $pRootA.ok
  upstream_port             = $portA
  log_file                  = $logFile
  duration_ms               = [int]((Get-Date) - $start).TotalMilliseconds
  ready_for_S4_3            = ($httpsBindingOk -and $hasProxy -and $arrEnabled -and $rewriteRuntimeOk)
}
J (($summary.ready_for_S4_3) ? 'info' : 'warn') 'summary' 'S4.2d finalize summary' $summary

$banner = if ($summary.ready_for_S4_3) { 'READY' } else { 'NEEDS_ACTION' }
Write-Host ("`n== S4.2d Health: {0} (see {1})" -f $banner, $logFile)
