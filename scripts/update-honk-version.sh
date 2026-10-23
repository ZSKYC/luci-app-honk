#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Manually advance the pinned honk-core revision (daeuniverse/honk main).
# The per-architecture tarballs and hashes are produced by the release workflow's
# ci/build-core.sh, so this script only moves the source pin and bumps the version.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPSTREAM="${HONK_UPSTREAM_REPO:-https://github.com/daeuniverse/honk.git}"
BRANCH="${HONK_UPSTREAM_BRANCH:-main}"

command -v git >/dev/null 2>&1 || { echo "error: git is required" >&2; exit 1; }

# shellcheck disable=SC1091
. "$REPO_DIR/ci/pins.env"

core_new="$(git ls-remote "$UPSTREAM" "refs/heads/$BRANCH" | cut -f1)"
if ! [[ "$core_new" =~ ^[0-9a-f]{40}$ ]]; then
	echo "error: cannot resolve $BRANCH head from $UPSTREAM" >&2
	exit 1
fi

if [ "$core_new" = "$CORE_COMMIT" ]; then
	echo "No upstream change: already at $CORE_COMMIT"
	exit 0
fi

version="$(TZ=Asia/Shanghai date +%Y.%m.%d)"
current_version="$(sed -n 's/^PKG_VERSION:=//p' "$REPO_DIR/honk/Makefile")"
current_release="$(sed -n 's/^PKG_RELEASE:=//p' "$REPO_DIR/honk/Makefile")"

# The package version carries the build date. A second build on the same day
# needs a new release number, otherwise apk compares the version strings and
# sees no upgrade at all.
if [ "$current_version" = "$version" ]; then
	release=$((current_release + 1))
else
	release=1
fi

# A portable in place edit: GNU sed and BSD sed take different arguments for
# -i, and the author develops on macOS.
replace_line() {
	file=$1
	expression=$2
	tmp="$(mktemp "${TMPDIR:-/tmp}/honk-version.XXXXXX")"
	sed "$expression" "$file" > "$tmp"
	mv "$tmp" "$file"
}

echo "Advancing core pin:"
echo "  $(printf '%s' "$CORE_COMMIT" | cut -c1-7) -> $(printf '%s' "$core_new" | cut -c1-7)"
echo "  PKG_VERSION -> $version"
echo "  PKG_RELEASE -> $release"

replace_line "$REPO_DIR/ci/pins.env" "s|^CORE_COMMIT=.*|CORE_COMMIT=$core_new|"
replace_line "$REPO_DIR/ci/pins.env" "s|^CORE_RELEASE=.*|CORE_RELEASE=$core_new|"
replace_line "$REPO_DIR/honk/Makefile" "s|^CORE_COMMIT:=.*|CORE_COMMIT:=$core_new|"
replace_line "$REPO_DIR/honk/Makefile" "s|^PKG_VERSION:=.*|PKG_VERSION:=$version|"
replace_line "$REPO_DIR/honk/Makefile" "s|^PKG_RELEASE:=.*|PKG_RELEASE:=$release|"

echo "Done. Run the release workflow to build the multi-arch tarballs and publish."
