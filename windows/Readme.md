# Windows Implementation

# Tun2Socks Wi-Fi Watcher for Windows

This setup starts the configured `tun2socks` tunnel when Windows connects to a chosen Wi-Fi SSID and stops it when Windows disconnects from that network. The watcher listens for WLAN AutoConfig events, so it can react to connections and disconnections that happen while it is running.

## Files

Keep these files together in one directory, for example `C:\Program Files\Tun2Socks`:

| File | Purpose |
| --- | --- |
| `tun2socks.ps1` | Watches Wi-Fi events and starts or stops the tunnel. |
| `tun2socks.yaml` | Configuration read by the watcher. Its basename must match the PowerShell script. |
| `wlanTunnelSignal.cs` | C# event-watcher type imported by the PowerShell script. |
| `register-tun2socks-task.ps1` | Registers or removes the login task. |

Additionally, you need the TUN binaries available on your PATH. You might as well put them in the same directory as the files above:

- `tun2socks.exe` [Get from here](https://github.com/xjasonlyu/tun2socks/releases)
- `wintun.dll` [Get from here](https://www.wintun.net/)


## Configure

Edit `tun2socks.yaml` as needed. The below are the personal config that were used (with TetherFuseNet and Tailscale running) during development:

```yaml
ssid: "DIRECT-TF-TetherFi"
tun_name: "tun0"
tun_address: "10.0.0.2/24"
dns_primary: "8.8.8.8"
dns_secondary: "100.100.100.100"
proxy: "socks5://192.168.49.1:8228"
```

DNS settings are technically optional. Leave a value empty to leave that DNS setting at its OS default, for example:

```yaml
dns_primary: ""
dns_secondary: ""
```

However, in the case of `TetherFuseNet` The proxy at `192.168.49.1:8228` does not answer DNS queries, so you likely need the manual overrides to get DNS resolution to work.

## Run manually

Open PowerShell in the directory containing the files and run:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\tun2socks.ps1
```

The watcher prints the current Wi-Fi SSID and logs WLAN event IDs such as `8001` (connected) and `8003` (disconnected). Leave this window open while testing. Press **Ctrl+C** to stop the watcher; it should also stop the tunnel during cleanup.

## Start automatically at login

Open PowerShell **as Administrator**, change to the setup directory, and register the task:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\register-tun2socks-task.ps1
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
