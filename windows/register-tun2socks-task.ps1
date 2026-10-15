param(
    [switch]$Unregister
)

$ErrorActionPreference = 'Stop'

# Keep this filename in sync with the watcher script beside this installer.
$TaskName = 'Tun2Socks Wi-Fi Watcher'
$WatcherPath = Join-Path $PSScriptRoot 'tun2socks.ps1'

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principalCheck = [Security.Principal.WindowsPrincipal]::new($identity)
$isAdministrator = $principalCheck.IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)

if (-not $isAdministrator) {
    throw 'Open PowerShell as Administrator and run this installer again.'
}

if ($Unregister) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "Removed scheduled task '$TaskName' if it existed."
    exit 0
}

if (-not (Test-Path -LiteralPath $WatcherPath -PathType Leaf)) {
    throw "Watcher script not found: $WatcherPath"
}

# Use the same PowerShell edition that is running this installer.
$PowerShellExe = (Get-Process -Id $PID).Path
if (-not $PowerShellExe) {
    throw 'Could not determine the current PowerShell executable.'
}

$UserName = $identity.Name
$LogPath = Join-Path $PSScriptRoot 'turn2socks.log'
$QuotedWatcherPath = "'" + $WatcherPath.Replace("'", "''") + "'"
$QuotedLogPath = "'" + $LogPath.Replace("'", "''") + "'"
$Command = "& $QuotedWatcherPath *> $QuotedLogPath"
$ActionArguments = '-NoLogo -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -Command "{0}"' -f $Command

$action = New-ScheduledTaskAction `
    -Execute $PowerShellExe `
    -Argument $ActionArguments `
    -WorkingDirectory $PSScriptRoot

$trigger = New-ScheduledTaskTrigger -AtLogOn -User $UserName
$taskPrincipal = New-ScheduledTaskPrincipal `
    -UserId $UserName `
    -LogonType Interactive `
    -RunLevel Highest

$settings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries

$task = New-ScheduledTask `
    -Action $action `
    -Trigger $trigger `
    -Principal $taskPrincipal `
    -Settings $settings `
    -Description 'Starts the tun2socks Wi-Fi watcher when this user logs in.'

Register-ScheduledTask -TaskName $TaskName -InputObject $task -Force | Out-Null

Write-Host "Registered '$TaskName' for $UserName."
Write-Host "Watcher: $WatcherPath"
Write-Host "Watcher output: $LogPath"
Write-Host 'It will start at your next login. To start it now, run:'
Write-Host "  Start-ScheduledTask -TaskName '$TaskName'"
Write-Host 'To remove it, run this installer with -Unregister.'
