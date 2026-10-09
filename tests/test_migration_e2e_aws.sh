#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/test_helper.sh
. "$(dirname "$0")/test_helper.sh"

# End-to-end test against a real VPSGuard 0.3.7 install layout exported from
# a live AWS Ubuntu 24.04 instance (ssh.socket mode, cloud-init image with
# its own 90-cloud-init-users sudoers grant and 60-cloudimg-settings.conf
# sshd drop-in; no conntrack files, since the cloud image ships its own
# conntrack sysctl and VPSGuard detected that foreign config and skipped
# writing its own). Real IPs/hostnames were replaced with documentation-
# reserved values before this fixture was committed; everything else (file
# layout, content, markers) is verbatim.
#
# Unlike an isolated migrate_from_vpsguard() call, this exercises migration
# followed immediately by a full, real main() - the exact sequence a real
# upgrade runs, and the sequence that caught a real bug on a live Vultr box
# (configure_fail2ban refusing a migrated jail file still carrying the old
# VPSGuard marker) that calling migrate_from_vpsguard() alone could not
# have caught, since nothing downstream of it ran.
#
# Stubbed: OS-user/identity plumbing that is orthogonal to the migration/
# marker logic under test here and already covered elsewhere (ensure_
# managed_user, configure_authorized_keys, check_root_ssh_key, configure_
# sudo/verify_sudo_configuration - note neither AWS nor Vultr's fixture has
# a migrated sudoers file at all, since both use password sudo without one,
# so configure_sudo's own marker check is not reachable through these two
# fixtures either way; it is covered separately in
# test_migration_half_migrated_marker.sh), package management (upgrade_
# system, fail2ban_systemd_backend_available), and pure OS-state read-only
# verification that duplicates what write_*/configure_* already prove
# (verify_effective_sshd_config, verify_ssh_listener, apply_ssh_runtime,
# ufw_tcp_rule_exists, configure_ufw_before_ssh, run_final_acceptance,
# print_final_summary). Left real and unstubbed: every function that
# writes a managed file behind an ownership/marker check - write_hguard_
# sshd_config, write_hguard_ssh_socket_override, configure_fail2ban,
# write_bbr_files, write_conntrack_files, install_hguard_cli, install_apt_
# hook, and migrate_from_vpsguard itself - which is the actual target of
# this test.

temporary_root="$(mktemp -d)"
trap 'rm -rf "$temporary_root"' EXIT
export HGUARD_TEST_MODE=1
export HGUARD_ETC_ROOT="$temporary_root/etc"
export HGUARD_RUN_ROOT="$temporary_root/run"
export HGUARD_PROC_ROOT="$temporary_root/proc"
export HGUARD_SYS_MODULE_ROOT="$temporary_root/sys/module"
mkdir -p "$HGUARD_ETC_ROOT"
cp -R "$TEST_ROOT/tests/fixtures/vpsguard-0.3.7-aws/etc/." "$HGUARD_ETC_ROOT/"
# install_apt_hook requires its target directory to already exist (a real
# machine always has /etc/apt/apt.conf.d; test_helper.sh's sandbox does
# not create it automatically) - create it so this install's apt hook
# write is actually exercised, not silently skipped.
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
    -T) printf 'port 22\n'; return 0 ;;
    *) return 0 ;;
  esac
}
fail2ban-client() { [ "$1" = "-t" ] && return 0; [ "$*" = "status sshd" ] && return 0; return 0; }
# AWS is ssh.socket mode: detect_ssh_runtime_mode must see ssh.socket as a
# known, active unit (and no sshd.service) for write_hguard_ssh_runtime_
# policy to keep the socket override - otherwise it treats the just-
# migrated override as belonging to the wrong mode and deletes it.
systemctl() {
  case "$1" in
    list-unit-files)
      case "$2" in ssh.socket|ssh.service|fail2ban.service) printf '%s\n' "$2"; return 0 ;; esac
      return 1 ;;
    is-active|is-enabled)
      local unit="$2"; [ "$unit" = "--quiet" ] && unit="$3"
      case "$unit" in ssh.socket|fail2ban.service) return 0 ;; esac
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

# Snapshot everything untouched by VPSGuard, to assert byte-identical
# afterward: the cloud-init sudoers grant, the cloud-init sshd drop-in, and
# the sudoers README.
cloud_init_sudoers_before="$(cat "${HGUARD_ETC_ROOT}/sudoers.d/90-cloud-init-users")"
cloudimg_sshd_before="$(cat "${HGUARD_ETC_ROOT}/ssh/sshd_config.d/60-cloudimg-settings.conf")"
sudoers_readme_before="$(cat "${HGUARD_ETC_ROOT}/sudoers.d/README")"
legacy_state_env_before="$(cat "${HGUARD_ETC_ROOT}/vpsguard/state.env")"

main

### The real bug this test targets: every migrated managed file must carry
### the current Hguard marker, not the VPSGuard one it was copied with.
for managed_file in \
  "${HGUARD_ETC_ROOT}/hguard/config.env" \
  "${HGUARD_ETC_ROOT}/ssh/sshd_config.d/00-hguard.conf" \
  "${HGUARD_ETC_ROOT}/systemd/system/ssh.socket.d/00-hguard.conf" \
  "${HGUARD_ETC_ROOT}/fail2ban/jail.d/hguard-sshd.local" \
  "${HGUARD_ETC_ROOT}/sysctl.d/99-hguard-bbr.conf" \
  "${HGUARD_ETC_ROOT}/modules-load.d/hguard-bbr.conf"; do
  any_generation_marker_owns "$managed_file" || fail "${managed_file} does not exist or isn't recognized as managed"
  head -n 2 "$managed_file" | grep -Fq 'Managed by VPSGuard' \
    && fail "${managed_file} still carries the old VPSGuard marker after a full install run"
done

### State files: copied verbatim to the new location, including the
### original pre-install snapshot, with correct values preserved.
assert_file_contains "${HGUARD_ETC_ROOT}/hguard/config.env" "NEW_USER='hadmin'"
assert_file_contains "${HGUARD_ETC_ROOT}/hguard/config.env" "SSH_PORT='22'"
assert_file_contains "${HGUARD_ETC_ROOT}/hguard/config.env" "ORIGINAL_SSH_PORT='22'"
assert_equal "$legacy_state_env_before" "$(cat "${HGUARD_ETC_ROOT}/hguard/state.env")" \
  "state.env's pre-install snapshot is preserved byte-for-byte, header included"
assert_file_contains "${HGUARD_ETC_ROOT}/hguard/managed-rules" "22/tcp"
if head -n 1 "${HGUARD_ETC_ROOT}/hguard/managed-rules" | grep -Fq VPSGuard; then
  fail "managed-rules' header still says VPSGuard after a full install run"
fi
[ -f "${HGUARD_ETC_ROOT}/hguard/.installed" ] || fail ".installed marker was not migrated"
assert_file_contains "${HGUARD_ETC_ROOT}/hguard/.installed" "success"

### sshd: new include block + drop-in in place, old VPSGuard include block
### gone, cloud-init's own Include and drop-in untouched, sshd.socket
### override migrated too (AWS is ssh.socket mode), port unchanged.
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

### fail2ban: new jail in place with the real bug's exact failure point -
### port and ignoreip preserved, old jail gone.
[ ! -e "${HGUARD_ETC_ROOT}/fail2ban/jail.d/vpsguard-sshd.local" ] || fail "the old fail2ban jail was not removed"
assert_file_contains "${HGUARD_ETC_ROOT}/fail2ban/jail.d/hguard-sshd.local" "port = 22"

### sudoers: AWS uses password sudo (no vpsguard-hadmin sudoers file ever
### existed), so cloud-init's grant and the README must be left alone.
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

### Conntrack: the real AWS machine never had VPSGuard conntrack files,
### because the cloud image's own sysctl.d/50-cloudimg-settings.conf
### (present in this fixture, real content from the machine) sets
### net.netfilter.nf_conntrack_max itself - foreign_conntrack_config_
### sources() detects that and a full normal install run correctly skips
### writing any Hguard conntrack profile, matching the real machine
### exactly (hguard status there reports "Runtime profile: not
### configured").
[ ! -e "${HGUARD_ETC_ROOT}/sysctl.d/99-hguard-conntrack.conf" ] || fail "install must not create conntrack files when the cloud image's own foreign conntrack sysctl is present"
[ ! -e "${HGUARD_ETC_ROOT}/hguard/apply-conntrack-profile.sh" ] || fail "install must not create a conntrack helper when a foreign conntrack source is present"
[ ! -e "${HGUARD_ETC_ROOT}/systemd/system/hguard-conntrack.service" ] || fail "install must not create a conntrack service when a foreign conntrack source is present"

### No file anywhere is still a *currently effective* VPSGuard-managed
### file - everything that existed has either been removed (replaced) or
### was never VPSGuard's to begin with (cloud-init's own files).
[ -z "$(legacy_vpsguard_files_present)" ] || fail "legacy_vpsguard_files_present must report nothing still in effect after a clean migration"

### /etc/vpsguard is preserved as a backup, with the MIGRATED marker.
[ -d "${HGUARD_ETC_ROOT}/vpsguard" ] || fail "/etc/vpsguard must be preserved, not removed"
[ -f "$VPSGUARD_MIGRATED_MARKER_FILE" ] || fail "MIGRATED-TO-HGUARD marker was not written"
assert_file_contains "$VPSGUARD_MIGRATED_MARKER_FILE" "Migrated to Hguard"

### The hguard CLI and apt hook (also behind assert_managed_or_absent)
### install cleanly on the first real run, nothing to do with migration
### itself but the same ownership-check code path.
assert_file_contains "$HGUARD_CLI_PATH" "# Managed by Hguard"
assert_file_contains "$HGUARD_APT_HOOK_FILE" "# Managed by Hguard"

pass "migration + a full real main() correctly handle a real AWS (ssh.socket, cloud-init, no-conntrack) VPSGuard 0.3.7 layout"

### A second full main() run - the actual real-world rerun scenario this
### bug was found under - must also succeed, without re-migrating and
### without the port/markers drifting.
main
assert_file_contains "${HGUARD_ETC_ROOT}/ssh/sshd_config.d/00-hguard.conf" "Port 22"
assert_file_contains "${HGUARD_ETC_ROOT}/hguard/.installed" "success"
assert_failure migrate_from_vpsguard_needed

pass "a second full main() run also succeeds, without re-migrating or losing the port"
