param()

$ErrorActionPreference = 'Stop'
$script:reqId  = [guid]::NewGuid().ToString()
$script:start  = Get-Date

# determine repo root & log path
$script:repoRoot = Split-Path $PSScriptRoot -Parent
if (-not $script:repoRoot) { $script:repoRoot = "C:\SocintAI" }
$logDir = Join-Path $script:repoRoot 'logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
$script:logFile = Join-Path $logDir ("S1_upgrade_pwsh_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))

function Write-Log {
    param([string]$level,[string]$op,[string]$msg,[hashtable]$data=@{})
    $o = [ordered]@{
        ts     = (Get-Date).ToString('o')
        level  = $level
        step   = 'S1.upgradePwsh'
        req_id = $script:reqId
        op     = $op
        msg    = $msg
        data   = $data
    }
    $json = $o | ConvertTo-Json -Compress -Depth 6
    Write-Host $json
    Add-Content -LiteralPath $script:logFile -Value $json
}

Write-Log 'info' 'start' 'Starting PowerShell 7 upgrade' @{ user=$env:UserName; machine=$env:COMPUTERNAME; repoRoot=$script:repoRoot }

# --- admin check & self-elevate ---
$IsElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
               ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Write-Log 'info' 'env.admin' ('Elevated: {0}' -f $IsElevated) @{ elevated=$IsElevated }
if (-not $IsElevated) {
  Write-Log 'info' 'env.relaunch' 'Relaunching with elevation' @{}
  $args = @('-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"")
  Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $args
  exit
}

# --- detect existing pwsh ---
$pwshCmd='pwsh'
$pwshVersion = $null
$pwshFound = $false
try {
  $pv = & $pwshCmd -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' 2>$null
  if ($LASTEXITCODE -eq 0 -and $pv) { $pwshVersion=$pv.Trim(); $pwshFound=$true }
} catch {}
Write-Log 'info' 'env.pwsh' ('Existing pwsh found: {0}' -f $pwshFound) @{ version=$pwshVersion }

# --- winget availability ---
$wingetOk = $false
$wingetVer = $null
try {
   $wingetVer = (winget --version) 2>$null
   if ($LASTEXITCODE -eq 0) { $wingetOk = $true }
} catch {}
Write-Log 'info' 'env.winget' ('winget available: {0}' -f $wingetOk) @{ version=$wingetVer }

# --- install via winget if needed ---
$installAttempted=$false
if (-not $pwshFound) {
  if ($wingetOk) {
    Write-Log 'info' 'install.winget' 'Installing Microsoft.PowerShell via winget' @{ id='Microsoft.PowerShell' }
    $installAttempted=$true
    $args = @('install','--id','Microsoft.PowerShell','--source','winget','--accept-package-agreements','--accept-source-agreements','--scope','machine','--silent')
    winget @args | ForEach-Object { Write-Log 'info' 'install.winget.out' 'winget output' @{ line=$_ } }
  } else {
    Write-Log 'warn' 'install.manual' 'winget not available; install MSI x64 from https://aka.ms/PowerShell-Release?tag=stable' @{}
  }
}

# --- verify post-install ---
$pwshPath = 'C:\Program Files\PowerShell\7\pwsh.exe'
$pwshPathExists = Test-Path $pwshPath
$pwshVersion2 = $pwshVersion
if ($pwshPathExists) {
  try {
     $pv2 = & $pwshPath -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'
     if ($LASTEXITCODE -eq 0) { $pwshVersion2 = $pv2.Trim(); $pwshFound = $true }
  } catch {}
}
Write-Log 'info' 'verify.pwsh' 'Post-install verify' @{ path=$pwshPath; exists=$pwshPathExists; version=$pwshVersion2 }

# --- convenience alias for current session ---
try { Set-Alias -Name pwsh -Value $pwshPath -Scope Global -ErrorAction SilentlyContinue } catch {}

# --- health: require >= 7.2 ---
$verOk = $false
try {
   if ($pwshVersion2) {
     $parts = $pwshVersion2.Split('.')
     if ($parts.Length -ge 2) {
       $major = [int]$parts[0]; $minor=[int]$parts[1]
       $verOk = ($major -ge 8) -or ($major -ge 7 -and $minor -ge 2)
     }
   }
} catch {}

$summary = [ordered]@{
  pwsh_installed     = $pwshFound
  pwsh_path          = $pwshPath
  pwsh_version       = $pwshVersion2
  version_ok         = $verOk
  winget_available   = $wingetOk
  install_attempted  = $installAttempted
  log_file           = $script:logFile
  duration_ms        = [int]((Get-Date) - $script:start).TotalMilliseconds
  ready_for_S1_rerun = ($pwshFound -and $verOk)
}

$level = 'warn'; if ($summary.ready_for_S1_rerun) { $level = 'info' }
Write-Log $level 'summary' 'S1 Upgrade PowerShell summary' $summary

Write-Host "`n== S1 Upgrade Health: " + ($(if($summary.ready_for_S1_rerun){'READY'}else{'NEEDS_ACTION'})) + " (see $($script:logFile))"
