#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/test_helper.sh
. "$(dirname "$0")/test_helper.sh"

# End-to-end migrate_from_vpsguard test against a real VPSGuard 0.3.7
# install layout exported from a live AWS Ubuntu 24.04 instance (ssh.socket
# mode, cloud-init image with its own 90-cloud-init-users sudoers grant and
# 60-cloudimg-settings.conf sshd drop-in; no conntrack files, since the
# cloud image ships its own conntrack sysctl and VPSGuard detected that
# foreign config and skipped writing its own). Real IPs/hostnames were
# replaced with documentation-reserved values before this fixture was
# committed; everything else (file layout, content, markers) is verbatim.

temporary_root="$(mktemp -d)"
trap 'rm -rf "$temporary_root"' EXIT
export HGUARD_TEST_MODE=1
export HGUARD_ETC_ROOT="$temporary_root/etc"
mkdir -p "$HGUARD_ETC_ROOT"
cp -R "$TEST_ROOT/tests/fixtures/vpsguard-0.3.7-aws/etc/." "$HGUARD_ETC_ROOT/"
# shellcheck source=install-core.sh
. "$TEST_ROOT/install-core.sh"

# Collaborators that need real system tools (sshd, systemd, fail2ban) are
# stubbed; migrate_from_vpsguard's own file-handling logic is what's under
# test here, not those tools' own already-tested behavior.
sshd() { [ "$1" = "-t" ] && return 0; return 0; }
fail2ban-client() { [ "$1" = "-t" ] && return 0; return 0; }
visudo() { return 0; }
sysctl() { return 0; }
detect_ssh_runtime_mode() { SSH_RUNTIME_MODE="socket"; SSH_SERVICE_UNIT="ssh.service"; }
apply_ssh_runtime() { detect_ssh_runtime_mode; return 0; }
verify_ssh_listener() { return 0; }

# Snapshot everything untouched by VPSGuard, to assert byte-identical
# afterward: the cloud-init sudoers grant, the cloud-init sshd drop-in, and
# the sudoers README.
cloud_init_sudoers_before="$(cat "${HGUARD_ETC_ROOT}/sudoers.d/90-cloud-init-users")"
cloudimg_sshd_before="$(cat "${HGUARD_ETC_ROOT}/ssh/sshd_config.d/60-cloudimg-settings.conf")"
sudoers_readme_before="$(cat "${HGUARD_ETC_ROOT}/sudoers.d/README")"
legacy_state_env_before="$(cat "${HGUARD_ETC_ROOT}/vpsguard/state.env")"

assert_success migrate_from_vpsguard_needed
migrate_from_vpsguard

### State files: copied verbatim to the new location, including the
### original pre-install snapshot.
assert_file_contains "${HGUARD_ETC_ROOT}/hguard/config.env" "NEW_USER='hadmin'"
assert_file_contains "${HGUARD_ETC_ROOT}/hguard/config.env" "SSH_PORT='22'"
assert_file_contains "${HGUARD_ETC_ROOT}/hguard/config.env" "ORIGINAL_SSH_PORT='22'"
assert_equal "$legacy_state_env_before" "$(cat "${HGUARD_ETC_ROOT}/hguard/state.env")" \
  "state.env's pre-install snapshot is preserved byte-for-byte"
assert_file_contains "${HGUARD_ETC_ROOT}/hguard/managed-rules" "22/tcp"
[ -f "${HGUARD_ETC_ROOT}/hguard/.installed" ] || fail ".installed marker was not migrated"

### sshd: new include block + drop-in in place, old VPSGuard include block
### gone, cloud-init's own Include and drop-in untouched, sshd.socket
### override migrated too (AWS is ssh.socket mode).
if grep -Fq 'VPSGuard managed include' "${HGUARD_ETC_ROOT}/ssh/sshd_config"; then
  fail "the old VPSGuard sshd include block was not removed"
fi
assert_file_contains "${HGUARD_ETC_ROOT}/ssh/sshd_config" "# BEGIN Hguard managed include"
assert_file_contains "${HGUARD_ETC_ROOT}/ssh/sshd_config" "Include ${HGUARD_ETC_ROOT}/ssh/sshd_config.d/00-hguard.conf"
assert_file_contains "${HGUARD_ETC_ROOT}/ssh/sshd_config" "Include /etc/ssh/sshd_config.d/*.conf"
[ ! -e "${HGUARD_ETC_ROOT}/ssh/sshd_config.d/00-vpsguard.conf" ] || fail "the old sshd drop-in was not removed"
assert_file_contains "${HGUARD_ETC_ROOT}/ssh/sshd_config.d/00-hguard.conf" "Port 22"
assert_equal "$cloudimg_sshd_before" "$(cat "${HGUARD_ETC_ROOT}/ssh/sshd_config.d/60-cloudimg-settings.conf")" \
  "cloud-init's own sshd drop-in must be byte-for-byte untouched"
[ ! -e "${HGUARD_ETC_ROOT}/systemd/system/ssh.socket.d/00-vpsguard.conf" ] || fail "the old ssh.socket override was not removed"
assert_file_contains "${HGUARD_ETC_ROOT}/systemd/system/ssh.socket.d/00-hguard.conf" "ListenStream=0.0.0.0:22"

### fail2ban: new jail in place (copied verbatim), old jail gone.
[ ! -e "${HGUARD_ETC_ROOT}/fail2ban/jail.d/vpsguard-sshd.local" ] || fail "the old fail2ban jail was not removed"
assert_file_contains "${HGUARD_ETC_ROOT}/fail2ban/jail.d/hguard-sshd.local" "port = 22"

### sudoers: AWS uses password sudo (no vpsguard-hadmin sudoers file ever
### existed), so there is nothing of VPSGuard's own to migrate here - the
### real requirement is that cloud-init's grant and the README are left
### completely alone.
[ ! -e "${HGUARD_ETC_ROOT}/sudoers.d/vpsguard-hadmin" ] || fail "unexpected legacy sudoers file"
[ ! -e "${HGUARD_ETC_ROOT}/sudoers.d/hguard-hadmin" ] || fail "no sudoers file should have been created (password mode never had one)"
assert_equal "$cloud_init_sudoers_before" "$(cat "${HGUARD_ETC_ROOT}/sudoers.d/90-cloud-init-users")" \
  "cloud-init's own sudoers grant must be byte-for-byte untouched"
assert_equal "$sudoers_readme_before" "$(cat "${HGUARD_ETC_ROOT}/sudoers.d/README")" \
  "the stock sudoers README must be byte-for-byte untouched"

### BBR: migrated.
[ ! -e "${HGUARD_ETC_ROOT}/sysctl.d/99-vpsguard-bbr.conf" ] || fail "the old BBR sysctl file was not removed"
assert_file_contains "${HGUARD_ETC_ROOT}/sysctl.d/99-hguard-bbr.conf" "tcp_congestion_control = bbr"
[ ! -e "${HGUARD_ETC_ROOT}/modules-load.d/vpsguard-bbr.conf" ] || fail "the old BBR modules-load file was not removed"
assert_file_contains "${HGUARD_ETC_ROOT}/modules-load.d/hguard-bbr.conf" "tcp_bbr"

### Conntrack: AWS never had any VPSGuard conntrack files (foreign config
### from the cloud image made VPSGuard skip writing its own) - migration
### must not invent any.
[ ! -e "${HGUARD_ETC_ROOT}/sysctl.d/99-hguard-conntrack.conf" ] || fail "migration must not create conntrack files that never existed on AWS"
[ ! -e "${HGUARD_ETC_ROOT}/hguard/apply-conntrack-profile.sh" ] || fail "migration must not create a conntrack helper that never existed"
[ ! -d "${HGUARD_ETC_ROOT}/systemd/system" ] || [ ! -e "${HGUARD_ETC_ROOT}/systemd/system/hguard-conntrack.service" ] \
  || fail "migration must not create a conntrack service that never existed"

### No file anywhere is still a *currently effective* VPSGuard-managed
### file - everything that existed has either been removed (replaced) or
### was never VPSGuard's to begin with (cloud-init's own files).
remaining="$(any_generation_marker_owns "${HGUARD_ETC_ROOT}/ssh/sshd_config.d/00-vpsguard.conf" && echo found; \
  any_generation_marker_owns "${HGUARD_ETC_ROOT}/fail2ban/jail.d/vpsguard-sshd.local" && echo found; \
  any_generation_marker_owns "${HGUARD_ETC_ROOT}/sysctl.d/99-vpsguard-bbr.conf" && echo found; true)"
[ -z "$remaining" ] || fail "a VPSGuard-managed file is still present and effective after migration"
[ -z "$(legacy_vpsguard_files_present)" ] || fail "legacy_vpsguard_files_present must report nothing still in effect after a clean migration"

### /etc/vpsguard is preserved as a backup, with the MIGRATED marker.
[ -d "${HGUARD_ETC_ROOT}/vpsguard" ] || fail "/etc/vpsguard must be preserved, not removed"
[ -f "$VPSGUARD_MIGRATED_MARKER_FILE" ] || fail "MIGRATED-TO-HGUARD marker was not written"
assert_file_contains "$VPSGUARD_MIGRATED_MARKER_FILE" "Migrated to Hguard"

### Rerunning must be a no-op: migrate_from_vpsguard_needed is now false,
### and a second call does not error or duplicate anything.
assert_failure migrate_from_vpsguard_needed
migrate_from_vpsguard
assert_file_contains "${HGUARD_ETC_ROOT}/ssh/sshd_config.d/00-hguard.conf" "Port 22"

pass "migrate_from_vpsguard correctly migrates a real AWS (ssh.socket, cloud-init, no-conntrack) VPSGuard 0.3.7 layout"
