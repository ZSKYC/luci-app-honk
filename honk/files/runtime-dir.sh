#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
#
# Runtime files that the panel reads back (the upgrade log, the geo update
# log, the backup archive and the restore upload) need predictable paths, but
# /tmp is world writable: another local user could plant a symlink there and
# have a root script truncate or overwrite an arbitrary file. The files
# therefore live in one directory that only root may enter, which also closes
# the race between checking a path and writing it.

HONK_RUNTIME_DIR=/tmp/honk-runtime

# The directory exists, is a real directory and is not writable by anyone
# but root. Anything else is refused instead of being repaired.
honk_runtime_dir() {
	if [ -e "$HONK_RUNTIME_DIR" ] || [ -L "$HONK_RUNTIME_DIR" ]; then
		[ -d "$HONK_RUNTIME_DIR" ] && [ ! -L "$HONK_RUNTIME_DIR" ] || return 1
		[ "$(stat -c '%u:%a' "$HONK_RUNTIME_DIR" 2>/dev/null)" = 0:700 ] || return 1
		return 0
	fi
	# mkdir without -p fails when the path is taken, so a directory that
	# another user planted in between is never adopted.
	mkdir "$HONK_RUNTIME_DIR" 2>/dev/null || return 1
	chmod 0700 "$HONK_RUNTIME_DIR" 2>/dev/null || return 1
	return 0
}

# The path of a runtime file.
honk_runtime_path() {
	honk_runtime_dir || return 1
	printf '%s\n' "$HONK_RUNTIME_DIR/$1"
}

# Prepare a runtime file for writing: the directory is checked, a symlink at
# the path is removed and the file ends up readable by root only.
honk_runtime_prepare() {
	honk_runtime_dir || return 1
	runtime_target=$HONK_RUNTIME_DIR/$1
	if [ -L "$runtime_target" ]; then
		rm -f "$runtime_target" 2>/dev/null || return 1
	fi
	: > "$runtime_target" 2>/dev/null || return 1
	chmod 0600 "$runtime_target" 2>/dev/null || return 1
	return 0
}
