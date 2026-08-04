#!/usr/bin/env bash
set -euo pipefail

# Used by every test that sources this helper.
# shellcheck disable=SC2034
TEST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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
