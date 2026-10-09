#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/test_helper.sh
. "$(dirname "$0")/test_helper.sh"

# Every existing unit test sources install-core.sh and calls its functions
# directly in the same shell, overriding whichever ones it needs as plain
# shell functions. That approach cannot catch a bug that only shows up when
# the *installed* dispatcher is actually run as a real user would: a fresh
# `bash hguard status` subprocess, with no test-file function overrides in
# scope at all (those aren't inherited into a child process the way
# exported shell functions are - and even an exported function stub is
# shadowed the instant install-core.sh defines its own function of the
# same name, which it always does for every function IT owns), relying on
# nothing but what the install itself wrote to config.env. All four bugs
# this test was added for (status.sh dying partway through under set -e,
# verify.sh missing SUDO_MODE and swallowing its own failure reasons) were
# invisible to the existing function-level tests for exactly that reason.
#
# What CAN be overridden for the subprocess, and is: genuinely external
# commands (sshd, ss, systemctl, ufw, fail2ban-client, sysctl, sudo,
# passwd, visudo, getent, stat, id, apt-cache) - install-core.sh never
# redefines those names as shell functions, so an exported stub is not
# shadowed. Faking those is enough to drive every real install-core.sh/
# status.sh/verify.sh function (never themselves overridden) into
# reporting a genuinely healthy state, without creating a real OS user.

temporary_root="$(mktemp -d)"
trap 'rm -rf "$temporary_root"' EXIT
export HGUARD_TEST_MODE=1
export HGUARD_ETC_ROOT="$temporary_root/etc"
export HGUARD_RUN_ROOT="$temporary_root/run"
export HGUARD_PROC_ROOT="$temporary_root/proc"
export HGUARD_SYS_MODULE_ROOT="$temporary_root/sys/module"
mkdir -p "$HGUARD_ETC_ROOT" "${HGUARD_ETC_ROOT}/ssh/sshd_config.d"
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

TEST_USER="hguardtestadmin"
export TEST_USER
export NEW_USER="$TEST_USER"
export SSH_PORT=2222
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
sshd() { case "$1" in -t) return 0 ;; -T) printf 'port 2222\n'; return 0 ;; *) return 0 ;; esac; }
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

main
[ -f "$HGUARD_CLI_PATH" ] || fail "the install did not produce the hguard dispatcher"
[ -f "$HGUARD_CONFIG_FILE" ] || fail "the install did not produce config.env"
assert_file_contains "$HGUARD_CONFIG_FILE" "SUDO_MODE='password'"

### A fake home/authorized_keys for the managed user - real file,
### content doesn't matter (only non-empty), since ownership/mode below
### are answered by the stubbed `stat`, not the real filesystem.
mkdir -p "${temporary_root}/home/${TEST_USER}/.ssh"
printf 'ssh-ed25519 AAAAFAKEKEYFORTESTONLY test\n' > "${temporary_root}/home/${TEST_USER}/.ssh/authorized_keys"

### Run the INSTALLED dispatcher as real subprocesses. Export only the
### sandbox path roots and external-command stubs below - nothing that
### resembles install-core.sh's own internal state. Each invocation below
### explicitly sets HGUARD_TEST_MODE=0 for itself: status.sh/verify.sh
### have the exact same "only auto-run main() when HGUARD_TEST_MODE!=1"
### bottom-of-file guard install-core.sh does, so leaving it at 1 (needed
### earlier for the sandboxed-paths guard while sourcing install-core.sh
### to perform the install) would make the dispatcher exec into
### status.sh/verify.sh, which would then silently never call their own
### main() at all - exactly the kind of silent, misleading "exit 0 with
### no output" this test exists to catch, so it must not fall into it
### itself. HGUARD_LOG_FILE is sandboxed too, since turning TEST_MODE off
### re-enables the real install log write that TEST_MODE otherwise skips.
export HGUARD_ETC_ROOT HGUARD_RUN_ROOT HGUARD_PROC_ROOT HGUARD_SYS_MODULE_ROOT
export HGUARD_BIN_DIR HGUARD_LIB_DIR HGUARD_CLI_PATH APT_CONF_DIR HGUARD_APT_HOOK_FILE HGUARD_APT_HOOK_SCRIPT
export HGUARD_LOG_FILE="${temporary_root}/hguard.log"
export temporary_root TEST_USER

sshd() {
  case "$1" in
    -t) return 0 ;;
    -T)
      printf 'port 2222\npermitrootlogin no\npasswordauthentication no\npubkeyauthentication yes\n'
      return 0 ;;
    *) return 0 ;;
  esac
}
export -f sshd
# shellcheck disable=SC2317,SC2329
fail2ban-client() { [ "$1" = "-t" ] && return 0; [ "$*" = "status sshd" ] && return 0; return 0; }
export -f fail2ban-client
systemctl() { return 0; }
export -f systemctl
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
export -f sysctl
ss() {
  printf 'tcp   LISTEN 0      128          0.0.0.0:2222       0.0.0.0:*     users:(("sshd",pid=1,fd=3))\n'
}
export -f ss
ufw() {
  case "$1" in
    status) printf 'Status: active\n\n2222/tcp                   ALLOW       Anywhere\n' ;;
    show) printf '\n' ;;
    *) ;;
  esac
}
export -f ufw
# shellcheck disable=SC2329
id() {
  case "$1" in
    -u) printf '0\n' ;;
    -nG) printf 'sudo\n' ;;
    *) return 0 ;;
  esac
}
export -f id
# shellcheck disable=SC2329
passwd() {
  case "$1" in
    -S) printf '%s P 01/01/2024 0 99999 7 -1\n' "$2"; return 0 ;;
    *) return 0 ;;
  esac
}
export -f passwd
# shellcheck disable=SC2329
visudo() { return 0; }
export -f visudo
# shellcheck disable=SC2329
sudo() {
  case "$*" in
    "-u ${TEST_USER} sudo -k") return 0 ;;
    "-u ${TEST_USER} sudo -n true") return 1 ;;
    "-l -U ${TEST_USER}") printf '(ALL : ALL) ALL\n'; return 0 ;;
    *) return 1 ;;
  esac
}
export -f sudo
# shellcheck disable=SC2329
getent() {
  if [ "$1" = "passwd" ] && [ "$2" = "$TEST_USER" ]; then
    printf '%s:x:1500:1500:Test Admin:%s/home/%s:/bin/bash\n' "$TEST_USER" "$temporary_root" "$TEST_USER"
  else
    return 2
  fi
}
export -f getent
# shellcheck disable=SC2329
stat() {
  local arg fmt="" path=""
  for arg in "$@"; do
    case "$arg" in
      -c|-f) ;;
      *%U:%G*) fmt="owner" ;;
      *%a*) fmt="mode" ;;
      *) path="$arg" ;;
    esac
  done
  case "$path" in
    */authorized_keys) [ "$fmt" = "owner" ] && printf '%s:%s\n' "$TEST_USER" "$TEST_USER" || printf '600\n' ;;
    */.ssh) [ "$fmt" = "owner" ] && printf '%s:%s\n' "$TEST_USER" "$TEST_USER" || printf '700\n' ;;
    *) [ "$fmt" = "owner" ] && printf 'root:root\n' || printf '600\n' ;;
  esac
}
export -f stat
# shellcheck disable=SC2329
apt-cache() {
  [ "$1" = "policy" ] || return 1
  printf '%s:\n  Installed: 1.0\n  Candidate: 1.0\n' "$2"
}
export -f apt-cache
# shellcheck disable=SC2329
curl() { fail "curl must not run when every sibling file is found locally"; }
export -f curl
# shellcheck disable=SC2329
wget() { fail "wget must not run when every sibling file is found locally"; }
export -f wget

if status_output="$(HGUARD_TEST_MODE=0 bash "$HGUARD_CLI_PATH" status 2>&1)"; then status_exit=0; else status_exit=$?; fi
assert_equal 0 "$status_exit" "the installed dispatcher's status subcommand exits 0"
for section in "Hguard" "Managed components" "Managed administrator" "SSH" "UFW" "fail2ban" "BBR" "Conntrack"; do
  case "$status_output" in
    *"==> ${section}"*) ;;
    *) fail "hguard status output is missing the '${section}' section (output: ${status_output})" ;;
  esac
done

pass "the installed dispatcher's hguard status runs to completion and prints every section, with nothing preset but config.env"

if verify_output="$(HGUARD_TEST_MODE=0 bash "$HGUARD_CLI_PATH" verify 2>&1)"; then verify_exit=0; else verify_exit=$?; fi
case "$verify_output" in
  *"PASS"*) ;;
  *) fail "hguard verify did not report PASS in a healthy state (exit=${verify_exit}, output: ${verify_output})" ;;
esac
assert_equal 0 "$verify_exit" "the installed dispatcher's verify subcommand exits 0 when healthy"

if quiet_output="$(HGUARD_TEST_MODE=0 bash "$HGUARD_CLI_PATH" verify --quiet 2>&1)"; then quiet_exit=0; else quiet_exit=$?; fi
assert_equal 0 "$quiet_exit" "verify --quiet also exits 0 when healthy"
case "$quiet_output" in
  *$'\n'*) fail "verify --quiet must print exactly one line (got: ${quiet_output})" ;;
esac

pass "the installed dispatcher's hguard verify reports PASS in a healthy state, with nothing preset but config.env"

### Induce a real failure at the external-command level (fail2ban-client,
### not an install-core.sh function - the subprocess can't override
### those) and confirm the specific reason is visible without --quiet.
fail2ban-client() { [ "$1" = "-t" ] && return 0; return 1; }
export -f fail2ban-client
if broken_output="$(HGUARD_TEST_MODE=0 bash "$HGUARD_CLI_PATH" verify 2>&1)"; then broken_exit=0; else broken_exit=$?; fi
assert_equal 1 "$broken_exit" "verify exits non-zero when an acceptance check genuinely fails"
case "$broken_output" in
  *"fail2ban sshd jail unavailable"*) ;;
  *) fail "hguard verify's FAIL output does not show the specific failing check (got: ${broken_output})" ;;
esac
case "$broken_output" in
  *"FAIL:"*) ;;
  *) fail "hguard verify's FAIL output is missing the summary line (got: ${broken_output})" ;;
esac

if quiet_broken_output="$(HGUARD_TEST_MODE=0 bash "$HGUARD_CLI_PATH" verify --quiet 2>&1)"; then quiet_broken_exit=0; else quiet_broken_exit=$?; fi
assert_equal 1 "$quiet_broken_exit" "verify --quiet also exits non-zero on a real failure"
case "$quiet_broken_output" in
  *"fail2ban"*) fail "verify --quiet must not show the per-check reason (got: ${quiet_broken_output})" ;;
esac

pass "the installed dispatcher's hguard verify shows the specific failing check's reason when something is actually broken, and --quiet still suppresses it"
