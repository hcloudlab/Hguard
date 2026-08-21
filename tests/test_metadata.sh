#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/test_helper.sh
. "$(dirname "$0")/test_helper.sh"

version="$(tr -d '[:space:]' < "$TEST_ROOT/VERSION")"
assert_equal 0.3.6 "$version" "VERSION"
assert_file_contains "$TEST_ROOT/install.sh" 'VPSGUARD_VERSION="0.3.6"'
assert_file_contains "$TEST_ROOT/status.sh" 'VPSGUARD_VERSION="0.3.6"'
assert_file_contains "$TEST_ROOT/uninstall.sh" 'VPSGUARD_VERSION="0.3.6"'
assert_file_contains "$TEST_ROOT/README.md" 'VPSGuard v0.3.6'
assert_file_contains "$TEST_ROOT/README.md" '22.04 LTS | 已完成真实 VPS 验证'
assert_file_contains "$TEST_ROOT/README.md" '24.04 LTS | 已完成真实 VPS 验证'
assert_file_contains "$TEST_ROOT/README.md" '26.04 LTS | Experimental / 待验证'
assert_file_contains "$TEST_ROOT/CHANGELOG.md" '## [0.3.6] - 2026-08-21'
assert_file_contains "$TEST_ROOT/CHANGELOG.md" 'password and passwordless sudo modes'
assert_file_contains "$TEST_ROOT/CHANGELOG.md" 'conntrack health check'
assert_file_contains "$TEST_ROOT/README.md" 'Conntrack 健康检查'
assert_file_contains "$TEST_ROOT/README.md" 'sudo bash install.sh --optimize-conntrack'
assert_file_contains "$TEST_ROOT/.github/workflows/shell-ci.yml" 'bash tests/run.sh'

old_owner='hexa46656-''creator'
if grep -RIn --exclude-dir=.git "$old_owner" "$TEST_ROOT" >/dev/null; then
  fail "current repository links still use the old owner"
fi

pass "version, documentation, workflow and repository-link metadata"
