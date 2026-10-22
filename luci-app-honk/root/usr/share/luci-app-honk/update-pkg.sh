#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# update-pkg.sh <honk|luci-app-honk>
# Refresh package indexes and upgrade the named package via apk. Forks to
# background; the result is streamed to /tmp/luci-app-honk.pkg.<name>.log.

PKG="$1"
case "$PKG" in
	honk|luci-app-honk) ;;
	*)
		echo "usage: $0 <honk|luci-app-honk>" >&2
		exit 64
		;;
esac

# Run from a /tmp copy so upgrading luci-app-honk (which replaces this script)
# cannot corrupt the in-flight upgrade.
case "$0" in
	/tmp/.honk-upd-*) ;;
	*)
		_self="/tmp/.honk-upd-$$"
		cp "$0" "$_self" 2>/dev/null && exec sh "$_self" "$@"
		;;
esac

LOCK="/tmp/luci-app-honk.pkg-${PKG}.lock"
LOG="/tmp/luci-app-honk.pkg-${PKG}.log"

# The lifecycle helper reports whether the core runs and owns its api
# listener; the upgrade check needs it before and after the package change.
if [ -r /usr/share/honk/lifecycle.sh ]; then
	. /usr/share/honk/lifecycle.sh
fi

# The installed version of the named package, empty when it is not installed.
installed_version() {
	apk list --installed 2>/dev/null | awk -v p="$PKG" '$1 ~ "^" p "-[0-9]" { print $1; exit }'
}

# Whether the managed core runs and answers on its api listener.
honk_core_ready() {
	hr_pid=$(honk_lifecycle_managed_pid 2>/dev/null) || return 1
	[ -n "$hr_pid" ] || return 1
	honk_lifecycle_api_owned "$hr_pid" "" >/dev/null 2>&1 || return 1
	return 0
}

# Wait for the core to come up and answer on its api listener.
wait_honk_ready() {
	wr_timeout=${1:-60}
	wr_wait=0
	while [ "$wr_wait" -lt "$wr_timeout" ]; do
		honk_core_ready && return 0
		sleep 1
		wr_wait=$((wr_wait + 1))
	done
	return 1
}

# Recovery for an upgraded core that did not come up: drain whatever is
# running and start the new binary.
restart_honk_service() {
	[ -x /etc/init.d/honk ] || { echo "honk: init script is missing"; return 1; }
	[ -r /usr/share/honk/lifecycle.sh ] || { echo "honk: lifecycle helper is missing"; return 1; }
	. /usr/share/honk/lifecycle.sh || { echo "honk: lifecycle helper cannot be loaded"; return 1; }
	echo "honk: draining the running core"
	honk_lifecycle_stop 60 || { echo "honk: the old core did not drain"; return 1; }
	echo "honk: starting the upgraded core"
	honk_lifecycle_start 60 || { echo "honk: the upgraded core did not become ready"; return 1; }
	echo "honk: restarted on the upgraded core"
	return 0
}

if [ -f "$LOCK" ]; then
	mtime=$(date -r "$LOCK" +%s 2>/dev/null || echo 0)
	age=$(( $(date +%s) - mtime ))
	if [ "$age" -lt 300 ]; then
		echo "${PKG} update already in progress (PID $(cat "$LOCK" 2>/dev/null), age ${age}s)" >&2
		exit 75
	fi
	rm -f "$LOCK"
fi

if ! ( set -C; echo "$$" >"$LOCK" ) 2>/dev/null; then
	echo "${PKG} update already in progress" >&2
	exit 75
fi

(
	exec >"$LOG" 2>&1
	trap 'rm -f "$LOCK"; [ "${0#/tmp/.honk-upd-}" != "$0" ] && rm -f "$0"' EXIT INT TERM

	echo "$(date '+%F %T') begin upgrade: $PKG"

	if command -v apk >/dev/null 2>&1; then
		before_version=$(installed_version)
		was_running=0
		command -v honk_lifecycle_managed_pid >/dev/null 2>&1 && \
			honk_lifecycle_managed_pid >/dev/null 2>&1 && was_running=1
		(
			flock 9
			apk update 2>&1
			ver=$(apk list "$PKG" 2>/dev/null | awk -v p="$PKG" '$1 ~ "^" p "-[0-9]" { v=$1; sub("^" p "-", "", v); print v }' | sort -V | tail -1)
			if [ -n "$ver" ]; then
				constraint="$PKG=$ver"
			else
				echo "result: 软件源中没有找到 $PKG，请检查网络或软件源配置"
				exit 1
			fi

			echo "--- apk add -s $constraint ---"
			if ! apk add -s "$constraint" 2>&1; then
				echo "note: apk 预检失败，通常是系统上其它软件包的问题，继续尝试升级"
			fi
			echo "--- apk add $constraint ---"
			apk add "$constraint" 2>&1
			exit 0
		) 9>/tmp/luci-app-honk.apk.lock
		rc=$?
		after_version=$(installed_version)
		pkg_result=
		if [ "$rc" != 0 ]; then
			pkg_result="the upgrade command failed"
		elif ! apk list --installed 2>/dev/null | grep -q "^${PKG}-"; then
			pkg_result="$PKG is not installed"
			rc=1
		elif apk list -u 2>/dev/null | grep -q "^${PKG}-"; then
			pkg_result="$PKG still has a pending upgrade"
			rc=1
		else
			pkg_result="$PKG is at the latest available version"
			rc=0
		fi
		if [ "$rc" = 0 ] && [ "$PKG" = "honk" ] && [ "$before_version" != "$after_version" ] && [ "$was_running" = 1 ]; then
			# The package postinst restarts the service on the upgrade path;
			# wait for the new core to own its api and recover it when the
			# restart did not bring it up.
			if wait_honk_ready 60; then
				echo "honk: the upgraded core is ready"
			else
				echo "honk: the upgraded core did not come up, restarting it"
				restart_honk_service || {
					pkg_result="honk was upgraded but the service did not restart"
					rc=1
				}
			fi
		fi
		[ -z "$pkg_result" ] || echo "result: $pkg_result"
	else
		echo "no package manager found"
		exit 3
	fi

	if [ "$rc" = 0 ]; then echo "$(date '+%F %T') ✓ 完成"; else echo "$(date '+%F %T') ✗ 失败 (rc=$rc)"; fi

	if [ "$PKG" = "luci-app-honk" ] && [ "$rc" = "0" ]; then
		echo "reloading rpcd to pick up new ACL"
		/etc/init.d/rpcd reload 2>&1
	fi
) </dev/null >/dev/null 2>&1 &

echo "started in background, see $LOG"
exit 0
