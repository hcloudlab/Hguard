#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/test_helper.sh
. "$(dirname "$0")/test_helper.sh"

# End-to-end migrate_from_vpsguard test against a real VPSGuard 0.3.7
# install layout exported from a live Vultr Ubuntu 24.04 instance
# (ssh.service mode, SSH port already migrated from 22 to 22222 before
# this export, UFW pre-enabled with existing proxy port rules, full
# conntrack sysctl/modprobe/modules/service set written by VPSGuard).
# Real IPs were replaced with documentation-reserved values before this
# fixture was committed; everything else is verbatim.

temporary_root="$(mktemp -d)"
trap 'rm -rf "$temporary_root"' EXIT
export HGUARD_TEST_MODE=1
export HGUARD_ETC_ROOT="$temporary_root/etc"
mkdir -p "$HGUARD_ETC_ROOT"
cp -R "$TEST_ROOT/tests/fixtures/vpsguard-0.3.7-vultr/etc/." "$HGUARD_ETC_ROOT/"
# shellcheck source=install-core.sh
. "$TEST_ROOT/install-core.sh"

sshd() { [ "$1" = "-t" ] && return 0; return 0; }
fail2ban-client() { [ "$1" = "-t" ] && return 0; return 0; }
visudo() { return 0; }
sysctl() { return 0; }
systemctl() { return 0; }
detect_ssh_runtime_mode() { SSH_RUNTIME_MODE="service"; SSH_SERVICE_UNIT="ssh.service"; }
apply_ssh_runtime() { detect_ssh_runtime_mode; return 0; }
verify_ssh_listener() { return 0; }

cloud_init_sshd_before="$(cat "${HGUARD_ETC_ROOT}/ssh/sshd_config.d/50-cloud-init.conf")"
sudoers_readme_before="$(cat "${HGUARD_ETC_ROOT}/sudoers.d/README")"
legacy_state_env_before="$(cat "${HGUARD_ETC_ROOT}/vpsguard/state.env")"

assert_success migrate_from_vpsguard_needed
migrate_from_vpsguard

### State files: copied verbatim, including the pre-install snapshot and
### the UFW-managed-rules list.
assert_file_contains "${HGUARD_ETC_ROOT}/hguard/config.env" "NEW_USER='hadmin'"
assert_file_contains "${HGUARD_ETC_ROOT}/hguard/config.env" "SSH_PORT='22222'"
assert_file_contains "${HGUARD_ETC_ROOT}/hguard/config.env" "ORIGINAL_SSH_PORT='22'"
assert_equal "$legacy_state_env_before" "$(cat "${HGUARD_ETC_ROOT}/hguard/state.env")" \
  "state.env's pre-install snapshot is preserved byte-for-byte"
for rule in 443/tcp 8443/udp 8443/tcp 34567/tcp 22222/tcp; do
  assert_file_contains "${HGUARD_ETC_ROOT}/hguard/managed-rules" "$rule"
done
[ -f "${HGUARD_ETC_ROOT}/hguard/.installed" ] || fail ".installed marker was not migrated"

### sshd: the port migration (22 -> 22222) was already finalized before
### this export (no .pending-port-finalization marker in the fixture), so
### the migrated drop-in must carry only the current port - 22222 must
### NOT be reset back to 22.
if grep -Fq 'VPSGuard managed include' "${HGUARD_ETC_ROOT}/ssh/sshd_config"; then
  fail "the old VPSGuard sshd include block was not removed"
fi
assert_file_contains "${HGUARD_ETC_ROOT}/ssh/sshd_config" "# BEGIN Hguard managed include"
assert_file_contains "${HGUARD_ETC_ROOT}/ssh/sshd_config" "Include ${HGUARD_ETC_ROOT}/ssh/sshd_config.d/00-hguard.conf"
assert_file_contains "${HGUARD_ETC_ROOT}/ssh/sshd_config" "PermitRootLogin yes"
[ ! -e "${HGUARD_ETC_ROOT}/ssh/sshd_config.d/00-vpsguard.conf" ] || fail "the old sshd drop-in was not removed"
assert_file_contains "${HGUARD_ETC_ROOT}/ssh/sshd_config.d/00-hguard.conf" "Port 22222"
if grep -Fxq "Port 22" "${HGUARD_ETC_ROOT}/ssh/sshd_config.d/00-hguard.conf"; then
  fail "the SSH port was incorrectly reset to 22 instead of staying at 22222"
fi
assert_equal "$cloud_init_sshd_before" "$(cat "${HGUARD_ETC_ROOT}/ssh/sshd_config.d/50-cloud-init.conf")" \
  "cloud-init's own sshd drop-in must be byte-for-byte untouched"
[ ! -e "${HGUARD_ETC_ROOT}/systemd/system/ssh.socket.d" ] || fail "Vultr is ssh.service mode; no socket override should exist"

### fail2ban: new jail in place, old jail gone, port carried over correctly.
[ ! -e "${HGUARD_ETC_ROOT}/fail2ban/jail.d/vpsguard-sshd.local" ] || fail "the old fail2ban jail was not removed"
assert_file_contains "${HGUARD_ETC_ROOT}/fail2ban/jail.d/hguard-sshd.local" "port = 22222"
assert_file_contains "${HGUARD_ETC_ROOT}/fail2ban/jail.d/hguard-sshd.local" "ignoreip = 127.0.0.1/8 ::1 203.0.113.47"

### sudoers: Vultr also uses password sudo (no vpsguard-hadmin file ever
### existed) - only the stock README is present and must stay untouched.
[ ! -e "${HGUARD_ETC_ROOT}/sudoers.d/vpsguard-hadmin" ] || fail "unexpected legacy sudoers file"
[ ! -e "${HGUARD_ETC_ROOT}/sudoers.d/hguard-hadmin" ] || fail "no sudoers file should have been created (password mode never had one)"
assert_equal "$sudoers_readme_before" "$(cat "${HGUARD_ETC_ROOT}/sudoers.d/README")" \
  "the stock sudoers README must be byte-for-byte untouched"

### BBR: migrated.
[ ! -e "${HGUARD_ETC_ROOT}/sysctl.d/99-vpsguard-bbr.conf" ] || fail "the old BBR sysctl file was not removed"
assert_file_contains "${HGUARD_ETC_ROOT}/sysctl.d/99-hguard-bbr.conf" "tcp_congestion_control = bbr"
[ ! -e "${HGUARD_ETC_ROOT}/modules-load.d/vpsguard-bbr.conf" ] || fail "the old BBR modules-load file was not removed"
assert_file_contains "${HGUARD_ETC_ROOT}/modules-load.d/hguard-bbr.conf" "tcp_bbr"

### Conntrack: Vultr had the full set - sysctl, modprobe, modules, helper
### script and systemd service - all must migrate.
[ ! -e "${HGUARD_ETC_ROOT}/sysctl.d/99-vpsguard-conntrack.conf" ] || fail "the old conntrack sysctl file was not removed"
assert_file_contains "${HGUARD_ETC_ROOT}/sysctl.d/99-hguard-conntrack.conf" "nf_conntrack_tcp_timeout_syn_sent = 30"
[ ! -e "${HGUARD_ETC_ROOT}/modprobe.d/vpsguard-nf-conntrack.conf" ] || fail "the old conntrack modprobe file was not removed"
assert_file_contains "${HGUARD_ETC_ROOT}/modprobe.d/hguard-nf-conntrack.conf" "hashsize=16384"
[ ! -e "${HGUARD_ETC_ROOT}/modules-load.d/vpsguard-conntrack.conf" ] || fail "the old conntrack modules-load file was not removed"
assert_file_contains "${HGUARD_ETC_ROOT}/modules-load.d/hguard-conntrack.conf" "nf_conntrack"
[ ! -e "${HGUARD_ETC_ROOT}/vpsguard/apply-conntrack-profile.sh" ] || fail "the old conntrack helper script was not removed"
assert_file_contains "${HGUARD_ETC_ROOT}/hguard/apply-conntrack-profile.sh" "nf_conntrack"
[ ! -e "${HGUARD_ETC_ROOT}/systemd/system/vpsguard-conntrack.service" ] || fail "the old conntrack service unit was not removed"
assert_file_contains "${HGUARD_ETC_ROOT}/systemd/system/hguard-conntrack.service" "ExecStart=/bin/bash ${HGUARD_ETC_ROOT}/hguard/apply-conntrack-profile.sh"

### No file anywhere is still a *currently effective* VPSGuard-managed
### file after a clean migration.
[ -z "$(legacy_vpsguard_files_present)" ] || fail "legacy_vpsguard_files_present must report nothing still in effect after a clean migration"

### /etc/vpsguard is preserved as a backup, with the MIGRATED marker.
[ -d "${HGUARD_ETC_ROOT}/vpsguard" ] || fail "/etc/vpsguard must be preserved, not removed"
[ -f "$VPSGUARD_MIGRATED_MARKER_FILE" ] || fail "MIGRATED-TO-HGUARD marker was not written"
assert_file_contains "$VPSGUARD_MIGRATED_MARKER_FILE" "Migrated to Hguard"

### Rerunning must be a no-op and must not touch the already-correct port.
assert_failure migrate_from_vpsguard_needed
migrate_from_vpsguard
assert_file_contains "${HGUARD_ETC_ROOT}/ssh/sshd_config.d/00-hguard.conf" "Port 22222"

pass "migrate_from_vpsguard correctly migrates a real Vultr (ssh.service, port 22222, UFW rules, conntrack) VPSGuard 0.3.7 layout"
