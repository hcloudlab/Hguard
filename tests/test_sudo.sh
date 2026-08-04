#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/test_helper.sh
. "$(dirname "$0")/test_helper.sh"

temporary_root="$(mktemp -d)"
trap 'rm -rf "$temporary_root"' EXIT
export VPSGUARD_TEST_MODE=1
export VPSGUARD_ETC_ROOT="$temporary_root/etc"
export SUDOERS_DIR="$temporary_root/etc/sudoers.d"
mkdir -p "$SUDOERS_DIR"
# shellcheck source=install.sh
. "$TEST_ROOT/install.sh"

NEW_USER="secureadmin"
mock_password_state="P"
passwordless_allowed="false"
sudoers_file="$(sudoers_file_for_user)"
legacy_file="${SUDOERS_DIR}/90-${NEW_USER}"

id() {
  if [ "${1:-}" = "-nG" ]; then
    printf 'secureadmin adm sudo\n'
  else
    return 0
  fi
}
passwd() {
  if [ "${1:-}" = "-S" ]; then
    printf 'secureadmin %s 2026-08-03 0 99999 7 -1\n' "$mock_password_state"
    return 0
  fi
  fail "passwd must not reset an existing test password"
}
visudo() { return 0; }
sudo() {
  if [ "${1:-}" = "-l" ]; then
    printf 'User secureadmin may run the following commands:\n    (ALL : ALL) ALL\n'
    return 0
  fi
  if [ "$*" = '-u secureadmin sudo -n true' ]; then
    [ "$passwordless_allowed" = "true" ]
    return
  fi
  return 0
}

printf 'User secureadmin may run the following commands:\n    (ALL : ALL) ALL\n' | assert_success sudo_policy_has_full_admin_from_text
printf 'User secureadmin may run the following commands:\n    (root) /usr/bin/systemctl\n' | assert_failure sudo_policy_has_full_admin_from_text
assert_success user_in_sudo_group
assert_success user_password_is_set

printf '# Managed by VPSGuard 0.3.5\n%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$NEW_USER" > "$sudoers_file"
printf '%s ALL=(ALL) NOPASSWD: ALL\n' "$NEW_USER" > "$legacy_file"
assert_success configure_sudo
[ ! -e "$sudoers_file" ] || fail "VPSGuard full-passwordless sudoers file was not removed"
[ ! -e "$legacy_file" ] || fail "recognized legacy full-passwordless sudoers file was not removed"
assert_success verify_sudo_configuration

passwordless_allowed="true"
assert_failure verify_sudo_configuration
passwordless_allowed="false"
mock_password_state="L"
assert_failure user_password_is_set

pass "standard password-authenticated sudo policy and legacy override migration"
