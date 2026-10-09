#!/usr/bin/env bash
set -euo pipefail

# Used by every test that sources this helper.
# shellcheck disable=SC2034
TEST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Hermetic test isolation: install_hguard_cli/install_apt_hook default to
# real system paths (/usr/local/sbin, /usr/local/lib/hguard, /etc/apt/
# apt.conf.d) when install-core.sh is sourced directly without these
# overridden. A test that calls main() or install_hguard_cli and forgets
# to override them would otherwise write to the real machine running the
# test suite - this happened (see test_runtime_dir.sh) before this was
# added. Sandboxing here, once, means no individual test file has to
# remember to do it. A test that explicitly sets one of these itself
# (before or after sourcing this file) still wins, since install-core.sh
# only applies its own default when the variable is unset.
#
# Deliberately NOT also defaulting HGUARD_TEST_MODE itself here:
# test_one_click_install_isolation.sh spawns `bash ./install.sh` as a real
# subprocess and needs install-core.sh's own bottom-of-file auto-run guard
# (`[ "$HGUARD_TEST_MODE" != "1" ] && main "$@"`) to fire, the same as a
# real install would - and since these sandboxed paths are exported
# regardless of HGUARD_TEST_MODE's value, that subprocess still can't
# reach a real system path even running with production auto-run behavior.
_hguard_test_sandbox="$(mktemp -d)"
export HGUARD_BIN_DIR="${HGUARD_BIN_DIR:-${_hguard_test_sandbox}/usr/local/sbin}"
export HGUARD_LIB_DIR="${HGUARD_LIB_DIR:-${_hguard_test_sandbox}/usr/local/lib/hguard}"
export HGUARD_CLI_PATH="${HGUARD_CLI_PATH:-${HGUARD_BIN_DIR}/hguard}"
export APT_CONF_DIR="${APT_CONF_DIR:-${_hguard_test_sandbox}/etc/apt/apt.conf.d}"
export HGUARD_APT_HOOK_FILE="${HGUARD_APT_HOOK_FILE:-${APT_CONF_DIR}/99-hguard-verify}"
export HGUARD_APT_HOOK_SCRIPT="${HGUARD_APT_HOOK_SCRIPT:-${HGUARD_LIB_DIR}/apt-hook.sh}"
# ponytail: this sandbox directory is left for the OS/CI container to
# reap rather than trap-cleaned, since each test file already installs
# its own `trap ... EXIT` for its own temporary_root, which would
# silently replace (not chain with) a trap set here.
unset _hguard_test_sandbox

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

assert_success() {
  "$@" || fail "expected success: $*"
}

assert_failure() {
  if "$@"; then
    fail "expected failure: $*"
  fi
}

assert_equal() {
  local expected="$1"
  local actual="$2"
  local message="$3"
  [ "$expected" = "$actual" ] || fail "${message}: expected '${expected}', got '${actual}'"
}

assert_file_contains() {
  local file="$1"
  local text="$2"
  grep -Fq -- "$text" "$file" || fail "${file} does not contain: ${text}"
}

checksum_file() {
  cksum "$1" | awk '{print $1 ":" $2}'
}
