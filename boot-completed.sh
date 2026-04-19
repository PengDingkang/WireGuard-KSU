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
  [ "$auto_start" = "1" ] || exit 0

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
)&
