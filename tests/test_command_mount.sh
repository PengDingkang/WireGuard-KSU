#!/bin/sh

set -eu

repo_dir=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
test_tmp=$(mktemp -d)
test_data="$test_tmp/data"
test_module="$test_tmp/modules/WireGuard-KSU"

cleanup() {
  rm -rf "$test_tmp"
}
trap cleanup 0 1 2 15

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

mkdir -p "$test_data" "$test_module" "$test_tmp/bin"
printf 'existing user config\n' > "$test_data/wg0.conf"
cat > "$test_tmp/wg" <<'EOF'
#!/bin/sh
case "$1" in
  genkey) echo test-private-key ;;
  pubkey) cat >/dev/null; echo test-public-key ;;
  *) exit 1 ;;
esac
EOF
chmod 755 "$test_tmp/wg"
sed -e "s|^wg_data=.*|wg_data=\"$test_data\"|" \
    -e "s|^wg_module=.*|wg_module=\"$test_module\"|" \
    "$repo_dir/wgksu" > "$test_tmp/wgksu"
sed -e "s|^wg_data=.*|wg_data=\"$test_data\"|" \
    -e "s|^wg_module=.*|wg_module=\"$test_module\"|" \
    "$repo_dir/customize.sh" > "$test_tmp/customize.sh"

install_module_fixture() {
  stage="$test_tmp/$1"
  test_ksu=false
  test_apatch=false
  case "${2:-magisk}" in
    kernelsu) test_ksu=true ;;
    apatch) test_apatch=true ;;
  esac
  mkdir -p "$stage"
  cp "$test_tmp/wg" "$stage/wg"
  cp "$test_tmp/wgksu" "$stage/wgksu"
  cp "$repo_dir/wg0.conf.example" "$stage/wg0.conf.example"
  BOOTMODE=true KSU="$test_ksu" KSU_VER=test KSU_VER_CODE=30000 APATCH="$test_apatch" \
    API=36 MAGISK_VER=test MAGISK_VER_CODE=30000 \
    MODPATH="$stage" sh -c '
      ui_print() { :; }
      abort() { echo "$*" >&2; exit 1; }
      set_perm() { chmod "$4" "$1"; }
      set_perm_recursive() { :; }
      . "$1"
    ' sh "$test_tmp/customize.sh"
}

install_module_fixture fresh
[ -f "$stage/skip_mount" ] || fail "fresh install unexpectedly enables mounting"
[ "$(cat "$test_data/mount_enabled")" = 0 ] || fail "default setting is not disabled"
[ "$(cat "$test_data/root_framework")" = magisk ] || fail "framework was not recorded"
[ -x "$stage/system/bin/wg" ] || fail "optional mounted command is missing"

sh "$test_data/wgksu" mount disable >/dev/null
[ -f "$test_module/skip_mount" ] || fail "disable did not create skip_mount"
[ "$(sh "$test_data/wgksu" mount status)" = 0 ] || fail "disabled status is wrong"
install_module_fixture disabled-upgrade
[ -f "$stage/skip_mount" ] || fail "upgrade lost disabled setting"

# A conflicting PATH tool must never replace the module's private tools.
printf '#!/bin/sh\nexit 77\n' > "$test_tmp/bin/wg"
chmod 755 "$test_tmp/bin/wg"
keys=$(PATH="$test_tmp/bin:$PATH" sh "$test_data/wgksu" genkey)
echo "$keys" | grep -q 'Public Key:  test-public-key' ||
  fail "unmounted command used the PATH tool instead of its private binary"

sh "$test_data/wgksu" mount enable >/dev/null
[ ! -e "$test_module/skip_mount" ] || fail "enable did not remove skip_mount"
install_module_fixture enabled-upgrade
[ ! -e "$stage/skip_mount" ] || fail "upgrade lost enabled setting"
[ "$(sh "$test_data/wgksu" mount status)" = 1 ] || fail "enabled status is wrong"

# Preserve users who disabled mounting externally before this setting existed.
rm "$test_data/mount_enabled"
touch "$test_module/skip_mount"
install_module_fixture migrated-upgrade
[ -f "$stage/skip_mount" ] || fail "upgrade lost existing skip_mount"
[ "$(cat "$test_data/mount_enabled")" = 0 ] || fail "existing skip_mount was not migrated"

# A legacy install without a saved choice also switches to the new default.
rm "$test_data/mount_enabled" "$test_module/skip_mount"
install_module_fixture legacy-upgrade kernelsu
[ -f "$stage/skip_mount" ] || fail "legacy upgrade did not default to mountless"
[ "$(cat "$test_data/root_framework")" = kernelsu ] || fail "KernelSU was not recorded"
cp "$stage/skip_mount" "$test_module/skip_mount"
[ "$(sh "$test_data/wgksu" mount supported)" = 0 ] || fail "KernelSU without a metamodule supports mounting"
if sh "$test_data/wgksu" mount enable >/dev/null 2>&1; then
  fail "enabled mounting without a provider"
fi
[ -f "$test_module/skip_mount" ] || fail "rejected enable changed skip_mount"
[ "$(cat "$test_data/mount_enabled")" = 0 ] || fail "rejected enable changed saved choice"

provider="$test_tmp/modules/custom-provider"
mkdir -p "$provider"
printf 'metamodule=true\n' > "$provider/module.prop"
[ "$(sh "$test_data/wgksu" mount supported)" = 0 ] || fail "install-only metamodule was accepted"
touch "$provider/metamount.sh"
[ "$(sh "$test_data/wgksu" mount supported)" = 1 ] || fail "custom mounting provider was not detected"
sh "$test_data/wgksu" mount enable >/dev/null
install_module_fixture ksu-enabled-upgrade kernelsu
[ ! -e "$stage/skip_mount" ] || fail "KernelSU upgrade lost explicitly enabled choice"
touch "$provider/disable"
[ "$(sh "$test_data/wgksu" mount supported)" = 0 ] || fail "disabled provider was accepted"
sh "$test_data/wgksu" mount disable >/dev/null
rm "$provider/disable"
touch "$provider/remove"
[ "$(sh "$test_data/wgksu" mount supported)" = 0 ] || fail "removed provider was accepted"
rm "$provider/remove"

# Respect KernelSU's selected provider even when another module looks usable.
ln -s "$provider" "$test_tmp/metamodule"
[ "$(sh "$test_data/wgksu" mount supported)" = 1 ] || fail "selected provider was not detected"
touch "$provider/disable"
mkdir -p "$test_tmp/modules/other-provider"
printf 'metamodule=1\n' > "$test_tmp/modules/other-provider/module.prop"
touch "$test_tmp/modules/other-provider/metamount.sh"
[ "$(sh "$test_data/wgksu" mount supported)" = 0 ] || fail "bypassed disabled selected provider"

install_module_fixture apatch-fresh apatch
[ "$(sh "$test_data/wgksu" mount supported)" = 1 ] || fail "APatch incorrectly requires a metamodule"
install_module_fixture magisk-again magisk
[ "$(sh "$test_data/wgksu" mount supported)" = 1 ] || fail "Magisk incorrectly requires a metamodule"

if sh "$test_data/wgksu" mount invalid >/dev/null 2>&1; then
  fail "invalid command succeeded"
fi
[ "$(cat "$test_data/wg0.conf")" = 'existing user config' ] || fail "user config changed"

echo "command mount defaults, providers, toggle, upgrade and private-tool tests passed"
