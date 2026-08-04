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
mock_password_state="L"
passwd_calls=0
sudo_v_calls=0
sudo_n_true_calls=0
sudo_n_i_calls=0
sudo_v_fail="false"
passwd_fail="false"
visudo_fail_file=""

id() {
  if [ "${1:-}" = "-nG" ]; then
    printf '%s sudo users\n' "$NEW_USER"
  else
    return 0
  fi
}

passwd() {
  if [ "${1:-}" = "-S" ]; then
    printf '%s %s 2026-08-03 0 99999 7 -1\n' "$NEW_USER" "$mock_password_state"
    return 0
  fi
  passwd_calls=$((passwd_calls + 1))
  if [ "$passwd_fail" = "true" ]; then
    return 1
  fi
  mock_password_state="P"
}

visudo() {
  if [ "${1:-}" = "-cf" ] && [ "$2" = "$visudo_fail_file" ]; then
    return 1
  fi
  return 0
}

mock_passwordless_effective() {
  local sudoers_file
  sudoers_file="$(sudoers_file_for_user)"
  [ -f "$sudoers_file" ] || return 1
  grep -Fxq "${NEW_USER} ALL=(ALL:ALL) NOPASSWD: ALL" "$sudoers_file"
}

sudo() {
  if [ "${1:-}" = "-l" ]; then
    printf 'User %s may run the following commands:\n    (ALL : ALL) ALL\n' "$NEW_USER"
    return 0
  fi
  if [ "$*" = "-u ${NEW_USER} sudo -k" ]; then
    return 0
  fi
  if [ "$*" = "-u ${NEW_USER} sudo -v" ]; then
    sudo_v_calls=$((sudo_v_calls + 1))
    [ "$sudo_v_fail" != "true" ] && [ "$mock_password_state" = "P" ]
    return
  fi
  if [ "$*" = "-u ${NEW_USER} sudo -n true" ]; then
    sudo_n_true_calls=$((sudo_n_true_calls + 1))
    mock_passwordless_effective
    return
  fi
  if [ "$*" = "-u ${NEW_USER} sudo -n -i true" ]; then
    sudo_n_i_calls=$((sudo_n_i_calls + 1))
    mock_passwordless_effective
    return
  fi
  return 1
}

assert_equal password "$(printf '\n' | prompt_initial_sudo_mode 2>/dev/null)" "default sudo selection"
assert_equal password "$(printf '2\nNO\n1\n' | prompt_initial_sudo_mode 2>/dev/null)" "wrong risk confirmation returns to menu"
assert_equal passwordless "$(printf '2\nI UNDERSTAND\n' | prompt_initial_sudo_mode 2>/dev/null)" "exact passwordless confirmation"
assert_equal passwordless "$(printf '\n' | prompt_rerun_sudo_mode passwordless 2>/dev/null)" "rerun keeps current mode"
assert_equal password "$(printf '2\n' | prompt_rerun_sudo_mode passwordless 2>/dev/null)" "rerun selects password mode"

printf 'User secureadmin may run the following commands:\n    (ALL : ALL) ALL\n' | assert_success sudo_policy_has_full_admin_from_text
printf 'User secureadmin may run the following commands:\n    (root) /usr/bin/systemctl\n' | assert_failure sudo_policy_has_full_admin_from_text

SUDO_MODE="password"
configure_sudo
assert_equal 1 "$passwd_calls" "password mode invokes passwd for a locked account"
assert_equal P "$mock_password_state" "password mode requires passwd state P"
assert_equal 1 "$sudo_v_calls" "password mode performs interactive sudo validation"
[ ! -e "$(sudoers_file_for_user)" ] || fail "password mode created a NOPASSWD file"
assert_success verify_sudo_configuration
assert_success passwordless_sudo_denied

mock_password_state="L"
passwd_calls=0
SUDO_MODE="passwordless"
configure_sudo
sudoers_file="$(sudoers_file_for_user)"
assert_equal 0 "$passwd_calls" "passwordless mode does not set or empty the Linux password"
assert_equal L "$mock_password_state" "passwordless mode preserves locked password state"
assert_equal 440 "$(sudoers_file_mode "$sudoers_file")" "passwordless sudoers mode"
assert_equal 1 "$(grep -Fxc 'secureadmin ALL=(ALL:ALL) NOPASSWD: ALL' "$sudoers_file")" "single exact NOPASSWD policy"
assert_success verify_sudo_configuration
[ "$sudo_n_true_calls" -gt 0 ] || fail "passwordless sudo -n true was not checked"
[ "$sudo_n_i_calls" -gt 0 ] || fail "passwordless sudo -n -i true was not checked"

first_checksum="$(checksum_file "$sudoers_file")"
for _iteration in {1..10}; do
  configure_passwordless_sudo >/dev/null
done
assert_equal "$first_checksum" "$(checksum_file "$sudoers_file")" "ten passwordless reruns are idempotent"
assert_equal 1 "$(grep -Fxc 'secureadmin ALL=(ALL:ALL) NOPASSWD: ALL' "$sudoers_file")" "rerun does not duplicate sudoers content"

chmod 640 "$sudoers_file"
printf '# Managed by VPSGuard 0.3.5; previous policy.\nsecureadmin ALL=(ALL:ALL) NOPASSWD: ALL\n# retained on rollback\n' > "$sudoers_file"
chmod 440 "$sudoers_file"
rollback_checksum="$(checksum_file "$sudoers_file")"
visudo_fail_file="$sudoers_file"
assert_failure configure_passwordless_sudo
assert_equal "$rollback_checksum" "$(checksum_file "$sudoers_file")" "visudo failure restores prior sudoers file"
visudo_fail_file=""

configure_passwordless_sudo >/dev/null
mock_password_state="P"
passwd_calls=0
SUDO_MODE="password"
configure_sudo
assert_equal 0 "$passwd_calls" "passwordless to password preserves an existing valid password"
[ ! -e "$sudoers_file" ] || fail "passwordless to password did not remove the managed policy"
assert_success verify_sudo_configuration

SUDO_MODE="passwordless"
configure_sudo
mock_password_state="P"
password_before="$mock_password_state"
configure_passwordless_sudo >/dev/null
assert_equal "$password_before" "$mock_password_state" "password to passwordless preserves the user password"

rollback_checksum="$(checksum_file "$sudoers_file")"
SUDO_MODE="password"
PREVIOUS_SUDO_MODE="passwordless"
INSTALL_STATUS="failed"
NEW_USER="secureadmin"
SSH_PORT="2222"
ORIGINAL_SSH_PORT="22"
write_pending_config_env
sudo_v_fail="true"
assert_failure configure_password_sudo
sudo_v_fail="false"
assert_equal "$rollback_checksum" "$(checksum_file "$sudoers_file")" "failed mode switch restores passwordless policy"
assert_equal passwordless "$(read_env_value "$VPSGUARD_CONFIG_FILE" SUDO_MODE)" "sudo validation failure preserves the effective configured mode"
assert_equal failed "$(read_env_value "$VPSGUARD_CONFIG_FILE" INSTALL_STATUS)" "failed migration remains visible"
assert_equal password "$SUDO_MODE" "pending config write preserves the requested in-memory mode"

mock_password_state="L"
passwd_fail="true"
assert_failure configure_password_sudo
passwd_fail="false"
assert_equal L "$mock_password_state" "failed passwd does not create or empty a Linux password"
assert_equal "$rollback_checksum" "$(checksum_file "$sudoers_file")" "passwd failure preserves passwordless policy"
assert_equal passwordless "$(read_env_value "$VPSGUARD_CONFIG_FILE" SUDO_MODE)" "passwd failure preserves the effective configured mode"

old_file="${SUDOERS_DIR}/vpsguard-oldadmin"
printf '# Managed by VPSGuard 0.3.5\noldadmin ALL=(ALL:ALL) NOPASSWD: ALL\n' > "$old_file"
chmod 440 "$old_file"
NEW_USER="newadmin"
SUDO_MODE="passwordless"
configure_passwordless_sudo >/dev/null
[ -e "$old_file" ] || fail "changing usernames deleted the old user's managed sudoers file"
[ -e "$(sudoers_file_for_user)" ] || fail "new user's managed sudoers file was not created"

if grep -Eq 'passwd[[:space:]]+(-d|--delete)|passwd[[:space:]]+(-e|--expire)' "$TEST_ROOT/install.sh"; then
  fail "installer contains a password deletion or expiration path"
fi

pass "selectable sudo modes, risk gate, behavior checks, migrations, rollback and idempotency"
