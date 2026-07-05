#!/system/bin/sh
# WireGuard boot-completed script - with network availability check

(
  # Ждём завершения загрузки Android
  until [ "$(getprop sys.boot_completed)" = "1" ]; do
    sleep 5
  done
  
  # Даём сети время подняться
  sleep 10

  # Проверяем что интернет доступен (пытаемся пропинговать 1.1.1.1)
  internet_ready=0
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1; then
      internet_ready=1
      break
    fi
    sleep 3
  done

  # Если интернета нет - пробуем ещё через DNS
  if [ "$internet_ready" = "0" ]; then
    if ping -c 1 -W 2 google.com >/dev/null 2>&1; then
      internet_ready=1
    fi
  fi

  # Запускаем интерфейсы
  started=0
  for f in /data/adb/wireguard/*.conf; do
    [ -f "$f" ] || continue
    iface=$(basename "$f" .conf)
    AUTO_START=1
    # shellcheck disable=SC1090
    [ -f "/data/adb/wireguard/autostart.${iface}" ] && . "/data/adb/wireguard/autostart.${iface}"
    if [ "${AUTO_START:-1}" = "1" ]; then
      if [ "$internet_ready" = "1" ]; then
        wgksu start "$iface"
        started=1
      else
        # Если интернета нет - пытаемся запустить, но с задержкой через 30 секунд
        (
          sleep 30
          wgksu start "$iface"
        ) &
        started=1
      fi
    fi
  done
  
  [ "$started" = "0" ] && { wgksu status >/dev/null 2>&1; exit 0; }

  # Обновляем статус KSU
  if command -v ksud >/dev/null 2>&1; then
    export KSU_MODULE="WireGuard-KSU"
    sleep 2
    wgksu status >/dev/null 2>&1
  fi

  # DNS re-resolve daemon: per-interface
  for f in /data/adb/wireguard/*.conf; do
    [ -f "$f" ] || continue
    iface=$(basename "$f" .conf)
    RERESOLVE_ENABLED=1
    RERESOLVE_INTERVAL=120
    # shellcheck disable=SC1090
    [ -f "/data/adb/wireguard/reresolve.${iface}" ] && . "/data/adb/wireguard/reresolve.${iface}"
    if [ "${RERESOLVE_ENABLED:-1}" = "1" ]; then
      (
        while sleep "${RERESOLVE_INTERVAL:-120}"; do
          wgksu reresolve-dns "$iface" 2>/dev/null
        done
      ) &
    fi
  done
)&
