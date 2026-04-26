# WireGuard KSU v1.1.0

- Per-interface autostart control
- Per-interface DNS re-resolve configuration
- Automatic DNS re-resolve for domain endpoints
- Pre-resolve domain endpoints before `wg setconf` (static wg binary DNS fix)
- Config syntax validation before start and save
- Keypair generation in CLI (`wgksu genkey`) and WebUI
- Create and delete interfaces from WebUI
- Start/stop/restart buttons now control current selected interface
- Accurate handshake timestamps and transfer stats via `wg show dump`
- Timestamped error logs with interface prefix
- 15s timeout for WebUI controls to prevent hanging
- Fix config parsing with Windows-style line endings (\r)
- Cleanup interface on `setconf` failure
- Binary fallback for devices without overlay support

# WireGuard KSU v1.0.0

- Initial release
- Kernel-level WireGuard with userspace `wg` tool
- sh-based wg-quick replacement for Android
- Multi-interface support (wg0, wg1, ...)
- KSU/APatch WebUI management
  - Interface status and peer list
  - Config file editor with save & restart
  - Boot auto-start toggle
- CLI management (start/stop/restart/status/enable/disable)
- KSU module description overlay with status and IP

wireguard-tools version: `1.0.20260223`
