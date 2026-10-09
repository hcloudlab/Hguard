#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/test_helper.sh
. "$(dirname "$0")/test_helper.sh"

# The exact real-machine scenario reported after the first round of
# migration fixes: a Vultr box ran the (then-fixed) migration once,
# MIGRATED-TO-HGUARD already exists (so migrate_from_vpsguard_needed is
# false - no migration runs on this or any later install), fail2ban's
# jail got its marker corrected because configure_fail2ban rewrites it
# unconditionally every run - but the four conntrack files (sysctl,
# modprobe, modules-load, helper script) did not, because write_
# conntrack_files only rewrites on a change-detected-or-runtime-wrong
# gate, and a file whose *content* already matches the current profile
# trips neither: its stale "Managed by VPSGuard" marker never has a
# reason to be touched by the normal write path, on any future run, no
# matter how many times install.sh is rerun. Worse: foreign_conntrack_
# config_sources() only recognizes the sysctl/modprobe files as Hguard's
# own by checking for the current marker specifically - a stale-marked
# file trips the *foreign config detected* branch instead, making
# optimize_conntrack skip conntrack management entirely rather than ever
# approaching the file. relabel_stale_legacy_markers() must run
# unconditionally, independent of any content/runtime gate, to fix this.

temporary_root="$(mktemp -d)"
trap 'rm -rf "$temporary_root"' EXIT
export HGUARD_TEST_MODE=1
export HGUARD_ETC_ROOT="$temporary_root/etc"
export HGUARD_RUN_ROOT="$temporary_root/run"
export HGUARD_PROC_ROOT="$temporary_root/proc"
export HGUARD_SYS_MODULE_ROOT="$temporary_root/sys/module"
mkdir -p "$HGUARD_ETC_ROOT" "$HGUARD_ETC_ROOT/ssh/sshd_config.d" "$HGUARD_ETC_ROOT/sysctl.d" \
  "$HGUARD_ETC_ROOT/modprobe.d" "$HGUARD_ETC_ROOT/modules-load.d" "$HGUARD_ETC_ROOT/vpsguard"
mkdir -p "$APT_CONF_DIR"
{
  printf 'ID=ubuntu\n'
  printf 'VERSION_ID="24.04"\n'
  printf 'PRETTY_NAME="Ubuntu 24.04.1 LTS"\n'
} > "${HGUARD_ETC_ROOT}/os-release"
{
  printf '# This is the sshd server system-wide configuration file.\n'
  printf 'Include %s/ssh/sshd_config.d/*.conf\n' "$HGUARD_ETC_ROOT"
} > "${HGUARD_ETC_ROOT}/ssh/sshd_config"
unset NEW_USER SSH_PORT ALLOW_PORTS 2>/dev/null || true
# shellcheck source=install-core.sh
. "$TEST_ROOT/install-core.sh"

mkdir -p "$HGUARD_STATE_DIR"
chmod 700 "$HGUARD_STATE_DIR"
{
  printf "# Managed by Hguard %s; values are validated before use.\n" "$HGUARD_VERSION"
  printf "NEW_USER='hadmin'\n"
  printf "SUDO_MODE='password'\n"
  printf "SSH_PORT='22222'\n"
  printf "ORIGINAL_SSH_PORT='22'\n"
  printf "INSTALL_STATUS='success'\n"
} > "$HGUARD_CONFIG_FILE"
chmod 600 "$HGUARD_CONFIG_FILE"

# Migration already fully completed, a while ago: the marker is there,
# so migrate_from_vpsguard_needed is false and no migration step runs on
# this (or any later) install.
atomic_write "$VPSGUARD_MIGRATED_MARKER_FILE" 600 "Migrated to Hguard ${HGUARD_VERSION} at 2026-01-01T00:00:00Z.
This directory is left in place as a backup only and is no longer used by Hguard.
"

# The four conntrack files, Hguard-named, with content already matching
# the current target profile exactly - "runtime state normal" means
# there is no content or runtime-state reason for write_conntrack_files
# to ever touch these - but still carrying the stale VPSGuard marker
# left over from before the relabeling fix existed. The sysctl file's
# comment also still names the conntrack modules-load file by its old
# vpsguard path, exactly as reported.
{
  printf '# Managed by VPSGuard 0.3.7; optional conntrack timeout profile.\n'
  printf '# nf_conntrack is loaded early through /etc/modules-load.d/vpsguard-conntrack.conf so systemd-sysctl can see these keys.\n'
  printf '# Netfilter conntrack timeouts; these are not TCP socket TIME_WAIT settings.\n'
  printf 'net.netfilter.nf_conntrack_tcp_timeout_syn_sent = 30\n'
  printf 'net.netfilter.nf_conntrack_tcp_timeout_syn_recv = 20\n'
  printf 'net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30\n'
} > "$CONNTRACK_SYSCTL_FILE"
{
  printf '# Managed by VPSGuard 0.3.7; applies when nf_conntrack is next loaded.\n'
  printf 'options nf_conntrack hashsize=16384\n'
} > "$CONNTRACK_MODPROBE_FILE"
{
  printf '# Managed by VPSGuard 0.3.7; load conntrack before systemd-sysctl.\n'
  printf 'nf_conntrack\n'
} > "$CONNTRACK_MODULES_FILE"
{
  printf '#!/usr/bin/env bash\n'
  printf '# Managed by VPSGuard 0.3.7; optional conntrack runtime floor.\n'
  printf 'set -euo pipefail\n'
  printf 'exit 0\n'
} > "$CONNTRACK_HELPER_FILE"
chmod 755 "$CONNTRACK_HELPER_FILE"

### Confirmed broken without the fix: a stale-marked conntrack sysctl/
### modprobe file is misclassified as foreign, not Hguard's own.
foreign_before="$(foreign_conntrack_config_sources)"
case "$foreign_before" in
  *"$CONNTRACK_SYSCTL_FILE"*) : ;;
  *) fail "expected the stale-marked conntrack sysctl file to be misdetected as foreign before relabeling" ;;
esac

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
sshd() { case "$1" in -t) return 0 ;; -T) printf 'port 22222\n'; return 0 ;; *) return 0 ;; esac; }
fail2ban-client() { [ "$1" = "-t" ] && return 0; [ "$*" = "status sshd" ] && return 0; return 0; }
systemctl() { return 0; }
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

### This is the actual regression: one real main() run (migration does
### NOT run - MIGRATED-TO-HGUARD already exists) must correct all four
### stale markers unconditionally, independent of write_conntrack_files'
### own change/runtime gate.
assert_failure migrate_from_vpsguard_needed
assert_success main

for f in "$CONNTRACK_SYSCTL_FILE" "$CONNTRACK_MODPROBE_FILE" "$CONNTRACK_MODULES_FILE" "$CONNTRACK_HELPER_FILE"; do
  head -n 2 "$f" | grep -Fq 'Managed by VPSGuard' \
    && fail "${f} still carries the old VPSGuard marker after a successful install run"
  assert_file_contains "$f" "# Managed by Hguard"
done

# The stale internal path reference is fixed too, not just the marker.
if grep -Fq 'vpsguard-conntrack.conf' "$CONNTRACK_SYSCTL_FILE"; then
  fail "the conntrack sysctl file's comment still names the old vpsguard modules-load path"
fi
assert_file_contains "$CONNTRACK_SYSCTL_FILE" "$CONNTRACK_MODULES_FILE"

# And the content that was already correct is still exactly correct -
# this was a marker/reference fix, not a content regeneration.
assert_file_contains "$CONNTRACK_SYSCTL_FILE" "net.netfilter.nf_conntrack_tcp_timeout_syn_sent = 30"
assert_file_contains "$CONNTRACK_MODPROBE_FILE" "hashsize=16384"

foreign_after="$(foreign_conntrack_config_sources)"
[ -z "$foreign_after" ] || fail "the relabeled conntrack files are still misdetected as foreign (got: ${foreign_after})"

pass "a fixed installer corrects stale conntrack markers and the internal stale path reference unconditionally, even when MIGRATED-TO-HGUARD already exists and content never changes"
