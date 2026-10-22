#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
for tool in bash sh node sha256sum git tar sqlite3; do
	command -v "$tool" >/dev/null || { echo "Missing required tool: $tool" >&2; exit 1; }
done

for script in ci/build-doona.sh scripts/check.sh; do
	bash -n "$script"
done
sh -n scripts/install.sh
for script in honk/files/*.sh luci-app-honk/root/usr/libexec/rpcd/honk luci-app-honk/root/usr/share/luci-app-honk/*.sh; do
	sh -n "$script"
done
sh -n honk/files/honk.init
sh -n honk/files/90-honk-boot
for file in luci-app-honk/htdocs/luci-static/resources/view/honk/{rpc,overview,settings,dashboard,logs,maintenance,sha256}.js; do
	node --check "$file"
done
test ! -e luci-app-honk/htdocs/luci-static/resources/view/honk/configuration.js
test ! -e luci-app-honk/htdocs/luci-static/resources/view/honk/converter.js
test ! -d luci-app-honk/htdocs/luci-static/resources/view/honk/vendor
node -e 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))' luci-app-honk/root/usr/share/luci/menu.d/luci-app-honk.json
node -e 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))' luci-app-honk/root/usr/share/rpcd/acl.d/luci-app-honk.json

grep -q '^CORE_COMMIT=[0-9a-f]\{40\}$' ci/pins.env
grep -q '^DOONA_COMMIT=[0-9a-f]\{40\}$' ci/pins.env
grep -q '^DOONA_PATCH_SHA256=[0-9a-f]\{64\}$' ci/pins.env
test "$(sha256sum ci/patches/doona-openwrt.patch | cut -d' ' -f1)" = "$(sed -n 's/^DOONA_PATCH_SHA256=//p' ci/pins.env)"
source ci/pins.env
test "$CORE_COMMIT" = "$(sed -n 's/^CORE_COMMIT:=//p' honk/Makefile)"
# The honk core is tracked by commit, so the recorded release marker is the
# same commit. A mismatch would make the daily job compare two different
# things and rebuild on every run.
test "$CORE_RELEASE" = "$CORE_COMMIT"
test "$DOONA_ARCHIVE" = "$(sed -n 's/^PKG_SOURCE:=//p' luci-app-honk/Makefile)"
grep -q '^PKG_HASH:=[0-9a-f]\{64\}$' luci-app-honk/Makefile

node <<'NODE'
const fs = require('fs');
const lines = fs.readFileSync('ci/patches/doona-openwrt.patch', 'utf8').split('\n');
const badAdditions = lines.filter(line => line.startsWith('+') && !line.startsWith('+++') && /[\t ]+$/.test(line.slice(1)));
if (badAdditions.length)
	throw new Error(`Patch contains added lines with trailing whitespace (${badAdditions.length})`);
const whitespaceContext = lines.filter(line => /^[\t ]+$/.test(line));
if (whitespaceContext.some(line => line !== ' '))
	throw new Error('Unified-diff context lines must be a single space');
NODE

verify_stage() {
	local makefile=$1 archive=$2 checksum expected
	test -f "$makefile" || return 0
	checksum=$(sed -n 's/^PKG_HASH:=//p' "$makefile")
	test "${#checksum}" -eq 64 || { echo "Invalid stage hash in $makefile" >&2; exit 1; }
	test "$checksum" = "$(sed -n 's/^PKG_HASH:=//p' luci-app-honk/Makefile)" || {
		echo "Committed Doona hash differs from staged archive." >&2
		exit 1
	}
	if test -s "artifacts/cache/$archive"; then
		expected=$(sha256sum "artifacts/cache/$archive" | cut -d' ' -f1)
		test "$checksum" = "$expected" || { echo "Staged archive hash mismatch: $archive" >&2; exit 1; }
	fi
}
verify_stage luci-app-honk/generated-doona-stage.mk "$DOONA_ARCHIVE"

node <<'NODE'
const fs = require('fs');
const rpcSource = fs.readFileSync('luci-app-honk/htdocs/luci-static/resources/view/honk/rpc.js', 'utf8');
const backend = fs.readFileSync('luci-app-honk/root/usr/libexec/rpcd/honk', 'utf8');
const acl = JSON.parse(fs.readFileSync('luci-app-honk/root/usr/share/rpcd/acl.d/luci-app-honk.json', 'utf8'))['luci-app-honk'];
const expected = ['status', 'check', 'initialize', 'start', 'stop', 'restart', 'settings', 'repair', 'backup', 'restore', 'restore_prepare', 'reset', 'job_status', 'logs', 'update_check', 'update_apply'];
const frontend = [...rpcSource.matchAll(/method:\s*'([^']+)'/g)].map(match => match[1]);
const list = backend.match(/echo '([^']+)'/);
if (!list) throw new Error('RPC backend has no list method declaration');
const declared = Object.keys(JSON.parse(list[1]));
const aclMethods = [...(acl.read.ubus.honk || []), ...(acl.write.ubus.honk || [])].sort();
for (const [label, methods] of [['frontend', frontend], ['backend list', declared], ['ACL', aclMethods]]) {
	if (JSON.stringify([...methods].sort()) !== JSON.stringify([...expected].sort()))
		throw new Error(`${label} RPC methods do not match the required method set: ${methods.join(', ')}`);
}
for (const method of expected) {
	const block = backend.match(new RegExp(`\\n\\s*${method}\\)\\n([\\s\\S]*?)\\n\\s*;;`));
	if (!block || !block[1].trim() || /unknown_method/.test(block[1]))
		throw new Error(`RPC method ${method} has no concrete backend case`);
}
if (!/params:\s*\[\s*'lan_network',\s*'listen_port',\s*'boot_enabled'\s*\]/.test(rpcSource))
	throw new Error('settings RPC parameters do not include boot_enabled');
NODE

redacted=$(printf '%s\n' \
	'Authorization: Bearer HONK_BEARER_SECRET_7c2a' \
	'{"password": "HONK_PASSWORD_SECRET PW_TAIL_unique"}' \
	'subscription=https://user:HONK_URL_SECRET@example.invalid/feed?token=HONK_QUERY_SECRET' \
	'vmess://HONK_SHARELINK_SECRET' | sh honk/files/redact-log.sh)
case "$redacted" in
	*HONK_BEARER_SECRET_7c2a*|*HONK_PASSWORD_SECRET*|*PW_TAIL_unique*|*HONK_URL_SECRET*|*HONK_QUERY_SECRET*|*HONK_SHARELINK_SECRET*)
		echo 'Log redaction leaked a test secret.' >&2
		exit 1
		;;
esac

. honk/files/log-lines.sh
log_lines_added=0
json_add_string() { log_lines_added=$((log_lines_added + 1)); }
empty_log=$(mktemp)
honk_add_log_lines "$empty_log"
test "$log_lines_added" -eq 0
printf 'kept\n' > "$empty_log"
honk_add_log_lines "$empty_log"
rm -f "$empty_log"
test "$log_lines_added" -eq 1

log_fixture=$(mktemp)
printf '%s\n' \
	'Mon Oct  5 10:00:00 2026 daemon.info honk-core[11]: proxy text contains [ERROR]' \
	'Mon Oct  5 10:00:01 2026 daemon.err honk-core[11]: request failed' \
	'Mon Oct  5 10:00:02 2026 daemon.info honk-core[11]:  WARN candidate check' \
	'Mon Oct  5 10:00:03 2026 daemon.debug honk-core[11]: debug detail' > "$log_fixture"
error_logs=$(sh honk/files/log-level-filter.sh error < "$log_fixture")
warn_logs=$(sh honk/files/log-level-filter.sh warn < "$log_fixture")
info_logs=$(sh honk/files/log-level-filter.sh info < "$log_fixture")
rm -f "$log_fixture"
case "$error_logs" in *'request failed'*) ;; *) echo 'Syslog error severity was not recognized.' >&2; exit 1 ;; esac
case "$error_logs" in *'proxy text contains'*|*'WARN candidate'*) echo 'Log body text was misclassified as error.' >&2; exit 1 ;; esac
case "$warn_logs" in *'WARN candidate check'*) ;; *) echo 'Core warning prefix was not recognized.' >&2; exit 1 ;; esac
case "$warn_logs" in *'proxy text contains'*|*'debug detail'*) echo 'Warning severity filter included lower-level logs.' >&2; exit 1 ;; esac
case "$info_logs" in *'proxy text contains [ERROR]'*|*'request failed'*|*'WARN candidate check'*) ;; *) echo 'Info severity filter dropped expected log rows.' >&2; exit 1 ;; esac
case "$info_logs" in *'debug detail'*) echo 'Info severity filter included debug logs.' >&2; exit 1 ;; esac

reset_fixture=$(mktemp -d)
mkdir -p "$reset_fixture/old/etc/honk/state" "$reset_fixture/new"
printf 'include { extra.dae }\n' > "$reset_fixture/old/etc/honk/config.dae"
printf 'node { name: old }\n' > "$reset_fixture/old/etc/honk/extra.dae"
printf 'administrator-preserved\n' > "$reset_fixture/old/etc/honk/state/honk.db"
printf 'system config\n' > "$reset_fixture/system.dae"
printf 'default config\n' > "$reset_fixture/default.dae"
check_path=$PATH
export HONK_MAINT_LIBRARY=1
. honk/files/maintenance.sh
unset HONK_MAINT_LIBRARY
PATH=$check_path
export PATH
stage_reset_tree "$reset_fixture/old/etc/honk" "$reset_fixture/new/etc/honk" "$reset_fixture/system.dae" "$reset_fixture/default.dae"
test "$(cat "$reset_fixture/new/etc/honk/config.dae")" = 'default config'
test "$(cat "$reset_fixture/new/etc/honk/system.dae")" = 'system config'
test "$(cat "$reset_fixture/new/etc/honk/state/honk.db")" = 'administrator-preserved'
test ! -e "$reset_fixture/new/etc/honk/extra.dae"
rm -rf "$reset_fixture"

# The data reset clears the business state and keeps the administrator
# record: the upstream core has no command for it.
state_fixture=$(mktemp -d)
sqlite3 "$state_fixture/honk.db" "CREATE TABLE admin (id INTEGER PRIMARY KEY, record TEXT NOT NULL);
INSERT INTO admin (id, record) VALUES (1, 'administrator');
CREATE TABLE selector (grp TEXT, network TEXT, member TEXT);
INSERT INTO selector (grp, network, member) VALUES ('g', 'tcp', 'n');
CREATE TABLE dns_answer (key TEXT, expire_at INTEGER, entry BLOB);
INSERT INTO dns_answer (key, expire_at, entry) VALUES ('k', 0, x'00');"
reset_business_state "$state_fixture/honk.db"
test "$(sqlite3 "$state_fixture/honk.db" 'SELECT count(*) FROM admin;')" = 1
test "$(sqlite3 "$state_fixture/honk.db" 'SELECT count(*) FROM selector;')" = 0
test "$(sqlite3 "$state_fixture/honk.db" 'SELECT count(*) FROM dns_answer;')" = 0
rm -rf "$state_fixture"

# The lock file stores "pid starttime"; both columns have to match.
lock_fixture=$(mktemp -d)
. honk/files/lock.sh
HONK_LOCK_DIR="$lock_fixture"
printf '%s %s\n' 4242 987654 > "$HONK_LOCK_DIR/pid"
honk_lock_owner_matches 4242 987654
! honk_lock_owner_matches 4242 111111
! honk_lock_owner_matches 4243 987654
rm -rf "$lock_fixture"

grep -Fq 'include $(INCLUDE_DIR)/package.mk' luci-app-honk/Makefile
grep -Fq '$(eval $(call BuildPackage,luci-app-honk))' luci-app-honk/Makefile
! grep -Fq 'include $(TOPDIR)/feeds/luci/luci.mk' luci-app-honk/Makefile || {
	echo 'luci-app-honk must not pull the luci feed' >&2
	exit 1
}
grep -Fq 'PKG_BUILD_DEPENDS:=luci-base/host' luci-app-honk/Makefile
grep -Fq 'po2lmo ./po/zh-cn/honk.po' luci-app-honk/Makefile
grep -Fq '$(INSTALL_DATA) $(PKG_BUILD_DIR)/honk.zh-cn.lmo' luci-app-honk/Makefile
! grep -Fq 'view/honk/vendor' luci-app-honk/Makefile || {
	echo 'luci-app-honk must not install the removed vendor directory' >&2
	exit 1
}
grep -Fq '"/tmp/honk-maintenance/restore.tar.gz": [ "write" ]' luci-app-honk/root/usr/share/rpcd/acl.d/luci-app-honk.json

grep -Fq 'HONK_ASSET_X86_64?=' honk/Makefile
grep -Fq 'HONK_ASSET_AARCH64?=' honk/Makefile
grep -Fq 'HONK_ASSET_ARMV7?=' honk/Makefile
grep -Fq '@(x86_64||aarch64||arm)' honk/Makefile
grep -Fq '$(INSTALL_BIN) $(CURDIR)/files/update.sh' honk/Makefile

grep -Fq '+@KERNEL_DEBUG_INFO_BTF' honk/Makefile
grep -Fq '+curl' honk/Makefile
grep -Fq '+curl' luci-app-honk/Makefile
# The upgrade path restarts the service: default_postinst starts it while
# procd's stop from the upgrade is still running, which leaves the service
# "active with no instances".
grep -Fq 'PKG_UPGRADE' honk/Makefile
grep -Fq '/etc/init.d/honk restart' honk/Makefile
grep -Fq "! rg -n 'MockBackend|mockBackend|mock-backend' dist" ci/build-doona.sh
! grep -Fq "! rg -n 'mock backend|MockBackend|mockBackend' dist" ci/build-doona.sh || {
	echo 'the mock backend guard is missing from ci/build-doona.sh' >&2
	exit 1
}
grep -Fq 'node tools/notices.mjs "$STAGE"' ci/build-doona.sh
grep -Fq 'for file in LICENSE NOTICE CHANGELOG.md README.md; do' ci/build-doona.sh
grep -Fq 'rm -rf "$STAGE/fonts" "$STAGE/.vite"' ci/build-doona.sh

grep -Fq 'start_job update_check' luci-app-honk/root/usr/libexec/rpcd/honk
grep -Fq 'update_gate' luci-app-honk/root/usr/libexec/rpcd/honk
grep -Fq 'trap cleanup_update EXIT' honk/files/update.sh
grep -Fq 'UPDATE_LOCK_OWNED=1' honk/files/update.sh
grep -Fq 'checking_feed' honk/files/job.sh


grep -Fq "honk.settings(networkSelect.value, port, bootEnabledInput.checked)" luci-app-honk/htdocs/luci-static/resources/view/honk/overview.js


# The configuration plane lives in Doona. The LuCI side keeps the sysadmin
# duties only, so no view, rpc method, acl entry or translation may reference
# the removed import path any more.
! grep -RqiE 'add_subscription|add_nodes|import_dae|importDae|addSubscription|addNodes' \
	luci-app-honk/htdocs/luci-static/resources/view/honk \
	luci-app-honk/root/usr/libexec/rpcd/honk \
	luci-app-honk/root/usr/share/rpcd/acl.d/luci-app-honk.json || {
	echo 'a removed configuration method is still referenced' >&2
	exit 1
}
! grep -q 'honk/configuration' luci-app-honk/root/usr/share/luci/menu.d/luci-app-honk.json || {
	echo 'the removed configuration view is still in the menu' >&2
	exit 1
}
! grep -q 'honk-v2-upload' luci-app-honk/root/usr/share/rpcd/acl.d/luci-app-honk.json || {
	echo 'the removed dae import upload path is still in the ACL' >&2
	exit 1
}

# The native API binds every interface, so the firewall rule is the boundary
# that keeps the management API on the lan zone.
grep -Fq 'honk_native_api_lan' honk/files/firewall.sh
grep -Fq 'honk_native_api_wan' honk/files/firewall.sh
grep -Fq "option src='lan'" honk/files/firewall.sh || grep -Fq ".src='lan'" honk/files/firewall.sh
grep -Fq ".src='wan'" honk/files/firewall.sh
grep -Fq 'target' honk/files/firewall.sh
grep -Fq 'files/firewall.sh' honk/Makefile
grep -Fq 'Package/honk/postinst' honk/Makefile
grep -Fq 'Package/honk/postrm' honk/Makefile
grep -Fq 'honk_firewall_apply' honk/files/control.sh
grep -Fq 'honk_firewall_remove' honk/files/firewall.sh

# The runtime listener is a wildcard, not the LAN address: a later address
# change must not strand the panel on a stale one.
grep -Fq 'system_listen=${4:-0.0.0.0}' honk/files/control.sh
grep -Fq 'system_host=0.0.0.0' honk/files/control.sh
grep -Fq '0.0.0.0) HONK_LIFECYCLE_LISTEN="127.0.0.1:$HONK_LIFECYCLE_PORT"' honk/files/lifecycle.sh
grep -Fq 'lan_address()' luci-app-honk/root/usr/libexec/rpcd/honk

# procd_set_param env REPLACES the whole environment list, so a second call in
# the same instance silently drops the first variable. That once dropped
# DAE_LOCATION_ASSET, and the core could not find geoip.dat/geosite.dat.
test "$(grep -c '^[[:space:]]*procd_set_param env' honk/files/honk.init)" -eq 1 || {
	echo 'honk/files/honk.init must set every procd env variable in one call' >&2
	exit 1
}
grep -Fq 'DAE_LOCATION_ASSET=/usr/share/v2ray' honk/files/honk.init

# The panel link follows the address the browser already uses for the router.
grep -Fq 'window.location' luci-app-honk/htdocs/luci-static/resources/view/honk/rpc.js
grep -Fq "isIpLiteral" luci-app-honk/htdocs/luci-static/resources/view/honk/rpc.js

# The daily job reacts to upstream releases, not to branch heads, and stays
# silent when the release tags it recorded are still the latest ones.
grep -Fq "cron: '0 0 * * *'" .github/workflows/auto-bump.yml || {
	echo 'the upstream check must run at 00:00 UTC, which is 08:00 in Asia/Shanghai' >&2
	exit 1
}
grep -Fq 'latest_release_tag' .github/workflows/auto-bump.yml || {
	echo 'the upstream check must read published releases' >&2
	exit 1
}
# The honk core follows the upstream main branch head, which carries no
# "this exact commit was published" guarantee. The upstream CI is the gate
# instead: only a commit whose own required lanes are all green is accepted,
# and the lane list is part of the workflow, not an assumption.
grep -Fq 'latest_green_commit daeuniverse/honk main' .github/workflows/auto-bump.yml || {
	echo 'the honk core must follow the upstream main branch head' >&2
	exit 1
}
grep -Fq 'REQUIRED_LANES=' .github/workflows/auto-bump.yml || {
	echo 'the upstream check must gate the branch head on a list of CI lanes' >&2
	exit 1
}
grep -Fq 'repos/$repo/commits/$sha/check-runs' .github/workflows/auto-bump.yml || {
	echo 'the upstream check must read the CI verdict of the candidate commit' >&2
	exit 1
}
grep -Fq 'CORE_REPOSITORY=https://github.com/daeuniverse/honk.git' ci/pins.env || {
	echo 'the core pin must track the official daeuniverse/honk repository' >&2
	exit 1
}
grep -Fq 'CORE_RELEASE=' ci/pins.env
grep -Fq 'DOONA_RELEASE=' ci/pins.env
# The Rust toolchains are read back from the pinned upstream checkout, not
# pinned here: upstream moves them on its own schedule (the eBPF nightly moved
# on 2026-10-22), and a stale local nightly cannot compile the eBPF object at
# all — the build dies inside honk-core's build.rs with a missing rust-src.
grep -Fq 'crates/honk-ebpf/rust-toolchain.toml' ci/build-core.sh || {
	echo 'the core build must take the eBPF toolchain from the upstream checkout' >&2
	exit 1
}
! grep -q '^NIGHTLY=' ci/pins.env || {
	echo 'the Rust nightly must not be pinned in ci/pins.env' >&2
	exit 1
}
# The SDK and its ~1 GB container are gone: the packages are built by
# ci/build-apk.sh with apk-tools directly. Both of these are load-bearing, so a
# reintroduction should be a deliberate decision rather than a stray line.
for banned in gh-action-sdk 'immortalwrt/sdk' 'OPENWRT_SDK_URL'; do
	! grep -RqF "$banned" .github/workflows/ || {
		echo "the release pipeline must not reference $banned" >&2
		exit 1
	}
done
# 24.10 and opkg are gone; nothing may produce or collect a .ipk again.
! grep -RqF '.ipk' .github/workflows/ || {
	echo 'the release pipeline no longer ships .ipk (24.10/opkg support is dropped)' >&2
	exit 1
}
grep -Fq 'ci/build-apk.sh' .github/workflows/release.yml || {
	echo 'the build job must call ci/build-apk.sh' >&2
	exit 1
}
grep -Fq 'ci/install-apk-tools.sh' .github/workflows/release.yml || {
	echo 'the build job must install apk-tools' >&2
	exit 1
}
# The build job uploads one artifact named `packages`; the release and feed
# jobs download that one by name. A `pattern:` that matches nothing still exits
# 0 and does not even create the target directory, which is how the release job
# silently lost its files when the SDK matrix was replaced by the apk job.
! grep -Fq 'pattern: packages' .github/workflows/release.yml || {
	echo 'the packages artifact must be downloaded by name, not by pattern' >&2
	exit 1
}
grep -Fq 'R2 credentials are absent' .github/workflows/release.yml || {
	echo 'a release without R2 credentials must not fail the pipeline' >&2
	exit 1
}

# Release asset URLs carry the repository name (.../szwjp/luci-app-honk/...),
# so install.sh must match file names. Filtering the URLs with
# `grep -v "luci-app-honk"` drops every honk asset and breaks the installer.
! grep -Fq '| grep -v "luci-app-honk"' scripts/install.sh || {
	echo 'scripts/install.sh must match asset file names, not exclude the repo path' >&2
	exit 1
}

# The R2 credentials are read from a file outside the repository. The helper
# must never read them from the tree, and the tree must not carry one.
test -f scripts/set-r2-secrets.sh
bash -n scripts/set-r2-secrets.sh
grep -Fq 'HONK_R2_SECRETS' scripts/set-r2-secrets.sh
grep -Fq 'must be mode 600' scripts/set-r2-secrets.sh
! grep -RIlE 'R2_SECRET_ACCESS_KEY *= *[A-Za-z0-9]' . --exclude-dir=.git 2>/dev/null | grep -q . || {
	echo 'a credential value is present in the working tree' >&2
	exit 1
}

if command -v msgfmt >/dev/null 2>&1; then
	msgfmt --check -o /dev/null luci-app-honk/po/zh-cn/honk.po
fi

# --- apk-native packer -----------------------------------------------------
# ci/build-apk.sh stages the same files the package Makefiles describe. The
# Makefiles stay in place for anyone building with an SDK, so a file added to
# one and forgotten in the other has to fail here rather than in a release.
for script in ci/install-apk-tools.sh ci/build-po2lmo.sh ci/build-apk.sh scripts/set-apk-key.sh; do
	test -f "$script" || { echo "missing $script" >&2; exit 1; }
	bash -n "$script"
done
for var in APK_TOOLS_SHA256 APK_COMPAT LUCI_COMMIT; do
	grep -q "^${var}=." ci/pins.env || { echo "ci/pins.env is missing $var" >&2; exit 1; }
done
test "$(sed -n 's/^APK_TOOLS_SHA256=//p' ci/pins.env | tr -d '\n' | wc -c)" -eq 64

# Every install target named in a Makefile must be staged by the packer.
targets_file=$(mktemp)
trap 'rm -f "$targets_file"' EXIT
for makefile in honk/Makefile luci-app-honk/Makefile; do
	awk '/^define Package\/.*\/install$/ { inb = 1; next }
	     inb && /^endef$/ { exit }
	     inb { print }' "$makefile" |
		grep -oE '\$\(1\)/[^[:space:]"]+' |
		sed 's|^\$(1)/||; s|/*$||' | LC_ALL=C sort -u > "$targets_file"
	test -s "$targets_file" || { echo "no install targets found in $makefile" >&2; exit 1; }
	while IFS= read -r target; do
		[ -n "$target" ] || continue
		grep -Fq "$target" ci/build-apk.sh || {
			echo "$makefile installs $target but ci/build-apk.sh never stages it" >&2
			exit 1
		}
	done < "$targets_file"
done

# The signing key must never be committed, and the helper must not read one
# from the working tree.
grep -Fq 'gh secret set APK_PRIVATE_KEY' scripts/set-apk-key.sh
grep -Fq 'must be mode 600' scripts/set-apk-key.sh
! grep -RIlE 'BEGIN (EC )?PRIVATE KEY' . --exclude-dir=.git --exclude-dir=.cache --exclude-dir=artifacts 2>/dev/null | grep -q . || {
	echo 'a private key is present in the working tree' >&2
	exit 1
}

# Real-device installs uncovered two packaging defects that no static check
# caught: apk's depends field is ONE space-separated blob (a comma-joined list
# becomes a single bogus dependency name), and packaged files must be owned by
# root (OpenWrt stages under fakeroot, while apk-tools-static ignores LD_PRELOAD
# so the tree has to be chowned instead).
grep -Fq 'chown -R 0:0' ci/build-apk.sh || {
	echo 'ci/build-apk.sh must stage root-owned files for mkpkg' >&2
	exit 1
}
! grep -Fq 'out="${out:+$out,}$entry"' ci/build-apk.sh || {
	echo 'apk depends must be space-separated, not comma-joined' >&2
	exit 1
}
# postrm runs after the package files are gone, so it cannot source the
# packaged firewall.sh; the firewall cleanup has to be inline.
! awk '/^define Package\/honk\/postrm$/,/^endef$/' honk/Makefile | grep -q 'honk_firewall_remove' || {
	echo 'Package/honk/postrm must not source the packaged firewall.sh' >&2
	exit 1
}

git diff --check
echo 'Static checks passed.'
