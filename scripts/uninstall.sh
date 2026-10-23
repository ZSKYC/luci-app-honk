#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
set -eu

# The geo update cron has to go before the package that owns it, otherwise it
# keeps calling a script that is no longer installed.
if [ -x /usr/share/luci-app-honk/geo-cron.sh ]; then
	/usr/share/luci-app-honk/geo-cron.sh disable >/dev/null 2>&1 || :
fi
CRONTAB=/etc/crontabs/root
if [ -f "$CRONTAB" ]; then
	grep -vF -e '# luci-app-honk geo-update' \
		-e '/usr/share/luci-app-honk/update-geo.sh' "$CRONTAB" > "$CRONTAB.honk-clean" 2>/dev/null || :
	if [ -f "$CRONTAB.honk-clean" ]; then
		mv "$CRONTAB.honk-clean" "$CRONTAB" 2>/dev/null || rm -f "$CRONTAB.honk-clean" 2>/dev/null || :
		chmod 0600 "$CRONTAB" 2>/dev/null || :
	fi
fi

rc=0
if command -v apk >/dev/null 2>&1; then
	if apk info -e honk >/dev/null 2>&1 || apk info -e luci-app-honk >/dev/null 2>&1; then
		apk del luci-app-honk honk || rc=$?
	fi
elif command -v opkg >/dev/null 2>&1; then
	if opkg list-installed luci-app-honk >/dev/null 2>&1 || opkg list-installed honk >/dev/null 2>&1; then
		opkg remove luci-app-honk honk || rc=$?
	fi
else
	echo "未找到包管理器（opkg/apk）。" >&2
	exit 1
fi

# A package that is removed while an operation is running leaves its journals
# and runtime files behind; they would block the next installation.
rm -rf /etc/.honk-maintenance /etc/.honk-update /tmp/honk-runtime /tmp/honk-jobs 2>/dev/null || :

if [ "$rc" -ne 0 ]; then
	echo "卸载失败（退出码 $rc），请检查包管理器的输出。" >&2
	exit "$rc"
fi

echo "已卸载 honk 与 luci-app-honk。"
