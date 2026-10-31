#!/bin/sh

set -eu

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 PACKAGE.zip" >&2
  exit 2
fi

package_path=$1
package_list=$(mktemp)

cleanup() {
  rm -f "$package_list"
}
trap cleanup 0 1 2 15

unzip -tq "$package_path"
unzip -Z -1 "$package_path" | tee "$package_list"

required_paths="
META-INF/com/google/android/update-binary
META-INF/com/google/android/updater-script
webroot/index.html
translations/en/strings.sh
translations/ru/strings.sh
boot-completed.sh
customize.sh
uninstall.sh
wgksu
wg
wg0.conf.example
module.prop
"

for required_path in $required_paths; do
  if ! grep -Fxq "$required_path" "$package_list"; then
    echo "Missing package entry: $required_path" >&2
    exit 1
  fi
  if ! unzip -p "$package_path" "$required_path" | cmp -s - "$required_path"; then
    echo "Package entry differs from source: $required_path" >&2
    exit 1
  fi
done

for forbidden_pattern in \
  '^\.git/' \
  '^\.github/' \
  '^tests/' \
  '^scripts/' \
  '^README\.md$' \
  '^LICENSE$' \
  '^changelog\.md$' \
  '^CORE_VERSION$'; do
  if grep -Eq "$forbidden_pattern" "$package_list"; then
    echo "Forbidden package entry matching: $forbidden_pattern" >&2
    exit 1
  fi
done

duplicate_paths=$(sort "$package_list" | uniq -d)
if [ -n "$duplicate_paths" ]; then
  echo "Duplicate package entries:" >&2
  echo "$duplicate_paths" >&2
  exit 1
fi
