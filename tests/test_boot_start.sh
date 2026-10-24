#!/bin/sh

set -eu

repo_dir=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
test_tmp=$(mktemp -d)
boot_lib="$test_tmp/boot-functions.sh"
fake_wgksu="$test_tmp/wgksu-fail-once"
count_file="$test_tmp/start-count"
log_file="$test_tmp/error.log"

cleanup() {
  rm -rf "$test_tmp"
}
trap cleanup 0 1 2 15

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

awk '$0 == "(" { exit } { print }' "$repo_dir/boot-completed.sh" > "$boot_lib"
cp "$repo_dir/tests/helpers/wgksu-fail-once" "$fake_wgksu"
chmod 755 "$fake_wgksu"
busybox=busybox
export busybox
# shellcheck disable=SC1090
. "$boot_lib"

wg_data="$test_tmp/data"
log_file="$test_tmp/error.log"
WGKSU="$fake_wgksu"
WGKSU_TEST_COUNT_FILE="$count_file"
export WGKSU WGKSU_TEST_COUNT_FILE wg_data

# Called indirectly by start_iface_when_ready from the sourced boot script.
# shellcheck disable=SC2317,SC2329
boot_network_ready() {
  return 0
}

sleep() {
  :
}

start_iface_when_ready "$test_tmp/wg1.conf" wg1 ||
  fail "boot worker did not recover from a transient start failure"

[ "$(cat "$count_file")" = "2" ] ||
  fail "expected two start attempts"
grep -q "start failed; retrying" "$log_file" ||
  fail "boot retry was not logged"

echo "late network readiness preserves the startup retry budget"
rm -f "$count_file" "$log_file"
network_checks=0
# Called indirectly by start_iface_when_ready from the sourced boot script.
# shellcheck disable=SC2317,SC2329
boot_network_ready() {
  network_checks=$((network_checks + 1))
  [ "$network_checks" -ge 60 ]
}

start_iface_when_ready "$test_tmp/wg1.conf" wg1 ||
  fail "late network readiness consumed the startup retry budget"

[ "$network_checks" = "60" ] ||
  fail "expected network readiness on check 60"
[ "$(cat "$count_file")" = "2" ] ||
  fail "expected two start attempts after late network readiness"
grep -q "network ready after 295s" "$log_file" ||
  fail "late network readiness was not logged"
if grep -q "network not ready" "$log_file"; then
  fail "late network readiness was incorrectly reported as a timeout"
fi

echo "boot start retry test passed"
