#!/system/bin/sh
# WireGuard boot-completed script

(
  until [ "$(getprop sys.boot_completed)" = "1" ]; do
    sleep 5
  done
  sleep 5

  auto_start=1
  if [ -f /data/adb/wireguard/autostart ]; then
    # shellcheck disable=SC1091
    . /data/adb/wireguard/autostart
    auto_start=${AUTO_START:-1}
  fi
  [ "$auto_start" = "1" ] || { wgksu status >/dev/null 2>&1; exit 0; }

  # skip if no real configs (only example)
  real_conf=0
  for f in /data/adb/wireguard/*.conf; do
    [ -f "$f" ] && real_conf=1 && break
  done
  [ "$real_conf" = "1" ] || exit 0

  wgksu start

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
