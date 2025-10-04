param()

$ErrorActionPreference = 'Stop'
$reqId  = [guid]::NewGuid().ToString()
$start  = Get-Date

# paths
$repoRoot = Split-Path $PSScriptRoot -Parent
if (-not $repoRoot) { $repoRoot = 'C:\SocintAI' }
$logDir = Join-Path $repoRoot 'logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
$logFile = Join-Path $logDir ("S4_arr_finalize_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))

$siteName = 'SocintGateway'
$appcmd   = Join-Path $env:WINDIR 'System32\inetsrv\appcmd.exe'
$state    = Join-Path (Join-Path $repoRoot 'env') 'bg_ports.json'

function J { param($lvl,$op,$msg,$data=@{}) 
  $o=[ordered]@{ts=(Get-Date).ToString('o');level=$lvl;step='S4.arr_finalize';req_id=$reqId;op=$op;msg=$msg;data=$data}
  $json=$o|ConvertTo-Json -Compress -Depth 15; Write-Host $json; Add-Content -LiteralPath $logFile -Value $json
}

J 'info' 'start' 'Normalizing ARR detection using runtime proof' @{ user=$env:UserName; machine=$env:COMPUTERNAME }

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

# ports
$ports = Get-Content $state | ConvertFrom-Json
$portA = [int]$ports.A.port

# 1) ensure proxy section is enabled at apphost
$setOut = & $appcmd set config -section:system.webServer/proxy /enabled:"True" /preserveHostHeader:"True" /reverseRewriteHostInResponseHeaders:"True" /commit:apphost 2>&1
$getOut = & $appcmd list config -section:system.webServer/proxy 2>&1
$arrSectionPresent = ($getOut -match '<proxy' -or $getOut -match 'enabled.*True')
J ($arrSectionPresent ? 'info' : 'warn') 'proxy.section' 'ARR proxy section' @{ present=$arrSectionPresent; raw=$getOut }

# 2) modules snapshot (ProxyModule may not list on some builds; runtime will decide)
$mods = & $appcmd list modules 2>&1
$proxyModuleSeen = ($mods -match 'ProxyModule')
$rewriteModuleSeen = ($mods -match 'RewriteModule')
J 'info' 'modules' 'Module presence' @{ proxyModule=$proxyModuleSeen; rewriteModule=$rewriteModuleSeen }

# 3) binding check
$bindings = & $appcmd list site "$siteName" /text:bindings 2>&1
$httpsBindingOk = ($bindings -match 'https.*:8443:')
J ($httpsBindingOk ? 'info' : 'warn') 'site.bind' 'HTTPS binding check' @{ ok=$httpsBindingOk; bindings=$bindings }

# 4) runtime probes decide "rewrite_runtime_ok"
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
$pHealth = Probe "https://localhost:8443/healthz"
$pRootGw = Probe "https://localhost:8443/"
$pRootA  = Probe ("http://127.0.0.1:{0}/" -f $portA) $false

$slotHint = ''; if ($pRootGw.headers.ContainsKey('X-BlueGreen')) { $slotHint = $pRootGw.headers['X-BlueGreen'] }
$rewriteRuntimeOk = ($pHealth.ok -and $pRootGw.ok -and ($slotHint -eq 'A' -or $pRootA.ok))

# 5) final readiness (runtime-first)
$ready = ($httpsBindingOk -and $arrSectionPresent -and $rewriteRuntimeOk)

# summary
$summary = [ordered]@{
  https_binding_ok          = $httpsBindingOk
  arr_section_present       = $arrSectionPresent
  proxy_module_seen         = $proxyModuleSeen
  rewrite_module_present    = $rewriteModuleSeen
  rewrite_runtime_ok        = $rewriteRuntimeOk
  gateway_health_ok         = $pHealth.ok
  probe_root_via_gateway_ok = $pRootGw.ok
  slot_hint_header          = $slotHint
  directA_ok                = $pRootA.ok
  upstream_port             = $portA
  log_file                  = $logFile
  duration_ms               = [int]((Get-Date) - $start).TotalMilliseconds
  ready_for_S4_3            = $ready
}
J (($summary.ready_for_S4_3) ? 'info' : 'warn') 'summary' 'S4.2e finalize summary' $summary

$banner = if ($summary.ready_for_S4_3) { 'READY' } else { 'NEEDS_ACTION' }
Write-Host ("`n== S4.2e Health: {0} (see {1})" -f $banner, $logFile)
