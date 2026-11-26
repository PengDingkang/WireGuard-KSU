#!/bin/sh

set -eu

repo_dir=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
test_tmp=$(mktemp -d)
test_data="$test_tmp/data"
test_module="$test_tmp/modules/WireGuard-KSU"
test_lib="$test_tmp/wgksu-lock-functions.sh"
test_full_lib="$test_tmp/wgksu-functions.sh"
test_holder="$test_tmp/wgksu-lock-holder.sh"
test_delayed_holder="$test_tmp/delayed-wgksu-holder"
test_wedged_holder="$test_tmp/wedged-wgksu-holder.sh"
test_busybox="$test_tmp/busybox"
test_busybox_no_flock="$test_tmp/busybox-no-flock"
wedged_holder_pid_file="$test_tmp/wedged-holder.pid"
holder_pid=""

cleanup() {
  if [ -n "$holder_pid" ]; then
    kill -TERM "$holder_pid" 2>/dev/null || true
    wait "$holder_pid" 2>/dev/null || true
  fi
  if [ -f "$wedged_holder_pid_file" ]; then
    wedged_holder_pid=$(cat "$wedged_holder_pid_file")
    kill -KILL "$wedged_holder_pid" 2>/dev/null || true
  fi
  rm -rf "$test_tmp"
}
trap cleanup 0 1 2 15

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_exists() {
  [ -e "$1" ] || fail "expected $1 to exist"
}

assert_not_exists() {
  [ ! -e "$1" ] || fail "expected $1 not to exist"
}

wait_for_file() {
  wait_tries=0
  while [ ! -f "$1" ]; do
    wait_tries=$((wait_tries + 1))
    [ "$wait_tries" -lt 50 ] || fail "timed out waiting for $1"
    sleep 0.1
  done
}

mkdir -p "$test_data" "$test_module"
cp -R "$repo_dir/translations" "$test_module/"

# Redirect a complete wgksu copy and its BusyBox fallback into the test temp
# directory. The full copy runs the internal lock-holder command, while the
# extracted prefix lets test processes call the production lock functions.
cp "$repo_dir/tests/helpers/busybox" "$test_busybox"
cp "$repo_dir/tests/helpers/busybox-no-flock" "$test_busybox_no_flock"
cp "$repo_dir/tests/helpers/delayed-wgksu-holder" "$test_delayed_holder"
chmod 755 "$test_busybox"
chmod 755 "$test_busybox_no_flock"
chmod 755 "$test_delayed_holder"
PATH="$test_tmp:$PATH"
export PATH
sed -e "s|^wg_data=.*|wg_data=\"$test_data\"|" \
    -e "s|^wg_module=.*|wg_module=\"$test_module\"|" \
    "$repo_dir/wgksu" > "$test_holder"
chmod 755 "$test_holder"
awk '
  /^  : > "\$holder_ready_file"$/ {
    print "  if [ \"${WGKSU_TEST_HOLDER_HANG_AFTER_LOCK:-0}\" = \"1\" ]; then"
    print "    echo \"$$\" > \"${WGKSU_TEST_HOLDER_PID_FILE:?}\""
    print "    while :; do"
    print "      :"
    print "    done"
    print "  fi"
  }
  { print }
' "$test_holder" > "$test_wedged_holder"
chmod 755 "$test_wedged_holder"
grep -q WGKSU_TEST_HOLDER_HANG_AFTER_LOCK "$test_wedged_holder" ||
  fail "failed to inject wedged holder test hook"
awk '/^# --- wg-quick replacement/{ exit } { print }' "$test_holder" > "$test_lib"
awk '$0 == "case \"$1\" in" { exit } { print }' "$test_holder" > "$test_full_lib"
WGKSU_SELF="$test_holder"
export WGKSU_SELF

lock_file="$test_data/endpoint-routes.wg1.lock.fd"

echo "normal acquire/release"
sh -c '
  . "$1"
  acquire_endpoint_routes_lock wg1
  test -f "$wg_data/endpoint-routes.wg1.lock.fd"
  release_endpoint_routes_lock
' sh "$test_lib"
assert_exists "$lock_file"
[ "$(stat -c %a "$lock_file")" = "600" ] ||
  fail "expected $lock_file mode 600"

echo "delayed holder initialization is tolerated"
WGKSU_TEST_REAL_HOLDER="$test_holder"
WGKSU_TEST_HOLDER_DELAY=1.5
export WGKSU_TEST_REAL_HOLDER WGKSU_TEST_HOLDER_DELAY
sh -c '
  . "$1"
  wgksu_self="$2"
  acquire_endpoint_routes_lock delayed
  release_endpoint_routes_lock
' sh "$test_lib" "$test_delayed_holder"
assert_exists "$test_data/endpoint-routes.delayed.lock.fd"

echo "holder initialization timeout cannot orphan the kernel lock"
WGKSU_TEST_HOLDER_HANG_AFTER_LOCK=1
WGKSU_TEST_HOLDER_PID_FILE="$wedged_holder_pid_file"
export WGKSU_TEST_HOLDER_HANG_AFTER_LOCK WGKSU_TEST_HOLDER_PID_FILE
if sh -c '
  . "$1"
  wgksu_self="$2"
  acquire_endpoint_routes_lock wedged
' sh "$test_lib" "$test_wedged_holder"; then
  fail "wedged holder unexpectedly initialized"
fi
if ! sh -c '
  . "$1"
  acquire_endpoint_routes_lock wedged
  release_endpoint_routes_lock
' sh "$test_lib"; then
  fail "holder initialization timeout left the kernel lock held"
fi
unset WGKSU_TEST_HOLDER_HANG_AFTER_LOCK WGKSU_TEST_HOLDER_PID_FILE

echo "concurrent callers serialize"
holder_ready="$test_tmp/holder-ready"
sh -c '
  . "$1"
  acquire_endpoint_routes_lock wg1
  : > "$2"
  sleep 1
  release_endpoint_routes_lock
' sh "$test_lib" "$holder_ready" &
holder_pid=$!
wait_for_file "$holder_ready"
sh -c '
  . "$1"
  acquire_endpoint_routes_lock wg1
  release_endpoint_routes_lock
' sh "$test_lib"
wait "$holder_pid"
holder_pid=""

echo "TERM releases the kernel lock"
holder_ready="$test_tmp/term-ready"
sh -c '
  . "$1"
  acquire_endpoint_routes_lock wg1
  : > "$2"
  while :; do sleep 1; done
' sh "$test_lib" "$holder_ready" &
holder_pid=$!
wait_for_file "$holder_ready"
kill -TERM "$holder_pid"
wait "$holder_pid" 2>/dev/null || true
holder_pid=""
sh -c '
  . "$1"
  acquire_endpoint_routes_lock wg1
  release_endpoint_routes_lock
' sh "$test_lib"

echo "SIGKILL releases the kernel lock without owner recovery"
holder_ready="$test_tmp/kill-ready"
sh -c '
  . "$1"
  acquire_endpoint_routes_lock wg1
  : > "$2"
  while :; do sleep 1; done
' sh "$test_lib" "$holder_ready" &
holder_pid=$!
wait_for_file "$holder_ready"
kill -KILL "$holder_pid"
wait "$holder_pid" 2>/dev/null || true
holder_pid=""
sh -c '
  . "$1"
  acquire_endpoint_routes_lock wg1
  release_endpoint_routes_lock
' sh "$test_lib"
assert_not_exists "$test_data/endpoint-routes.wg1.lock"
assert_not_exists "$test_data/endpoint-routes.wg1.lock.reclaim"

echo "concurrent callers proceed after SIGKILL"
contender_pids=""
for _ in 1 2 3 4; do
  sh -c '
    . "$1"
    acquire_endpoint_routes_lock wg1
    sleep 0.1
    release_endpoint_routes_lock
  ' sh "$test_lib" &
  contender_pids="$contender_pids $!"
done
for contender_pid in $contender_pids; do
  wait "$contender_pid"
done

echo "live holder is never bypassed"
holder_ready="$test_tmp/live-ready"
sh -c '
  . "$1"
  acquire_endpoint_routes_lock wg1
  : > "$2"
  while :; do sleep 1; done
' sh "$test_lib" "$holder_ready" &
holder_pid=$!
wait_for_file "$holder_ready"
sh -c '
  . "$1"
  cleanup_boot_endpoint_routes_locks
' sh "$test_lib"
if sh -c '
  . "$1"
  acquire_endpoint_routes_lock wg1
' sh "$test_lib"; then
  fail "contender unexpectedly acquired a live lock"
fi
kill -TERM "$holder_pid"
wait "$holder_pid" 2>/dev/null || true
holder_pid=""

echo "boot cleanup removes malformed legacy owners"
legacy_empty="$test_data/endpoint-routes.empty.lock"
legacy_partial="$test_data/endpoint-routes.partial.lock"
legacy_reclaim="$test_data/endpoint-routes.partial.lock.reclaim"
legacy_nonempty="$test_data/endpoint-routes.nonempty.lock"
mkdir "$legacy_empty" "$legacy_partial" "$legacy_reclaim" "$legacy_nonempty"
: > "$legacy_empty/owner"
printf '%s\n' "partial-owner" > "$legacy_partial/owner"
printf '%s\n' "partial-reclaimer" > "$legacy_reclaim/owner"
: > "$legacy_nonempty/unexpected"
sh -c '
  . "$1"
  cleanup_boot_endpoint_routes_locks
' sh "$test_lib"
assert_not_exists "$legacy_empty"
assert_not_exists "$legacy_partial"
assert_not_exists "$legacy_reclaim"
assert_exists "$legacy_nonempty/unexpected"

echo "legacy debris cannot block the new lock path"
sh -c '
  . "$1"
  acquire_endpoint_routes_lock nonempty
  release_endpoint_routes_lock
' sh "$test_lib"
assert_exists "$test_data/endpoint-routes.nonempty.lock.fd"

echo "system flock is used when BusyBox omits the applet"
sh -c '
  . "$1"
  busybox="$2"
  acquire_endpoint_routes_lock system-fallback
  test "$endpoint_routes_flock_backend" = system
  release_endpoint_routes_lock
' sh "$test_lib" "$test_busybox_no_flock"
assert_exists "$test_data/endpoint-routes.system-fallback.lock.fd"

echo "startup fails before interface creation when no compatible flock exists"
valid_conf="$test_data/no-flock.conf"
printf '%s\n' \
  "[Interface]" \
  "PrivateKey = test-private-key" \
  "[Peer]" \
  "PublicKey = test-public-key" \
  "Endpoint = 192.0.2.1:51820" > "$valid_conf"
if sh -c '
  . "$1"
  ip_add_marker="$2"
  conf_path="$3"
  output_path="$4"
  endpoint_routes_flock_available() { return 1; }
  ip() {
    if [ "${1:-} ${2:-}" = "link add" ]; then
      : > "$ip_add_marker"
    fi
    return 1
  }
  if wg_up "$conf_path" wg1 > "$output_path"; then
    exit 1
  fi
  grep -q "refusing to start without endpoint route locking" "$output_path"
  test ! -e "$ip_add_marker"
' sh "$test_full_lib" "$test_tmp/ip-link-add-called" "$valid_conf" "$test_tmp/no-flock-output"; then
  :
else
  fail "wg_up did not fail safely without flock"
fi

echo "start command preserves startup failures"
if sh "$test_holder" start missing > "$test_tmp/start-missing-output"; then
  fail "start command hid wg_up failure"
fi
grep -q "config not found" "$test_tmp/start-missing-output" ||
  fail "missing config error was not reported"

echo "all endpoint route lock tests passed"
