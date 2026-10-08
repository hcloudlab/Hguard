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

# Not keyed off $HGUARD_STATE_DIR's existence: migrate_vpsguard_copy_state_files
# creates that directory as step one, so if the trigger checked it instead
# of the MIGRATED marker, a migration that failed partway through would
# permanently strand the system half-migrated - a rerun would never retry.
mkdir -p "$HGUARD_STATE_DIR"
assert_success migrate_from_vpsguard_needed
printf 'anything\n' > "$VPSGUARD_MIGRATED_MARKER_FILE"
assert_failure migrate_from_vpsguard_needed
rm -f "$VPSGUARD_MIGRATED_MARKER_FILE"
rmdir "$HGUARD_STATE_DIR"

pass "migrate_from_vpsguard_needed is keyed off the MIGRATED marker, not HGUARD_STATE_DIR's existence, so a failed migration can be retried"

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

### Regression: a failing subsystem step (sshd here, forced by making the
### legacy sshd_config contain a VPSGuard include block with a malformed
### sshd syntax) must not write the MIGRATED marker, so a subsequent run
### retries instead of silently reporting success with a half-migrated
### system - this used to abort the whole script via set -e instead of
### reaching this point at all.
rm -rf "$HGUARD_STATE_DIR" "$VPSGUARD_MIGRATED_MARKER_FILE"
export SSHD_CONFIG="$temporary_root/sshd_config"
printf '%s\n%s\n%s\n' \
  '# BEGIN VPSGuard managed include' \
  "Include ${VPSGUARD_LEGACY_SSHD_CONFIG}" \
  '# END VPSGuard managed include' > "$SSHD_CONFIG"
sshd() { [ "$1" = "-t" ] && return 1; return 0; }
if (migrate_from_vpsguard) 2>/dev/null; then
  fail "migrate_from_vpsguard must report failure when a subsystem step fails"
fi
[ ! -f "$VPSGUARD_MIGRATED_MARKER_FILE" ] || fail "the MIGRATED marker must not be written when a step failed"
assert_success migrate_from_vpsguard_needed

pass "a failing subsystem step leaves the MIGRATED marker unwritten, so a rerun retries instead of reporting false success"

### Regression: migrate_vpsguard_sudoers must compute the new sudoers path
### from the username it just read out of the migrated config.env, not
### from sudoers_file_for_user() (which reads the global $NEW_USER - still
### unset at migration time, since resolve_managed_user hasn't run yet).
### The bug produced a malformed path missing the username entirely.
rm -rf "$HGUARD_STATE_DIR" "$VPSGUARD_MIGRATED_MARKER_FILE"
unset SSH_PORT NEW_USER
mkdir -p "$HGUARD_STATE_DIR"
printf "NEW_USER='admin'\nSSH_PORT='22'\n" > "$HGUARD_CONFIG_FILE"
export SUDOERS_DIR="$temporary_root/sudoers.d"
mkdir -p "$SUDOERS_DIR"
printf 'admin ALL=(ALL:ALL) NOPASSWD: ALL\n' > "${SUDOERS_DIR}/vpsguard-admin"
visudo() { [ "$1" = "-cf" ] || [ "$1" = "-c" ]; }
migrate_vpsguard_sudoers
[ -f "${SUDOERS_DIR}/hguard-admin" ] || fail "migrated sudoers file was not created at the correct hguard-<user> path"
[ ! -e "${SUDOERS_DIR}/vpsguard-admin" ] || fail "the old vpsguard-<user> sudoers file was not removed"
assert_file_contains "${SUDOERS_DIR}/hguard-admin" "admin ALL=(ALL:ALL) NOPASSWD: ALL"

pass "migrate_vpsguard_sudoers writes the new file at hguard-<user>, not a path missing the username"
