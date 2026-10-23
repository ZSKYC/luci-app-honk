#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# Background apk index refresh for the Maintenance view. Returns at once.

# The marker lives in a private runtime directory: its path is predictable, so
# a world writable /tmp could hold a symlink planted by another user, which a
# root script would then write through.
. /usr/share/honk/runtime-dir.sh || exit 0
honk_runtime_dir || exit 0

LOCK="$HONK_RUNTIME_DIR/index.lock"

if [ -f "$LOCK" ]; then
	mtime=$(date -r "$LOCK" +%s 2>/dev/null || echo 0)
	[ "$(( $(date +%s) - mtime ))" -lt 90 ] && exit 0
fi
honk_runtime_prepare "index.lock" || exit 0

(
	if command -v apk >/dev/null 2>&1; then
		flock -n "$HONK_RUNTIME_DIR/apk.lock" apk update
	fi
) >/dev/null 2>&1 </dev/null &

exit 0
