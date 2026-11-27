#!/system/bin/sh
# Cleanup on module uninstall
# Note: /data/adb/wireguard is kept to preserve user configs

# stop auto-tunnel & status notification watchers if running
for pidf in /data/adb/wireguard/autotunnel.pid /data/adb/wireguard/notifwatch.pid; do
  if [ -f "$pidf" ]; then
    at_pid=$(cat "$pidf" 2>/dev/null)
    case "$at_pid" in
      ""|*[!0-9]*) ;;
      *) kill "$at_pid" 2>/dev/null || true ;;
    esac
    rm -f "$pidf"
  fi
done

# remove status bar notification companion app cleanly
if command -v am >/dev/null 2>&1; then
  am broadcast --user 0 -n com.wireguard.ksu.status/.StatusReceiver -a com.wireguard.ksu.status.CANCEL >/dev/null 2>&1 || true
fi
if command -v pm >/dev/null 2>&1; then
  pm uninstall com.wireguard.ksu.status >/dev/null 2>&1 || true
fi

# stop all interfaces cleanly (including endpoint routes and IPv4/IPv6 policy rules)
if [ -f /data/adb/wireguard/wgksu ]; then
  if [ -f /data/adb/wireguard/captive_portal.backup ]; then
    sh /data/adb/wireguard/wgksu captive-portal default >/dev/null 2>&1 || true
  fi
  sh /data/adb/wireguard/wgksu stop >/dev/null 2>&1
fi

# fallback cleanup if wgksu was unavailable
for conf in /data/adb/wireguard/*.conf; do
  [ -f "$conf" ] || continue
  iface=$(basename "$conf" .conf)
  ip link set "$iface" down 2>/dev/null
  ip link del "$iface" 2>/dev/null
done
ip -4 rule del from all lookup main pref 1 2>/dev/null
ip -6 rule del from all lookup main pref 1 2>/dev/null

# clean up any leftover global DNS redirect rules
for ipt in iptables ip6tables; do
  command -v "$ipt" >/dev/null 2>&1 || continue
  n=0; while [ "$n" -lt 16 ] && "$ipt" -w -t nat -D OUTPUT -j WGKSU_DNS 2>/dev/null; do n=$((n + 1)); done
  n=0; while [ "$n" -lt 16 ] && "$ipt" -w -t nat -D POSTROUTING -j WGKSU_DNS_POST 2>/dev/null; do n=$((n + 1)); done
  "$ipt" -w -t nat -F WGKSU_DNS 2>/dev/null || true
  "$ipt" -w -t nat -X WGKSU_DNS 2>/dev/null || true
  "$ipt" -w -t nat -F WGKSU_DNS_POST 2>/dev/null || true
  "$ipt" -w -t nat -X WGKSU_DNS_POST 2>/dev/null || true
  n=0; while [ "$n" -lt 16 ] && "$ipt" -w -t filter -D OUTPUT -j WGKSU_DNS_BLOCK 2>/dev/null; do n=$((n + 1)); done
  "$ipt" -w -t filter -F WGKSU_DNS_BLOCK 2>/dev/null || true
  "$ipt" -w -t filter -X WGKSU_DNS_BLOCK 2>/dev/null || true
  n=0; while [ "$n" -lt 16 ] && "$ipt" -w -t mangle -D POSTROUTING -j WGKSU_MSS 2>/dev/null; do n=$((n + 1)); done
  "$ipt" -w -t mangle -F WGKSU_MSS 2>/dev/null || true
  "$ipt" -w -t mangle -X WGKSU_MSS 2>/dev/null || true
done
rm -f /data/adb/wireguard/dns.active /data/adb/wireguard/dns.* /data/adb/wireguard/mtu.* /data/adb/wireguard/manual_pause.*

# remove fallback binaries (keep configs)
rm -f /data/adb/wireguard/wg
rm -f /data/adb/wireguard/wgksu
rm -f /data/adb/wireguard/wgksu-status.apk /data/adb/wireguard/.notif-hook.sh /data/adb/wireguard/.companion_ver
