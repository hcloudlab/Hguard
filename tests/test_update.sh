#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/test_helper.sh
. "$(dirname "$0")/test_helper.sh"

temporary_root="$(mktemp -d)"
trap 'rm -rf "$temporary_root"' EXIT
export HGUARD_TEST_MODE=1
export HGUARD_ETC_ROOT="$temporary_root/etc"
export HGUARD_STATE_DIR="$temporary_root/etc/hguard"
export HGUARD_CONFIG_FILE="$HGUARD_STATE_DIR/config.env"
mkdir -p "$HGUARD_STATE_DIR"
printf "NEW_USER='admin'\nSSH_PORT='22'\n" > "$HGUARD_CONFIG_FILE"
# shellcheck source=update.sh
. "$TEST_ROOT/update.sh"

id() { [ "$1" = "-u" ] && printf '0\n' || return 0; }

# Real `apt-cache policy` output captured from a live Ubuntu 24.04 container
# (docker run --rm ubuntu:24.04), for a package with no installed version and
# one with an installed version older than its candidate.
NOT_INSTALLED_POLICY='openssh-server:
  Installed: (none)
  Candidate: 1:9.6p1-3ubuntu13.19
  Version table:
     1:9.6p1-3ubuntu13.19 500
        500 http://ports.ubuntu.com/ubuntu-ports noble-updates/main arm64 Packages
        500 http://ports.ubuntu.com/ubuntu-ports noble-security/main arm64 Packages
     1:9.6p1-3ubuntu13 500
        500 http://ports.ubuntu.com/ubuntu-ports noble/main arm64 Packages'

UPGRADABLE_SUDO_POLICY='sudo:
  Installed: 1.9.15p5-3ubuntu5
  Candidate: 1.9.15p5-3ubuntu5.24.04.4
  Version table:
     1.9.15p5-3ubuntu5.24.04.4 500
        500 http://ports.ubuntu.com/ubuntu-ports noble-updates/main arm64 Packages
        500 http://ports.ubuntu.com/ubuntu-ports noble-security/main arm64 Packages
 *** 1.9.15p5-3ubuntu5 500
        500 http://ports.ubuntu.com/ubuntu-ports noble/main arm64 Packages
        100 /var/lib/dpkg/status'

UP_TO_DATE_POLICY='ufw:
  Installed: 0.36.2-6
  Candidate: 0.36.2-6
  Version table:
 *** 0.36.2-6 500
        500 http://ports.ubuntu.com/ubuntu-ports noble/main arm64 Packages
        100 /var/lib/dpkg/status'

assert_equal '1.9.15p5-3ubuntu5 1.9.15p5-3ubuntu5.24.04.4' \
  "$(printf '%s\n' "$UPGRADABLE_SUDO_POLICY" | awk '/^ *Installed:/ {i=$2} /^ *Candidate:/ {c=$2} END {print i, c}')" \
  "sanity: the captured policy text has the versions this test expects"

apt-cache() {
  [ "$1" = "policy" ] || return 1
  case "$2" in
    sudo) printf '%s\n' "$UPGRADABLE_SUDO_POLICY" ;;
    openssh-server) printf '%s\n' "$NOT_INSTALLED_POLICY" ;;
    ufw|fail2ban|python3-systemd) printf '%s\n' "$UP_TO_DATE_POLICY" | sed "s/^ufw:/${2}:/" ;;
    *) return 1 ;;
  esac
}

assert_equal '1.9.15p5-3ubuntu5 1.9.15p5-3ubuntu5.24.04.4' "$(package_versions sudo)" \
  "package_versions parses a real 'Installed: X / Candidate: Y' block"
assert_failure package_versions openssh-server

result="$(upgradable_managed_packages)"
assert_equal 'sudo 1.9.15p5-3ubuntu5 1.9.15p5-3ubuntu5.24.04.4' "$result" \
  "only sudo is upgradable; the not-installed and up-to-date packages are excluded"

# Real `apt-get -s install --only-upgrade sudo` output, captured from the
# same container after pinning sudo to the older (non-updates) version.
SIMULATE_UPGRADE_OUTPUT='Reading package lists...
Building dependency tree...
Reading state information...
The following packages will be upgraded:
  sudo
1 upgraded, 0 newly installed, 0 to remove and 3 not upgraded.
Inst sudo [1.9.15p5-3ubuntu5] (1.9.15p5-3ubuntu5.24.04.4 Ubuntu:24.04/noble-updates, Ubuntu:24.04/noble-security [arm64])
Conf sudo (1.9.15p5-3ubuntu5.24.04.4 Ubuntu:24.04/noble-updates, Ubuntu:24.04/noble-security [arm64])'

# Real output for the no-op case (nothing installed, --only-upgrade skips
# every package rather than installing it fresh).
SIMULATE_NOOP_OUTPUT='Reading package lists...
Building dependency tree...
Reading state information...
Skipping openssh-server, it is not installed and only upgrades are requested.
Skipping ufw, it is not installed and only upgrades are requested.
Skipping fail2ban, it is not installed and only upgrades are requested.
Skipping python3-systemd, it is not installed and only upgrades are requested.
Skipping sudo, it is not installed and only upgrades are requested.
0 upgraded, 0 newly installed, 0 to remove and 3 not upgraded.'

assert_failure simulation_would_remove "$SIMULATE_UPGRADE_OUTPUT"
assert_failure simulation_would_remove "$SIMULATE_NOOP_OUTPUT"
assert_equal 'Inst sudo [1.9.15p5-3ubuntu5] (1.9.15p5-3ubuntu5.24.04.4 Ubuntu:24.04/noble-updates, Ubuntu:24.04/noble-security [arm64])
Conf sudo (1.9.15p5-3ubuntu5.24.04.4 Ubuntu:24.04/noble-updates, Ubuntu:24.04/noble-security [arm64])' \
  "$(simulation_plan_lines "$SIMULATE_UPGRADE_OUTPUT")" \
  "simulation_plan_lines extracts the real Inst/Conf lines"

# apt's Remv line format (`Remv <pkg> [<version>]`) is well-documented and
# stable, but reproducing a genuine removal during --only-upgrade needs an
# engineered package conflict that didn't finish building in a sandboxed
# container in time for this change - this one line is constructed from
# that documented format, appended after real Inst/Conf lines above, rather
# than being an independently captured run.
SIMULATE_REMOVAL_OUTPUT="${SIMULATE_UPGRADE_OUTPUT}
Remv conflicting-package [1.0]"
assert_success simulation_would_remove "$SIMULATE_REMOVAL_OUTPUT"

pass "package_versions/upgradable_managed_packages/simulation parsing match real apt-cache policy and apt-get -s output"

### End-to-end: nothing upgradable -> no-op, no apt-get mutation attempted.
# Called below, before being redefined further down for the next scenario.
# shellcheck disable=SC2329
apt-cache() {
  [ "$1" = "policy" ] || return 1
  case "$2" in
    ufw|fail2ban|python3-systemd|sudo|openssh-server) printf '%s\n' "$UP_TO_DATE_POLICY" | sed "s/^ufw:/${2}:/" ;;
    *) return 1 ;;
  esac
}
# Deliberately never called - that's what this assertion is checking.
# shellcheck disable=SC2329
apt-get() { fail "apt-get must not run when nothing is upgradable"; }
output="$(main)"
assert_equal 'All managed components are already at their candidate version. Nothing to update.' "$output" \
  "main reports nothing to update and performs no apt-get action"

### End-to-end: sudo is upgradable, --yes skips the confirmation prompt,
### the upgrade runs, /run/sshd is recreated, and verify passes.
apt-cache() {
  [ "$1" = "policy" ] || return 1
  case "$2" in
    sudo) printf '%s\n' "$UPGRADABLE_SUDO_POLICY" ;;
    openssh-server) printf '%s\n' "$NOT_INSTALLED_POLICY" ;;
    ufw|fail2ban|python3-systemd) printf '%s\n' "$UP_TO_DATE_POLICY" | sed "s/^ufw:/${2}:/" ;;
    *) return 1 ;;
  esac
}
install_log="$temporary_root/apt-install.log"
: > "$install_log"
apt-get() {
  case "$1" in
    update) return 0 ;;
    -s) printf '%s\n' "$SIMULATE_UPGRADE_OUTPUT" ;;
    *)
      if printf '%s\n' "$*" | grep -q 'install --only-upgrade -y'; then
        printf '%s\n' "$*" >> "$install_log"
      fi
      ;;
  esac
}
sshd_runtime_prepared="false"
prepare_sshd_runtime_directory() { sshd_runtime_prepared="true"; }
validate_existing_user_account() { :; }
verify_authorized_keys() { return 0; }
verify_sudo_configuration() { return 0; }
verify_effective_sshd_config() { return 0; }
verify_ssh_runtime_healthy() { return 0; }
verify_ssh_listener() { return 0; }
ufw_is_active() { return 0; }
ufw_tcp_rule_exists() { return 0; }
verify_config_permissions() { return 0; }
systemctl() { return 0; }
fail2ban-client() { return 0; }
sysctl() { [ "$2" = "net.ipv4.tcp_congestion_control" ] && printf 'bbr\n' || printf 'fq\n'; }

main_output_file="$temporary_root/update-main-output.log"
main --yes > "$main_output_file"
assert_file_contains "$install_log" 'sudo'
assert_equal 'true' "$sshd_runtime_prepared" "update recreates /run/sshd after upgrading, the same as a fresh install"
assert_file_contains "$main_output_file" 'sudo: 1.9.15p5-3ubuntu5 -> 1.9.15p5-3ubuntu5.24.04.4'
assert_file_contains "$main_output_file" 'Verification: PASS'

### A simulation that would remove a package must refuse before touching
### the system, regardless of --yes.
apt-get() {
  case "$1" in
    update) return 0 ;;
    -s) printf '%s\n' "$SIMULATE_REMOVAL_OUTPUT" ;;
    *) fail "apt-get must not run install --only-upgrade when the simulation shows a removal" ;;
  esac
}
if (main --yes) 2>/dev/null; then
  fail "update must refuse when the simulation would remove a package"
fi

pass "hguard update: no-op when nothing upgradable, upgrades+verifies on --yes, refuses if the simulation would remove a package"
