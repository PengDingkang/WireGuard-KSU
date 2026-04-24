#!/system/bin/sh
# WireGuard boot-completed script

(
  until [ "$(getprop sys.boot_completed)" = "1" ]; do
    sleep 5
  done
  sleep 5

  # start interfaces with autostart enabled (per-interface)
  started=0
  for f in /data/adb/wireguard/*.conf; do
    [ -f "$f" ] || continue
    iface=$(basename "$f" .conf)
    AUTO_START=1
    # shellcheck disable=SC1090
    [ -f "/data/adb/wireguard/autostart.${iface}" ] && . "/data/adb/wireguard/autostart.${iface}"
    if [ "${AUTO_START:-1}" = "1" ]; then
      wgksu start "$iface"
      started=1
    fi
  done
  [ "$started" = "0" ] && { wgksu status >/dev/null 2>&1; exit 0; }

  # update KSU description
  if command -v ksud >/dev/null 2>&1; then
    export KSU_MODULE="WireGuard-KSU"
    sleep 2
    wgksu status >/dev/null 2>&1
  fi

  # DNS re-resolve daemon: periodically re-resolve domain endpoints
  RERESOLVE_ENABLED=1
  RERESOLVE_INTERVAL=120
  # shellcheck disable=SC1091
  [ -f /data/adb/wireguard/reresolve ] && . /data/adb/wireguard/reresolve
  if [ "${RERESOLVE_ENABLED:-1}" = "1" ]; then
    while sleep "${RERESOLVE_INTERVAL:-120}"; do
      wgksu reresolve-dns 2>/dev/null
    done
  fi
)&
