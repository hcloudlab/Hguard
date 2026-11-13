#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/test_helper.sh
. "$(dirname "$0")/test_helper.sh"

temporary_root="$(mktemp -d)"
trap 'rm -rf "$temporary_root"' EXIT
export HGUARD_TEST_MODE=1
export HGUARD_ETC_ROOT="$temporary_root/etc"
export HGUARD_LOG_FILE="$temporary_root/hguard.log"
mkdir -p "$HGUARD_ETC_ROOT"
# shellcheck source=install-core.sh
. "$TEST_ROOT/install-core.sh"

write_os_release() {
  printf 'ID=%s\nVERSION_ID="%s"\nPRETTY_NAME="%s"\n' "$1" "$2" "$3" > "$HGUARD_ETC_ROOT/os-release"
}

# Supported releases: check passes and globals are populated, without
# leaking os-release variables (ID, VERSION_ID) into the caller.
for entry in "ubuntu|22.04|Ubuntu 22.04.5 LTS" "ubuntu|24.04|Ubuntu 24.04.3 LTS" \
  "debian|12|Debian GNU/Linux 12 (bookworm)" "debian|13|Debian GNU/Linux 13 (trixie)"; do
  IFS='|' read -r os_id version_id pretty <<< "$entry"
  write_os_release "$os_id" "$version_id" "$pretty"
  unset ID VERSION_ID 2>/dev/null || true
  (check_supported_os >/dev/null) || fail "${pretty} should be supported"
  check_supported_os >/dev/null
  assert_equal "$os_id" "$HGUARD_OS_ID" "${pretty} id"
  assert_equal "$version_id" "$HGUARD_OS_VERSION_ID" "${pretty} version"
  assert_equal "$pretty" "$HGUARD_OS_PRETTY_NAME" "${pretty} pretty name"
  [ -z "${ID:-}" ] || fail "os-release ID leaked into the caller"
done
pass "Ubuntu 22.04/24.04 and Debian 12/13 are accepted"

# Debian's real os-release (no quotes around VERSION_ID, extra fields).
cat > "$HGUARD_ETC_ROOT/os-release" <<'EOF'
PRETTY_NAME="Debian GNU/Linux 13 (trixie)"
NAME="Debian GNU/Linux"
VERSION_ID="13"
VERSION="13 (trixie)"
VERSION_CODENAME=trixie
DEBIAN_VERSION_FULL=13.1
ID=debian
HOME_URL="https://www.debian.org/"
EOF
check_supported_os >/dev/null
assert_equal "debian:13" "${HGUARD_OS_ID}:${HGUARD_OS_VERSION_ID}" "real trixie os-release"
pass "a real Debian 13 os-release file is parsed"

# Refused releases: must exit non-zero before any change.
for entry in "ubuntu|26.04|Ubuntu 26.04 LTS" "ubuntu|20.04|Ubuntu 20.04.6 LTS" "ubuntu|25.10|Ubuntu 25.10" \
  "debian|11|Debian GNU/Linux 11 (bullseye)" "debian||Debian GNU/Linux forky/sid" \
  "linuxmint|22|Linux Mint 22" "centos|9|CentOS Stream 9"; do
  IFS='|' read -r os_id version_id pretty <<< "$entry"
  write_os_release "$os_id" "$version_id" "$pretty"
  if (check_supported_os) >/dev/null 2>&1; then
    fail "${pretty} must be refused"
  fi
done
pass "EOL, non-LTS, untested and non-Debian-family releases are refused"

rm -f "$HGUARD_ETC_ROOT/os-release"
if (check_supported_os) >/dev/null 2>&1; then
  fail "a missing os-release must be refused"
fi
pass "a missing os-release is refused"
