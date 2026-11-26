#!/sbin/sh

### INSTALLATION ###

resolve_install_locale() {
  locale_candidate=$(printf '%s' "$1" | cut -d',' -f1 | tr '_' '-')
  locale_language=$(printf '%s' "$locale_candidate" | cut -d'-' -f1 | tr '[:upper:]' '[:lower:]')
  case "$locale_language" in
    en|ru) install_locale="$locale_language"; return 0 ;;
  esac
  return 1
}

resolve_install_locale "$(settings get system system_locales 2>/dev/null)" ||
  resolve_install_locale "$(getprop persist.sys.locale 2>/dev/null)" ||
  resolve_install_locale "$(getprop ro.product.locale 2>/dev/null)" ||
  resolve_install_locale "$(
    cmd activity get-config 2>/dev/null |
      grep -m1 '^config:' |
      sed 's/^config:[[:space:]]*//' |
      tr '-' '\n' |
      grep -m1 -E '^[a-zA-Z]{2,3}$' ||
      :
  )" ||
  install_locale="en"

install_strings="$MODPATH/translations/$install_locale/strings.sh"
if [ ! -f "$install_strings" ]; then
  install_locale="en"
  install_strings="$MODPATH/translations/$install_locale/strings.sh"
fi
if [ ! -f "$install_strings" ]; then
  abort "ERROR: installer translations are missing"
fi
# shellcheck source=translations/en/strings.sh
# shellcheck disable=SC1090
. "$install_strings"

if [ "$BOOTMODE" != true ]; then
  ui_print "-----------------------------------------------------------"
  ui_print "! $install_manager_required"
  ui_print "! $install_recovery_unsupported"
  abort "-----------------------------------------------------------"
fi

if [ "$KSU" = true ] && [ "$KSU_VER_CODE" -lt 10670 ]; then
  abort "$install_error_ksu_update"
fi

if [ "$API" -lt 28 ]; then
  ui_print "! $install_unsupported_sdk $API"
  abort "! $install_minimum_sdk"
else
  ui_print "- $install_device_sdk $API"
fi

# detect environment
if [ "$KSU" = true ]; then
  root_framework=kernelsu
  ui_print "- $install_kernelsu_version $KSU_VER ($KSU_VER_CODE)"
elif [ "$APATCH" = true ]; then
  root_framework=apatch
  ui_print "- $install_apatch_detected"
else
  root_framework=magisk
  ui_print "- $install_magisk_version $MAGISK_VER ($MAGISK_VER_CODE)"
fi

# check kernel WireGuard support
if [ -f /proc/config.gz ]; then
  if zcat /proc/config.gz | grep -q 'CONFIG_WIREGUARD=y'; then
    ui_print "- $install_kernel_wg_supported"
  else
    ui_print "- $install_kernel_wg_missing"
    ui_print "- $install_kernel_wg_required"
  fi
else
  ui_print "- $install_kernel_config_unavailable"
fi

ui_print "- $install_module_installing"

# data directory for config
wg_data="/data/adb/wireguard"
if [ ! -d "$wg_data" ]; then
  mkdir -p "$wg_data"
  set_perm "$wg_data" 0 0 0700
fi
printf '%s\n' "$root_framework" > "$wg_data/root_framework" || abort "! $install_error_framework_save"

# generate initial config with keypair if no configs exist
if ! ls "$wg_data"/wg*.conf >/dev/null 2>&1; then
  privkey=$("$MODPATH/wg" genkey)
  pubkey=$(echo "$privkey" | "$MODPATH/wg" pubkey)
  cat > "$wg_data/wg0.conf" <<EOF
[Interface]
PrivateKey = ${privkey}
Address = 10.0.0.2/24
# DNS = 1.1.1.1
# MTU = 1420

[Peer]
PublicKey = REPLACE_WITH_SERVER_PUBLIC_KEY
Endpoint = REPLACE_WITH_SERVER_IP:51820
AllowedIPs = 10.0.0.0/24
PersistentKeepalive = 25
EOF
  chmod 600 "$wg_data/wg0.conf"
  ui_print "- $install_config_generated"
  ui_print "- $install_public_key $pubkey"
  ui_print "- $install_config_edit_hint"
else
  ui_print "- $install_existing_config"
fi

# install default module settings if not exists
if [ ! -f "$wg_data/autostart" ]; then
  echo "AUTO_START=1" > "$wg_data/autostart"
  set_perm "$wg_data/autostart" 0 0 0644
  ui_print "- $install_autostart_default"
fi

# install binaries
ui_print "- $install_binaries_installing"
# overlay mount
mkdir -p "$MODPATH/system/bin"
cp -f "$MODPATH/wg" "$MODPATH/system/bin/"
cp -f "$MODPATH/wgksu" "$MODPATH/system/bin/"
# fallback: also install to data dir (works without overlay/magic mount)
cp -f "$MODPATH/wg" "$wg_data/wg"
cp -f "$MODPATH/wgksu" "$wg_data/wgksu"
chmod 755 "$wg_data/wg" "$wg_data/wgksu"
rm -f "$MODPATH/wg" "$MODPATH/wgksu" "$MODPATH/wg0.conf.example"

# permissions
ui_print "- $install_permissions_setting"
set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/system/bin/wg" 0 0 0755
set_perm "$MODPATH/system/bin/wgksu" 0 0 0755

# Mountless by default; preserve only an explicitly saved enabled choice.
mount_enabled=0
if [ -f "$wg_data/mount_enabled" ]; then
  [ "$(cat "$wg_data/mount_enabled")" = 1 ] && mount_enabled=1
  ui_print "- $install_mount_choice_preserved"
else
  ui_print "- $install_mount_default_disabled"
  ui_print "- $install_mount_full_paths_hint"
fi
printf '%s\n' "$mount_enabled" > "$wg_data/mount_enabled" || abort "! $install_error_mount_save"
if [ "$mount_enabled" = 0 ]; then
  touch "$MODPATH/skip_mount" || abort "! $install_error_mount_disable"
  ui_print "- $install_mount_status: $install_disabled"
else
  ui_print "- $install_mount_status: $install_enabled"
fi
if [ "$(sh "$wg_data/wgksu" mount supported)" != 1 ]; then
  ui_print "- $install_mount_unavailable"
fi

ui_print "- $install_complete"
ui_print "- $install_config_dir /data/adb/wireguard/"
ui_print "- $install_manage /data/adb/wireguard/wgksu {start|stop|restart|status}"
ui_print "- $install_mount_webui_hint"
