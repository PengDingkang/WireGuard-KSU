#!/system/bin/sh
# WireGuard boot-completed script

wg_data="/data/adb/wireguard"
# Combined runtime log, including successful startup output and errors.
log_file="$wg_data/error.log"

WGKSU="$wg_data/wgksu"

# find busybox across Magisk/KSU/APatch
for bb in /data/adb/magisk/busybox /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox; do
  [ -f "$bb" ] && busybox="$bb" && break
done
[ -z "$busybox" ] && busybox="busybox"

boot_log() {
  mkdir -p "$wg_data"
  printf '%s [boot] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$log_file"
}

is_ipv4() {
  echo "$1" | awk -F. '
    NF != 4 { exit 1 }
    {
      for (i = 1; i <= 4; i++) {
        if ($i !~ /^[0-9]+$/ || $i < 0 || $i > 255) exit 1
      }
      exit 0
    }
  '
}

is_ipv6() {
  case "$1" in
    *:*) echo "$1" | grep -Eq '^[0-9A-Fa-f:]+$' ;;
    *) return 1 ;;
  esac
}

endpoint_host() {
  endpoint="$1"
  case "$endpoint" in
    \[*\]*:*) host="${endpoint%%]*}"; echo "${host#[}" ;;
    *) echo "${endpoint%:*}" ;;
  esac
}

route_table_dump() {
  family="$1"
  routes=$(ip "-$family" route show table all 2>/dev/null)
  if [ -n "$routes" ]; then
    echo "$routes"
    return
  fi

  ip "-$family" route show 2>/dev/null
  for table in wlan0 eth0 rmnet_data0 rmnet_data1 rmnet_data2 rmnet_data3 rmnet_data4 ccmni0 ccmni1; do
    ip "-$family" route show table "$table" 2>/dev/null
  done
}

underlay_default_ready() {
  family="$1"
  route_table_dump "$family" | awk '
    $1 == "default" {
      dev = ""
      for (i = 1; i <= NF; i++) {
        if ($i == "dev") dev = $(i + 1)
      }
      if (dev ~ /^(wlan|eth|rmnet|ccmni|usb|rndis)/) found = 1
    }
    END { exit found ? 0 : 1 }
  '
}

resolve_host4() {
  host="$1"
  addr=$(ping -c1 -W2 "$host" 2>/dev/null | grep -oE '\([0-9]+(\.[0-9]+){3}\)' | head -1 | tr -d '()')
  [ -n "$addr" ] && echo "$addr" && return
  addr=$(getent hosts "$host" 2>/dev/null | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+(\.[0-9]+){3}$/) { print $i; exit } }')
  [ -n "$addr" ] && echo "$addr" && return
  addr=$($busybox nslookup "$host" 2>/dev/null | awk '
    /^Name:/ || /^Non-authoritative answer:/ { answer = 1; next }
    answer {
      for (i = 1; i <= NF; i++) {
        v = $i
        sub(/#.*/, "", v)
        if (v ~ /^[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*$/) {
          print v
          exit
        }
      }
    }
  ')
  is_ipv4 "$addr" && echo "$addr"
}

resolve_host6() {
  host="$1"
  if command -v ping6 >/dev/null 2>&1; then
    addr=$(ping6 -c1 -W2 "$host" 2>/dev/null | grep -oE '([0-9A-Fa-f]{0,4}:){2,}[0-9A-Fa-f:]+' | head -1)
    [ -n "$addr" ] && echo "$addr" && return
  fi
  addr=$(getent hosts "$host" 2>/dev/null | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^[0-9A-Fa-f:]*:[0-9A-Fa-f:]*$/) { print $i; exit } }')
  [ -n "$addr" ] && echo "$addr" && return
  addr=$($busybox nslookup "$host" 2>/dev/null | awk '
    /^Name:/ || /^Non-authoritative answer:/ { answer = 1; next }
    answer {
      for (i = 1; i <= NF; i++) {
        v = $i
        sub(/#.*/, "", v)
        gsub(/^\[/, "", v)
        gsub(/\]$/, "", v)
        if (v ~ /^[0-9A-Fa-f:]*:[0-9A-Fa-f:]*$/ && v ~ /:/) {
          print v
          exit
        }
      }
    }
  ')
  is_ipv6 "$addr" && echo "$addr"
}

resolve_host() {
  host="$1"
  addr=$(resolve_host4 "$host")
  [ -n "$addr" ] && echo "$addr" && return
  resolve_host6 "$host"
}

boot_network_ready() {
  conf="$1"
  endpoints=$(grep -i '^[[:space:]]*Endpoint[[:space:]]*=' "$conf" 2>/dev/null | sed 's/^[^=]*= *//' | tr -d ' ')

  [ -z "$endpoints" ] && return 0

  for endpoint in $endpoints; do
    host=$(endpoint_host "$endpoint")
    if is_ipv4 "$host"; then
      underlay_default_ready 4 || return 1
    elif is_ipv6 "$host"; then
      underlay_default_ready 6 || return 1
    else
      resolved=$(resolve_host "$host")
      [ -n "$resolved" ] || return 1
      if is_ipv4 "$resolved"; then
        underlay_default_ready 4 || return 1
      elif is_ipv6 "$resolved"; then
        underlay_default_ready 6 || return 1
      else
        return 1
      fi
    fi
  done

  return 0
}

start_iface_when_ready() {
  conf="$1"
  iface="$2"
  attempts=0
  max_attempts=60

  while [ "$attempts" -lt "$max_attempts" ]; do
    if boot_network_ready "$conf"; then
      [ "$attempts" -gt 0 ] &&
        boot_log "$iface: network ready after $((attempts * 5))s"
      break
    fi

    [ "$attempts" = "0" ] &&
      boot_log "$iface: waiting for physical network and DNS before autostart"
    attempts=$((attempts + 1))
    sleep 5
  done

  if [ "$attempts" -ge "$max_attempts" ]; then
    boot_log "$iface: network not ready after $((max_attempts * 5))s; skipped autostart"
    return 1
  fi

  start_attempts=0
  max_start_attempts=3
  while [ "$start_attempts" -lt "$max_start_attempts" ]; do
    if "$WGKSU" start "$iface" >> "$log_file" 2>&1; then
      "$WGKSU" status >/dev/null 2>&1
      return 0
    fi

    start_attempts=$((start_attempts + 1))
    if [ "$start_attempts" -ge "$max_start_attempts" ]; then
      boot_log "$iface: failed to start after $start_attempts attempts"
      return 1
    fi
    boot_log "$iface: start failed; retrying in 5s ($start_attempts/$max_start_attempts)"
    sleep 5
  done
}

(
  until [ "$(getprop sys.boot_completed)" = "1" ]; do
    sleep 5
  done
  sleep 5

  # No lock owner can survive a reboot. Remove locks from older versions or
  # dead owners before starting any interface workers for this boot.
  "$WGKSU" cleanup-route-locks >> "$log_file" 2>&1

  # start interfaces with autostart enabled (per-interface)
  started=0
  for f in "$wg_data"/*.conf; do
    [ -f "$f" ] || continue
    iface=$(basename "$f" .conf)
    AUTO_START=1
    # shellcheck disable=SC1090
    [ -f "$wg_data/autostart.${iface}" ] && . "$wg_data/autostart.${iface}"
    if [ "${AUTO_START:-1}" = "1" ]; then
      start_iface_when_ready "$f" "$iface" &
      started=1
    fi
  done
  [ "$started" = "0" ] && { "$WGKSU" status >/dev/null 2>&1; exit 0; }

  # update KSU description
  if command -v ksud >/dev/null 2>&1; then
    export KSU_MODULE="WireGuard-KSU"
    sleep 2
    "$WGKSU" status >/dev/null 2>&1
  fi

  # DNS re-resolve daemon: per-interface
  for f in "$wg_data"/*.conf; do
    [ -f "$f" ] || continue
    iface=$(basename "$f" .conf)
    RERESOLVE_ENABLED=1
    RERESOLVE_INTERVAL=120
    # shellcheck disable=SC1090
    [ -f "$wg_data/reresolve.${iface}" ] && . "$wg_data/reresolve.${iface}"
    if [ "${RERESOLVE_ENABLED:-1}" = "1" ]; then
      (
        while sleep 30; do
          "$WGKSU" repair-routes "$iface" 2>/dev/null
        done
      ) &
      (
        while sleep "${RERESOLVE_INTERVAL:-120}"; do
          "$WGKSU" reresolve-dns "$iface" 2>/dev/null
        done
      ) &
    fi
  done
)&
