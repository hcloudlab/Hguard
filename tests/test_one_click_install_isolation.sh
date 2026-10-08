#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/test_helper.sh
. "$(dirname "$0")/test_helper.sh"

# Simulates `bash <(curl -fsSL .../install.sh)`: install.sh's own directory
# (or a piped script's "no directory") has none of this repo's other files -
# only install.sh itself is present locally, and the real install-core.sh is
# fetched over the network via CORE_URL. This is the regression test D1
# requires: if install-core.sh (or anything install.sh fetches) ever grows a
# `source` of some other repo file (e.g. a shared lib/paths.sh), the one-click
# install breaks even though every test that runs from a full checkout - with
# every file present on disk - would keep passing.

temporary_root="$(mktemp -d)"
trap 'rm -rf "$temporary_root"' EXIT

isolated_dir="$temporary_root/isolated"
mkdir -p "$isolated_dir"
cp "$TEST_ROOT/install.sh" "$isolated_dir/install.sh"
# Deliberately nothing else copied here - no install-core.sh, no tests/, no
# lib/ of any kind. If install.sh's LOCAL_CORE check somehow found a file
# anyway this test would not be exercising the download path, so confirm
# the directory really is isolated first.
[ "$(find "$isolated_dir" -type f | wc -l | tr -d ' ')" = "1" ] \
  || fail "isolated test directory unexpectedly contains more than install.sh"

download_log="$temporary_root/downloads.log"
export download_log TEST_ROOT
: > "$download_log"
# install.sh calls: curl -fsSL --proto '=https' --tlsv1.2 "$CORE_URL" -o "$TEMP_CORE"
# Stub the network fetch; serve this repo's real install-core.sh so the test
# proves the actual production file is self-contained, not a fake stand-in.
curl() {
  local out=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -o) out="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  [ -n "$out" ] || fail "curl stub did not see a -o destination"
  printf '%s\n' "$out" >> "$download_log"
  cp "$TEST_ROOT/install-core.sh" "$out"
}
export -f curl

help_output="$(cd "$isolated_dir" && bash ./install.sh --help)"
assert_equal 1 "$(wc -l < "$download_log" | tr -d ' ')" "install.sh downloaded install-core.sh exactly once"
assert_equal 'Usage: sudo bash install.sh [--optimize-conntrack] [--ssh-only]' "$help_output" \
  "the downloaded install-core.sh ran --help correctly with nothing else on disk"

pass "a one-click install (no local install-core.sh) runs using only the single downloaded file"
