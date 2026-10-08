#!/usr/bin/env bash
set -euo pipefail

test_directory="$(cd "$(dirname "$0")" && pwd)"
count=0

for test_file in "$test_directory"/test_*.sh; do
  [ "$(basename "$test_file")" = "test_helper.sh" ] && continue
  printf '\nRunning %s\n' "$(basename "$test_file")"
  bash "$test_file"
  count=$((count + 1))
done

printf '\nAll %s Hguard test files passed.\n' "$count"
