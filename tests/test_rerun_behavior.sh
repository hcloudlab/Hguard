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

apt_calls=""
apt() { apt_calls="$apt_calls|$*"; }

# First install: marker absent.
rm -f "$VPSGUARD_INSTALLED_MARKER"
apt_calls=""
upgrade_system
assert_equal "true" "$(printf '%s' "$apt_calls" | grep -q 'upgrade -y' && echo true || echo false)" "first install runs full apt upgrade"

# Rerun: marker present with a successful status.
printf 'success\n' > "$VPSGUARD_INSTALLED_MARKER"
apt_calls=""
upgrade_system
assert_equal "false" "$(printf '%s' "$apt_calls" | grep -q 'upgrade -y' && echo true || echo false)" "rerun does not run full apt upgrade"
assert_equal "true" "$(printf '%s' "$apt_calls" | grep -q 'install -y' && echo true || echo false)" "rerun still installs missing dependencies"

pass "upgrade_system only runs full apt upgrade on first install"

export ROOT_AUTHORIZED_KEYS="$temporary_root/root-authorized_keys"
ssh-keygen -q -t ed25519 -N '' -f "$temporary_root/root_test_key" </dev/null
cp "$temporary_root/root_test_key.pub" "$ROOT_AUTHORIZED_KEYS"
NEW_USER="admin"
managed_user_home() { printf '%s\n' "$temporary_root/home/admin"; }
mkdir -p "$temporary_root/home/admin/.ssh"
ssh-keygen -q -t ed25519 -N '' -f "$temporary_root/admin_test_key" </dev/null
cp "$temporary_root/admin_test_key.pub" "$temporary_root/home/admin/.ssh/authorized_keys"
chmod 700 "$temporary_root/home/admin/.ssh"
chmod 600 "$temporary_root/home/admin/.ssh/authorized_keys"

# Rerun, admin's authorized_keys already non-empty and this is not first install:
# the admin's own key must survive and root's key must NOT be force-merged again
# beyond what configure_authorized_keys already guarantees (union, never remove) --
# the real regression this guards is sync happening on every rerun being renamed
# into a *conditional* call; verify the condition function directly instead.
printf 'success\n' > "$VPSGUARD_INSTALLED_MARKER"
assert_equal "false" "$(root_pubkey_sync_required && echo true || echo false)" "rerun with existing non-empty admin authorized_keys skips root pubkey sync"

: > "$temporary_root/home/admin/.ssh/authorized_keys"
assert_equal "true" "$(root_pubkey_sync_required && echo true || echo false)" "empty admin authorized_keys still triggers sync even on rerun"

rm -f "$VPSGUARD_INSTALLED_MARKER"
cp "$temporary_root/admin_test_key.pub" "$temporary_root/home/admin/.ssh/authorized_keys"
assert_equal "true" "$(root_pubkey_sync_required && echo true || echo false)" "first install always syncs regardless of existing admin keys"

pass "root_pubkey_sync_required reflects first-install-or-empty-admin-keys"
