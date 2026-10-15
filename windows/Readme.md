# Windows Implementation

# Tun2Socks Wi-Fi Watcher for Windows

This setup starts the configured `tun2socks` tunnel when Windows connects to a chosen Wi-Fi SSID and stops it when Windows disconnects from that network. The watcher listens for WLAN AutoConfig events, so it can react to connections and disconnections that happen while it is running.

## Files

Keep these files together in one directory, for example `C:\Program Files\Tun2Socks`:

| File | Purpose |
| --- | --- |
| `turn2socks.ps1` | Watches Wi-Fi events and starts or stops the tunnel. |
| `turn2socks.yaml` | Configuration read by the watcher. Its basename must match the PowerShell script. |
| `wlanTunnelSignal.cs` | C# event-watcher type imported by the PowerShell script. |
| `register-tun2socks-task.ps1` | Registers or removes the login task. |

The spelling `turn2socks` is intentional here because that is the current script filename. If you rename the watcher, rename its YAML file to match and update the filename in `Register-Tun2SocksTask.ps1`.

## Configure

Edit `turn2socks.yaml`:

```yaml
ssid: "DIRECT-TF-TetherFi"
tun_name: "tun0"
tun_address: "10.0.0.2/24"
dns_primary: "8.8.8.8"
dns_second: "100.100.100.100"
proxy: "socks5://192.168.49.1:8228"
```

Use the actual interface name, CIDR address, and SOCKS proxy URL for your setup. `tun_address` includes the prefix length; the watcher derives the tunnel gateway from the address. The proxy value is a full connection URL such as `socks5://host:port`.

DNS settings are optional. Leave a value empty to leave that DNS setting at its OS default, for example:

```yaml
dns_primary: ""
dns_second: ""
```

The proxy at `192.168.49.1:8228` does not answer DNS queries, so leave manual DNS servers configured if clients need DNS resolution while using this setup.

## Run manually

Open PowerShell in the directory containing the files and run:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\turn2socks.ps1
```

The watcher prints the current Wi-Fi SSID and logs WLAN event IDs such as `8001` (connected) and `8003` (disconnected). Leave this window open while testing. Press **Ctrl+C** to stop the watcher; it should also stop the tunnel during cleanup.

## Start automatically at login

Open PowerShell **as Administrator**, change to the setup directory, and register the task:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\Register-Tun2SocksTask.ps1
```

The task is named `Tun2Socks Wi-Fi Watcher`. It runs the watcher in the current user's interactive session at logon, with the highest available privileges. It uses the same PowerShell executable (Windows PowerShell or PowerShell 7) that runs the installer. The task starts on the next login. To start it now:

```powershell
Start-ScheduledTask -TaskName 'Tun2Socks Wi-Fi Watcher'
```

To check its state or last result:

```powershell
Get-ScheduledTask -TaskName 'Tun2Socks Wi-Fi Watcher'
Get-ScheduledTaskInfo -TaskName 'Tun2Socks Wi-Fi Watcher'
```

To remove the login task, run the installer from an elevated PowerShell window:

```powershell
.\Register-Tun2SocksTask.ps1 -Unregister
```

This removes the scheduled task. It does not delete the scripts or configuration files.

## Debug WLAN event notifications

In a separate PowerShell window, inspect recent WLAN AutoConfig events:

```powershell
Get-WinEvent -FilterHashtable @{
    LogName = 'Microsoft-Windows-WLAN-AutoConfig/Operational'
} -MaxEvents 15 |
    Select-Object TimeCreated, Id, Message |
    Format-List
```

Successful connection and disconnection events are typically IDs `8001` and `8003`. If Windows records these events but the watcher prints none, confirm the watcher is still running, that its C# companion file is beside it, and that the WLAN AutoConfig Operational log is enabled. To check the channel state:

```powershell
wevtutil.exe gl Microsoft-Windows-WLAN-AutoConfig/Operational
```

If it reports `enabled: false`, enable it from an elevated PowerShell window:

```powershell
wevtutil.exe sl Microsoft-Windows-WLAN-AutoConfig/Operational /e:true
```

To see the current Wi-Fi profile reported by Windows:

```powershell
Get-NetConnectionProfile | Format-List Name, InterfaceAlias, InterfaceIndex, IPv4Connectivity
```

Windows may append a suffix such as ` 6` to the profile `Name`. The watcher should compare the actual SSID, configured by `target_ssid`, rather than assuming the profile name is identical.

## Troubleshooting

- **Watcher reports an empty SSID:** Check `Get-NetConnectionProfile` and `netsh wlan show interfaces`. Windows privacy/location settings can prevent `netsh` from exposing the SSID to desktop applications; the watcher should use the available connection-profile/event data path instead.
- **Tunnel fails when the target network connects:** Run the watcher manually to see the error in its console. Check the YAML values, the proxy URL, the TUN adapter name/address, and any required DNS servers.
- **Scheduled task does not start:** Check `Get-ScheduledTaskInfo`, confirm that the watcher and its companion files remain at the registered path, and verify the task's logon user. Re-run the installer after moving the directory.
- **Need to inspect all recent WLAN events:** The Operational log command above shows the event details, including the SSID and disconnect reason.

The watcher needs to remain running for event-driven start/stop behavior. The scheduled task launches it at login; it does not run the watcher as a short-lived one-shot command.
