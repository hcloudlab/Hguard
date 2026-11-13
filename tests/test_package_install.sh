#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/test_helper.sh
. "$(dirname "$0")/test_helper.sh"

temporary_root="$(mktemp -d)"
trap 'rm -rf "$temporary_root"' EXIT
export HGUARD_TEST_MODE=1
export HGUARD_ETC_ROOT="$temporary_root/etc"
export HGUARD_STATE_DIR="$temporary_root/etc/hguard"
export HGUARD_LOG_FILE="$temporary_root/hguard.log"
# shellcheck source=install-core.sh
. "$TEST_ROOT/install-core.sh"

apt_log="$temporary_root/apt.log"
unavailable_packages=" lsb-release net-tools "
optional_install_fails="false"
required_install_fails="false"

apt-cache() {
  [ "$1" = "show" ] || return 1
  case "$unavailable_packages" in *" $2 "*) return 100 ;; esac
  return 0
}
apt-get() {
  printf '%s\n' "$*" >> "$apt_log"
  case "$*" in
    *" install -y sudo "*) [ "$required_install_fails" = "true" ] && return 100 ;;
    *" install -y "*) [ "$optional_install_fails" = "true" ] && return 100 ;;
  esac
  return 0
}

: > "$apt_log"
HGUARD_OS_PRETTY_NAME="Debian GNU/Linux 13 (trixie)"
upgrade_system >/dev/null 2>&1
required_line="$(grep -F ' install -y sudo ' "$apt_log")"
for package in sudo ufw fail2ban python3-systemd openssh-server nftables kmod procps adduser; do
  printf ' %s ' "$required_line" | grep -Fq " ${package} " || fail "required install is missing ${package}"
done
optional_line="$(grep -F ' install -y wget ' "$apt_log")"
printf '%s' "$optional_line" | grep -Fq 'jq' || fail "available optional packages must be installed"
if printf '%s' "$optional_line" | grep -Eq 'lsb-release|net-tools'; then
  fail "packages missing from the release must be skipped, not passed to apt-get"
fi
pass "required packages are installed and unavailable optional ones are skipped"

: > "$apt_log"
optional_install_fails="true"
(upgrade_system >/dev/null 2>&1) || fail "an optional package failure must not abort the install"
pass "optional package failures are non-fatal"

optional_install_fails="false"
required_install_fails="true"
if (upgrade_system >/dev/null 2>&1); then
  fail "a required package failure must abort the install"
fi
pass "required package failures are fatal"
