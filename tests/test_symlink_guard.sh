#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/test_helper.sh
. "$(dirname "$0")/test_helper.sh"

temporary_root="$(mktemp -d)"
trap 'rm -rf "$temporary_root"' EXIT
export HGUARD_TEST_MODE=1
export HGUARD_ETC_ROOT="$temporary_root/etc"
export HGUARD_STATE_DIR="$temporary_root/etc/hguard"
# shellcheck source=install-core.sh
. "$TEST_ROOT/install-core.sh"

# ensure_directory and ensure_admin_ssh_directory each re-check for a
# symlink immediately before chmod/chown (not only in an earlier caller
# check), since mkdir -p is a no-op on an existing symlink and chmod/chown
# follow it by default - without this, a path swapped to a symlink between
# an earlier check and the actual privileged operation would make it run,
# as root, against whatever target the symlink points to.

real_target="$(mktemp -d)"
chmod 755 "$real_target"
symlinked_path="$temporary_root/symlinked-dir"
ln -s "$real_target" "$symlinked_path"

if (ensure_directory "$symlinked_path" 700) 2>/dev/null; then
  fail "ensure_directory must refuse to chmod/chown through a symlink"
fi
real_target_mode="$(stat -c '%a' "$real_target" 2>/dev/null || stat -f '%Lp' "$real_target")"
assert_equal 755 "$real_target_mode" "ensure_directory must not have touched the symlink's target"

pass "ensure_directory refuses a path that is a symlink"

NEW_USER="admin"
chown() { fail "chown must not run when ~/.ssh is a symlink"; }
symlinked_ssh="$temporary_root/symlinked-ssh"
ln -s "$real_target" "$symlinked_ssh"

if (ensure_admin_ssh_directory "$symlinked_ssh") 2>/dev/null; then
  fail "ensure_admin_ssh_directory must refuse to chown/chmod through a symlink"
fi

pass "ensure_admin_ssh_directory refuses a path that is a symlink"
