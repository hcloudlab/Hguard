#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=tests/test_helper.sh
. "$(dirname "$0")/test_helper.sh"

version_file_content="$(cat "$TEST_ROOT/VERSION")"
in_file_version="$(grep -oE '^VPSGUARD_VERSION="[^"]+"' "$TEST_ROOT/install.sh" | cut -d'"' -f2)"

assert_equal "$version_file_content" "$in_file_version" "VERSION file matches install.sh's VPSGUARD_VERSION literal"

# CORE_URL interpolates ${VPSGUARD_VERSION} directly rather than duplicating the
# version as a separate literal, so the two can never drift apart by
# construction - this just confirms the interpolation is actually there.
# Intentionally single-quoted: checking install.sh's literal source text, not expanding it here.
# shellcheck disable=SC2016
assert_file_contains "$TEST_ROOT/install.sh" 'CORE_URL="https://raw.githubusercontent.com/hcloudlab/vpsguard/v${VPSGUARD_VERSION}/install-core.sh"'

pass "install.sh CORE_URL tag matches the VERSION file"
