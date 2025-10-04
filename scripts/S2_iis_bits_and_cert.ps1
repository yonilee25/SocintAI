param()

$ErrorActionPreference = 'Stop'
$reqId  = [guid]::NewGuid().ToString()
$start  = Get-Date

# --- repo + logs ---
$repoRoot = Split-Path $PSScriptRoot -Parent
if (-not $repoRoot) { $repoRoot = 'C:\SocintAI' }
$logDir = Join-Path $repoRoot 'logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
$logFile = Join-Path $logDir ("S2_iis_bits_and_cert_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))
$depsDir = Join-Path $repoRoot 'deps'
if (-not (Test-Path $depsDir)) { New-Item -ItemType Directory -Force -Path $depsDir | Out-Null }

function Write-Log {
  param([string]$level,[string]$op,[string]$msg,[hashtable]$data=@{})
  $o = [ordered]@{
    ts     = (Get-Date).ToString('o')
    level  = $level
    step   = 'S2.iis_bits_and_cert'
    req_id = $reqId
    op     = $op
    msg    = $msg
    data   = $data
  }
  $json = $o | ConvertTo-Json -Compress -Depth 8
  Write-Host $json
  Add-Content -LiteralPath $logFile -Value $json
}

Write-Log 'info' 'start' 'Starting S2 install (URL Rewrite, ARR, WebSockets, cert)' @{ user=$env:UserName; machine=$env:COMPUTERNAME; repoRoot=$repoRoot }

# --- ensure admin (self-elevate) ---
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

# --- helpers ---
function Ensure-Feature {
  param([string]$name)
  try {
    $state = (Get-WindowsOptionalFeature -Online -FeatureName $name -ErrorAction Stop).State
    if ("$state" -ne 'Enabled') {
      Write-Log 'info' 'feature.enable' "Enabling Windows feature: $name" @{ feature=$name; prev_state="$state" }
      Enable-WindowsOptionalFeature -Online -FeatureName $name -All -NoRestart -ErrorAction Stop | Out-Null
      return @{changed=$true; name=$name}
    } else {
      Write-Log 'info' 'feature.skip' "Feature already enabled: $name" @{ feature=$name }
      return @{changed=$false; name=$name}
    }
  } catch {
    Write-Log 'error' 'feature.error' "Failed enabling feature: $name" @{ feature=$name; err="$_" }
    throw
  }
}

function Install-MSI {
  param([string]$url,[string]$outFile)
  if (-not (Test-Path $outFile)) {
    Write-Log 'info' 'download' "Downloading $url" @{ to=$outFile }
    Invoke-WebRequest -Uri $url -OutFile $outFile -UseBasicParsing
  } else {
    Write-Log 'info' 'download.skip' 'Installer already cached' @{ file=$outFile }
  }
  Write-Log 'info' 'msi.exec' "Installing $outFile (silent)" @{}
  $p = Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/i',"`"$outFile`"","/qn","/norestart") -Wait -PassThru
  $code = $p.ExitCode
  $needsRestart = ($code -eq 3010)
  Write-Log ($needsRestart ? 'warn' : 'info') 'msi.exit' "msiexec exit code: $code" @{ file=$outFile; restart_required=$needsRestart }
  return @{ exit=$code; restart=$needsRestart }
}

function Test-UrlRewriteInstalled {
  $dll = Join-Path $env:windir 'System32\inetsrv\rewrite.dll'
  $reg = $null
  try {
    $reg = Get-Item 'HKLM:\SOFTWARE\Microsoft\IIS Extensions' -ErrorAction SilentlyContinue |
           Get-ChildItem -ErrorAction SilentlyContinue |
           Where-Object { $_.PSChildName -like '*URL*Rewrite*' }
  } catch {}
  return ((Test-Path $dll) -or ($null -ne $reg))
}

function Test-ArrInstalled {
  $proxyModulePresent = $false
  $inetsrv = Join-Path $env:windir 'System32\inetsrv'
  try {
    if (Test-Path $inetsrv) {
      $mods = & "$inetsrv\appcmd.exe" list modules 2>$null
      if ($mods) { $proxyModulePresent = ($mods | Select-String -SimpleMatch 'ProxyModule') -ne $null }
    }
  } catch {}
  $reg = $null
  try {
    $reg = Get-Item 'HKLM:\SOFTWARE\Microsoft\IIS Extensions' -ErrorAction SilentlyContinue |
           Get-ChildItem -ErrorAction SilentlyContinue |
           Where-Object { $_.PSChildName -like '*Application Request Routing*' -or $_.PSChildName -like '*Request Routing*' }
  } catch {}
  return ($proxyModulePresent -or ($null -ne $reg))
}

# --- ensure core IIS features used by our proxy path ---
$changed = @()
$changed += Ensure-Feature 'IIS-WebServer'
$changed += Ensure-Feature 'IIS-ManagementConsole'
$changed += Ensure-Feature 'IIS-HttpRedirect'
$changed += Ensure-Feature 'IIS-ISAPIExtensions'
$changed += Ensure-Feature 'IIS-ISAPIFilter'
$changed += Ensure-Feature 'IIS-WebSockets'   # recommended for Node proxy

# --- install URL Rewrite 2.1 (x64) if missing ---
$rewriteOk = Test-UrlRewriteInstalled
if (-not $rewriteOk) {
  $rewriteUrl = 'https://download.microsoft.com/download/1/2/8/128E2E22-C1B9-44A4-BE2A-5859ED1D4592/rewrite_amd64_en-US.msi'
  $rewriteMsi = Join-Path $depsDir 'rewrite_amd64_en-US.msi'
  $res = Install-MSI -url $rewriteUrl -outFile $rewriteMsi
  if ($res.restart) { $global:RestartNeeded = $true }
  Start-Sleep -Seconds 2
  $rewriteOk = Test-UrlRewriteInstalled
}
Write-Log ($rewriteOk ? 'info' : 'warn') 'check.urlrewrite' "URL Rewrite installed: $rewriteOk" @{ installed=$rewriteOk }

# --- install ARR 3.0 (x64) if missing (depends on URL Rewrite) ---
$arrOk = Test-ArrInstalled
if (-not $arrOk) {
  # official fwlink from IIS page (x64)
  $arrUrl = 'https://go.microsoft.com/fwlink/?LinkID=615136'
  $arrMsi = Join-Path $depsDir 'requestRouter_amd64.msi'
  Write-Log 'info' 'note' 'ARR depends on URL Rewrite; installing ARR after Rewrite' @{}
  $res = Install-MSI -url $arrUrl -outFile $arrMsi
  if ($res.restart) { $global:RestartNeeded = $true }
  Start-Sleep -Seconds 2
  $arrOk = Test-ArrInstalled
}
Write-Log ($arrOk ? 'info' : 'warn') 'check.arr' "ARR installed: $arrOk" @{ installed=$arrOk }

# --- restart IIS service just to load modules ---
try { iisreset /restart | Out-Null } catch {}

# --- cert: ensure a self-signed cert for https://localhost:8443 ---
$certFriendly = 'SocintAI Local Dev 8443'
$cert = Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.FriendlyName -eq $certFriendly -and $_.Subject -match 'CN=localhost' } | Sort-Object NotAfter -Descending | Select-Object -First 1
if (-not $cert) {
  Write-Log 'info' 'cert.create' 'Creating self-signed certificate for CN=localhost' @{ friendly=$certFriendly }
  $cert = New-SelfSignedCertificate -DnsName 'localhost' -FriendlyName $certFriendly `
          -CertStoreLocation 'Cert:\LocalMachine\My' -KeyAlgorithm RSA -KeyLength 2048 -HashAlgorithm SHA256 `
          -KeyExportPolicy Exportable -NotAfter (Get-Date).AddYears(2)
}
$thumb = $cert.Thumbprint
Write-Log 'info' 'cert.present' 'Dev certificate present' @{ friendly=$certFriendly; thumbprint=$thumb; notAfter=$cert.NotAfter }

# --- port 8443 free? (we will bind it in S4) ---
$portInUse = $false
try {
  $conn = Get-NetTCPConnection -LocalPort 8443 -State Listen -ErrorAction SilentlyContinue
  $portInUse = $conn -ne $null
} catch {}
$portFree = -not $portInUse

# --- websockets state ---
$wsState = (Get-WindowsOptionalFeature -Online -FeatureName 'IIS-WebSockets' -ErrorAction SilentlyContinue).State
$wsEnabled = ("$wsState" -eq 'Enabled')

# --- summary ---
$summary = [ordered]@{
  url_rewrite_installed = $rewriteOk
  arr_installed         = $arrOk
  websockets_enabled    = $wsEnabled
  cert_thumbprint       = $thumb
  port_8443_free        = $portFree
  restart_required      = [bool]$global:RestartNeeded
  log_file              = $logFile
  duration_ms           = [int]((Get-Date) - $start).TotalMilliseconds
  ready_for_S3          = ($rewriteOk -and $arrOk -and $wsEnabled -and $thumb -and $portFree)
}
Write-Log (($summary.ready_for_S3) ? 'info' : 'warn') 'summary' 'S2 install summary' $summary

$banner = if ($summary.ready_for_S3) { 'READY' } else { 'NEEDS_ACTION' }
Write-Host ("`n== S2 Health: {0} (see {1})" -f $banner, $logFile)
