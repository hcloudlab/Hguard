#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/test_helper.sh
. "$(dirname "$0")/test_helper.sh"

temporary_root="$(mktemp -d)"
trap 'rm -rf "$temporary_root"' EXIT
export VPSGUARD_TEST_MODE=1
export VPSGUARD_ETC_ROOT="$temporary_root/etc"
export VPSGUARD_STATE_DIR="$temporary_root/etc/vpsguard"
export VPSGUARD_CONFIG_FILE="$VPSGUARD_STATE_DIR/config.env"
# shellcheck source=install.sh
. "$TEST_ROOT/install.sh"

assert_failure validate_username ""
assert_failure validate_username root
assert_failure validate_username Admin
assert_failure validate_username 1admin
assert_failure validate_username "my admin"
assert_failure validate_username 'my/admin'
assert_failure validate_username 'my\admin'
assert_failure validate_username 'my:admin'
assert_failure validate_username 'my;admin'
assert_failure validate_username "my\$admin"
assert_success validate_username deploy
assert_success validate_username service_admin-2
assert_success validate_username "a$(printf 'b%.0s' {1..31})"
assert_failure validate_username "a$(printf 'b%.0s' {1..32})"

prompt_warning_file="$temporary_root/prompt-warning.log"
prompted_user="$(printf '\nvpsadmin\n' | prompt_for_username 2>"$prompt_warning_file")"
assert_equal vpsadmin "$prompted_user" "valid username after an invalid interactive attempt"
assert_file_contains "$prompt_warning_file" '用户名无效'

NEW_USER="existingadmin"
adduser() { fail "adduser must not run for an existing user"; }
usermod_log="$temporary_root/usermod.log"
id() {
  if [ "${1:-}" = "-nG" ]; then
    printf 'existingadmin sudo\n'
  else
    return 0
  fi
}
usermod() { printf '%s\n' "$*" >> "$usermod_log"; }
getent() { printf 'existingadmin:x:1000:1000::/home/existingadmin:/bin/bash\n'; }
assert_success ensure_managed_user
assert_file_contains "$usermod_log" '-aG sudo existingadmin'

if VPSGUARD_TEST_MODE=1 VPSGUARD_CONFIG_FILE="$temporary_root/missing-config" bash -c '. "$1"; resolve_managed_user' _ "$TEST_ROOT/install.sh" >/dev/null 2>&1; then
  fail "non-interactive execution without NEW_USER must fail"
fi

# The inner shell must expand NEW_USER after sourcing install.sh.
# shellcheck disable=SC2016
assert_success env VPSGUARD_TEST_MODE=1 VPSGUARD_CONFIG_FILE="$temporary_root/missing-config" NEW_USER=ciadmin bash -c '. "$1"; resolve_managed_user; [ "$NEW_USER" = ciadmin ]' _ "$TEST_ROOT/install.sh"
# shellcheck disable=SC2016
assert_failure env VPSGUARD_TEST_MODE=1 VPSGUARD_CONFIG_FILE="$temporary_root/missing-config" NEW_USER=RootUser bash -c '. "$1"; resolve_managed_user' _ "$TEST_ROOT/install.sh"

legacy_default='a''lex'
legacy_pattern="NEW_USER=.*${legacy_default}|default user: ${legacy_default}|默认.*${legacy_default}"
if grep -RIn --exclude-dir=.git --exclude='CHANGELOG.md' --exclude='test_username.sh' -E "$legacy_pattern" "$TEST_ROOT" >/dev/null; then
  fail "repository still contains a default administrator username"
fi

pass "username validation, interactive retry, existing-user reuse and non-interactive behavior"
