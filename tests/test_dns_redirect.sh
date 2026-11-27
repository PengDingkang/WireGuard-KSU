#!/bin/sh

set -eu

repo_dir=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
test_tmp=$(mktemp -d)
test_data="$test_tmp/data"
test_module="$test_tmp/modules/WireGuard-KSU"
test_bin="$test_tmp/bin"
test_state="$test_tmp/state"
test_wgksu="$test_tmp/wgksu"

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
      show) [ -f "$state/ifaces/$1.exists" ] || exit 1; printf '10: %s: <UP> mtu 1420\n' "$1" ;;
      add) : > "$state/ifaces/$1.exists" ;;
      set)
        iface="$1"; shift || true
        case "${1:-}" in
          up) : > "$state/ifaces/$iface.up" ;;
          down) rm -f "$state/ifaces/$iface.up" ;;
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
    rf="$state/rules${family}"
    touch "$rf"
    case "$act" in
      show)
        printf '0:\tfrom all lookup local\n'
        cat "$rf"
        printf '22000:\tfrom all fwmark 0x0/0xffff iif lo lookup wlan0\n'
        ;;
      add) printf '1:\tfrom all lookup main\n' >> "$rf" ;;
      del) : > "$rf" ;;
    esac
    ;;
esac
EOF

# Stateful mock iptables / ip6tables storing rules per (family, table)
cat > "$test_bin/iptables" <<'EOF'
#!/bin/sh
state="$WGKSU_TEST_STATE"
fam="${WGKSU_IPT_FAM:-4}"
[ "${1:-}" = "-w" ] && shift
tbl="filter"
if [ "${1:-}" = "-t" ]; then
  tbl="$2"
  shift 2
fi
if [ "$fam" = "6" ] && [ "$tbl" = "nat" ] && [ "${WGKSU_TEST_NO_IP6_NAT:-0}" = "1" ]; then
  exit 1
fi
op="${1:-}"; shift || true
chain="${1:-}"; shift || true
rfile="$state/ipt${fam}.${tbl}"
cfile="$state/ipt${fam}.${tbl}.chains"
touch "$rfile" "$cfile"
printf 'ipt%s -t %s %s %s %s\n' "$fam" "$tbl" "$op" "$chain" "$*" >> "$state/ipt.log"
case "$op" in
  -N)
    grep -qx "$chain" "$cfile" && exit 1
    printf '%s\n' "$chain" >> "$cfile"
    ;;
  -X)
    grep -qx "$chain" "$cfile" || exit 1
    grep -vx "$chain" "$cfile" > "$cfile.tmp" || true
    mv "$cfile.tmp" "$cfile"
    ;;
  -F)
    grep -v "^${chain} " "$rfile" > "$rfile.tmp" || true
    mv "$rfile.tmp" "$rfile"
    ;;
  -A)
    printf '%s %s\n' "$chain" "$*" >> "$rfile"
    ;;
  -I)
    case "${1:-}" in [0-9]*) shift ;; esac
    printf '%s %s\n' "$chain" "$*" >> "$rfile"
    ;;
  -C)
    grep -Fxq "${chain} $*" "$rfile"
    ;;
  -D)
    grep -Fxq "${chain} $*" "$rfile" || exit 1
    awk -v target="${chain} $*" '!removed && $0 == target { removed=1; next } { print }' "$rfile" > "$rfile.tmp"
    mv "$rfile.tmp" "$rfile"
    ;;
esac
EOF

cat > "$test_bin/ip6tables" <<'EOF'
#!/bin/sh
WGKSU_IPT_FAM=6 exec "$(dirname "$0")/iptables" "$@"
EOF

cat > "$test_bin/ndc" <<'EOF'
#!/bin/sh
printf 'ndc %s\n' "$*" >> "$WGKSU_TEST_STATE/ndc.log"
exit 0
EOF

cat > "$test_bin/service" <<'EOF'
#!/bin/sh
printf 'service %s\n' "$*" >> "$WGKSU_TEST_STATE/service.log"
exit 0
EOF

cat > "$test_bin/cmd" <<'EOF'
#!/bin/sh
printf 'cmd %s\n' "$*" >> "$WGKSU_TEST_STATE/cmd.log"
exit 0
EOF

cat > "$test_bin/dumpsys" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "connectivity" ] && [ -f "$WGKSU_TEST_STATE/dumpsys.connectivity" ]; then
  cat "$WGKSU_TEST_STATE/dumpsys.connectivity"
fi
exit 0
EOF

cat > "$test_bin/settings" <<'EOF'
#!/bin/sh
state="$WGKSU_TEST_STATE"
sdir="$state/settings"
mkdir -p "$sdir"
op="${1:-}"
ns="${2:-}"
key="${3:-}"
val="${4:-}"
case "$op" in
  get)
    if [ "$key" = "private_dns_mode" ]; then
      printf '%s\n' "${WGKSU_TEST_PDNS:-opportunistic}"
    elif [ -f "$sdir/${ns}.${key}" ]; then
      cat "$sdir/${ns}.${key}"
    elif [ "$key" = "system_locales" ]; then
      printf 'en-US\n'
    else
      printf 'null\n'
    fi
    ;;
  put)
    printf '%s\n' "$val" > "$sdir/${ns}.${key}"
    ;;
  delete)
    rm -f "$sdir/${ns}.${key}"
    ;;
esac
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
    WGKSU_TEST_PDNS="${WGKSU_TEST_PDNS:-opportunistic}" \
    WGKSU_TEST_NO_IP6_NAT="${WGKSU_TEST_NO_IP6_NAT:-0}" \
    sh "$test_wgksu" "$@"
}

echo "1. Dual-stack DNS = 10.10.10.1, fd42::1 installs v4+v6 DNAT, SNAT, DNS host routes, DoT guard, and flushes netd cache"
cat > "$test_data/wg0.conf" <<'EOF'
[Interface]
PrivateKey = priv0
Address = 10.10.10.4/32, fd42::2/128
DNS = 10.10.10.1, fd42::1

[Peer]
PublicKey = pub0
Endpoint = 198.51.100.10:51820
AllowedIPs = 0.0.0.0/0, ::/0
EOF

run_wgksu start wg0 >/dev/null

grep -q '^10.10.10.1/32 dev wg0' "$test_state/routes4.main" || fail "missing IPv4 DNS host route via wg0"
grep -q '^fd42::1/128 dev wg0 metric 50' "$test_state/routes6.main" || fail "missing IPv6 DNS host route via wg0"
grep -q '^WGKSU_DNS -p udp --dport 53 -j DNAT --to-destination 10.10.10.1:53$' "$test_state/ipt4.nat" || fail "missing IPv4 UDP DNS DNAT"
grep -q '^WGKSU_DNS -p tcp --dport 53 -j DNAT --to-destination 10.10.10.1:53$' "$test_state/ipt4.nat" || fail "missing IPv4 TCP DNS DNAT"
grep -q '^WGKSU_DNS_POST -o wg0 -p udp --dport 53 -j SNAT --to-source 10.10.10.4$' "$test_state/ipt4.nat" || fail "missing IPv4 DNS SNAT on wg0"
grep -q '^WGKSU_DNS -p udp --dport 53 -j DNAT --to-destination \[fd42::1\]:53$' "$test_state/ipt6.nat" || fail "missing IPv6 UDP DNS DNAT"
grep -q '^WGKSU_DNS_POST -o wg0 -p udp --dport 53 -j SNAT --to-source fd42::2$' "$test_state/ipt6.nat" || fail "missing IPv6 DNS SNAT on wg0"
grep -q '^WGKSU_DNS_BLOCK -d fe80::/10 -p udp --dport 53 -j REJECT$' "$test_state/ipt6.filter" || fail "missing link-local IPv6 DNS reject"
grep -q '^WGKSU_DNS_BLOCK -p tcp --dport 853 -j REJECT' "$test_state/ipt4.filter" || fail "missing opportunistic DoT 853 guard"
grep -q 'ndc resolver flushdefaultif' "$test_state/ndc.log" || fail "did not flush netd DNS cache"

dns_st=$(run_wgksu dns-status)
echo "$dns_st" | grep -qx 'V4_NAT=1' || fail "dns-status V4_NAT not 1: $dns_st"
echo "$dns_st" | grep -qx 'V6_MODE=nat' || fail "dns-status V6_MODE not nat: $dns_st"

echo "2. Stopping wg0 cleanly removes ALL iptables/ip6tables DNS chains and rules"
run_wgksu stop wg0 >/dev/null
[ ! -s "$test_state/ipt4.nat" ] || fail "leftover IPv4 nat rules after stop: $(cat "$test_state/ipt4.nat")"
[ ! -s "$test_state/ipt6.nat" ] || fail "leftover IPv6 nat rules after stop: $(cat "$test_state/ipt6.nat")"
[ ! -s "$test_state/ipt4.filter" ] || fail "leftover IPv4 filter rules after stop"
[ ! -s "$test_state/ipt6.filter" ] || fail "leftover IPv6 filter rules after stop"

echo "3. IPv4-only DNS = 10.10.10.1 blocks IPv6 port 53 so Android netd never leaks to ISP IPv6 DNS"
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

run_wgksu start wg0 >/dev/null
grep -q '^WGKSU_DNS -p udp --dport 53 -j DNAT --to-destination 10.10.10.1:53$' "$test_state/ipt4.nat" || fail "missing IPv4 DNS DNAT"
grep -q '^WGKSU_DNS_BLOCK -p udp --dport 53 -j REJECT$' "$test_state/ipt6.filter" || fail "IPv6 port 53 was not rejected when only IPv4 DNS configured"
dns_st2=$(run_wgksu dns-status)
echo "$dns_st2" | grep -qx 'V6_MODE=block' || fail "dns-status V6_MODE not block: $dns_st2"

echo "4. Strict private_dns_mode=hostname skips DoT 853 reject to avoid breaking explicit user DoT"
run_wgksu stop wg0 >/dev/null
WGKSU_TEST_PDNS=hostname run_wgksu start wg0 >/dev/null
if grep -q -- '--dport 853' "$test_state/ipt4.filter"; then
  fail "DoT 853 was blocked even when user set strict private_dns_mode=hostname"
fi

echo "5. repair-routes self-heals flushed iptables DNS rules"
: > "$test_state/ipt4.nat"
: > "$test_state/ipt4.nat.chains"
run_wgksu repair-routes wg0 >/dev/null
grep -q '^WGKSU_DNS -p udp --dport 53 -j DNAT --to-destination 10.10.10.1:53$' "$test_state/ipt4.nat" || fail "repair-routes did not restore flushed DNS DNAT rules"

run_wgksu stop wg0 >/dev/null

echo "6. Android 10-16 dnsresolver flush & Pixel NetworkMonitor revalidation targets ONLY unvalidated physical Internet netIds"
cat > "$test_state/dumpsys.connectivity" <<'EOF'
Active default network: 100
Current Networks:
  NetworkAgentInfo{network{100}  handle{432902426637}  ni{[type: WIFI[], state: CONNECTED/CONNECTED]} created=2026-11-27T05:00:00Z  lp{InterfaceName: wlan0}  nc{[ Transports: WIFI Capabilities: NOT_METERED&INTERNET&NOT_RESTRICTED&TRUSTED&NOT_VPN&FOREGROUND ]}}
  NetworkAgentInfo{network{101}  handle{437197393933}  ni{[type: MOBILE[5G], state: CONNECTED/CONNECTED]} created=2026-11-27T05:00:00Z lastValidated 2026-11-27T05:00:02Z  lp{InterfaceName: rmnet_data2}  nc{[ Transports: CELLULAR Capabilities: INTERNET&NOT_RESTRICTED&TRUSTED&NOT_VPN&VALIDATED ]}}
  NetworkAgentInfo{network{102}  handle{441492361229}  ni{[type: MOBILE_IMS[LTE], state: CONNECTED/CONNECTED]} created=2026-11-27T05:00:00Z  lp{InterfaceName: rmnet_data0}  nc{[ Transports: CELLULAR Capabilities: IMS&NOT_RESTRICTED&TRUSTED&NOT_VPN ]}}
  NetworkAgentInfo{network{103}  handle{445787328525}  ni{[type: WIFI[], state: CONNECTED/CONNECTED]} created=2026-11-27T05:00:00Z lingering  lp{InterfaceName: wlan1}  nc{[ Transports: WIFI Capabilities: INTERNET&NOT_VPN ]}}
  NetworkAgentInfo{network{104}  handle{450082295821}  ni{[type: VPN[], state: CONNECTED/CONNECTED]} created=2026-11-27T05:00:00Z  lp{InterfaceName: tun0}  nc{[ Transports: VPN Capabilities: INTERNET&NOT_RESTRICTED ]}}
EOF
: > "$test_state/service.log"
: > "$test_state/cmd.log"

run_wgksu start wg0 >/dev/null
grep -qx 'service call dnsresolver 10 i32 100' "$test_state/service.log" || fail "did not flush Android 10+ dnsresolver cache for netId 100: $(cat "$test_state/service.log")"
grep -qx 'service call dnsresolver 10 i32 101' "$test_state/service.log" || fail "did not flush Android 10+ dnsresolver cache for netId 101"
grep -qx 'cmd connectivity reevaluate 100' "$test_state/cmd.log" || fail "did not trigger reevaluate for unvalidated netId 100: $(cat "$test_state/cmd.log")"
for skip_id in 101 102 103 104; do
  if grep -qx "cmd connectivity reevaluate ${skip_id}" "$test_state/cmd.log"; then
    fail "should NOT reevaluate netId ${skip_id} (validated/IMS/lingering/VPN)"
  fi
done

run_wgksu stop wg0 >/dev/null

echo "7. Network with historical lastValidated but missing VALIDATED capability is still revalidated"
cat > "$test_state/dumpsys.connectivity" <<'EOF'
Active default network: 105
  NetworkAgentInfo{network{105} ni{MOBILE[LTE] CONNECTED extra: ctlte} created 24386 lastValidated 25000 partialConnectivity 245822 lp{InterfaceName: rmnet1} nc{[ Transports: CELLULAR Capabilities: INTERNET&NOT_VPN&PARTIAL_CONNECTIVITY ]}}
EOF
: > "$test_state/cmd.log"
run_wgksu revalidate-net >/dev/null
grep -qx 'cmd connectivity reevaluate 105' "$test_state/cmd.log" || fail "failed to revalidate netId 105 with historical lastValidated: $(cat "$test_state/cmd.log")"

echo "8. captive-portal cn / ignore / default switches Android 17 probe URLs and cleanly restores backup"
[ "$(run_wgksu captive-portal status)" = "default" ] || fail "initial captive-portal status should be default"
run_wgksu captive-portal cn
[ "$(run_wgksu captive-portal status)" = "cn" ] || fail "captive-portal status should be cn"
[ "$(cat "$test_state/settings/global.captive_portal_https_url")" = "https://connect.rom.miui.com/generate_204" ] || fail "missing CN https URL"
[ "$(cat "$test_state/settings/global.captive_portal_http_url")" = "http://connect.rom.miui.com/generate_204" ] || fail "missing CN http URL"
[ "$(cat "$test_state/settings/global.captive_portal_mode")" = "1" ] || fail "captive_portal_mode should stay 1 in cn mode"
run_wgksu captive-portal ignore
[ "$(run_wgksu captive-portal status)" = "ignore" ] || fail "captive-portal status should be ignore"
[ "$(cat "$test_state/settings/global.captive_portal_mode")" = "0" ] || fail "captive_portal_mode should be 0 in ignore mode"
run_wgksu captive-portal default
[ "$(run_wgksu captive-portal status)" = "default" ] || fail "captive-portal status should return to default"
[ ! -f "$test_state/settings/global.captive_portal_https_url" ] || fail "default restore did not delete custom https URL"
[ ! -f "$test_data/captive_portal.backup" ] || fail "backup file should be removed after restoring default"

echo "all global tunnel DNS redirect tests passed"
