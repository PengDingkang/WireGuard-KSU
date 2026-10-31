[简体中文](README_CN.md) | **English** | [Русский](README_RU.md)

# WireGuard-KSU

Manage kernel-based WireGuard VPN on Android with the built-in KernelSU/APatch WebUI.

## v1.2.0 upgrade note: shell command mounting is disabled by default

**When upgrading from a version that did not save a mount preference, command mounting will be disabled by default and the change takes effect after reboot.**
The `wg` and `wgksu` short commands may no longer be available in the terminal. Tunnels, WebUI, boot auto-start, and existing configurations are not affected.

| State before installation or upgrade | Mount setting afterward |
| --- | --- |
| Fresh install | Disabled |
| Older version with no saved mount preference | Disabled, even if it mounted commands automatically |
| A mount preference was saved | The previous enabled/disabled choice is preserved |

When mounting is disabled, use the full paths `/data/adb/wireguard/wgksu` and
`/data/adb/wireguard/wg` in a root shell. Update any scripts that use the commands as well.
To restore the short commands, enable **Shell Command Mount** in the WebUI and reboot.
KernelSU requires an available mounting metamodule. See [Optional shell command mounting](#optional-shell-command-mounting).

## Highlights

- **Kernel-based WireGuard**: Uses the WireGuard module built into Linux 5.6+ kernels
- **Kernel handles tunnel traffic**: No userspace VPN forwarding daemon; background scripts maintain endpoint routes and DNS
- **Multiple interfaces**: Run tunnels such as wg0 and wg1 simultaneously
- **WebUI management**: Manage the module directly in KernelSU/APatch Manager
- **Three root frameworks supported**: Magisk, KernelSU, and APatch

## Features

- CLI management (`start/stop/restart/status/enable/disable/genkey/mount`)
- KernelSU/APatch WebUI
  - Switch between interfaces; create and delete interfaces
  - Generate a keypair when creating an interface
  - View interface IP, port, and public key
  - View peer endpoints, latest handshakes, transfer, and Allowed IPs
  - Edit configuration files online and save or restart
  - Keypair generation tool
  - Boot auto-start toggle
  - Optional shell command mounting toggle (off by default)
  - Runtime logs for startup, route maintenance, warnings, and errors
- Generates an initial keypair and configuration template on first install
- Supports common fields from the standard wg-quick configuration format
- Automatically starts configured interfaces at boot
- Shows interface status and IP in the KSU module list
- Installer messages, module description, and `wgksu` CLI status messages follow the system language (English and Russian; other languages fall back to English)
- Pins WireGuard endpoint routes to the underlying physical network to avoid routing outer WireGuard UDP traffic through another VPN/TUN
- Repairs endpoint routes after network rebuilds, improving recovery after Wi-Fi/mobile network changes
- Optional Stay Awake mode keeps WireGuard reachable while the screen is off, at the cost of increased battery use

## Requirements

The kernel must support WireGuard (`CONFIG_WIREGUARD=y`). The installer checks for this automatically.

Most KernelSU kernels based on Linux 5.6 or later include WireGuard support.

MMRS, meta-overlayfs, or another mounting metamodule is not required by default; WireGuard and the WebUI work without one.
KernelSU only requires a mounting metamodule if you want to mount commands into `/system/bin`.

Endpoint route locking requires file-descriptor-mode `flock`. The module prefers the BusyBox applet provided by Magisk/KernelSU/APatch and also tries a compatible system implementation. If neither is available, interface startup fails explicitly rather than continuing without pinned endpoint routes.

## Installation

1. Download the ZIP from [Releases](../../releases).
2. Flash it in Magisk, KernelSU, or APatch Manager.
3. On first install, a keypair and `wg0.conf` template are generated; the public key is shown in the installer log.
4. Edit `/data/adb/wireguard/wg0.conf` with your server details, or edit it in the WebUI.
5. Reboot to apply the installation or upgrade. Interfaces with boot auto-start enabled will start automatically.

You can also click "＋" in the WebUI to create an interface; a keypair is generated and the editor opens.

## Usage

Run these commands in a root shell (run `su` first). Full paths work whether command mounting is enabled or disabled:

```sh
/data/adb/wireguard/wgksu start              # Start all interfaces
/data/adb/wireguard/wgksu stop               # Stop all interfaces
/data/adb/wireguard/wgksu restart            # Restart all interfaces
/data/adb/wireguard/wgksu start wg0          # Start a specific interface
/data/adb/wireguard/wgksu stop wg0           # Stop a specific interface
/data/adb/wireguard/wgksu status             # Show all interface statuses
/data/adb/wireguard/wgksu enable             # Enable boot auto-start
/data/adb/wireguard/wgksu disable            # Disable boot auto-start
/data/adb/wireguard/wgksu stay-awake enable wg0   # Hold a wakelock and enable Wi-Fi hi-perf while wg0 is running
/data/adb/wireguard/wgksu stay-awake disable wg0  # Disable Stay Awake for wg0
/data/adb/wireguard/wgksu genkey             # Generate a new keypair
```

KernelSU/APatch users can open the module WebUI in Manager.

### Optional shell command mounting

The WebUI **Shell Command Mount** toggle controls whether `wg` and `wgksu` are mounted into
`/system/bin` for convenient terminal use. It is off by default. Tunnels, WebUI, boot auto-start,
route repair, DNS re-resolution, and Stay Awake continue to work when mounting is off.

A reboot is required for a changed mount setting to take effect. The setting applies to the whole module and is preserved during upgrades.
If MMRS separately blocks this module from mounting, allow it there as well to use commands through the system path.

On KernelSU, mounting can only be enabled when an enabled, non-removed metamodule providing `metamount.sh` is detected. Otherwise, the WebUI toggle is disabled with an explanation and the CLI refuses to enable mounting. Magisk/APatch use their built-in mounting support.
The saved choice is stored in `/data/adb/wireguard/mount_enabled` (`1` enabled, `0` disabled).
`mount status` reports the saved setting for the next boot, not whether mounting has already completed.
`mount supported` only reports whether mounting support was detected; it does not mean MMRS has allowed this module to mount.

When mounting is off, use full paths in the terminal:

```sh
/data/adb/wireguard/wgksu start
/data/adb/wireguard/wg show
/data/adb/wireguard/wgksu mount disable  # Save disabled; takes effect after reboot
/data/adb/wireguard/wgksu mount enable   # Save enabled; takes effect after reboot
/data/adb/wireguard/wgksu mount status   # Next-boot setting: 1 enabled, 0 disabled
/data/adb/wireguard/wgksu mount supported # Mount support: 1 yes, 0 no
```

The module always calls its tools from `/data/adb/wireguard/` and does not depend on the system command path.

### Logs

The WebUI **Runtime Log** shows a shared log for all interfaces, including boot startup, route maintenance, warnings, and errors. `wg0 up` indicates a successful interface start, not an error. When there are no entries, the UI shows **No log entries**.
The UI displays the latest 50 lines. Clearing the log removes runtime entries for all interfaces.

To preserve existing entries and compatibility with running scripts, the log path remains `/data/adb/wireguard/error.log`.
Boot startup appends command stdout and stderr to this file. Commands run manually still print to the invoking terminal or WebUI; only explicitly logged messages are written to the runtime log.

DNS endpoint address changes are recorded separately in `/data/adb/wireguard/reresolve.log`.
View them under **DNS Re-resolve → Re-resolve Log**. Related route maintenance and failure messages remain in the runtime log.

## Configuration

Configuration files are stored in `/data/adb/wireguard/` and use the standard WireGuard format:

```ini
[Interface]
PrivateKey = YOUR_PRIVATE_KEY
Address = 10.0.0.2/24
DNS = 1.1.1.1
MTU = 1420

[Peer]
PublicKey = SERVER_PUBLIC_KEY
Endpoint = server.example.com:51820
AllowedIPs = 10.0.0.0/24
PersistentKeepalive = 25
```

Multiple configuration files are supported (`wg0.conf`, `wg1.conf`, and so on); each file corresponds to one interface.

Common WireGuard fields used by `wg setconf`, along with `Address`, `DNS`, and `MTU`, are supported.
The module does not run wg-quick `PreUp`, `PostUp`, `PreDown`, or `PostDown` hooks, and does not implement the `Table` or `SaveConfig` options. Do not rely on these options for additional network setup.

### Endpoint route pinning

When starting an interface, the module waits for a physical network and DNS to become available, then adds a more specific host route for each peer `Endpoint`. This directs WireGuard's outer UDP traffic through the physical network (preferring `wlan`, then `eth`, then mobile networks) and prevents another Android VPN/TUN from capturing the endpoint traffic.

If Android rebuilds the network after the screen turns off, Wi-Fi toggles, or mobile network changes, the module periodically checks the underlying route for each running peer endpoint and re-pins it if the route is missing or points to the wrong device. This lightweight check runs about every 30 seconds by default and does not perform DNS queries.

For domain endpoints, the DNS re-resolve loop handles changes in DNS results. Its default interval is 120 seconds and can be shortened in the WebUI DNS re-resolve settings; shorter intervals increase wakeups and DNS queries while the screen is off.

### Stay reachable while the screen is off

Kernel-based WireGuard does not use an Android `VpnService` foreground service. Some devices put Wi-Fi/CPU into a low-power state when the screen is off, preventing inbound connections to the tunnel address even when `PersistentKeepalive` is configured.

To remain reachable from outside while the screen is off, enable Stay Awake for an interface:

```sh
/data/adb/wireguard/wgksu stay-awake enable wg0
```

If the interface is already running, the setting takes effect immediately; otherwise, it applies the next time the interface starts. The module writes to `/sys/power/wake_lock` and runs `cmd wifi force-hi-perf-mode enabled`. Stopping the interface or disabling Stay Awake releases the wakelock and disables Wi-Fi hi-perf if the module enabled it.

`cmd wifi force-hi-perf-mode` requires Android 10 or later. It may be unavailable on Android 9; in that case, the failure is logged and the module still attempts to acquire the wakelock.

This mode prevents normal deep sleep and can significantly increase battery use. Enable it only for development, remote maintenance, or devices connected to constant power.

### Generate a keypair

Run this in a root shell on the phone:

```sh
/data/adb/wireguard/wgksu genkey
```

On any device with the `wg` tool:

```bash
wg genkey | tee privatekey | wg pubkey > publickey
```

## Compatibility

- Magisk ≥ v20.4
- KernelSU ≥ 0.6.7
- APatch
- Android ≥ 9 (API 28)
- Kernel with `CONFIG_WIREGUARD=y` (Linux 5.6+)
- arm64 devices

## License

This project (module scripts and WebUI) is licensed under the [MIT License](LICENSE).

The `wg` tool is built by CI from [wireguard-tools](https://git.zx2c4.com/wireguard-tools) and is subject to [GPL-2.0](https://git.zx2c4.com/wireguard-tools/about/).


本项目（模块脚本、WebUI）采用 [MIT License](LICENSE)。

`wg` 工具由 CI 从 [wireguard-tools](https://git.zx2c4.com/wireguard-tools) 编译，受 [GPL-2.0](https://git.zx2c4.com/wireguard-tools/about/) 约束。
