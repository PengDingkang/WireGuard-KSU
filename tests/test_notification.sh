#!/bin/sh

set -eu

repo_dir=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
test_tmp=$(mktemp -d)
test_data="$test_tmp/data"
test_module="$test_tmp/modules/WireGuard-KSU"
test_bin="$test_tmp/bin"
test_state="$test_tmp/state"
test_notif_dir="$test_tmp/app_files"
test_wgksu="$test_tmp/wgksu"

cleanup() {
  rm -rf "$test_tmp"
}
trap cleanup 0 1 2 15

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

mkdir -p "$test_data" "$test_module/companion" "$test_bin" "$test_state/ifaces" "$test_notif_dir"
cp -R "$repo_dir/translations" "$test_module/"
cp "$repo_dir/companion/wgksu-status.apk" "$test_module/companion/wgksu-status.apk"
cp "$repo_dir/tests/helpers/busybox" "$test_bin/busybox"
chmod 755 "$test_bin/busybox"

cat > "$test_data/wg" <<'EOF'
#!/bin/sh
state="$WGKSU_TEST_STATE"
cmd="${1:-}"
shift || true
case "$cmd" in
  setconf) cp "$2" "$state/ifaces/$1.wgconf" ;;
  set) : ;;
  show)
    if [ "${1:-}" = "interfaces" ]; then
      for f in "$state/ifaces"/*.up; do [ -f "$f" ] && basename "$f" .up; done
      exit 0
    fi
    case "${2:-}" in
      allowed-ips) printf 'pub0\t0.0.0.0/0 ::/0\n' ;;
      endpoints) printf 'pub0\t198.51.100.10:51820\n' ;;
    esac
    ;;
esac
EOF
chmod 755 "$test_data/wg"

cat > "$test_bin/ip" <<'EOF'
#!/bin/sh
state="$WGKSU_TEST_STATE"
family=4
case "${1:-}" in
  -4) family=4; shift ;;
  -6) family=6; shift ;;
esac
obj="${1:-}"; shift || true
case "$obj" in
  link)
    act="${1:-}"; shift || true
    case "$act" in
      show)
        [ -f "$state/ifaces/$1.exists" ] || exit 1
        mtu=$(cat "$state/ifaces/$1.mtu" 2>/dev/null || echo 1420)
        printf '10: %s: <UP> mtu %s\n' "$1" "$mtu"
        ;;
      add) : > "$state/ifaces/$1.exists" ;;
      set)
        iface="$1"; shift || true
        case "${1:-}" in
          up) : > "$state/ifaces/$iface.up" ;;
          down) rm -f "$state/ifaces/$iface.up" ;;
          mtu) printf '%s\n' "${2:-1420}" > "$state/ifaces/$iface.mtu" ;;
        esac
        ;;
      del) rm -f "$state/ifaces/$1.exists" "$state/ifaces/$1.up" "$state/ifaces/$1.addr4" "$state/ifaces/$1.addr6" ;;
    esac
    ;;
  addr)
    act="${1:-}"; shift || true
    case "$act" in
      add)
        if [ "$family" = "6" ]; then
          printf '    inet6 %s scope global %s\n' "$1" "$3" >> "$state/ifaces/$3.addr6"
        else
          printf '    inet %s scope global %s\n' "$1" "$3" >> "$state/ifaces/$3.addr4"
        fi
        ;;
      show)
        iface=""
        for a in "$@"; do
          case "$a" in dev|scope|global) ;; *) iface="$a"; break ;; esac
        done
        cat "$state/ifaces/$iface.addr${family}" 2>/dev/null || true
        ;;
    esac
    ;;
  route)
    act="${1:-}"; shift || true
    mf="$state/routes${family}.main"
    case "$act" in
      show)
        if [ "${1:-}" = "table" ] && [ "${2:-}" = "wlan0" ]; then
          [ "$family" = "4" ] && printf 'default via 192.168.1.1 dev wlan0\n'
          [ "$family" = "6" ] && printf 'default via fe80::1 dev wlan0\n'
        elif [ "${1:-}" = "table" ] && [ "${2:-}" = "main" ]; then
          shift 2
          [ -f "$mf" ] || exit 0
          [ -n "${1:-}" ] && grep -E "^(${1}|${1%/*}) " "$mf" || cat "$mf"
        fi
        ;;
      replace|add)
        dst="$1"; shift || true
        touch "$mf"
        grep -v -E "^(${dst}|${dst%/*}) " "$mf" > "$mf.tmp" || true
        printf '%s %s\n' "$dst" "$*" >> "$mf.tmp"
        mv "$mf.tmp" "$mf"
        ;;
      del)
        [ -f "$mf" ] || exit 0
        grep -v -E "^(${1}|${1%/*}) " "$mf" > "$mf.tmp" || true
        mv "$mf.tmp" "$mf"
        ;;
    esac
    ;;
  rule)
    act="${1:-}"; shift || true
    case "$act" in
      show)
        printf '0:\tfrom all lookup local\n'
        printf '22000:\tfrom all fwmark 0x0/0xffff iif lo lookup wlan0\n'
        ;;
    esac
    ;;
esac
EOF

cat > "$test_bin/pm" <<'EOF'
#!/bin/sh
state="$WGKSU_TEST_STATE"
printf 'pm %s\n' "$*" >> "$state/pm.log"
case "$1" in
  path)
    case "$2" in
      me.weishu.kernelsu) echo "package:/data/app/me.weishu.kernelsu/base.apk"; exit 0 ;;
      com.wireguard.ksu.status) [ -f "$state/companion.installed" ] && echo "package:/data/app/com.wireguard.ksu.status/base.apk" && exit 0; exit 1 ;;
      *) exit 1 ;;
    esac
    ;;
  install)
    : > "$state/companion.installed"
    exit 0
    ;;
  grant) exit 0 ;;
esac
EOF

cat > "$test_bin/am" <<'EOF'
#!/bin/sh
printf 'am %s\n' "$*" >> "$WGKSU_TEST_STATE/am.log"
case " $* " in
  *" --activity-new-task "*)
    echo "java.lang.IllegalArgumentException: Unknown option: --activity-new-task" >&2
    exit 1
    ;;
esac
if [ "${WGKSU_TEST_FAIL_ALL_COMP:-0}" = "1" ] && [ "${1:-}" = "start" ]; then
  case " $* " in
    *" -n "*)
      echo "SecurityException: Permission Denial: not exported" >&2
      exit 0
      ;;
  esac
fi
if [ "${WGKSU_TEST_FAIL_FIRST_AM:-0}" = "1" ] && [ "${1:-}" = "start" ]; then
  case " $* " in
    *" me.weishu.kernelsu/.ui.webui.WebUIActivity "*)
      echo "Error type 3: Activity class {me.weishu.kernelsu/me.weishu.kernelsu.ui.webui.WebUIActivity} does not exist." >&2
      exit 0
      ;;
  esac
fi
exit 0
EOF

cat > "$test_bin/appops" <<'EOF'
#!/bin/sh
printf 'appops %s\n' "$*" >> "$WGKSU_TEST_STATE/appops.log"
exit 0
EOF

cat > "$test_bin/cmd" <<'EOF'
#!/bin/sh
if [ "$1" = "wifi" ] && [ "$2" = "status" ]; then
  printf 'Wifi is enabled\nWifi is connected to "%s"\n' "${WGKSU_TEST_WIFI_SSID:-Coffee_Guest}"
fi
EOF

cat > "$test_bin/dumpsys" <<'EOF'
#!/bin/sh
case "$1" in
  connectivity)
    printf 'Active default network: 100\n'
    printf 'NetworkAgentInfo{network{100} ni{[type: WIFI[], state: CONNECTED/CONNECTED]} lastValidated 100 lp{InterfaceName: wlan0} nc{[ Transports: WIFI Capabilities: INTERNET&NOT_VPN&VALIDATED ]}}\n'
    ;;
  package)
    if [ "${2:-}" = "me.weishu.kernelsu" ]; then
      printf '  Activity Resolver Table:\n    me.weishu.kernelsu/.ui.custom.WebUIActivity filter 1234\n'
    fi
    ;;
  deviceidle) : ;;
esac
EOF

cat > "$test_bin/settings" <<'EOF'
#!/bin/sh
printf 'zh-CN\n'
EOF

chmod 755 "$test_bin/"*

sed -e "s|^wg_data=.*|wg_data=\"$test_data\"|" \
    -e "s|^wg_module=.*|wg_module=\"$test_module\"|" \
    "$repo_dir/wgksu" > "$test_wgksu"
chmod 755 "$test_wgksu"

run_wgksu() {
  PATH="$test_bin:$PATH" \
    WGKSU_SELF="$test_wgksu" \
    WGKSU_NO_DAEMON=1 \
    WGKSU_NOTIF_DIR="$test_notif_dir" \
    WGKSU_TEST_STATE="$test_state" \
    WGKSU_TEST_WIFI_SSID="${WGKSU_TEST_WIFI_SSID:-Coffee_Guest}" \
    sh "$test_wgksu" "$@"
}

cat > "$test_data/wg0.conf" <<'EOF'
[Interface]
PrivateKey = priv0
Address = 10.10.10.4/32, fd42::2/128
DNS = 10.10.10.1

[Peer]
PublicKey = pub0
Endpoint = 198.51.100.10:51820
AllowedIPs = 0.0.0.0/0, ::/0
EOF

echo "1. Starting wg0 auto-installs companion APK, grants POST_NOTIFICATIONS, and broadcasts running state"
run_wgksu start wg0 >/dev/null
grep -q 'pm install -r -g .*wgksu-status.apk' "$test_state/pm.log" || fail "companion APK was not auto-installed"
grep -q 'pm grant com.wireguard.ksu.status android.permission.POST_NOTIFICATIONS' "$test_state/pm.log" || fail "POST_NOTIFICATIONS not granted"
grep -q 'com.wireguard.ksu.status.UPDATE.*--es state running.*--es iface wg0.*--es ip4 10.10.10.4.*--es ip6 fd42::2.*--es dns 10.10.10.1' "$test_state/am.log" || fail "missing running notification broadcast: $(cat "$test_state/am.log")"

echo "2. Notification one-tap STOP stops wg0 and updates notification to stopped"
: > "$test_state/am.log"
printf 'stop\n' > "$test_notif_dir/action.req"
run_wgksu notif-handle
[ ! -f "$test_state/ifaces/wg0.up" ] || fail "one-tap stop did not stop wg0"
grep -q 'com.wireguard.ksu.status.UPDATE.*--es state stopped' "$test_state/am.log" || fail "missing stopped broadcast after one-tap stop"

echo "3. Notification one-tap START on blacklisted Wi-Fi refuses start and sends Toast explanation"
cat > "$test_data/autotunnel.wg0" <<'EOF'
AUTOTUNNEL_ENABLED=1
WIFI_MODE=exclude
MOBILE_SIM1=on
MOBILE_SIM2=off
EOF
printf 'Home_5G\n' > "$test_data/autotunnel.wg0.ssids"
: > "$test_state/am.log"
printf 'start\n' > "$test_notif_dir/action.req"
WGKSU_TEST_WIFI_SSID="Home_5G" run_wgksu notif-handle
[ ! -f "$test_state/ifaces/wg0.up" ] || fail "one-tap start bypassed Wi-Fi blacklist!"
grep -q -- '--es toast .*已拒绝启动' "$test_state/am.log" || fail "missing refusal toast in broadcast: $(cat "$test_state/am.log")"

echo "3b. Notification one-tap STOP with Auto-Tunnel sets paused state, and RESUME-AUTO clears pause & resumes"
WGKSU_TEST_WIFI_SSID="Coffee_Guest" run_wgksu start wg0 >/dev/null
: > "$test_state/am.log"
printf 'stop\n' > "$test_notif_dir/action.req"
WGKSU_TEST_WIFI_SSID="Coffee_Guest" run_wgksu notif-handle
[ ! -f "$test_state/ifaces/wg0.up" ] || fail "notification stop did not stop wg0"
[ -f "$test_data/manual_pause.wg0" ] || fail "notification stop did not set manual_pause.wg0"
grep -q 'com.wireguard.ksu.status.UPDATE.*--es state paused' "$test_state/am.log" || fail "notification did not broadcast paused state: $(cat "$test_state/am.log")"
: > "$test_state/am.log"
printf 'resume-auto\n' > "$test_notif_dir/action.req"
WGKSU_TEST_WIFI_SSID="Home_5G" run_wgksu notif-handle
[ ! -f "$test_data/manual_pause.wg0" ] || fail "notification resume-auto did not clear manual_pause.wg0"
grep -q -- '--es toast 已恢复网络自动启停' "$test_state/am.log" || fail "missing resume toast: $(cat "$test_state/am.log")"

echo "4. Notification one-tap OPEN-PANEL launches KernelSU WebUIActivity directly with module ID"
: > "$test_state/am.log"
printf 'open-panel\n' > "$test_notif_dir/action.req"
run_wgksu notif-handle
grep -q 'am start --user 0 -n me.weishu.kernelsu/.ui.webui.WebUIActivity -d ksu://webui?id=WireGuard-KSU --es id WireGuard-KSU' "$test_state/am.log" || fail "open-panel did not launch KernelSU WebUIActivity: $(cat "$test_state/am.log")"

echo "4b. OPEN-PANEL detects am start Error: (exit 0) and falls back to exact WebUIActivity from dumpsys package"
: > "$test_state/am.log"
printf 'open-panel\n' > "$test_notif_dir/action.req"
WGKSU_TEST_FAIL_FIRST_AM=1 run_wgksu notif-handle
grep -q 'am start --user 0 -n me.weishu.kernelsu/.ui.custom.WebUIActivity' "$test_state/am.log" || fail "open-panel did not fall back to exact dumpsys WebUIActivity: $(cat "$test_state/am.log")"

echo "4c. OPEN-PANEL falls back to KernelSU intent_token ksu://webui deeplink when direct WebUIActivity fails"
mkdir -p "$test_tmp/prefs/me.weishu.kernelsu/shared_prefs"
cat > "$test_tmp/prefs/me.weishu.kernelsu/shared_prefs/settings.xml" <<'EOF'
<?xml version='1.0' encoding='utf-8' standalone='yes' ?>
<map>
    <string name="intent_token">deadbeef0123456789</string>
</map>
EOF
: > "$test_state/am.log"
printf 'open-panel\n' > "$test_notif_dir/action.req"
WGKSU_TEST_FAIL_ALL_COMP=1 WGKSU_KSU_PREFS_ROOT="$test_tmp/prefs" run_wgksu notif-handle
grep -q 'am start --user 0 -a android.intent.action.VIEW -d ksu://webui?id=WireGuard-KSU&token=deadbeef0123456789 -p me.weishu.kernelsu' "$test_state/am.log" || fail "open-panel did not fall back to intent_token deeplink: $(cat "$test_state/am.log")"

echo "5. Disabling notification cancels status bar notification cleanly"
: > "$test_state/am.log"
run_wgksu notification disable
[ "$(run_wgksu notification status)" = "0" ] || fail "notification status should be 0"
grep -q 'com.wireguard.ksu.status.CANCEL' "$test_state/am.log" || fail "disabling notification did not broadcast CANCEL"

echo "all native status notification tests passed"
