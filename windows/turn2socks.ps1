function Import-TunnelConfig {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Configuration file not found: $Path"
    }
    $config = @{}

    foreach ($line in Get-Content -LiteralPath $Path) {
        $line = $line.Trim()

        if (-not $line -or $line.StartsWith('#')) {
            continue
        }

        if ($line -notmatch '^([a-z][a-z0-9_]*)\s*:\s*(.*?)\s*$') {
            throw "Invalid config line: $line"
        }

        $key = $Matches[1]
        $value = $Matches[2].Trim()

        if ($config.ContainsKey($key)) {
            throw "Duplicate config key: $key"
        }

        if ($value.StartsWith('"') -and $value.EndsWith('"')) {
            $value = ConvertFrom-Json -InputObject $value
        } elseif ($value.StartsWith("'") -and $value.EndsWith("'")) {
            $value = $value.Substring(1, $value.Length - 2).Replace("''", "'")
        } else {
            $value = ($value -replace '\s+#.*$', '').Trim()
        }
        $config[$key] = [string]$value
    }

    $requiredKeys = @(
        'target_ssid',
        'tun_name',
        'tun_address',
        'tun_gateway',
        'proxy'
    )

    foreach ($key in $requiredKeys) {
        if (-not $config.ContainsKey($key) -or
                [string]::IsNullOrWhiteSpace($config[$key])) {
            throw "Missing or empty config value: $key"
        }
    }

    foreach ($key in @('dns_primary', 'dns_second')) {
        if (-not $config.ContainsKey($key)) {
            $config[$key] = ''
        }
    }

    return $config

}

$configPath = [System.IO.Path]::ChangeExtension($PSCommandPath, '.yaml')
$config = Import-TunnelConfig -Path $configPath

$TargetSSID = $config['target_ssid']
$TunName    = $config['tun_name']
$TunAddress = $config['tun_address']
$TunGateway = $config['tun_gateway']
$DnsPrimary = $config['dns_primary']
$DnsSecond  = $config['dns_second']
$Proxy      = $config['proxy']
$Tun2Socks  = Join-Path $PSScriptRoot 'tun2socks.exe'
# -------------------------

$ErrorActionPreference = 'Stop'
$script:ProxyProcess = $null
$script:TunnelActive = $false

if (-not ([Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent()
)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script as Administrator.'
}

if (-not (Test-Path $Tun2Socks)) {
    throw "Could not find tun2socks.exe: $Tun2Socks"
}

wevtutil sl Microsoft-Windows-WLAN-AutoConfig/Operational /e:true

Add-Type -AssemblyName System.Diagnostics.EventLog

$eventLogAssembly = [System.Diagnostics.Eventing.Reader.EventLogWatcher].Assembly.Location
$consoleAssembly = [System.Console].Assembly.Location

Add-Type -ReferencedAssemblies @(
    $eventLogAssembly,
    $consoleAssembly
) -TypeDefinition @'
using System;
using System.Diagnostics.Eventing.Reader;

public static class WlanTunnelSignal {
    private static EventLogWatcher watcher;

    public static string TargetSSID = "";
    public static volatile bool Connected = false;
    public static volatile bool Changed = false;

    public static void Start() {
        var query = new EventLogQuery(
            "Microsoft-Windows-WLAN-AutoConfig/Operational",
            PathType.LogName,
            "*[System[(EventID=8001 or EventID=8003)]]"
        );

        watcher = new EventLogWatcher(query);
        watcher.EventRecordWritten += (sender, e) => {
            if (e.EventException != null) {
                System.Console.WriteLine("WLAN watcher error: " + e.EventException.Message);
                return;
            }

            if (e.EventRecord == null) return;

            using (var record = e.EventRecord) {
                string message = record.FormatDescription();
                bool isTarget = false;

                foreach (string line in message.Split(
                    new[] { '\r', '\n' },
                    StringSplitOptions.RemoveEmptyEntries
                )) {
                    int marker = line.IndexOf("SSID:", StringComparison.OrdinalIgnoreCase);
                    if (marker >= 0 &&
                        line.Substring(marker + 5).Trim().Equals(
                            TargetSSID, StringComparison.OrdinalIgnoreCase
                        )) {
                        isTarget = true;
                        break;
                    }
                }

                System.Console.WriteLine(
                    "WLAN event " + record.Id +
                    (isTarget ? " for target SSID" : " for another SSID")
                );

                if (isTarget && record.Id == 8001) {
                    Connected = true;
                    Changed = true;
                } else if (isTarget && record.Id == 8003) {
                    Connected = false;
                    Changed = true;
                }
            }
        };

        watcher.Enabled = true;
    }

    public static void Stop() {
        if (watcher != null) {
            watcher.Enabled = false;
            watcher.Dispose();
            watcher = null;
        }
    }
}
'@

[WlanTunnelSignal]::TargetSSID = $TargetSSID

function Remove-TunnelRoute {
    Get-NetRoute -InterfaceAlias $TunName `
        -DestinationPrefix '0.0.0.0/0' `
        -ErrorAction SilentlyContinue |
            Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
}

function Stop-Tunnel {
    Remove-TunnelRoute

    if ($script:ProxyProcess) {
        try {
            if (-not $script:ProxyProcess.HasExited) {
                Stop-Process -Id $script:ProxyProcess.Id -Force -ErrorAction SilentlyContinue
            }
        } catch {
            # The process may already have exited.
        }
    }

    $script:ProxyProcess = $null
    $script:TunnelActive = $false
    Write-Host 'Tunnel stopped.'
}

function Start-Tunnel {
    if ($script:TunnelActive) { return }

    Write-Host "Connected to '$TargetSSID'; starting tun2socks..."
    Remove-TunnelRoute

    $script:ProxyProcess = Start-Process -FilePath $Tun2Socks `
        -ArgumentList @('-d', $TunName, '-p', "socks5://$Proxy") `
        -PassThru -NoNewWindow

    $adapter = $null
    for ($i = 0; $i -lt 15; $i++) {
        Start-Sleep -Seconds 1
        $adapter = Get-NetAdapter -Name $TunName -ErrorAction SilentlyContinue
        if ($adapter) { break }

        if ($script:ProxyProcess.HasExited) {
            throw "tun2socks exited with code $($script:ProxyProcess.ExitCode)."
        }
    }

    if (-not $adapter) {
        throw "$TunName did not appear."
    }

    netsh interface ipv4 set address name="$TunName" `
        source=static addr=$TunAddress mask=255.255.255.0 gateway=none >$null 2>&1
    if ($LASTEXITCODE -ne 0) { throw 'Failed to set the tunnel address.' }

    $dnsServers = @()
    foreach ($server in @($DnsPrimary, $DnsSecond)) {
        if (-not [string]::IsNullOrWhiteSpace($server)) {
            $dnsServers += $server
        }
    }

    if ($dnsServers.Count -eq 0) {
        # Reset the interface to automatic DNS configuration.
        netsh interface ipv4 set dnsservers name="$TunName" `
            source=dhcp >$null 2>&1
        if ($LASTEXITCODE -ne 0) { throw 'Failed to reset DNS to automatic.' }
    } else {
        netsh interface ipv4 set dnsservers name="$TunName" `
            source=static address=$dnsServers[0] register=none validate=no >$null 2>&1
        if ($LASTEXITCODE -ne 0) { throw 'Failed to set primary DNS.' }

        for ($i = 1; $i -lt $dnsServers.Count; $i++) {
            netsh interface ipv4 add dnsservers name="$TunName" `
                address=$dnsServers[$i] index=$($i + 1) validate=no >$null 2>&1
            if ($LASTEXITCODE -ne 0) { throw "Failed to add DNS server $($dnsServers[$i])." }
        }
    }

    netsh interface ipv4 add route 0.0.0.0/0 `
        "$TunName" $TunGateway metric=1 >$null 2>&1
    if ($LASTEXITCODE -ne 0) { throw 'Failed to add the tunnel route.' }

    ipconfig /flushdns >$null 2>&1
    $script:TunnelActive = $true
    Write-Host 'Tunnel is up.'
}

function Sync-TunnelToSSID {
    if ([WlanTunnelSignal]::Connected) {
        if (-not $script:TunnelActive) {
            Start-Tunnel
        }
    } elseif ($script:TunnelActive -or $script:ProxyProcess) {
        Stop-Tunnel
    }
}

try {
    # Infer the initial state from the newest logged event for this SSID.
    $latestTargetEvent = Get-WinEvent -FilterHashtable @{
        LogName = 'Microsoft-Windows-WLAN-AutoConfig/Operational'
        Id      = 8001, 8003
    } -MaxEvents 100 |
            Where-Object {
                $_.Message -match "(?im)^\s*(Network )?SSID:\s*$([regex]::Escape($TargetSSID))\s*$"
            } |
            Select-Object -First 1

    [WlanTunnelSignal]::Connected = (
    $latestTargetEvent -and $latestTargetEvent.Id -eq 8001
    )

    [WlanTunnelSignal]::Start()
    Sync-TunnelToSSID

    Write-Host "Watching for '$TargetSSID'. Press Ctrl+C to exit."

    while ($true) {
        if ([WlanTunnelSignal]::Changed) {
            [WlanTunnelSignal]::Changed = $false
            Start-Sleep -Milliseconds 800

            try {
                Sync-TunnelToSSID
            } catch {
                Write-Error $_
                Stop-Tunnel
            }
        }

        Start-Sleep -Milliseconds 250
    }
}
finally {
    [WlanTunnelSignal]::Stop()
    Stop-Tunnel
}