#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Build the honk packages straight with apk-tools, without the OpenWrt SDK.
#
# The SDK only did four things for us that mattered: it packaged, it signed, it
# generated the on-device /lib/apk/packages metadata, and it indexed the feed.
# All four are reachable from apk-tools directly:
#
#   * apk mkpkg  -I/-F/-s/-o plus --sign-key   (apk-tools src/app_mkpkg.c)
#   * apk mkndx  --output packages.adb          (imagebuilder/files/Makefile)
#
# The metadata below mirrors include/package-pack.mk from OpenWrt. Two details
# are load-bearing rather than cosmetic:
#
#   1. /lib/apk/packages/<pkg>.list must exist and list /etc/uci-defaults/*,
#      because the on-device default_postinst (base-files lib/functions.sh:354)
#      greps that file to decide which boot scripts to run. Without it 90-honk
#      never executes, the firewall rule is never applied, and `apk add` still
#      reports success. That is a silent failure, not a build error.
#   2. .list is generated *before* .conffiles/.conffiles_static and never lists
#      itself, because upstream writes it to a temp dir and moves it in.
#
# Set APK_DRY_RUN=1 to stage and generate metadata without calling apk, so the
# file tree and the metadata can be inspected on a non-Linux host.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/ci/pins.env"

: "${HONK_SOURCE_TAG:?set HONK_SOURCE_TAG to the release holding the source assets}"
: "${APK_PRIVATE_KEY:?set APK_PRIVATE_KEY to the signing key in PEM form}"

DRY_RUN=${APK_DRY_RUN:-0}
OUT_ROOT=${APK_OUT_DIR:-$ROOT/artifacts/apk}
DL_DIR=${APK_DL_DIR:-$ROOT/.cache/apk-dl}
PO2LMO=${PO2LMO_BIN:-$ROOT/.cache/hostbin/po2lmo}
KEY_DIR=$ROOT/.cache/sign

[ -x "$PO2LMO" ] || { echo "po2lmo missing; run ci/build-po2lmo.sh first" >&2; exit 1; }
if [ "$DRY_RUN" != 1 ]; then
	command -v apk >/dev/null || { echo "apk not on PATH; run ci/install-apk-tools.sh first" >&2; exit 1; }
fi

# The generated stage files are written for make, which accepts `KEY:=value`.
# Bash has no `:=` assignment operator — it would treat the whole line as a
# command — so the operator is normalised away before sourcing. Every value in
# these files is a URL, a hash or a file name, none of which needs quoting.
load_stage_mk() { source <(sed 's/:=/=/' "$1"); }

# Both files define PKG_SOURCE_URL, so capture each one before loading the
# next or the second silently wins.
load_stage_mk "$ROOT/honk/generated-stage.mk"
CORE_SOURCE_URL=$PKG_SOURCE_URL
load_stage_mk "$ROOT/luci-app-honk/generated-doona-stage.mk"
DOONA_SOURCE_URL=$PKG_SOURCE_URL
DOONA_HASH=$PKG_HASH
DOONA_ARCHIVE=${PKG_SOURCE:-}
[ -n "$CORE_SOURCE_URL" ] && [ -n "$DOONA_SOURCE_URL" ] && [ -n "$DOONA_HASH" ] &&
	[ -n "$DOONA_ARCHIVE" ] || {
	echo "generated stage files are incomplete" >&2
	exit 1
}

mkdir -p "$DL_DIR" "$OUT_ROOT" "$KEY_DIR"

# GNU and BSD sed disagree about `-i` (BSD reads the next word as a suffix),
# so in-place edits are written through a temp file instead. That also lets the
# staging logic run on a non-Linux host for inspection.
edit_file() { # edit_file <file> <sed-script>
	local tmp
	tmp=$(mktemp)
	sed "$2" "$1" >"$tmp"
	cat "$tmp" >"$1"
	rm -f "$tmp"
}

prepend_line() { # prepend_line <file> <line>
	local tmp
	tmp=$(mktemp)
	printf '%s\n' "$2" >"$tmp"
	cat "$1" >>"$tmp"
	cat "$tmp" >"$1"
	rm -f "$tmp"
}

# --- signing key -----------------------------------------------------------
# apk reads these keys as PEM-with-a-comment. OpenWrt prepends the line to both
# halves (imagebuilder/files/Makefile:372); without it apk_trust_load_key fails.
SEC_KEY=$KEY_DIR/private-key.pem
PUB_KEY=$KEY_DIR/public-key.pem
printf '%s\n' "$APK_PRIVATE_KEY" >"$SEC_KEY"
chmod 0600 "$SEC_KEY"
openssl ec -in "$SEC_KEY" -pubout >"$PUB_KEY" 2>/dev/null
prepend_line "$SEC_KEY" 'untrusted comment: luci-app-honk package signing key'
prepend_line "$PUB_KEY" 'untrusted comment: luci-app-honk package signing key'
install -m 0644 "$PUB_KEY" "$OUT_ROOT/luci-app-honk.pub.pem"

# --- Makefile extraction ---------------------------------------------------
# Maintainer scripts, conffiles and DEPENDS stay owned by the package Makefiles,
# so there is only one place to edit them.
HONK_MAKEFILE=$ROOT/honk/Makefile
LUCI_MAKEFILE=$ROOT/luci-app-honk/Makefile

make_block() { # make_block <makefile> <define-name>
	awk -v name="$2" '
		$0 ~ "^define " name "[ \t]*$" { inb = 1; next }
		inb && /^endef[ \t]*$/ { exit }
		inb { print }
	' "$1"
}

# `make` collapses `$$` to `$` when it writes a maintainer script. Extracting
# the raw Makefile text leaves the doubled form, and in shell `$$` is the PID,
# so `"$${IPKG_INSTROOT}"` would compare a literal like "1234{IPKG_INSTROOT}"
# and the guard would never fire.
make_body() { # make_body <makefile> <define-name>
	make_block "$1" "$2" | sed 's/\$\$/$/g'
}

make_value() { # make_value <makefile> <VARNAME>
	sed -E -n "s/^$2:?=//p" "$1" | head -1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

HONK_POSTINST=$(make_body "$HONK_MAKEFILE" Package/honk/postinst)
HONK_POSTRM=$(make_body "$HONK_MAKEFILE" Package/honk/postrm)
LUCI_POSTINST=$(make_body "$LUCI_MAKEFILE" Package/luci-app-honk/postinst)
LUCI_POSTRM=$(make_body "$LUCI_MAKEFILE" Package/luci-app-honk/postrm)
HONK_CONFFILES=$(make_block "$HONK_MAKEFILE" Package/honk/conffiles)
HONK_VERSION=$(make_value "$HONK_MAKEFILE" PKG_VERSION)
LUCI_VERSION=$(make_value "$LUCI_MAKEFILE" PKG_VERSION)
[ -n "$HONK_POSTINST" ] && [ -n "$HONK_CONFFILES" ] && [ -n "$HONK_VERSION" ] &&
	[ -n "$LUCI_VERSION" ] || { echo "could not read the package Makefiles" >&2; exit 1; }

# DEPENDS minus the @-prefixed conditional entries, which OpenWrt drops on the
# apk path anyway (include/package-pack.mk:409 does a filter-out @%).
make_depends() { # <pkg>
	local makefile deps entry out=
	case $1 in
	honk) makefile=$HONK_MAKEFILE ;;
	luci-app-honk) makefile=$LUCI_MAKEFILE ;;
	*) echo "unknown package $1" >&2; return 1 ;;
	esac
	deps=$(make_block "$makefile" "Package/$1" |
		sed -n 's/^[[:space:]]*DEPENDS:[:=]*//p' | head -1)
	[ -n "$deps" ] || { echo "no DEPENDS line for $1" >&2; return 1; }
	for entry in $deps; do
		# OpenWrt drops the '+' first and only then filters '@%'
		# (strip_deps in include/package-pack.mk), so `+@SYMBOL` does go.
		entry=${entry#+}
		case $entry in
		@*) continue ;;
		esac
		[ -n "$entry" ] || continue
		out="${out:+$out,}$entry"
	done
	printf '%s' "$out"
}

# --- payload ---------------------------------------------------------------
core_asset_for() { # OpenWrt ARCH_PACKAGES -> core asset name
	case $1 in
	x86_64) printf '%s' "$HONK_ASSET_X86_64" ;;
	aarch64*) printf '%s' "$HONK_ASSET_AARCH64" ;;
	arm_*) printf '%s' "$HONK_ASSET_ARMV7" ;;
	*) return 1 ;;
	esac
}
core_hash_for() {
	case $1 in
	x86_64) printf '%s' "$HONK_HASH_X86_64" ;;
	aarch64*) printf '%s' "$HONK_HASH_AARCH64" ;;
	arm_*) printf '%s' "$HONK_HASH_ARMV7" ;;
	*) return 1 ;;
	esac
}

fetch_verified() { # <url> <sha256> <destination>
	[ -n "$2" ] || { echo "refusing to fetch without a hash" >&2; exit 1; }
	if [ -f "$3" ] && [ "$(sha256sum "$3" | cut -d' ' -f1)" = "$2" ]; then
		return 0
	fi
	curl -fsSL -o "$3" "$1"
	echo "${2}  $3" | sha256sum -c - >/dev/null
}

# --- install scripts -------------------------------------------------------
# Byte-for-byte the shapes OpenWrt writes in include/package-pack.mk, because
# the on-device default_postinst/default_prerm are invoked from these.
write_post_install() { # <pkg> <body-file> <out>
	{
		echo '#!/bin/sh'
		echo '[ "${IPKG_NO_SCRIPT}" = "1" ] && exit 0'
		echo '[ -s "${IPKG_INSTROOT}/lib/functions.sh" ] || exit 0'
		echo '. ${IPKG_INSTROOT}/lib/functions.sh'
		echo 'export root="${IPKG_INSTROOT}"'
		printf 'export pkgname="%s"\n' "$1"
		echo 'add_group_and_user'
		echo 'default_postinst'
		# OpenWrt concatenates postinst-pkg with its shebang stripped.
		sed '/^[[:space:]]*#!/d' <"$2"
	} >"$3"
}

write_post_upgrade() { # <post-install-file> <out>
	{
		echo '#!/bin/sh'
		echo 'export PKG_UPGRADE=1'
		# OpenWrt re-emits the post-install body with its shebang dropped.
		sed '/^[[:space:]]*#!/d' <"$1"
	} >"$2"
}

write_pre_deinstall() { # <pkg> <prerm-body-file-or-empty> <out>
	{
		echo '#!/bin/sh'
		echo '[ -s "${IPKG_INSTROOT}/lib/functions.sh" ] || exit 0'
		echo '. ${IPKG_INSTROOT}/lib/functions.sh'
		echo 'export root="${IPKG_INSTROOT}"'
		printf 'export pkgname="%s"\n' "$1"
		echo 'default_prerm'
		sed '/^[[:space:]]*#!/d' <"$2"
	} >"$3"
}

# --- metadata --------------------------------------------------------------
write_metadata() { # <stage-dir> <pkg> <conffiles-newline-list>
	local idir=$1 pkg=$2 conffiles=$3 tmp
	mkdir -p "$idir/lib/apk/packages"
	# Same output as `find . -type f,l -printf '/%P\n'`, spelled portably so
	# the tree can also be inspected from a non-GNU host.
	tmp=$(mktemp)
	(cd "$idir" && find . \( -type f -o -type l \) -print |
		sed 's|^\./|/|' | LC_ALL=C sort) >"$tmp"
	mv "$tmp" "$idir/lib/apk/packages/$pkg.list"

	if [ -n "$conffiles" ]; then
		printf '%s\n' "$conffiles" | sed '/^[[:space:]]*$/d' \
			>"$idir/lib/apk/packages/$pkg.conffiles"
		: >"$idir/lib/apk/packages/$pkg.conffiles_static"
		while IFS= read -r file; do
			[ -n "$file" ] || continue
			[ -f "$idir$file" ] || continue
			echo "$file $(sha256sum "$idir$file" | cut -d' ' -f1)" \
				>>"$idir/lib/apk/packages/$pkg.conffiles_static"
		done <"$idir/lib/apk/packages/$pkg.conffiles"
	fi
}

# --- staging ---------------------------------------------------------------
# scripts/check.sh asserts that every $(1)/... install target named in the
# Makefiles is staged here, so the two file lists cannot drift apart.
stage_luci() { # <stage-dir>
	local idir=$1 work="$DL_DIR/doona" f
	mkdir -p "$work" "$idir/usr/share/doona" \
		"$idir/usr/share/licenses/honk-doona/LICENSES"
	fetch_verified "${DOONA_SOURCE_URL%/}/$DOONA_ARCHIVE" "$DOONA_HASH" \
		"$DL_DIR/$DOONA_ARCHIVE"
	rm -rf "$work"
	mkdir -p "$work"
	tar --strip-components=1 -C "$work" -xzf "$DL_DIR/$DOONA_ARCHIVE"
	cp -pR "$work/." "$idir/usr/share/doona/"
	edit_file "$idir/usr/share/doona/SOURCE" \
		's#^Build patch: .*#Build patch: '"$DOONA_PATCH"'#'
	for f in LICENSE NOTICE THIRD-PARTY-NOTICES.txt; do
		[ -f "$idir/usr/share/doona/$f" ] || continue
		install -m 0644 "$idir/usr/share/doona/$f" \
			"$idir/usr/share/licenses/honk-doona/$f"
	done
	[ -d "$idir/usr/share/doona/LICENSES" ] &&
		cp -pR "$idir/usr/share/doona/LICENSES/." \
			"$idir/usr/share/licenses/honk-doona/LICENSES/"

	install -d -m 0755 "$idir/usr/libexec/rpcd"
	install -m 0755 "$ROOT/luci-app-honk/root/usr/libexec/rpcd/honk" \
		"$idir/usr/libexec/rpcd/honk"
	install -d -m 0755 "$idir/usr/share/luci-app-honk"
	install -m 0755 "$ROOT/luci-app-honk/root/usr/share/luci-app-honk/pkg-info.sh" \
		"$idir/usr/share/luci-app-honk/pkg-info.sh"
	install -m 0755 "$ROOT/luci-app-honk/root/usr/share/luci-app-honk/refresh-index.sh" \
		"$idir/usr/share/luci-app-honk/refresh-index.sh"
	install -m 0755 "$ROOT/luci-app-honk/root/usr/share/luci-app-honk/update-pkg.sh" \
		"$idir/usr/share/luci-app-honk/update-pkg.sh"
	install -m 0755 "$ROOT/luci-app-honk/root/usr/share/luci-app-honk/update-geo.sh" \
		"$idir/usr/share/luci-app-honk/update-geo.sh"
	install -m 0755 "$ROOT/luci-app-honk/root/usr/share/luci-app-honk/geo-cron.sh" \
		"$idir/usr/share/luci-app-honk/geo-cron.sh"
	install -d -m 0755 "$idir/usr/share/luci/menu.d"
	install -m 0644 "$ROOT/luci-app-honk/root/usr/share/luci/menu.d/luci-app-honk.json" \
		"$idir/usr/share/luci/menu.d/luci-app-honk.json"
	install -d -m 0755 "$idir/usr/share/rpcd/acl.d"
	install -m 0644 "$ROOT/luci-app-honk/root/usr/share/rpcd/acl.d/luci-app-honk.json" \
		"$idir/usr/share/rpcd/acl.d/luci-app-honk.json"
	install -d -m 0755 "$idir/www/luci-static/resources/view/honk"
	install -m 0644 "$ROOT"/luci-app-honk/htdocs/luci-static/resources/view/honk/*.js \
		"$idir/www/luci-static/resources/view/honk/"
	install -m 0644 "$ROOT"/luci-app-honk/htdocs/luci-static/resources/view/honk/*.css \
		"$idir/www/luci-static/resources/view/honk/"
	install -d -m 0755 "$idir/usr/lib/lua/luci/i18n"
	"$PO2LMO" "$ROOT/luci-app-honk/po/zh-cn/honk.po" \
		"$idir/usr/lib/lua/luci/i18n/honk.zh-cn.lmo"
	chmod 0644 "$idir/usr/lib/lua/luci/i18n/honk.zh-cn.lmo"
}

stage_honk() { # <stage-dir> <arch>
	local idir=$1 arch=$2 asset hash work s
	asset=$(core_asset_for "$arch") || { echo "unknown arch $arch" >&2; exit 1; }
	hash=$(core_hash_for "$arch")
	fetch_verified "${CORE_SOURCE_URL%/}/$asset" "$hash" "$DL_DIR/$asset"
	work="$DL_DIR/core-$arch"
	rm -rf "$work"
	mkdir -p "$work"
	tar --strip-components=1 -C "$work" -xzf "$DL_DIR/$asset"
	test -x "$work/honk-core" || { echo "$asset has no honk-core binary" >&2; exit 1; }

	install -d -m 0755 "$idir/usr/bin"
	install -m 0755 "$work/honk-core" "$idir/usr/bin/honk-core"
	install -d -m 0755 "$idir/usr/share/licenses/honk"
	install -m 0644 "$work/LICENSE" "$idir/usr/share/licenses/honk/LICENSE"

	install -d -m 0755 "$idir/etc/config"
	install -m 0600 "$ROOT/honk/files/honk.config" "$idir/etc/config/honk"
	install -d -m 0755 "$idir/etc/honk"
	install -m 0600 "$ROOT/honk/files/config.dae" "$idir/etc/honk/config.dae"
	install -m 0600 "$ROOT/honk/files/system.dae" "$idir/etc/honk/system.dae"
	chmod 0444 "$idir/etc/honk/system.dae"
	install -d -m 0700 "$idir/etc/honk/state"

	install -d -m 0755 "$idir/etc/init.d"
	install -m 0755 "$ROOT/honk/files/honk.init" "$idir/etc/init.d/honk"
	install -d -m 0755 "$idir/etc/uci-defaults"
	install -m 0755 "$ROOT/honk/files/90-honk-boot" "$idir/etc/uci-defaults/90-honk"

	install -d -m 0755 "$idir/usr/share/honk"
	install -m 0644 "$ROOT/honk/files/config.dae" "$idir/usr/share/honk/default-config.dae"
	install -m 0644 "$ROOT/honk/generated-provenance.json" \
		"$idir/usr/share/honk/provenance.json"
	# Listed one by one, not in a loop: scripts/check.sh verifies every
	# Makefile install target appears here, which a loop would hide.
	install -m 0755 "$ROOT/honk/files/control.sh" "$idir/usr/share/honk/control.sh"
	install -m 0755 "$ROOT/honk/files/lock.sh" "$idir/usr/share/honk/lock.sh"
	install -m 0755 "$ROOT/honk/files/firewall.sh" "$idir/usr/share/honk/firewall.sh"
	install -m 0755 "$ROOT/honk/files/lifecycle.sh" "$idir/usr/share/honk/lifecycle.sh"
	install -m 0755 "$ROOT/honk/files/maintenance.sh" "$idir/usr/share/honk/maintenance.sh"
	install -m 0755 "$ROOT/honk/files/job.sh" "$idir/usr/share/honk/job.sh"
	install -m 0755 "$ROOT/honk/files/update.sh" "$idir/usr/share/honk/update.sh"
	install -m 0755 "$ROOT/honk/files/redact-log.sh" "$idir/usr/share/honk/redact-log.sh"
	install -m 0755 "$ROOT/honk/files/log-level-filter.sh" "$idir/usr/share/honk/log-level-filter.sh"
	install -m 0644 "$ROOT/honk/files/log-lines.sh" "$idir/usr/share/honk/log-lines.sh"
}

# --- packaging -------------------------------------------------------------
mkpkg() { # <stage-dir> <pkg> <arch-info> <version> <postinst> <postrm> <conffiles>
	local idir=$1 pkg=$2 archinfo=$3 version=$4 postinst=$5 postrm=$6 sd depends
	local out="$OUT_ROOT/$pkg-$version-$archinfo.apk"
	sd="$scratch/scripts-$pkg-$archinfo"
	rm -rf "$sd"
	mkdir -p "$sd"
	: >"$sd/prerm-body"
	write_post_install "$pkg" "$postinst" "$sd/post-install"
	write_post_upgrade "$sd/post-install" "$sd/post-upgrade"
	write_pre_deinstall "$pkg" "$sd/prerm-body" "$sd/pre-deinstall"
	# OpenWrt hands postrm to apk unchanged apart from normalising whitespace
	# before the shebang (package-pack.mk:574), so keep the shebang here.
	cp "$postrm" "$sd/post-deinstall"
	chmod 0755 "$sd/post-install" "$sd/post-upgrade" "$sd/pre-deinstall" \
		"$sd/post-deinstall"

	depends=$(make_depends "$pkg")
	local -a args=(
		mkpkg --compat "$APK_COMPAT"
		--info "name:$pkg"
		--info "version:$version"
		--info "arch:$archinfo"
		--info "depends:$depends"
		--info "license:GPL-3.0-only"
		--info "origin:https://github.com/szwjp/luci-app-honk"
		--info "url:https://github.com/szwjp/luci-app-honk"
		--info "maintainer:szwjp"
		--info "description:Honk transparent proxy for OpenWrt"
		--script "post-install:$sd/post-install"
		--script "post-upgrade:$sd/post-upgrade"
		--script "pre-deinstall:$sd/pre-deinstall"
		--script "post-deinstall:$sd/post-deinstall"
		--files "$idir"
		--sign-key "$SEC_KEY"
		--output "$out"
	)

	if [ "$DRY_RUN" = 1 ]; then
		printf '[dry-run] apk %s\n' "${args[*]}"
	else
		SOURCE_DATE_EPOCH=0 apk "${args[@]}"
	fi
	echo "built $(basename "$out")"
}

# --- main ------------------------------------------------------------------
# APK_SCRATCH keeps the staging tree around for inspection instead of deleting
# it on exit; handy when a package's file list is what needs checking.
if [ -n "${APK_SCRATCH:-}" ]; then
	mkdir -p "$APK_SCRATCH"
	scratch=$APK_SCRATCH
else
	scratch=$(mktemp -d)
	trap 'rm -rf "$scratch"' EXIT
fi
printf '%s\n' "$HONK_POSTINST" >"$scratch/honk-postinst"
printf '%s\n' "$HONK_POSTRM" >"$scratch/honk-postrm"
printf '%s\n' "$LUCI_POSTINST" >"$scratch/luci-postinst"
printf '%s\n' "$LUCI_POSTRM" >"$scratch/luci-postrm"

# luci-app-honk is arch-independent (PKGARCH:=all), so it is built once.
luci_stage="$scratch/luci"
stage_luci "$luci_stage"
write_metadata "$luci_stage" luci-app-honk ""
mkpkg "$luci_stage" luci-app-honk noarch "$LUCI_VERSION" \
	"$scratch/luci-postinst" "$scratch/luci-postrm" ""

for arch in $OPENWRT_ARCHS; do
	echo "=== $arch"
	honk_stage="$scratch/honk-$arch"
	stage_honk "$honk_stage" "$arch"
	write_metadata "$honk_stage" honk "$HONK_CONFFILES"
	mkpkg "$honk_stage" honk "$arch" "$HONK_VERSION" \
		"$scratch/honk-postinst" "$scratch/honk-postrm" "$HONK_CONFFILES"
	if [ "$DRY_RUN" != 1 ]; then
		install -d -m 0755 "$OUT_ROOT/$arch"
		mv -f "$OUT_ROOT/honk-$HONK_VERSION-$arch.apk" "$OUT_ROOT/$arch/"
	fi
done

if [ "$DRY_RUN" != 1 ]; then
	(cd "$OUT_ROOT" && find . -name '*.apk' -print0 |
		xargs -0 apk mkndx --sign-key "$SEC_KEY" --allow-untrusted \
			--output packages.adb)
	echo "index: $OUT_ROOT/packages.adb"
fi
