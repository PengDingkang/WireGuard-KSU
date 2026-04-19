#!/system/bin/sh
# Cleanup on module uninstall
# Note: /data/adb/wireguard is kept to preserve user configs

# bring down all interfaces
for conf in /data/adb/wireguard/*.conf; do
  [ -f "$conf" ] || continue
  iface=$(basename "$conf" .conf)
  ip link set "$iface" down 2>/dev/null
  ip link del "$iface" 2>/dev/null
done
