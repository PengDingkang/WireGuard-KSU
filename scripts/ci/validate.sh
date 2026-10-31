#!/bin/sh

set -eu

scripts="
customize.sh
boot-completed.sh
uninstall.sh
wgksu
translations/en/strings.sh
translations/ru/strings.sh
tests/test_endpoint_route_locks.sh
tests/test_boot_start.sh
tests/test_command_mount.sh
tests/test_localized_description.sh
tests/helpers/busybox
tests/helpers/busybox-no-flock
tests/helpers/delayed-wgksu-holder
tests/helpers/wgksu-fail-once
scripts/ci/validate.sh
scripts/ci/build-wg.sh
scripts/ci/package-module.sh
scripts/ci/verify-package.sh
"

for script in $scripts; do
  sh -n "$script"
  if [ "$script" = "customize.sh" ] || [ "$script" = "wgksu" ]; then
    shellcheck -x "$script"
  else
    shellcheck "$script"
  fi
done

sh tests/test_endpoint_route_locks.sh
sh tests/test_boot_start.sh
sh tests/test_command_mount.sh
sh tests/test_localized_description.sh
