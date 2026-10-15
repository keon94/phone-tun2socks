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
        'ssid',
        'tun_name',
        'tun_address',
        'proxy'
    )

    foreach ($key in $requiredKeys) {
        if (-not $config.ContainsKey($key) -or
                [string]::IsNullOrWhiteSpace($config[$key])) {
            throw "Missing or empty config value: $key"
        }
    }

    foreach ($key in @('dns_primary', 'dns_secondary')) {
        if (-not $config.ContainsKey($key)) {
            $config[$key] = ''
        }
    }

    return $config

}

function ConvertFrom-TunAddressCidr {
    param(
        [Parameter(Mandatory)]
        [string]$Cidr
    )

    $parts = $Cidr -split '/', 2
    if ($parts.Count -ne 2) {
        throw "tun_address must be CIDR format, such as 10.0.0.2/24."
    }

    $ip = $null
    if (-not [System.Net.IPAddress]::TryParse($parts[0], [ref]$ip) -or
            $ip.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
        throw "tun_address must contain a valid IPv4 address."
    }

    $prefixLength = 0
    if (-not [int]::TryParse($parts[1], [ref]$prefixLength) -or
            $prefixLength -lt 1 -or $prefixLength -gt 32) {
        throw "tun_address must have a valid prefix length from 1 to 32."
    }

    # Preserve the current convention: gateway is the address before the TUN address.
    $gatewayBytes = $ip.GetAddressBytes()
    for ($i = 3; $i -ge 0; $i--) {
        if ($gatewayBytes[$i] -gt 0) {
            $gatewayBytes[$i]--
            break
        }
        $gatewayBytes[$i] = 255
    }

    [pscustomobject]@{
        Address      = $ip.ToString()
        PrefixLength = $prefixLength
        Gateway      = ([System.Net.IPAddress]::new([byte[]]$gatewayBytes)).ToString()
    }
}

function Add-Types {

    Add-Type -AssemblyName System.Diagnostics.EventLog

    if (-not ("WlanTunnelSignal" -as [type])) {

        $eventLogAssembly = [System.Diagnostics.Eventing.Reader.EventLogWatcher].Assembly.Location
        $consoleAssembly = [System.Console].Assembly.Location

        $wlanTunnelSignalSrcPath = Join-Path $PSScriptRoot 'wlanTunnelSignal.cs'

        Add-Type -Path $wlanTunnelSignalSrcPath -ReferencedAssemblies @(
            $eventLogAssembly,
            $consoleAssembly
        )
    }
}

function Get-TunnelDnsServers {
    $configured = @($DnsPrimary, $DnsSecond) |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    if ($configured.Count -gt 0) {
        return $configured
    }

    $profilePattern = '^{0}(?:\s+\d+)?$' -f [regex]::Escape($TargetSSID)

    $profile = Get-NetConnectionProfile -ErrorAction Stop |
            Where-Object { $_.Name -match $profilePattern } |
            Select-Object -First 1

    if (-not $profile) {
        throw "Could not find the active network profile for '$TargetSSID'."
    }

    $servers = @(
    Get-DnsClientServerAddress `
            -InterfaceIndex $profile.InterfaceIndex `
            -AddressFamily IPv4 |
            ForEach-Object { $_.ServerAddresses } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Unique
    )

    if ($servers.Count -eq 0) {
        throw "The '$TargetSSID' interface has no IPv4 DNS servers to inherit."
    }

    Write-Host "Using DNS from '$TargetSSID': $($servers -join ', ')"
    return $servers
}

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
        -ArgumentList @('--device', $TunDevice, '-p', "$Proxy") `
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

    $dnsServers = @(Get-TunnelDnsServers)
    $primaryDns = [string]$dnsServers[0]

    $dnsOutput = & netsh interface ipv4 set dnsservers `
        "name=$TunName" source=static "address=$primaryDns" `
        register=none validate=no 2>&1

    if ($LASTEXITCODE -ne 0) {
        throw "Failed to set primary DNS ($primaryDns): $($dnsOutput -join ' ')"
    }

    for ($i = 1; $i -lt $dnsServers.Count; $i++) {
        $extraDns = [string]$dnsServers[$i]

        $dnsOutput = & netsh interface ipv4 add dnsservers `
            "name=$TunName" "address=$extraDns" "index=$($i + 1)" `
            validate=no 2>&1

        if ($LASTEXITCODE -ne 0) {
            throw "Failed to add DNS server ($extraDns): $($dnsOutput -join ' ')"
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

############################ Main Execution ###################################
function main {

    $configPath = [System.IO.Path]::ChangeExtension($PSCommandPath, '.yaml')
    $config = Import-TunnelConfig -Path $configPath

    $TargetSSID = $config['ssid']
    $TunName = $config['tun_name']

    $TunGuid = '7FE5A4A1-1326-40E2-974C-EF617156ACA8'
    $TunDevice = "tun://${TunName}?guid={$TunGuid}"

    $tunConfig = ConvertFrom-TunAddressCidr -Cidr $config['tun_address']
    $TunAddress = $tunConfig.Address
    $TunGateway = $tunConfig.Gateway

    $DnsPrimary = $config['dns_primary']
    $DnsSecond  = $config['dns_secondary']
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

    Add-Types

    [WlanTunnelSignal]::TargetSSID = $TargetSSID

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

}

main