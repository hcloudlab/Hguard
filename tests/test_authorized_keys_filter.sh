#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/test_helper.sh
. "$(dirname "$0")/test_helper.sh"

temporary_root="$(mktemp -d)"
trap 'rm -rf "$temporary_root"' EXIT
export VPSGUARD_TEST_MODE=1
export VPSGUARD_ETC_ROOT="$temporary_root/etc"
export VPSGUARD_STATE_DIR="$temporary_root/etc/vpsguard"
export VPSGUARD_INSTALLED_MARKER="$VPSGUARD_STATE_DIR/.installed"
mkdir -p "$VPSGUARD_STATE_DIR"
# shellcheck source=install-core.sh
. "$TEST_ROOT/install-core.sh"

chown() { :; }  # NEW_USER below is not a real OS account in this test sandbox

export ROOT_AUTHORIZED_KEYS="$temporary_root/root-authorized_keys"
NEW_USER="admin"
fake_user_home="$temporary_root/home/admin"
managed_user_home() { printf '%s\n' "$fake_user_home"; }

ssh-keygen -q -t ed25519 -N '' -f "$temporary_root/root_key" </dev/null
ssh-keygen -q -t ed25519 -N '' -f "$temporary_root/sudo_user_key" </dev/null
root_pubkey="$(cat "$temporary_root/root_key.pub")"
sudo_user_pubkey="$(cat "$temporary_root/sudo_user_key.pub")"
restricted_line="no-port-forwarding,no-agent-forwarding,no-X11-forwarding,command=\"echo 'Please login as the user \\\"ubuntu\\\" rather than the user \\\"root\\\".';echo;sleep 10;exit 142\" ${root_pubkey}"
from_restricted_line='from="10.0.0.0/8" '"${root_pubkey}"

reset_sandbox() {
  rm -rf "${temporary_root:?}/home" "${VPSGUARD_INSTALLED_MARKER:?}" "${ROOT_AUTHORIZED_KEYS:?}"
  mkdir -p "$VPSGUARD_STATE_DIR"
  unset SUDO_USER
}

### 1. usable_pubkey_lines skips command= lines, keeps other options (from=).
reset_sandbox
printf '%s\n%s\n' "$restricted_line" "$from_restricted_line" > "$ROOT_AUTHORIZED_KEYS"
filtered="$(usable_pubkey_lines "$ROOT_AUTHORIZED_KEYS")"
assert_equal "$from_restricted_line" "$filtered" "command= line dropped, from= line kept verbatim"

### 2. root only has a forced-command key, no SUDO_USER: check_root_ssh_key
### must error with no system change, before any sync happens.
reset_sandbox
printf '%s\n' "$restricted_line" > "$ROOT_AUTHORIZED_KEYS"
if (check_root_ssh_key) 2>/dev/null; then
  fail "check_root_ssh_key must reject a root key that only has a forced command"
fi

### 3. root restricted, but SUDO_USER has a clean key: fallback is used for
### both the preflight check and the actual authorized_keys sync, and the
### forced-command line from root is never copied to the admin.
reset_sandbox
printf '%s\n' "$restricted_line" > "$ROOT_AUTHORIZED_KEYS"
export SUDO_USER="ubuntu"
# Called indirectly by resolve_admin_pubkey_source.
# shellcheck disable=SC2329
getent() {
  if [ "$1" = "passwd" ] && [ "$2" = "ubuntu" ]; then
    printf 'ubuntu:x:1000:1000::%s/home/ubuntu:/bin/bash\n' "$temporary_root"
  fi
}
mkdir -p "$temporary_root/home/ubuntu/.ssh"
printf '%s\n' "$sudo_user_pubkey" > "$temporary_root/home/ubuntu/.ssh/authorized_keys"

assert_success check_root_ssh_key
assert_success configure_authorized_keys
assert_file_contains "$fake_user_home/.ssh/authorized_keys" "$sudo_user_pubkey"
if grep -Fq 'command=' "$fake_user_home/.ssh/authorized_keys"; then
  fail "a forced-command line from root must never be copied to the admin's authorized_keys"
fi

pass "command= keys are filtered out; SUDO_USER's clean key is used as fallback"

### 4. Neither root nor SUDO_USER has a usable key: hard error, no files
### touched on the admin side.
reset_sandbox
printf '%s\n' "$restricted_line" > "$ROOT_AUTHORIZED_KEYS"
export SUDO_USER="ubuntu"
getent() {
  if [ "$1" = "passwd" ] && [ "$2" = "ubuntu" ]; then
    printf 'ubuntu:x:1000:1000::%s/home/ubuntu:/bin/bash\n' "$temporary_root"
  fi
}
mkdir -p "$temporary_root/home/ubuntu/.ssh"
: > "$temporary_root/home/ubuntu/.ssh/authorized_keys"

if (check_root_ssh_key) 2>/dev/null; then
  fail "check_root_ssh_key must reject when neither root nor SUDO_USER has a usable key"
fi
[ ! -e "$fake_user_home" ] || fail "no admin files should be touched when the preflight fails"

pass "check_root_ssh_key fails closed when no usable key exists anywhere"

### 5. Rerun cleanup: a prior buggy run copied root's forced-command line
### verbatim into the admin's authorized_keys. A fresh run (even one that
### takes the "leave untouched" fast path) must strip exactly that line and
### nothing else.
reset_sandbox
printf '%s\n' "$restricted_line" > "$ROOT_AUTHORIZED_KEYS"
export SUDO_USER="ubuntu"
getent() {
  if [ "$1" = "passwd" ] && [ "$2" = "ubuntu" ]; then
    printf 'ubuntu:x:1000:1000::%s/home/ubuntu:/bin/bash\n' "$temporary_root"
  fi
}
mkdir -p "$temporary_root/home/ubuntu/.ssh"
printf '%s\n' "$sudo_user_pubkey" > "$temporary_root/home/ubuntu/.ssh/authorized_keys"

mkdir -p "$fake_user_home/.ssh"
printf '%s\n%s\n' "$sudo_user_pubkey" "$restricted_line" > "$fake_user_home/.ssh/authorized_keys"
chmod 700 "$fake_user_home/.ssh"
chmod 600 "$fake_user_home/.ssh/authorized_keys"
printf 'success\n' > "$VPSGUARD_INSTALLED_MARKER"  # not first install; admin keys non-empty -> fast path

assert_success configure_authorized_keys
assert_file_contains "$fake_user_home/.ssh/authorized_keys" "$sudo_user_pubkey"
if grep -Fxq "$restricted_line" "$fake_user_home/.ssh/authorized_keys"; then
  fail "residual forced-command line must be purged even on the 'leave untouched' rerun path"
fi
assert_equal 1 "$(grep -c . "$fake_user_home/.ssh/authorized_keys")" "only the legitimate key line remains"

pass "a residual forced-command line is purged from the admin's authorized_keys on rerun"
