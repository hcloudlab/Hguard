#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/test_helper.sh
. "$(dirname "$0")/test_helper.sh"

# End-to-end test against a real VPSGuard 0.3.7 install layout exported
# from a live Vultr Ubuntu 24.04 instance (ssh.service mode, SSH port
# already migrated from 22 to 22222 before this export, UFW pre-enabled
# with existing proxy port rules, full conntrack sysctl/modprobe/modules/
# service set written by VPSGuard). Real IPs were replaced with
# documentation-reserved values before this fixture was committed;
# everything else is verbatim.
#
# See test_migration_e2e_aws.sh for the full rationale: this exercises
# migration followed immediately by a full, real main(), the exact
# sequence that caught a real bug on this Vultr box (configure_fail2ban
# refusing a migrated jail file still carrying the old VPSGuard marker,
# and migrate_vpsguard_conntrack_service leaving a dangling ExecStart
# path). Stubbed/real split and the reasoning behind it is identical to
# the AWS test; see its header comment instead of repeating it here.

temporary_root="$(mktemp -d)"
trap 'rm -rf "$temporary_root"' EXIT
export HGUARD_TEST_MODE=1
export HGUARD_ETC_ROOT="$temporary_root/etc"
export HGUARD_RUN_ROOT="$temporary_root/run"
export HGUARD_PROC_ROOT="$temporary_root/proc"
export HGUARD_SYS_MODULE_ROOT="$temporary_root/sys/module"
mkdir -p "$HGUARD_ETC_ROOT"
cp -R "$TEST_ROOT/tests/fixtures/vpsguard-0.3.7-vultr/etc/." "$HGUARD_ETC_ROOT/"
mkdir -p "$APT_CONF_DIR"
{
  printf 'ID=ubuntu\n'
  printf 'VERSION_ID="24.04"\n'
  printf 'PRETTY_NAME="Ubuntu 24.04.1 LTS"\n'
} > "${HGUARD_ETC_ROOT}/os-release"
unset NEW_USER SSH_PORT ALLOW_PORTS 2>/dev/null || true
# shellcheck source=install-core.sh
. "$TEST_ROOT/install-core.sh"

export BBR_MODULE_PERSISTENCE_REQUIRED=true

require_root() { :; }
ensure_managed_user() { :; }
configure_authorized_keys() { :; }
check_root_ssh_key() { :; }
configure_sudo() { :; }
verify_sudo_configuration() { :; }
upgrade_system() { :; }
fail2ban_systemd_backend_available() { :; }
configure_ufw_before_ssh() { :; }
verify_effective_sshd_config() { :; }
verify_ssh_listener() { :; }
apply_ssh_runtime() { :; }
ufw_tcp_rule_exists() { :; }
run_final_acceptance() {
  INSTALL_STATUS="success"
  write_config_env
  atomic_write "$HGUARD_INSTALLED_MARKER" 600 "${INSTALL_STATUS}
"
}
print_final_summary() { :; }

sshd() {
  case "$1" in
    -t) return 0 ;;
    -T) printf 'port 22222\n'; return 0 ;;
    *) return 0 ;;
  esac
}
fail2ban-client() { [ "$1" = "-t" ] && return 0; [ "$*" = "status sshd" ] && return 0; return 0; }
# Vultr is ssh.service mode: no ssh.socket unit exists at all, so
# detect_ssh_runtime_mode must correctly stay in "service" mode (unlike
# the AWS test's stub) - otherwise write_hguard_ssh_runtime_policy would
# wrongly think a socket override needs writing.
systemctl() {
  case "$1" in
    list-unit-files)
      case "$2" in ssh.service|fail2ban.service|hguard-conntrack.service) printf '%s\n' "$2"; return 0 ;; esac
      return 1 ;;
    is-active|is-enabled)
      local unit="$2"; [ "$unit" = "--quiet" ] && unit="$3"
      case "$unit" in ssh.service|fail2ban.service) return 0 ;; esac
      return 1 ;;
    *) return 0 ;;
  esac
}
sysctl() {
  case "$1" in
    -n)
      case "$2" in
        net.ipv4.tcp_congestion_control) printf 'bbr\n'; return 0 ;;
        net.core.default_qdisc) printf 'fq\n'; return 0 ;;
        net.ipv4.tcp_available_congestion_control) printf 'reno cubic bbr\n'; return 0 ;;
        *) return 1 ;;
      esac ;;
    *) return 0 ;;
  esac
}
# shellcheck disable=SC2329
curl() { fail "curl must not run when every sibling file is found locally"; }
# shellcheck disable=SC2329
wget() { fail "wget must not run when every sibling file is found locally"; }

sudoers_readme_before="$(cat "${HGUARD_ETC_ROOT}/sudoers.d/README")"
legacy_state_env_before="$(cat "${HGUARD_ETC_ROOT}/vpsguard/state.env")"
cloud_init_sshd_before="$(cat "${HGUARD_ETC_ROOT}/ssh/sshd_config.d/50-cloud-init.conf")"

main

### The real bug this test targets: every migrated managed file must carry
### the current Hguard marker, not the VPSGuard one it was copied with.
for managed_file in \
  "${HGUARD_ETC_ROOT}/hguard/config.env" \
  "${HGUARD_ETC_ROOT}/ssh/sshd_config.d/00-hguard.conf" \
  "${HGUARD_ETC_ROOT}/fail2ban/jail.d/hguard-sshd.local" \
  "${HGUARD_ETC_ROOT}/sysctl.d/99-hguard-bbr.conf" \
  "${HGUARD_ETC_ROOT}/modules-load.d/hguard-bbr.conf" \
  "${HGUARD_ETC_ROOT}/sysctl.d/99-hguard-conntrack.conf" \
  "${HGUARD_ETC_ROOT}/modprobe.d/hguard-nf-conntrack.conf" \
  "${HGUARD_ETC_ROOT}/modules-load.d/hguard-conntrack.conf" \
  "${HGUARD_ETC_ROOT}/hguard/apply-conntrack-profile.sh"; do
  any_generation_marker_owns "$managed_file" || fail "${managed_file} does not exist or isn't recognized as managed"
  head -n 2 "$managed_file" | grep -Fq 'Managed by VPSGuard' \
    && fail "${managed_file} still carries the old VPSGuard marker after a full install run"
done

### State files: copied verbatim, including the pre-install snapshot and
### the full UFW-managed-rules list, with the header relabeled.
assert_file_contains "${HGUARD_ETC_ROOT}/hguard/config.env" "NEW_USER='hadmin'"
assert_file_contains "${HGUARD_ETC_ROOT}/hguard/config.env" "SSH_PORT='22222'"
assert_file_contains "${HGUARD_ETC_ROOT}/hguard/config.env" "ORIGINAL_SSH_PORT='22'"
assert_equal "$legacy_state_env_before" "$(cat "${HGUARD_ETC_ROOT}/hguard/state.env")" \
  "state.env's pre-install snapshot is preserved byte-for-byte, header included"
for rule in 443/tcp 8443/udp 8443/tcp 34567/tcp 22222/tcp; do
  assert_file_contains "${HGUARD_ETC_ROOT}/hguard/managed-rules" "$rule"
done
if head -n 1 "${HGUARD_ETC_ROOT}/hguard/managed-rules" | grep -Fq VPSGuard; then
  fail "managed-rules' header still says VPSGuard after a full install run"
fi
[ -f "${HGUARD_ETC_ROOT}/hguard/.installed" ] || fail ".installed marker was not migrated"
assert_file_contains "${HGUARD_ETC_ROOT}/hguard/.installed" "success"

### sshd: the port migration (22 -> 22222) was already finalized before
### this export, so the port must stay 22222, not reset to 22. Old include
### block gone, cloud-init's own drop-in untouched.
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

### fail2ban: new jail in place, port preserved, old jail gone.
# configure_fail2ban (real, unlike an isolated migrate_from_vpsguard())
# unconditionally regenerates the jail's ignoreip list from the current
# connection every run, rather than preserving whatever migration copied
# forward - so the migrated 203.0.113.47 is correctly superseded here,
# not retained.
[ ! -e "${HGUARD_ETC_ROOT}/fail2ban/jail.d/vpsguard-sshd.local" ] || fail "the old fail2ban jail was not removed"
assert_file_contains "${HGUARD_ETC_ROOT}/fail2ban/jail.d/hguard-sshd.local" "port = 22222"
assert_file_contains "${HGUARD_ETC_ROOT}/fail2ban/jail.d/hguard-sshd.local" "ignoreip = 127.0.0.1/8 ::1"

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

### Conntrack: Vultr had the full real set - sysctl, modprobe, modules,
### helper script and systemd service - all migrated and old files gone.
### optimize_conntrack (real, runs unconditionally in a normal install)
### regenerates these from Hguard's own current target profile rather than
### preserving migration's copy verbatim, same as fail2ban above - the
### values below happen to match this fixture's real captured values, by
### coincidence of this profile not having changed, not because anything
### here is asserting content preservation.
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

### The hguard CLI and apt hook install cleanly on the first real run too.
assert_file_contains "$HGUARD_CLI_PATH" "# Managed by Hguard"
assert_file_contains "$HGUARD_APT_HOOK_FILE" "# Managed by Hguard"

pass "migration + a full real main() correctly migrate a real Vultr (ssh.service, port 22222, UFW rules, conntrack) VPSGuard 0.3.7 layout"

### A second full main() run must also succeed, without re-migrating and
### without the already-finalized port drifting back to 22.
main
assert_file_contains "${HGUARD_ETC_ROOT}/ssh/sshd_config.d/00-hguard.conf" "Port 22222"
assert_file_contains "${HGUARD_ETC_ROOT}/hguard/.installed" "success"
assert_failure migrate_from_vpsguard_needed

pass "a second full main() run also succeeds, without re-migrating or resetting the port back to 22"
