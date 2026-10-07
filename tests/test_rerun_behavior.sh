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
