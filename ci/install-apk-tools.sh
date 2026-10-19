#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Install apk-tools and expose it on PATH for the rest of the job.
#
# The package is Alpine's `apk-tools-static`, which is still a gzip tarball: it
# unpacks with tar and yields a statically linked sbin/apk.static. This is the
# only apk we can use here — the copy inside an OpenWrt SDK is a wrapper that
# execs a private ld.so plus runas.so against the SDK's staging_dir layout, so
# it does not travel.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/ci/pins.env"

PREFIX=${APK_TOOLS_PREFIX:-"$ROOT/.cache/apk-tools"}
mkdir -p "$PREFIX"

# GITHUB_PATH only exists inside Actions; the script is also runnable by hand.
add_to_path() { [ -n "${GITHUB_PATH:-}" ] && echo "$PREFIX/bin" >> "$GITHUB_PATH"; }

# `apk version` output has moved around between releases (bare number, number
# plus build id), so match a prefix rather than an exact string.
apk_version() { "$PREFIX/bin/apk" version 2>/dev/null | head -1 | tr -d '[:space:]' || true; }

if [ -x "$PREFIX/bin/apk" ]; then
	installed=$(apk_version)
	case "$installed" in
	"$APK_TOOLS_UPSTREAM"*)
		echo "apk-tools $installed already installed"
		add_to_path
		exit 0
		;;
	esac
fi

work="$PREFIX/.download"
rm -rf "$work"
mkdir -p "$work"
curl -fsSL -o "$work/apk-tools.apk" "$APK_TOOLS_URL"
echo "${APK_TOOLS_SHA256}  $work/apk-tools.apk" | sha256sum -c -
tar -xzf "$work/apk-tools.apk" -C "$work"
rm -rf "$PREFIX"
mkdir -p "$PREFIX/bin"
install -m 0755 "$work/sbin/apk.static" "$PREFIX/bin/apk"

reported=$(apk_version)
case "$reported" in
"$APK_TOOLS_UPSTREAM"*) ;;
*)
	echo "apk-tools reports '$reported', pinned $APK_TOOLS_UPSTREAM" >&2
	exit 1
	;;
esac
echo "apk-tools $reported ready in $PREFIX/bin"
add_to_path
