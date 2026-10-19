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

# `apk --help` prints "apk-tools <v>, compiled for <arch>." as its first line
# and then the applet list, so one call covers both the version check and the
# capability check below.
#
# `apk version` is NOT the version: in apk-tools 3 it is a subcommand printing
# a table of installed/available package versions, and in an empty environment
# it emits only a header, which reads back as an empty string.
apk_help() { "$PREFIX/bin/apk" --help 2>&1 || true; }

apk_version() {
	apk_help | grep -m1 '^apk-tools ' |
		sed 's/^apk-tools //; s/,.*$//' | tr -d '[:space:]' || true
}

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

# The download directory deliberately lives outside $PREFIX: a stale install is
# cleared by removing $PREFIX, and anything unpacked underneath it would go with
# it before the binary could be copied out.
work=$(mktemp -d "${TMPDIR:-/tmp}/honk-apk-tools.XXXXXX")
trap 'rm -rf "$work"' EXIT
curl -fsSL -o "$work/apk-tools.apk" "$APK_TOOLS_URL"
echo "${APK_TOOLS_SHA256}  $work/apk-tools.apk" | sha256sum -c -
tar -xzf "$work/apk-tools.apk" -C "$work"
test -f "$work/sbin/apk.static" || {
	echo "$APK_TOOLS_URL does not contain sbin/apk.static" >&2
	exit 1
}

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

# Assert the two subcommands this pipeline depends on actually exist rather
# than trusting that the pinned version still has them.
help=$(apk_help)
for sub in mkpkg mkndx; do
	printf '%s\n' "$help" | grep -qw "$sub" || {
		echo "apk-tools $reported has no $sub subcommand" >&2
		exit 1
	}
done

echo "apk-tools $reported ready in $PREFIX/bin"
add_to_path
