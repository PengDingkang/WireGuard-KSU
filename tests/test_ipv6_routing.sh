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
description_file="$test_tmp/description"

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

# Mock wg binary installed at $wg_data/wg
cat > "$test_data/wg" <<'EOF'
#!/bin/sh
state="$WGKSU_TEST_STATE"
cmd="${1:-}"
shift || true
case "$cmd" in
  setconf)
    iface="$1"
    conf="$2"
    cp "$conf" "$state/ifaces/$iface.wgconf"
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
        awk '
          { gsub(/\r/, ""); sub(/#.*$/, ""); low = tolower($0) }
          low ~ /^[[:space:]]*\[peer\]/ { if (pk != "") print pk "\t" aips; pk=""; aips=""; next }
          low ~ /^[[:space:]]*publickey[[:space:]]*=/ { sub(/^[^=]*=[[:space:]]*/, ""); sub(/[[:space:]]*$/, ""); pk=$0 }
          low ~ /^[[:space:]]*allowedips[[:space:]]*=/ { sub(/^[^=]*=[[:space:]]*/, ""); gsub(/,/, " "); gsub(/[[:space:]]+/, " "); sub(/^ /, ""); sub(/ $/, ""); aips=$0 }
          END { if (pk != "") print pk "\t" (aips != "" ? aips : "(none)") }
        ' "$conf"
        ;;
      endpoints)
        awk '
          { gsub(/\r/, ""); sub(/#.*$/, ""); low = tolower($0) }
          low ~ /^[[:space:]]*\[peer\]/ { if (pk != "") print pk "\t" (ep != "" ? ep : "(none)"); pk=""; ep=""; next }
          low ~ /^[[:space:]]*publickey[[:space:]]*=/ { sub(/^[^=]*=[[:space:]]*/, ""); sub(/[[:space:]]*$/, ""); pk=$0 }
          low ~ /^[[:space:]]*endpoint[[:space:]]*=/ { sub(/^[^=]*=[[:space:]]*/, ""); sub(/[[:space:]]*$/, ""); ep=$0 }
          END { if (pk != "") print pk "\t" (ep != "" ? ep : "(none)") }
        ' "$conf"
        ;;
    esac
    ;;
esac
EOF
chmod 755 "$test_data/wg"

# Mock ip binary tracking links, addresses, main-table routes, underlay tables, and IPv4/IPv6 policy rules.
cat > "$test_bin/ip" <<'EOF'
#!/bin/sh
state="$WGKSU_TEST_STATE"
log="$WGKSU_TEST_IP_LOG"
printf 'ip %s\n' "$*" >> "$log"

family=4
case "${1:-}" in
  -4) family=4; shift ;;
  -6) family=6; shift ;;
esac

obj="${1:-}"
shift || true

case "$obj" in
  link)
    act="${1:-}"
    shift || true
    case "$act" in
      show)
        iface="$1"
        [ -f "$state/ifaces/$iface.exists" ] || exit 1
        printf '10: %s: <POINTOPOINT,NOARP,UP> mtu 1420\n' "$iface"
        ;;
      add)
        iface="$1"
        : > "$state/ifaces/$iface.exists"
        ;;
      set)
        iface="$1"
        shift || true
        case "${1:-}" in
          up) : > "$state/ifaces/$iface.up" ;;
          down) rm -f "$state/ifaces/$iface.up" ;;
        esac
        ;;
      del)
        iface="$1"
        rm -f "$state/ifaces/$iface.exists" "$state/ifaces/$iface.up" \
          "$state/ifaces/$iface.addr4" "$state/ifaces/$iface.addr6"
        for rf in "$state/routes4.main" "$state/routes6.main"; do
          [ -f "$rf" ] || continue
          grep -v " dev $iface" "$rf" > "$rf.tmp" || true
          mv "$rf.tmp" "$rf"
        done
        ;;
    esac
    ;;
  addr)
    act="${1:-}"
    shift || true
    case "$act" in
      add)
        addr="$1"
        iface="$3"
        if [ "$family" = "6" ]; then
          printf '    inet6 %s scope global %s\n' "$addr" "$iface" >> "$state/ifaces/$iface.addr6"
          # Simulate kernel connected route for non-/128 prefix
          case "$addr" in
            */128) ;;
            */*) printf '%s dev %s proto kernel metric 256\n' "${addr%/*}/${addr#*/}" "$iface" >> "$state/routes6.main" ;;
          esac
        else
          printf '    inet %s scope global %s\n' "$addr" "$iface" >> "$state/ifaces/$iface.addr4"
          case "$addr" in
            */32) ;;
            */24)
              net=$(printf '%s' "${addr%/*}" | awk -F. '{printf "%s.%s.%s.0/24", $1, $2, $3}')
              printf '%s dev %s proto kernel scope link src %s\n' "$net" "$iface" "${addr%/*}" >> "$state/routes4.main"
              ;;
          esac
        fi
        ;;
      show)
        iface=""
        for arg in "$@"; do
          case "$arg" in
            dev|scope|global) ;;
            *) iface="$arg"; break ;;
          esac
        done
        if [ "$family" = "6" ]; then
          cat "$state/ifaces/$iface.addr6" 2>/dev/null || true
        else
          cat "$state/ifaces/$iface.addr4" 2>/dev/null || true
        fi
        ;;
    esac
    ;;
  route)
    act="${1:-}"
    shift || true
    main_file="$state/routes${family}.main"
    underlay_file="$state/underlay${family}"
    case "$act" in
      show)
        if [ "${1:-}" = "table" ] && [ "${2:-}" = "all" ]; then
          cat "$main_file" 2>/dev/null || true
          cat "$underlay_file" 2>/dev/null || true
        elif [ "${1:-}" = "table" ] && [ "${2:-}" = "main" ]; then
          shift 2
          prefix="${1:-}"
          dev_filter=""
          if [ "${2:-}" = "dev" ]; then
            dev_filter="${3:-}"
          fi
          [ -f "$main_file" ] || exit 0
          if [ -n "$prefix" ]; then
            bare="${prefix%/*}"
            awk -v p="$prefix" -v b="$bare" -v d="$dev_filter" '
              ($1 == p || $1 == b) && (d == "" || index($0, " dev " d) > 0) { print }
            ' "$main_file"
          else
            cat "$main_file"
          fi
        else
          cat "$main_file" 2>/dev/null || true
        fi
        ;;
      replace|add)
        dst="$1"
        shift || true
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
    act="${1:-}"
    shift || true
    rule_file="$state/rules${family}"
    touch "$rule_file"
    case "$act" in
      show)
        printf '0:\tfrom all lookup local\n'
        cat "$rule_file"
        printf '22000:\tfrom all fwmark 0x0/0xffff iif lo lookup wlan0\n'
        ;;
      add)
        printf '1:\tfrom all lookup main\n' >> "$rule_file"
        ;;
      del)
        if [ -s "$rule_file" ]; then
          awk 'NR > 1 { print }' "$rule_file" > "$rule_file.tmp"
          mv "$rule_file.tmp" "$rule_file"
        else
          exit 1
        fi
        ;;
    esac
    ;;
esac
EOF

cat > "$test_bin/ksud" <<'EOF'
#!/bin/sh
printf '%s\n' "$5" > "$WGKSU_TEST_DESCRIPTION_FILE"
EOF

cat > "$test_bin/settings" <<'EOF'
#!/bin/sh
printf 'en-US\n'
EOF

cat > "$test_bin/ndc" <<'EOF'
#!/bin/sh
exit 1
EOF

cat > "$test_bin/setprop" <<'EOF'
#!/bin/sh
printf '%s=%s\n' "$1" "$2" >> "$WGKSU_TEST_STATE/props"
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
    WGKSU_TEST_DESCRIPTION_FILE="$description_file" \
    sh "$test_wgksu" "$@"
}

# Set up dual-stack Android underlay tables (wlan0)
printf 'default via 192.168.1.1 dev wlan0 table wlan0\n' > "$test_state/underlay4"
printf 'default via fe80::1 dev wlan0 table wlan0 proto ra metric 1024\n' > "$test_state/underlay6"

echo "1. Dual-stack CRLF + multiline Address config pins IPv6 endpoint and adds IPv6 policy rule"
printf '[Interface]\r\nPrivateKey = priv0\r\nAddress = 10.0.0.2/32 # v4\r\nAddress = fd00:1234::2/128 # v6\r\nDNS = 1.1.1.1, 2606:4700:4700::1111\r\nMTU = 1380 # custom\r\n\r\n[Peer]\r\nPublicKey = pub0\r\nEndpoint = [2001:db8::1]:51820\r\nAllowedIPs = 0.0.0.0/0, ::/0\r\n' > "$test_data/wg0.conf"

run_wgksu start wg0 >/dev/null

grep -q 'ip -4 addr add 10.0.0.2/32 dev wg0' "$ip_log" || fail "missing IPv4 address add"
grep -q 'ip -6 addr add fd00:1234::2/128 dev wg0' "$ip_log" || fail "missing IPv6 address add (CRLF/multiline broken)"
grep -q 'ip link set wg0 mtu 1380' "$ip_log" || fail "missing MTU setting"
grep -q '^2001:db8::1/128 via fe80::1 dev wlan0' "$test_state/routes6.main" || fail "IPv6 endpoint /128 was not pinned in main table"
grep -q '^0.0.0.0/0 dev wg0' "$test_state/routes4.main" || fail "missing IPv4 default route on wg0"
grep -q '^::/0 dev wg0 metric 50' "$test_state/routes6.main" || fail "missing IPv6 default route with metric 50 on wg0"
[ "$(wc -l < "$test_state/rules4")" -eq 1 ] || fail "expected exactly 1 IPv4 pref 1 rule"
[ "$(wc -l < "$test_state/rules6")" -eq 1 ] || fail "expected exactly 1 IPv6 pref 1 rule"
grep -q 'net.dns1=1.1.1.1' "$test_state/props" || fail "missing IPv4 DNS setprop"
grep -q 'net.dns2=2606:4700:4700::1111' "$test_state/props" || fail "missing IPv6 DNS setprop"

echo "2. Multi-interface startup stays idempotent and stopping second interface keeps wg0 rules"
cat > "$test_data/wg1.conf" <<'EOF'
[Interface]
PrivateKey = priv1
Address = 10.10.0.2/24

[Peer]
PublicKey = pub1
Endpoint = 198.51.100.10:51820
AllowedIPs = 10.10.0.0/24
EOF

run_wgksu start wg1 >/dev/null
[ "$(wc -l < "$test_state/rules4")" -eq 1 ] || fail "duplicate IPv4 pref 1 rule added on second interface"
[ "$(wc -l < "$test_state/rules6")" -eq 1 ] || fail "duplicate IPv6 pref 1 rule added on second interface"
grep -q '^198.51.100.10/32 via 192.168.1.1 dev wlan0' "$test_state/routes4.main" || fail "IPv4 endpoint /32 was not pinned in main table"
grep -q '^10.10.0.0/24 dev wg1 proto kernel scope link src 10.10.0.2' "$test_state/routes4.main" || fail "connected kernel subnet route was clobbered"

run_wgksu stop wg1 >/dev/null
[ "$(wc -l < "$test_state/rules4")" -eq 1 ] || fail "stopping wg1 dropped IPv4 rule while wg0 is still running"
[ "$(wc -l < "$test_state/rules6")" -eq 1 ] || fail "stopping wg1 dropped IPv6 rule while wg0 is still running"
if grep -q '^198.51.100.10/32' "$test_state/routes4.main"; then
  fail "stopping wg1 left stale IPv4 endpoint route"
fi

echo "3. repair-routes restores dropped IPv6 policy rule and repairs endpoint route after network switch"
: > "$test_state/rules6"
printf '::/0 dev rmnet_data0 table rmnet_data0 proto ra metric 1024\n' > "$test_state/underlay6"
run_wgksu repair-routes wg0 >/dev/null
[ "$(wc -l < "$test_state/rules6")" -eq 1 ] || fail "repair-routes did not restore missing IPv6 policy rule"
grep -q '^2001:db8::1/128 dev rmnet_data0' "$test_state/routes6.main" || fail "repair-routes did not update IPv6 endpoint route to rmnet_data0"

echo "4. Stopping final interface cleans up both IPv4 and IPv6 policy rules and endpoint routes"
run_wgksu stop wg0 >/dev/null
[ "$(wc -l < "$test_state/rules4")" -eq 0 ] || fail "IPv4 policy rule was not removed after stopping all interfaces"
[ "$(wc -l < "$test_state/rules6")" -eq 0 ] || fail "IPv6 policy rule was not removed after stopping all interfaces"
if grep -q '^2001:db8::1/128' "$test_state/routes6.main"; then
  fail "IPv6 endpoint route was not removed on wg_down"
fi

echo "5. IPv6-only interface adds only IPv6 policy rule and reports IPv6 in KSU description"
rm -f "$test_data/wg0.conf" "$test_data/wg1.conf"
cat > "$test_data/wg6.conf" <<'EOF'
[Interface]
PrivateKey = priv6
Address = 2001:db8:cafe::2/64

[Peer]
PublicKey = pub6
Endpoint = [2001:db8::9]:51820
AllowedIPs = ::/0
EOF

run_wgksu start wg6 >/dev/null
[ "$(wc -l < "$test_state/rules4")" -eq 0 ] || fail "IPv6-only interface unexpectedly added IPv4 rule"
[ "$(wc -l < "$test_state/rules6")" -eq 1 ] || fail "IPv6-only interface did not add IPv6 rule"
[ "$(cat "$description_file")" = "✅ Running | wg6: 2001:db8:cafe::2" ] || fail "KSU description did not fall back to IPv6 address: $(cat "$description_file")"

run_wgksu stop wg6 >/dev/null
[ "$(wc -l < "$test_state/rules6")" -eq 0 ] || fail "IPv6-only stop left IPv6 policy rule behind"

echo "all IPv6 routing tests passed"
