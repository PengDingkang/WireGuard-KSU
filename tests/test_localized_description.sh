#!/bin/sh

set -eu

repo_dir=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
test_tmp=$(mktemp -d)
test_data="$test_tmp/data"
test_module="$test_tmp/modules/WireGuard-KSU"
test_bin="$test_tmp/bin"
test_wgksu="$test_tmp/wgksu"
description_file="$test_tmp/description"

cleanup() {
  rm -rf "$test_tmp"
}
trap cleanup 0 1 2 15

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

mkdir -p "$test_data" "$test_module" "$test_bin"
cp -R "$repo_dir/translations" "$test_module/"
sed -e "s|^wg_data=.*|wg_data=\"$test_data\"|" \
    -e "s|^wg_module=.*|wg_module=\"$test_module\"|" \
    "$repo_dir/wgksu" > "$test_wgksu"

cat > "$test_bin/settings" <<'EOF'
#!/bin/sh
printf '%s\n' "${WGKSU_TEST_SETTINGS_LOCALE:-}"
EOF
cat > "$test_bin/getprop" <<'EOF'
#!/bin/sh
case "$1" in
  persist.sys.locale) printf '%s\n' "${WGKSU_TEST_PERSIST_LOCALE:-}" ;;
  ro.product.locale) printf '%s\n' "${WGKSU_TEST_PRODUCT_LOCALE:-}" ;;
esac
EOF
cat > "$test_bin/cmd" <<'EOF'
#!/bin/sh
printf 'config: mcc310-mnc260-%s\n' "${WGKSU_TEST_CONFIG_LANGUAGE:-en-rUS}"
EOF
cat > "$test_bin/ksud" <<'EOF'
#!/bin/sh
printf '%s\n' "$5" > "$WGKSU_TEST_DESCRIPTION_FILE"
EOF
cat > "$test_bin/ip" <<'EOF'
#!/bin/sh
case "$1" in
  link)
    [ "$3" = wg0 ]
    ;;
  -4)
    printf '    inet 10.8.0.2/24 scope global wg0\n'
    ;;
  *)
    exit 1
    ;;
esac
EOF
chmod 755 "$test_bin/"*

run_wgksu() {
  PATH="$test_bin:$PATH" \
    WGKSU_TEST_SETTINGS_LOCALE="${WGKSU_TEST_SETTINGS_LOCALE:-}" \
    WGKSU_TEST_PERSIST_LOCALE="${WGKSU_TEST_PERSIST_LOCALE:-}" \
    WGKSU_TEST_PRODUCT_LOCALE="${WGKSU_TEST_PRODUCT_LOCALE:-}" \
    WGKSU_TEST_CONFIG_LANGUAGE="${WGKSU_TEST_CONFIG_LANGUAGE:-en-rUS}" \
    WGKSU_TEST_DESCRIPTION_FILE="$description_file" \
    sh "$test_wgksu" "$@"
}

run_status() {
  run_wgksu status >/dev/null
}

WGKSU_TEST_SETTINGS_LOCALE=ru-RU,en-US run_status
[ "$(cat "$description_file")" = "⏹ Остановлен" ] ||
  fail "Russian stopped description was not selected"

if start_output=$(WGKSU_TEST_SETTINGS_LOCALE=ru-RU run_wgksu start missing 2>&1); then
  fail "missing config unexpectedly started"
fi
case "$start_output" in
  *"ОШИБКА: конфиг не найден: $test_data/missing.conf"*) ;;
  *) fail "Russian config-not-found message was not selected" ;;
esac

WGKSU_TEST_SETTINGS_LOCALE=en-US run_status
[ "$(cat "$description_file")" = "⏹ Stopped" ] ||
  fail "English stopped description was not selected"

WGKSU_TEST_SETTINGS_LOCALE=es-ES \
  WGKSU_TEST_PERSIST_LOCALE=ru-RU run_status
[ "$(cat "$description_file")" = "⏹ Остановлен" ] ||
  fail "persistent locale fallback was not selected"

WGKSU_TEST_SETTINGS_LOCALE=es-ES \
  WGKSU_TEST_PERSIST_LOCALE='' \
  WGKSU_TEST_PRODUCT_LOCALE='' \
  WGKSU_TEST_CONFIG_LANGUAGE=ru-rRU run_status
[ "$(cat "$description_file")" = "⏹ Остановлен" ] ||
  fail "activity config locale fallback was not selected"

WGKSU_TEST_SETTINGS_LOCALE=es-ES \
  WGKSU_TEST_PERSIST_LOCALE='' \
  WGKSU_TEST_PRODUCT_LOCALE=fr-FR run_status
[ "$(cat "$description_file")" = "⏹ Stopped" ] ||
  fail "unsupported locale did not fall back to English"

printf '[Interface]\n' > "$test_data/wg0.conf"
WGKSU_TEST_SETTINGS_LOCALE=ru-RU run_status
[ "$(cat "$description_file")" = "✅ Работает | wg0: 10.8.0.2" ] ||
  fail "Russian running description did not include the interface address"

status_output=$(WGKSU_TEST_SETTINGS_LOCALE=ru-RU run_wgksu status 2>&1)
case "$status_output" in
  *"wg0 запущен"* ) ;;
  *) fail "Russian interface status was not selected" ;;
esac
case "$status_output" in
  *"wg0 автозапуск при загрузке: включено"* ) ;;
  *) fail "Russian boot auto-start status was not selected" ;;
esac
case "$status_output" in
  *"wg0 не гасить связь: отключено"* ) ;;
  *) fail "Russian stay-awake status was not selected" ;;
esac

stay_output=$(WGKSU_TEST_SETTINGS_LOCALE=ru-RU run_wgksu stay-awake status wg0 2>&1)
case "$stay_output" in
  *"не гасить связь wg0: 0"* ) ;;
  *) fail "numeric stay-awake command output changed" ;;
esac

echo "localized module description tests passed"
