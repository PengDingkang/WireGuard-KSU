#!/bin/sh

set -eu

repo_dir=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
test_tmp=$(mktemp -d)
test_data="$test_tmp/data"
test_module="$test_tmp/modules/WireGuard-KSU"
test_bin="$test_tmp/bin"
test_state="$test_tmp/state"
test_wgksu="$test_tmp/wgksu"
ip_log="$test_tmp/ip.log"
wg_log_file="$test_tmp/wg.log"

cleanup() {
  rm -rf "$test_tmp"
}
trap cleanup 0 1 2 15

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

mkdir -p "$test_data" "$test_module" "$test_bin" "$test_state/ifaces"
cp -R "$repo_dir/translations" "$test_module/"
cp "$repo_dir/tests/helpers/busybox" "$test_bin/busybox"
chmod 755 "$test_bin/busybox"

cat > "$test_data/wg" <<'EOF'
#!/bin/sh
state="$WGKSU_TEST_STATE"
printf 'wg %s\n' "$*" >> "$WGKSU_TEST_WG_LOG"
cmd="${1:-}"
shift || true
case "$cmd" in
  setconf)
    cp "$2" "$state/ifaces/$1.wgconf"
    ;;
  set)
    :
    ;;
  show)
    if [ "${1:-}" = "interfaces" ]; then
      for f in "$state/ifaces"/*.up; do
        [ -f "$f" ] || continue
        basename "$f" .up
      done
      exit 0
    fi
    iface="$1"
    sub="${2:-}"
    conf="$state/ifaces/$iface.wgconf"
    [ -f "$conf" ] || exit 1
    case "$sub" in
      allowed-ips)
        printf 'pub0\t0.0.0.0/0 ::/0\n'
        ;;
      endpoints)
        printf 'pub0\t198.51.100.10:51820\n'
        ;;
    esac
    ;;
esac
EOF
chmod 755 "$test_data/wg"

cat > "$test_bin/ip" <<'EOF'
#!/bin/sh
state="$WGKSU_TEST_STATE"
printf 'ip %s\n' "$*" >> "$WGKSU_TEST_IP_LOG"
family=4
case "${1:-}" in
  -4) family=4; shift ;;
  -6) family=6; shift ;;
esac
obj="${1:-}"
shift || true
case "$obj" in
  link)
    act="${1:-}"; shift || true
    case "$act" in
      show) [ -f "$state/ifaces/$1.exists" ] || exit 1; printf '10: %s: <UP> mtu 1420\n' "$1" ;;
      add) : > "$state/ifaces/$1.exists" ;;
      set)
        iface="$1"; shift || true
        case "${1:-}" in
          up) : > "$state/ifaces/$iface.up" ;;
          down) rm -f "$state/ifaces/$iface.up" ;;
          mtu) printf '%s\n' "${2:-}" > "$state/ifaces/$iface.mtu" ;;
        esac
        ;;
      del)
        rm -f "$state/ifaces/$1.exists" "$state/ifaces/$1.up" "$state/ifaces/$1.mtu"
        ;;
    esac
    ;;
  addr) : ;;
  route)
    act="${1:-}"; shift || true
    main_file="$state/routes${family}.main"
    case "$act" in
      show)
        if [ "${1:-}" = "table" ] && [ "${2:-}" = "all" ]; then
          cat "$main_file" 2>/dev/null || true
          cat "$state/underlay${family}" 2>/dev/null || true
        elif [ "${1:-}" = "table" ] && [ "${2:-}" = "main" ]; then
          shift 2
          prefix="${1:-}"
          [ -f "$main_file" ] || exit 0
          if [ -n "$prefix" ]; then
            bare="${prefix%/*}"
            awk -v p="$prefix" -v b="$bare" '($1 == p || $1 == b) { print }' "$main_file"
          else
            cat "$main_file"
          fi
        elif [ "${1:-}" = "table" ] && [ -n "${2:-}" ]; then
          tbl="$2"
          if [ -f "$state/table.${family}.${tbl}" ]; then
            cat "$state/table.${family}.${tbl}"
          fi
        else
          cat "$main_file" 2>/dev/null || true
        fi
        ;;
      replace|add)
        dst="$1"; shift || true
        # Simulate cellular gateway requiring `onlink` when not in main table
        if [ "${WGKSU_TEST_REQUIRE_ONLINK:-0}" = "1" ]; then
          case "$*" in
            *"via "*" dev rmnet_data2")
              case "$*" in
                *onlink*) ;;
                *) echo "RTNETLINK answers: Network is unreachable" >&2; exit 2 ;;
              esac
              ;;
          esac
        fi
        touch "$main_file"
        bare="${dst%/*}"
        grep -v -E "^(${dst}|${bare}) " "$main_file" > "$main_file.tmp" || true
        printf '%s %s\n' "$dst" "$*" >> "$main_file.tmp"
        mv "$main_file.tmp" "$main_file"
        ;;
      del)
        dst="$1"
        [ -f "$main_file" ] || exit 0
        bare="${dst%/*}"
        grep -v -E "^(${dst}|${bare}) " "$main_file" > "$main_file.tmp" || true
        mv "$main_file.tmp" "$main_file"
        ;;
    esac
    ;;
  rule)
    act="${1:-}"; shift || true
    rule_file="$state/rules${family}"
    touch "$rule_file"
    case "$act" in
      show)
        printf '0:\tfrom all lookup local\n'
        cat "$rule_file"
        def_tbl=$(cat "$state/default_table.${family}" 2>/dev/null || true)
        def_prio=$(cat "$state/default_prio.${family}" 2>/dev/null || echo 22000)
        if [ -n "$def_tbl" ]; then
          printf '30040:\tfrom all fwmark 0x0/0xffff iif lo uidrange 10161-10161 unreachable\n'
          printf '%s:\tfrom all fwmark 0x0/0xffff iif lo lookup %s\n' "$def_prio" "$def_tbl"
        fi
        ;;
      add) printf '1:\tfrom all lookup main\n' >> "$rule_file" ;;
      del) : > "$rule_file" ;;
    esac
    ;;
esac
EOF

cat > "$test_bin/cmd" <<'EOF'
#!/bin/sh
if [ "$1" = "wifi" ] && [ "$2" = "status" ]; then
  if [ -n "${WGKSU_TEST_WIFI_SSID:-}" ]; then
    printf 'Wifi is enabled\nWifi is connected to "%s"\n' "$WGKSU_TEST_WIFI_SSID"
  else
    printf 'Wifi is enabled\nWifi is not connected\n'
  fi
fi
EOF

cat > "$test_bin/dumpsys" <<'EOF'
#!/bin/sh
case "$1" in
  connectivity)
    if [ -f "$WGKSU_TEST_STATE/dumpsys.connectivity" ]; then
      cat "$WGKSU_TEST_STATE/dumpsys.connectivity"
    elif [ "${WGKSU_TEST_TRANSPORT:-}" = "wifi" ]; then
      printf 'Active default network: 101\n'
      printf 'NetworkAgentInfo{ netId: 101, [Transports: WIFI], state: CONNECTED/CONNECTED, extra: "%s" }\n' "${WGKSU_TEST_WIFI_SSID:-}"
    elif [ "${WGKSU_TEST_TRANSPORT:-}" = "mobile" ]; then
      printf 'Active default network: 102\n'
      printf 'NetworkAgentInfo{ netId: 102, [Transports: CELLULAR], state: CONNECTED/CONNECTED }\n'
    fi
    ;;
  isub)
    printf 'activeDataSubId=%s\n' "${WGKSU_TEST_ACTIVE_SUB:-4}"
    printf 'Active subscriptions:\n'
    printf ' [SubscriptionInfo: id=4 iccId=898600 simSlotIndex=0 displayName=中国移动 carrierName=中国移动]\n'
    printf ' [SubscriptionInfo: id=7 iccId=898603 simSlotIndex=1 displayName=中国电信 carrierName=中国电信]\n'
    ;;
esac
EOF

cat > "$test_bin/settings" <<'EOF'
#!/bin/sh
printf 'en-US\n'
EOF

cat > "$test_bin/iptables" <<'EOF'
#!/bin/sh
printf 'ipt%s %s\n' "${WGKSU_IPT_FAM:-4}" "$*" >> "$WGKSU_TEST_STATE/ipt.log"
case " $* " in
  *" -D "*) exit 1 ;;
esac
exit 0
EOF

cat > "$test_bin/ip6tables" <<'EOF'
#!/bin/sh
WGKSU_IPT_FAM=6 exec "$(dirname "$0")/iptables" "$@"
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
    WGKSU_TEST_STATE="$test_state" \
    WGKSU_TEST_IP_LOG="$ip_log" \
    WGKSU_TEST_WG_LOG="$wg_log_file" \
    WGKSU_TEST_TRANSPORT="${WGKSU_TEST_TRANSPORT:-}" \
    WGKSU_TEST_WIFI_SSID="${WGKSU_TEST_WIFI_SSID:-}" \
    WGKSU_TEST_ACTIVE_SUB="${WGKSU_TEST_ACTIVE_SUB:-4}" \
    WGKSU_TEST_REQUIRE_ONLINK="${WGKSU_TEST_REQUIRE_ONLINK:-0}" \
    sh "$test_wgksu" "$@"
}

cat > "$test_data/wg0.conf" <<'EOF'
[Interface]
PrivateKey = priv0
Address = 10.10.10.4/32, fd42::2/128

[Peer]
PublicKey = pub0
Endpoint = 198.51.100.10:51820
AllowedIPs = 0.0.0.0/0, ::/0
EOF

# Set up initial Wi-Fi underlay
printf 'wlan0\n' > "$test_state/default_table.4"
printf 'wlan0\n' > "$test_state/default_table.6"
printf 'default via 192.168.1.1 dev wlan0\n' > "$test_state/table.4.wlan0"
printf 'default via fe80::1 dev wlan0\n' > "$test_state/table.6.wlan0"

echo "1. Wi-Fi Exclude mode: stops on excluded SSID (with spaces/Chinese), starts on other SSID"
cat > "$test_data/autotunnel.wg0" <<'EOF'
AUTOTUNNEL_ENABLED=1
WIFI_MODE=exclude
MOBILE_SIM1=on
MOBILE_SIM2=off
EOF
printf 'Home WiFi 5G\n家里网络\n' > "$test_data/autotunnel.wg0.ssids"

WGKSU_TEST_TRANSPORT=wifi WGKSU_TEST_WIFI_SSID="Coffee Shop" run_wgksu auto-tunnel-apply wg0
[ -f "$test_state/ifaces/wg0.up" ] || fail "exclude mode did not start wg0 on non-excluded Wi-Fi"

WGKSU_TEST_TRANSPORT=wifi WGKSU_TEST_WIFI_SSID="Home WiFi 5G" run_wgksu auto-tunnel-apply wg0
[ ! -f "$test_state/ifaces/wg0.up" ] || fail "exclude mode did not stop wg0 on excluded Wi-Fi"

WGKSU_TEST_TRANSPORT=wifi WGKSU_TEST_WIFI_SSID="家里网络" run_wgksu auto-tunnel-apply wg0
[ ! -f "$test_state/ifaces/wg0.up" ] || fail "exclude mode failed on Chinese SSID"

echo "2. Wi-Fi Include mode: starts ONLY on included SSID, stops on others"
cat > "$test_data/autotunnel.wg0" <<'EOF'
AUTOTUNNEL_ENABLED=1
WIFI_MODE=include
MOBILE_SIM1=on
MOBILE_SIM2=off
EOF
WGKSU_TEST_TRANSPORT=wifi WGKSU_TEST_WIFI_SSID="Home WiFi 5G" run_wgksu auto-tunnel-apply wg0
[ -f "$test_state/ifaces/wg0.up" ] || fail "include mode did not start wg0 on included Wi-Fi"

WGKSU_TEST_TRANSPORT=wifi WGKSU_TEST_WIFI_SSID="Untrusted WiFi" run_wgksu auto-tunnel-apply wg0
[ ! -f "$test_state/ifaces/wg0.up" ] || fail "include mode did not stop wg0 on non-included Wi-Fi"

echo "3. Dual-SIM mobile detection maps non-sequential subId (4->sim1, 7->sim2) and applies SIM1=on / SIM2=off"
net_info_sim1=$(WGKSU_TEST_TRANSPORT=mobile WGKSU_TEST_ACTIVE_SUB=4 run_wgksu net-info)
echo "$net_info_sim1" | grep -qx 'SIM_SLOT=sim1' || fail "failed to detect SIM 1 from subId=4: $net_info_sim1"
echo "$net_info_sim1" | grep -qx 'SIM1_NAME=中国移动' || fail "missing SIM1 carrier name"
echo "$net_info_sim1" | grep -qx 'SIM2_NAME=中国电信' || fail "missing SIM2 carrier name"

WGKSU_TEST_TRANSPORT=mobile WGKSU_TEST_ACTIVE_SUB=4 run_wgksu auto-tunnel-apply wg0
[ -f "$test_state/ifaces/wg0.up" ] || fail "SIM 1 (on) did not start wg0"

WGKSU_TEST_TRANSPORT=mobile WGKSU_TEST_ACTIVE_SUB=7 run_wgksu auto-tunnel-apply wg0
[ ! -f "$test_state/ifaces/wg0.up" ] || fail "SIM 2 (off) did not stop wg0"

echo "4. Wi-Fi -> Mobile switch picks Android rule 22000 table (rmnet_data2, NOT IMS rmnet_data0 or stale wlan0), uses onlink fallback, and flushes wg peer endpoint cache"
WGKSU_TEST_TRANSPORT=wifi WGKSU_TEST_WIFI_SSID="Home WiFi 5G" run_wgksu auto-tunnel-apply wg0
[ -f "$test_state/ifaces/wg0.up" ] || fail "wg0 should be up on Wi-Fi before switching"
grep -q '^198.51.100.10/32 via 192.168.1.1 dev wlan0' "$test_state/routes4.main" || fail "initial wlan0 endpoint route missing"

# Now simulate Android switching from Wi-Fi to Mobile Data while lingering wlan0 AND IMS rmnet_data0 still exist!
printf 'rmnet_data2\n' > "$test_state/default_table.4"
printf 'default via 192.168.1.1 dev wlan0 table wlan0\ndefault dev rmnet_data0 table rmnet_data0\ndefault via 10.50.60.1 dev rmnet_data2 table rmnet_data2\n' > "$test_state/underlay4"
printf 'default via 10.50.60.1 dev rmnet_data2\n' > "$test_state/table.4.rmnet_data2"
: > "$wg_log_file"

WGKSU_TEST_REQUIRE_ONLINK=1 run_wgksu repair-routes wg0
grep -q '^198.51.100.10/32 via 10.50.60.1 dev rmnet_data2 onlink' "$test_state/routes4.main" || fail "did not pin endpoint to rule-22000 rmnet_data2 with onlink fallback: $(cat "$test_state/routes4.main")"
grep -q 'wg set wg0 peer pub0 endpoint 198.51.100.10:51820' "$wg_log_file" || fail "did not flush WireGuard peer endpoint src cache after underlay switch"

echo "5. Manual start/restart is REFUSED on blacklisted Wi-Fi, non-whitelisted Wi-Fi, and disabled SIM"
# Switch to exclude mode with Home WiFi 5G in blacklist, stop wg0 first
cat > "$test_data/autotunnel.wg0" <<'EOF'
AUTOTUNNEL_ENABLED=1
WIFI_MODE=exclude
MOBILE_SIM1=on
MOBILE_SIM2=off
EOF
run_wgksu stop wg0 >/dev/null
[ ! -f "$test_state/ifaces/wg0.up" ] || fail "wg0 should be stopped before manual guard test"

# 5a. Manual start on excluded Wi-Fi MUST fail (exit 2) and keep wg0 stopped
rc=0
err_out=$(WGKSU_TEST_TRANSPORT=wifi WGKSU_TEST_WIFI_SSID="Home WiFi 5G" run_wgksu start wg0 2>&1) || rc=$?
[ "$rc" -eq 2 ] || fail "expected exit 2 on blacklisted Wi-Fi manual start, got rc=$rc out=$err_out"
[ ! -f "$test_state/ifaces/wg0.up" ] || fail "wg0 started on blacklisted Wi-Fi!"

# 5b. Manual start on SIM 2 (off) MUST fail (exit 2) and keep wg0 stopped
rc=0
err_out=$(WGKSU_TEST_TRANSPORT=mobile WGKSU_TEST_ACTIVE_SUB=7 run_wgksu start wg0 2>&1) || rc=$?
[ "$rc" -eq 2 ] || fail "expected exit 2 on disabled SIM 2 manual start, got rc=$rc out=$err_out"
[ ! -f "$test_state/ifaces/wg0.up" ] || fail "wg0 started on disabled SIM 2!"

# 5c. Manual start on non-blacklisted Wi-Fi MUST succeed, and restart while on blacklisted Wi-Fi MUST leave wg0 stopped
WGKSU_TEST_TRANSPORT=wifi WGKSU_TEST_WIFI_SSID="Coffee Shop" run_wgksu start wg0 >/dev/null
[ -f "$test_state/ifaces/wg0.up" ] || fail "wg0 failed to start on allowed Wi-Fi"
rc=0
WGKSU_TEST_TRANSPORT=wifi WGKSU_TEST_WIFI_SSID="Home WiFi 5G" run_wgksu restart wg0 >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "expected exit 2 on restart while on blacklisted Wi-Fi, got rc=$rc"
[ ! -f "$test_state/ifaces/wg0.up" ] || fail "wg0 came back up during restart on blacklisted Wi-Fi!"

# 5d. Include (whitelist) mode: manual start on non-whitelisted Wi-Fi MUST fail
cat > "$test_data/autotunnel.wg0" <<'EOF'
AUTOTUNNEL_ENABLED=1
WIFI_MODE=include
MOBILE_SIM1=on
MOBILE_SIM2=off
EOF
rc=0
WGKSU_TEST_TRANSPORT=wifi WGKSU_TEST_WIFI_SSID="Untrusted WiFi" run_wgksu start wg0 >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "expected exit 2 on non-whitelisted Wi-Fi, got rc=$rc"
[ ! -f "$test_state/ifaces/wg0.up" ] || fail "wg0 started on non-whitelisted Wi-Fi!"

echo "6. Cellular underlay (rmnet1 mtu 1432) dynamically adjusts wg0 MTU to 1352 + clamps TCP MSS, and restores 1420 on Wi-Fi"
cat > "$test_data/autotunnel.wg0" <<'EOF'
AUTOTUNNEL_ENABLED=0
WIFI_MODE=ignore
MOBILE_SIM1=ignore
MOBILE_SIM2=ignore
EOF
printf 'rmnet1\n' > "$test_state/default_table.4"
printf 'rmnet1\n' > "$test_state/default_table.6"
printf 'default dev rmnet1 mtu 1500\n' > "$test_state/table.4.rmnet1"
printf 'default dev rmnet1 mtu 1432\n' > "$test_state/table.6.rmnet1"
: > "$test_state/ipt.log"
run_wgksu start wg0 >/dev/null
[ "$(cat "$test_state/ifaces/wg0.mtu")" = "1352" ] || fail "expected cellular safe MTU 1352, got $(cat "$test_state/ifaces/wg0.mtu")"
grep -q 'WGKSU_MSS -o wg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu' "$test_state/ipt.log" || fail "missing TCPMSS clamp rule on wg0"

# Switch back to Wi-Fi (1500) and repair-routes -> restores 1420
printf 'wlan0\n' > "$test_state/default_table.4"
printf 'wlan0\n' > "$test_state/default_table.6"
printf 'default via 192.168.1.1 dev wlan0\n' > "$test_state/table.4.wlan0"
printf 'default via fe80::1 dev wlan0\n' > "$test_state/table.6.wlan0"
run_wgksu repair-routes wg0 >/dev/null
[ "$(cat "$test_state/ifaces/wg0.mtu")" = "1420" ] || fail "expected Wi-Fi MTU restored to 1420, got $(cat "$test_state/ifaces/wg0.mtu")"

run_wgksu stop wg0 >/dev/null

echo "7. Android 17 Pixel rule 31000 + Dual-SIM switch excludes IMS rmnet16/rmnet2 and picks real Internet rmnet + detects mobile SIM"
cat > "$test_state/dumpsys.connectivity" <<'EOF'
Active default network: 101
  NetworkAgentInfo{network{101}  handle{437197393933}  ni{MOBILE[LTE] CONNECTED extra: ctlte} created=2026-11-27T05:41:01.029Z  lp{{InterfaceName: rmnet1 LinkAddresses: [ 240e:424:4e62:74a5::1/64,10.138.242.165/32 ] Routes: [ ::/0 -> :: rmnet1 mtu 1432,0.0.0.0/0 -> 0.0.0.0 rmnet1 mtu 1500 ]}}  nc{[ Transports: CELLULAR Capabilities: INTERNET&NOT_RESTRICTED&TRUSTED&NOT_VPN&FOREGROUND Specifier: <TelephonyNetworkSpecifier [mSubId = 7]> SubscriptionIds: {7}]}}
  NetworkAgentInfo{network{102}  handle{441492361229}  ni{MOBILE[LTE] CONNECTED ROAMING extra: ims} created=2026-11-27T05:41:02.510Z  lp{{InterfaceName: rmnet16 LinkAddresses: [ 10.172.215.60/32 ] Routes: [ 0.0.0.0/0 -> 0.0.0.0 rmnet16 mtu 1500 ]}}  nc{[ Transports: CELLULAR Capabilities: IMS&NOT_METERED&TRUSTED&NOT_VPN&VALIDATED Specifier: <TelephonyNetworkSpecifier [mSubId = 4]> SubscriptionIds: {4}]}}
  NetworkAgentInfo{network{103}  handle{445787328525}  ni{MOBILE[LTE] CONNECTED extra: ims} created=2026-11-27T05:41:02.630Z  lp{{InterfaceName: rmnet2 LinkAddresses: [ 240e:524:4e68:635d::1/64 ] Routes: [ ::/0 -> :: rmnet2 mtu 1432 ]}}  nc{[ Transports: CELLULAR Capabilities: IMS&NOT_METERED&TRUSTED&NOT_VPN&VALIDATED Specifier: <TelephonyNetworkSpecifier [mSubId = 7]> SubscriptionIds: {7}]}}
EOF

# 7a. Android 17 net-info must recognize network{101} + ni{MOBILE[LTE] CONNECTED} + mSubId=7 (SIM 2)!
a17_net=$(run_wgksu net-info)
echo "$a17_net" | grep -qx 'TRANSPORT=mobile' || fail "Android 17 failed to detect mobile transport: $a17_net"
echo "$a17_net" | grep -qx 'SIM_SLOT=sim2' || fail "Android 17 failed to detect SIM 2 from mSubId=7: $a17_net"

# 7b. Even with IMS rmnet16 listed FIRST in table all AND Android 17 rule pref 31000 (no 22000), wg0 pins to rmnet1 (NOT rmnet16)!
printf 'rmnet1\n' > "$test_state/default_table.4"
printf '31000\n' > "$test_state/default_prio.4"
printf 'rmnet1\n' > "$test_state/default_table.6"
printf '31000\n' > "$test_state/default_prio.6"
printf 'default dev rmnet16 table rmnet16\ndefault dev rmnet1 table rmnet1\n' > "$test_state/underlay4"
printf 'default dev rmnet1\n' > "$test_state/table.4.rmnet1"
printf 'default dev rmnet1 mtu 1432\n' > "$test_state/table.6.rmnet1"
run_wgksu start wg0 >/dev/null
grep -q '^198.51.100.10/32 dev rmnet1' "$test_state/routes4.main" || fail "Android 17 pinned wrong interface (expected rmnet1, not IMS rmnet16): $(cat "$test_state/routes4.main")"

# 7c. Even if ip rule 31000 is momentarily absent (fallback scan), IMS rmnet16 is strictly excluded -> switches cleanly to SIM 2 rmnet3!
: > "$test_state/default_table.4"
cat > "$test_state/dumpsys.connectivity" <<'EOF'
Active default network: none
  NetworkAgentInfo{network{102}  ni{MOBILE[LTE] CONNECTED extra: ims}  lp{{InterfaceName: rmnet16}}  nc{[ Transports: CELLULAR Capabilities: IMS&NOT_VPN ]}}
  NetworkAgentInfo{network{105}  ni{MOBILE[LTE] CONNECTED extra: cmnet}  lp{{InterfaceName: rmnet3}}  nc{[ Transports: CELLULAR Capabilities: INTERNET&NOT_VPN Specifier: <TelephonyNetworkSpecifier [mSubId = 4]> SubscriptionIds: {4}]}}
EOF
printf 'default dev rmnet16 table rmnet16\ndefault dev rmnet3 table rmnet3\n' > "$test_state/underlay4"
printf 'default dev rmnet3\n' > "$test_state/table.4.rmnet3"
: > "$wg_log_file"
run_wgksu repair-routes wg0 >/dev/null
grep -q '^198.51.100.10/32 dev rmnet3' "$test_state/routes4.main" || fail "fallback picked IMS rmnet16 instead of real Internet rmnet3: $(cat "$test_state/routes4.main")"
grep -q 'wg set wg0 peer pub0 endpoint 198.51.100.10:51820' "$wg_log_file" || fail "did not flush peer endpoint cache on SIM switch"

run_wgksu stop wg0 >/dev/null

echo "8. Manual stop pauses Auto-Tunnel across Wi-Fi/SIM switches until manual start or auto-tunnel-resume"
rm -f "$test_state/dumpsys.connectivity"
printf 'wlan0\n' > "$test_state/default_table.4"
printf '22000\n' > "$test_state/default_prio.4"
printf 'default via 192.168.1.1 dev wlan0 table wlan0\n' > "$test_state/underlay4"
printf 'default via 192.168.1.1 dev wlan0\n' > "$test_state/table.4.wlan0"
cat > "$test_data/autotunnel.wg0" <<'EOF'
AUTOTUNNEL_ENABLED=1
WIFI_MODE=exclude
MOBILE_SIM1=on
MOBILE_SIM2=off
EOF
printf 'Home WiFi 5G\n' > "$test_data/autotunnel.wg0.ssids"

# Start on Coffee Shop Wi-Fi -> runs normally
WGKSU_TEST_TRANSPORT=wifi WGKSU_TEST_WIFI_SSID="Coffee Shop" run_wgksu start wg0 >/dev/null
[ -f "$test_state/ifaces/wg0.up" ] || fail "wg0 should be up before manual stop test"
[ ! -f "$test_data/manual_pause.wg0" ] || fail "manual_pause should be clear after start"

# Manual stop -> sets manual_pause.wg0; Auto-Tunnel MUST NOT restart even on Coffee Shop or SIM 1!
run_wgksu stop wg0 >/dev/null
[ ! -f "$test_state/ifaces/wg0.up" ] || fail "wg0 should be down after manual stop"
[ -f "$test_data/manual_pause.wg0" ] || fail "manual stop did not create manual_pause.wg0"
WGKSU_TEST_TRANSPORT=wifi WGKSU_TEST_WIFI_SSID="Coffee Shop" run_wgksu auto-tunnel-apply wg0
[ ! -f "$test_state/ifaces/wg0.up" ] || fail "auto-tunnel restarted wg0 on Wi-Fi despite manual stop!"
WGKSU_TEST_TRANSPORT=mobile WGKSU_TEST_ACTIVE_SUB=4 run_wgksu auto-tunnel-apply wg0
[ ! -f "$test_state/ifaces/wg0.up" ] || fail "auto-tunnel restarted wg0 on SIM 1 despite manual stop!"

# auto-tunnel-resume while on Home WiFi 5G -> clears manual_pause without starting, then leaving Home WiFi auto-starts!
WGKSU_TEST_TRANSPORT=wifi WGKSU_TEST_WIFI_SSID="Home WiFi 5G" run_wgksu auto-tunnel-resume wg0 >/dev/null
[ ! -f "$test_data/manual_pause.wg0" ] || fail "auto-tunnel-resume did not clear manual_pause.wg0"
[ ! -f "$test_state/ifaces/wg0.up" ] || fail "wg0 should stay down on blacklisted Home WiFi after resume"
WGKSU_TEST_TRANSPORT=mobile WGKSU_TEST_ACTIVE_SUB=4 run_wgksu auto-tunnel-apply wg0
[ -f "$test_state/ifaces/wg0.up" ] || fail "wg0 did not auto-start on SIM 1 after auto-tunnel-resume!"

# Automatic stop on Home WiFi MUST NOT create manual_pause -> leaving Home WiFi auto-starts again!
WGKSU_TEST_TRANSPORT=wifi WGKSU_TEST_WIFI_SSID="Home WiFi 5G" run_wgksu auto-tunnel-apply wg0
[ ! -f "$test_state/ifaces/wg0.up" ] || fail "wg0 did not auto-stop on Home WiFi"
[ ! -f "$test_data/manual_pause.wg0" ] || fail "automatic stop wrongly set manual_pause.wg0!"
WGKSU_TEST_TRANSPORT=wifi WGKSU_TEST_WIFI_SSID="Office 5G" run_wgksu auto-tunnel-apply wg0
[ -f "$test_state/ifaces/wg0.up" ] || fail "wg0 did not auto-start after automatic stop!"

run_wgksu stop wg0 >/dev/null
echo "all auto-tunnel and Wi-Fi->Mobile switch tests passed"
