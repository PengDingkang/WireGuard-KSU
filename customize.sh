#!/sbin/sh

### INSTALLATION ###

if [ "$BOOTMODE" != true ]; then
  ui_print "-----------------------------------------------------------"
  ui_print "! Please install in Magisk/KernelSU/APatch Manager"
  ui_print "! Install from recovery is NOT supported"
  abort "-----------------------------------------------------------"
fi

if [ "$KSU" = true ] && [ "$KSU_VER_CODE" -lt 10670 ]; then
  abort "ERROR: Please update your KernelSU and KernelSU Manager"
fi

if [ "$API" -lt 28 ]; then
  ui_print "! Unsupported sdk: $API"
  abort "! Minimal supported sdk is 28 (Android 9)"
else
  ui_print "- Device sdk: $API"
fi

# detect environment
if [ "$KSU" = true ]; then
  ui_print "- KernelSU version: $KSU_VER ($KSU_VER_CODE)"
elif [ "$APATCH" = true ]; then
  ui_print "- APatch detected"
else
  ui_print "- Magisk version: $MAGISK_VER ($MAGISK_VER_CODE)"
fi

# check kernel WireGuard support
if [ -f /proc/config.gz ]; then
  if zcat /proc/config.gz | grep -q 'CONFIG_WIREGUARD=y'; then
    ui_print "- ✅ Kernel WireGuard support detected"
  else
    ui_print "- ⚠ Kernel WireGuard not detected, module may not work"
    ui_print "- Your kernel needs CONFIG_WIREGUARD=y"
  fi
else
  ui_print "- ⚠ Cannot check kernel config, assuming WireGuard support"
fi

ui_print "- Installing WireGuard KSU"

# data directory for config
wg_data="/data/adb/wireguard"
if [ ! -d "$wg_data" ]; then
  mkdir -p "$wg_data"
  set_perm "$wg_data" 0 0 0700
fi

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
  ui_print "- Generated wg0.conf with new keypair"
  ui_print "- Your public key: $pubkey"
  ui_print "- ⚠ Edit config to fill in server info before starting"
else
  ui_print "- Existing config found, keeping it"
fi

# install default module settings if not exists
if [ ! -f "$wg_data/autostart" ]; then
  echo "AUTO_START=1" > "$wg_data/autostart"
  set_perm "$wg_data/autostart" 0 0 0644
  ui_print "- Auto-start is enabled by default"
fi

# install binaries
ui_print "- Installing binaries"
mkdir -p "$MODPATH/system/bin"
mv -f "$MODPATH/wg" "$MODPATH/system/bin/"
mv -f "$MODPATH/wgksu" "$MODPATH/system/bin/"
rm -f "$MODPATH/wg0.conf.example"

# permissions
ui_print "- Setting permissions"
set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/system/bin/wg" 0 0 0755
set_perm "$MODPATH/system/bin/wgksu" 0 0 0755

ui_print "- Installation complete, reboot your device"
ui_print "- Config dir: /data/adb/wireguard/"
ui_print "- Manage: wgksu {start|stop|restart|status}"
