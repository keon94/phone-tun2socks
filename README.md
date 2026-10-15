# Universal Phone Hotspot

A small utility that allows your Windows or Linux machine connect to a phone Wi-Fi hotspot and route all traffic through it via a TUN interface, with
the use of [tun2socks](https://github.com/xjasonlyu/tun2socks) as the backend, effectively bypassing all of your traffic's ISP's DNS and routing.

This has been written in an event driven way, so it runs very efficiently on your system and requires no additional setup after the first time.

### Is this not just regular Hotspot?
No, not in the "regular" sense. Typically, with phone carrier plans you need to buy a hotspot package from them to get this kind of access. You are also often limited by how
much data you can use with their hotspot.

This bypasses both limitations - you effectively get a full unrestricted internet connection that is proxied by your phone.

### Limitations
This works on Android devices as they are allowed to broadcast SSIDs. As far as I know, iOS devices can't do that.

### Requirements
- A Linux or Windows machine
- Android device with an SSID broadcasting SOCKS5 proxy installed. I have tested [TetherFuseNet](https://github.com/pyamsoft/tetherfusenet).

### Instructions
- For Linux, see [README.md](./linux/Readme.md)
- For Windows, see [README.md](./windows/Readme.md)


