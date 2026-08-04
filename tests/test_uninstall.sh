#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/test_helper.sh
. "$(dirname "$0")/test_helper.sh"

temporary_root="$(mktemp -d)"
trap 'rm -rf "$temporary_root"' EXIT
export VPSGUARD_TEST_MODE=1
export VPSGUARD_ETC_ROOT="$temporary_root/etc"
export VPSGUARD_STATE_DIR="$temporary_root/etc/vpsguard"
export VPSGUARD_MANAGED_RULES="$VPSGUARD_STATE_DIR/managed-rules"
# shellcheck source=uninstall.sh
. "$TEST_ROOT/uninstall.sh"

managed="$temporary_root/managed.conf"
foreign="$temporary_root/foreign.conf"
printf '# Managed by VPSGuard 0.3.5\nvalue\n' > "$managed"
printf '# Managed by another tool\nvalue\n' > "$foreign"
remove_owned_file "$managed"
remove_owned_file "$foreign"
[ ! -e "$managed" ] || fail "managed file was not removed"
[ -e "$foreign" ] || fail "foreign file was removed"

mkdir -p "$VPSGUARD_STATE_DIR"
printf '# UFW rules added by VPSGuard\n22/tcp\n2222/tcp\n' > "$VPSGUARD_MANAGED_RULES"
ufw_log="$temporary_root/ufw.log"
ufw() {
  if [ "$1" = status ]; then
    printf 'Status: active\n22/tcp ALLOW IN Anywhere\n2222/tcp ALLOW IN Anywhere\n'
  else
    printf '%s\n' "$*" >> "$ufw_log"
  fi
}
remove_safe_ufw_rules 22
assert_file_contains "$ufw_log" 'delete allow 2222/tcp'
if grep -Fq 'delete allow 22/tcp' "$ufw_log"; then
  fail "current SSH rule was deleted"
fi

if grep -Eq 'systemctl (stop|disable) fail2ban|ufw (--force )?(disable|reset)|userdel|deluser' "$TEST_ROOT/uninstall.sh"; then
  fail "unsafe global disable/reset or user deletion remains in uninstall.sh"
fi

mkdir -p "$SUDOERS_DIR"
sudoers_file="${SUDOERS_DIR}/90-vpsguard-existingadmin"
printf '# Managed by VPSGuard 0.3.5\nexistingadmin ALL=(ALL:ALL) NOPASSWD: ALL\n' > "$sudoers_file"
id() { printf 'existingadmin sudo\n'; }
passwd() { printf 'existingadmin P 2026-08-03 0 99999 7 -1\n'; }
visudo() { return 0; }
sudo() {
  if [ "${1:-}" = "-l" ]; then
    printf 'User existingadmin may run the following commands:\n    (ALL : ALL) ALL\n'
    return 0
  fi
  if [ "$*" = '-u existingadmin sudo -n true' ]; then
    return 1
  fi
  return 0
}
assert_success remove_legacy_sudoers_safely existingadmin
[ ! -e "$sudoers_file" ] || fail "safe legacy passwordless sudo override was not removed"

pass "uninstall removes only owned files/rules and preserves standard sudo, current access, services and users"
