#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/test_helper.sh
. "$(dirname "$0")/test_helper.sh"

temporary_root="$(mktemp -d)"
trap 'rm -rf "$temporary_root"' EXIT
export HGUARD_TEST_MODE=1
export HGUARD_ETC_ROOT="$temporary_root/etc"
export HGUARD_STATE_DIR="$temporary_root/etc/hguard"
export HGUARD_LIB_DIR="$temporary_root/usr/local/lib/hguard"
export HGUARD_BIN_DIR="$temporary_root/usr/local/sbin"
export HGUARD_CLI_PATH="$HGUARD_BIN_DIR/hguard"
mkdir -p "$HGUARD_STATE_DIR"
# shellcheck source=install-core.sh
. "$TEST_ROOT/install-core.sh"

### 1. Full-checkout case: every sibling file is present next to
### install-core.sh (BASH_SOURCE[0], i.e. this repo), so nothing is fetched.
# Called indirectly by fetch_hguard_component, if install_hguard_cli
# wrongly decides a sibling needs fetching.
# shellcheck disable=SC2329
curl() { fail "curl must not run when every sibling file is found locally"; }
# shellcheck disable=SC2329
wget() { fail "wget must not run when every sibling file is found locally"; }

assert_success install_hguard_cli
for name in install-core.sh status.sh uninstall.sh verify.sh update.sh; do
  [ -f "${HGUARD_LIB_DIR}/${name}" ] || fail "install_hguard_cli did not install ${name}"
  mode="$(stat -c '%a' "${HGUARD_LIB_DIR}/${name}" 2>/dev/null || stat -f '%Lp' "${HGUARD_LIB_DIR}/${name}")"
  assert_equal 755 "$mode" "${name} is installed executable"
done
[ -x "$HGUARD_CLI_PATH" ] || fail "the hguard dispatcher was not installed executably"
assert_file_contains "$HGUARD_CLI_PATH" "exec bash \"\${HGUARD_LIB_DIR}/status.sh\""
assert_file_contains "$HGUARD_CLI_PATH" "# Managed by Hguard"

pass "install_hguard_cli installs every sibling file locally without any network fetch"

### 2. One-click case: no sibling files on disk next to install-core.sh (as
### if only install-core.sh itself had been downloaded) - everything else
### must be fetched via HGUARD_RAW_BASE_URL.
rm -rf "$HGUARD_LIB_DIR" "$HGUARD_BIN_DIR"
isolated_core="$temporary_root/isolated/install-core.sh"
mkdir -p "$(dirname "$isolated_core")"
cp "$TEST_ROOT/install-core.sh" "$isolated_core"

fetch_log="$temporary_root/fetch.log"
export fetch_log TEST_ROOT
: > "$fetch_log"
# Called indirectly by fetch_hguard_component via install_hguard_cli.
# shellcheck disable=SC2329
curl() {
  local url="" out=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -o) out="$2"; shift 2 ;;
      http*) url="$1"; shift ;;
      *) shift ;;
    esac
  done
  printf '%s\n' "$url" >> "$fetch_log"
  case "$url" in
    */status.sh) cp "$TEST_ROOT/status.sh" "$out" ;;
    */uninstall.sh) cp "$TEST_ROOT/uninstall.sh" "$out" ;;
    */verify.sh) cp "$TEST_ROOT/verify.sh" "$out" ;;
    */update.sh) cp "$TEST_ROOT/update.sh" "$out" ;;
    *) return 1 ;;
  esac
}
export -f curl

(
  cd "$(dirname "$isolated_core")"
  HGUARD_TEST_MODE=1 HGUARD_LIB_MODE=1 HGUARD_LIB_DIR="$HGUARD_LIB_DIR" HGUARD_BIN_DIR="$HGUARD_BIN_DIR" HGUARD_CLI_PATH="$HGUARD_CLI_PATH" \
    bash -c '. ./install-core.sh; install_hguard_cli'
)
for name in status.sh uninstall.sh verify.sh update.sh; do
  [ -f "${HGUARD_LIB_DIR}/${name}" ] || fail "one-click install_hguard_cli did not fetch ${name}"
done
[ -f "${HGUARD_LIB_DIR}/install-core.sh" ] || fail "install-core.sh itself (found locally, not fetched) was not installed"
assert_equal 4 "$(wc -l < "$fetch_log" | tr -d ' ')" "exactly the 4 missing siblings were fetched, not install-core.sh itself"

pass "install_hguard_cli fetches missing sibling files when run from a one-click (single-file) install"
