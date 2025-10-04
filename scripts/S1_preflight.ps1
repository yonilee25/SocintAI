param()

$ErrorActionPreference = 'Stop'
$reqId = [guid]::NewGuid().ToString()
$start = Get-Date

function Write-Log {
    param([string]$level,[string]$op,[string]$msg,[hashtable]$data=@{})
    $o = [ordered]@{
        ts    = (Get-Date).ToString('o')
        level = $level
        step  = 'S1.preflight'
        req_id= $reqId
        op    = $op
        msg   = $msg
        data  = $data
    }
    $json = $o | ConvertTo-Json -Compress -Depth 6
    Write-Host $json
    Add-Content -LiteralPath $global:logFile -Value $json
}

# --- setup log path relative to repo root ---
$repoRoot = Split-Path $PSScriptRoot -Parent
$logDir   = Join-Path $repoRoot 'logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
$logFile  = Join-Path $logDir ("S1_preflight_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))

Write-Log 'info' 'start' 'Starting S1 preflight' @{ user=$env:UserName; machine=$env:COMPUTERNAME }

# --- admin check ---
$IsElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Write-Log 'info' 'env.admin' ('PowerShell elevated: {0}' -f $IsElevated) @{ elevated=$IsElevated }

# --- node check (v18+) ---
$nodeVersion = $null
try {
    $nodeVersion = (node -v) 2>$null
    $nodeOk = $nodeVersion -match '^v(1[89]|2[0-9])\.'
    Write-Log 'info' 'env.node' ('node version: {0}' -f $nodeVersion) @{ node=$nodeVersion; ok=$nodeOk }
} catch {
    $nodeOk = $false
    Write-Log 'warn' 'env.node' 'node not found in PATH' @{}
}

# --- IIS features (read-only) ---
$featureNames = @('IIS-WebServerRole','IIS-WebServer','IIS-ManagementConsole','IIS-HttpRedirect','IIS-ISAPIExtensions','IIS-ISAPIFilter')
$featureStates = @{}
foreach ($f in $featureNames) {
    try {
        $state = (Get-WindowsOptionalFeature -Online -FeatureName $f -ErrorAction Stop).State
        $featureStates[$f] = $state
    } catch {
        $featureStates[$f] = 'Unknown'
    }
}
Write-Log 'info' 'env.iisFeatures' 'IIS feature states collected' @{ features=$featureStates }
$iisEnabled = ($featureStates['IIS-WebServer'] -eq 'Enabled' -or $featureStates['IIS-WebServerRole'] -eq 'Enabled')

# --- URL Rewrite detection (registry/file/module) ---
$rewriteReg = Get-Item 'HKLM:\SOFTWARE\Microsoft\IIS Extensions' -ErrorAction SilentlyContinue |
    Get-ChildItem -ErrorAction SilentlyContinue |
    Where-Object { $_.PSChildName -like '*URL*Rewrite*' }

$rewritePaths = @()
$rewritePaths += (Join-Path $env:windir 'System32\inetsrv\rewrite.dll')
if ($env:ProgramFiles) { $rewritePaths += (Join-Path $env:ProgramFiles 'IIS\URL Rewrite\rewrite.dll') }
if (${env:ProgramFiles(x86)}) { $rewritePaths += (Join-Path ${env:ProgramFiles(x86)} 'IIS\URL Rewrite\rewrite.dll') }

$rewriteDllFound = ($rewritePaths | Where-Object { Test-Path $_ } | Measure-Object).Count -gt 0
$rewritePresent = $rewriteDllFound -or $null -ne $rewriteReg
Write-Log 'info' 'env.urlrewrite' ('URL Rewrite present: {0}' -f $rewritePresent) @{
    registry = $rewriteReg.PSChildName
    dllFound = $rewriteDllFound
}

# --- ARR detection (registry + ProxyModule) ---
$arrReg = Get-Item 'HKLM:\SOFTWARE\Microsoft\IIS Extensions' -ErrorAction SilentlyContinue |
    Get-ChildItem -ErrorAction SilentlyContinue |
    Where-Object { $_.PSChildName -like '*Request Routing*' -or $_.PSChildName -like '*Application Request Routing*' }

$inetsrv = Join-Path $env:windir 'System32\inetsrv'
$proxyModulePresent = $false
try {
    if (Test-Path $inetsrv) {
        $modules = & "$inetsrv\appcmd.exe" list modules 2>$null
        if ($modules) {
            $proxyModulePresent = ($modules | Select-String -SimpleMatch 'ProxyModule') -ne $null
        }
    }
} catch { }
$arrPresent = ($arrReg -ne $null) -or $proxyModulePresent
Write-Log 'info' 'env.arr' ('ARR present: {0}' -f $arrPresent) @{
    registry = $arrReg.PSChildName
    proxyModule = $proxyModulePresent
}

# --- Port 8443 status (free = good) ---
$portInUse = $false
try {
    $conn = Get-NetTCPConnection -LocalPort 8443 -State Listen -ErrorAction SilentlyContinue
    $portInUse = $conn -ne $null
} catch { }
Write-Log 'info' 'env.port' ('Port 8443 listening: {0}' -f $portInUse) @{ in_use=$portInUse }

# --- Blue/Green directories existence ---
$bgA = 'C:\inetpub\SocintFrontend_A'
$bgB = 'C:\inetpub\SocintFrontend_B'
$bgAExists = Test-Path $bgA
$bgBExists = Test-Path $bgB
Write-Log 'info' 'env.bluegreen' 'Blue-green directories existence' @{ A=$bgAExists; B=$bgBExists }

# --- summary ---
$ready = $iisEnabled -and $rewritePresent -and $arrPresent -and $nodeOk -and (-not $portInUse)
$summary = [ordered]@{
    iis_enabled      = $iisEnabled
    url_rewrite      = $rewritePresent
    arr              = $arrPresent
    node_v18_plus    = $nodeOk
    port_8443_free   = (-not $portInUse)
    blue_green_dirs  = @{ A=$bgAExists; B=$bgBExists }
    elevated_shell   = $IsElevated
    log_file         = $logFile
    duration_ms      = [int]((Get-Date) - $start).TotalMilliseconds
    ready_for_S2     = $ready
}
Write-Log ($ready ? 'info' : 'warn') 'summary' 'S1 preflight summary' $summary

$banner = if ($ready) { 'READY' } else { 'NEEDS_ACTION' }
Write-Host ("`n== S1 Health: {0} (see {1})" -f $banner, $logFile)
