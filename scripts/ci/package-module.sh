#!/bin/sh

set -eu

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 OUTPUT.zip" >&2
  exit 2
fi

package_path=$1
case "$package_path" in
  *.zip) ;;
  *)
    echo "Package path must end in .zip: $package_path" >&2
    exit 2
    ;;
esac

mkdir -p "$(dirname "$package_path")"
package_tmp="${package_path%.zip}.tmp.$$.zip"

cleanup() {
  rm -f "$package_tmp"
}
trap cleanup 0 1 2 15

zip -qr "$package_tmp" \
  META-INF webroot translations \
  boot-completed.sh customize.sh uninstall.sh \
  wgksu wg wg0.conf.example \
  module.prop

mv -f "$package_tmp" "$package_path"
trap - 0 1 2 15
