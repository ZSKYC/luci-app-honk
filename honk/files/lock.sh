#!/bin/sh

HONK_LOCK_DIR=/run/honk.lock

# PID alone is not enough to identify a process (PID reuse race). We store
# "pid starttime" where starttime is field 22 of /proc/pid/stat.
_honk_proc_starttime() {
	cut -d' ' -f22 "/proc/$1/stat" 2>/dev/null
}

honk_lock_acquire() {
	mkdir "$HONK_LOCK_DIR" 2>/dev/null || return 1
	chmod 0700 "$HONK_LOCK_DIR" || { rmdir "$HONK_LOCK_DIR"; return 1; }
	printf '%s %s\n' "$$" "$(_honk_proc_starttime $$)" > "$HONK_LOCK_DIR/pid" || { rm -f "$HONK_LOCK_DIR/pid"; rmdir "$HONK_LOCK_DIR"; return 1; }
}

honk_lock_is_stale() {
	[ -r "$HONK_LOCK_DIR/pid" ] || return 1
	read -r owner owner_start < "$HONK_LOCK_DIR/pid" || return 1
	case "$owner" in ''|*[!0-9]*) return 1 ;; esac
	# Dead if the PID is gone, or if it was reused by a newer process.
	! kill -0 "$owner" 2>/dev/null && return 0
	[ "$(_honk_proc_starttime "$owner")" = "$owner_start" ] || return 0
	return 1
}

honk_lock_release() {
	[ -r "$HONK_LOCK_DIR/pid" ] || return 1
	read -r owner owner_start < "$HONK_LOCK_DIR/pid" || return 1
	[ "$owner" = "$$" ] && [ "$owner_start" = "$(_honk_proc_starttime $$)" ] || return 1
	rm -f "$HONK_LOCK_DIR/pid" && rmdir "$HONK_LOCK_DIR"
}

# Whether the lock is held by the given process. The lock file stores
# "pid starttime", so both columns are compared; comparing the whole file
# with a bare pid can never match.
honk_lock_owner_matches() {
	owner_match_pid=$1
	owner_match_start=$2
	case "$owner_match_pid" in ''|*[!0-9]*) return 1 ;; esac
	case "$owner_match_start" in ''|*[!0-9]*) return 1 ;; esac
	[ -r "$HONK_LOCK_DIR/pid" ] || return 1
	read -r owner_match_held_pid owner_match_held_start < "$HONK_LOCK_DIR/pid" || return 1
	[ "$owner_match_held_pid" = "$owner_match_pid" ] || return 1
	[ "$owner_match_held_start" = "$owner_match_start" ] || return 1
	return 0
}
