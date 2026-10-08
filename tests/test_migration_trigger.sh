#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/test_helper.sh
. "$(dirname "$0")/test_helper.sh"

# This covers only migrate_from_vpsguard's trigger condition and the
# MIGRATED-marker bookkeeping - pure filesystem-existence logic, no
# external command output to get wrong. The full migration (sshd/fail2ban/
# sudoers/conntrack file migration against a real VPSGuard 0.3.7 layout)
# is deliberately NOT tested here yet: per the real-machine fixture rule,
# those tests wait for the actual exported /etc/vpsguard layout and
# command output requested separately, rather than a hand-written stand-in.

temporary_root="$(mktemp -d)"
trap 'rm -rf "$temporary_root"' EXIT
export HGUARD_TEST_MODE=1
export HGUARD_ETC_ROOT="$temporary_root/etc"
export HGUARD_STATE_DIR="$temporary_root/etc/hguard"
export VPSGUARD_LEGACY_STATE_DIR="$temporary_root/etc/vpsguard"
# shellcheck source=install-core.sh
. "$TEST_ROOT/install-core.sh"

assert_failure migrate_from_vpsguard_needed

mkdir -p "$VPSGUARD_LEGACY_STATE_DIR"
assert_success migrate_from_vpsguard_needed

mkdir -p "$HGUARD_STATE_DIR"
assert_failure migrate_from_vpsguard_needed
rmdir "$HGUARD_STATE_DIR"

pass "migrate_from_vpsguard_needed triggers only when a VPSGuard dir exists and no Hguard dir exists yet"

### migrate_from_vpsguard, with nothing else to migrate (no sshd/fail2ban/
### sudoers/conntrack artifacts present), still copies state and leaves the
### MIGRATED marker so a second run is a no-op even without the Hguard dir
### existing as the sole signal.
printf "NEW_USER='admin'\nSSH_PORT='22'\n" > "${VPSGUARD_LEGACY_STATE_DIR}/config.env"
migrate_from_vpsguard
[ -f "${HGUARD_STATE_DIR}/config.env" ] || fail "config.env was not migrated"
assert_file_contains "${HGUARD_STATE_DIR}/config.env" "NEW_USER='admin'"
[ -f "$VPSGUARD_MIGRATED_MARKER_FILE" ] || fail "the MIGRATED-TO-HGUARD marker was not written"
assert_file_contains "$VPSGUARD_MIGRATED_MARKER_FILE" "Migrated to Hguard"
[ -d "$VPSGUARD_LEGACY_STATE_DIR" ] || fail "/etc/vpsguard must be preserved, not removed, after migration"

pass "migrate_from_vpsguard copies state and leaves a MIGRATED marker; /etc/vpsguard is preserved"
