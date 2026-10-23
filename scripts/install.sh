#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
set -eu

REPO="szwjp/luci-app-honk"
# 取最近若干个 release 而不是 /releases/latest：后者在全部为 pre-release 时
# 返回 404，而最近的一个 release 可能只有构建资产、没有可安装的包。
GH_API="https://api.github.com/repos/${REPO}/releases?per_page=10"
GH_RELEASE_API="https://api.github.com/repos/${REPO}/releases/tags"
# 第三方代理是可选的：GH_PROXY 置空即直连 GitHub。走代理时也只允许 https，
# 而且它只能保护传输，不能替代下面的签名校验。
GH_PROXY="${GH_PROXY:-}"
GEO_FEED="https://down.dllkids.xyz/openwrt-feed"
# The download directory is created with mktemp after the release is chosen:
# a fixed /tmp path could be planted as a symlink by a local user and then
# followed by this root script.
TMP_DIR=""
# 设备信任的签名公钥。它随每次 release 发布，安装到 /etc/apk/keys 之后
# apk 才会校验安装包的签名。
APK_KEY_FILE="/etc/apk/keys/luci-app-honk.rsa.pub"

cleanup() {
	[ -n "$TMP_DIR" ] && rm -rf "$TMP_DIR" 2>/dev/null || :
}
trap cleanup EXIT INT TERM

fetch_text() {
	url="$1"
	if command -v curl >/dev/null 2>&1; then curl -fsSL --connect-timeout 10 --max-time 30 "$url" 2>/dev/null; else wget -qO- "$url" 2>/dev/null; fi
}

download_file() {
	url="$1"; out="$2"
	# The packages are downloaded over https; the proxy is optional and only
	# ever prefixes a github url.
	if command -v curl >/dev/null 2>&1; then curl -fL --connect-timeout 10 --max-time 300 --retry 5 --retry-delay 10 --retry-all-errors "$url" -o "$out"; else wget -qO "$out" "$url"; fi
}

proxy_url() {
	case "$1" in
		https://github.com/*)
			[ -n "$GH_PROXY" ] || { printf '%s\n' "$1"; return 0; }
			case "$GH_PROXY" in
				https://*) printf '%s%s\n' "$GH_PROXY" "$1" ;;
				*)
					echo "GH_PROXY 必须是 https 地址。" >&2
					return 1
					;;
			esac
			;;
		*) printf '%s\n' "$1" ;;
	esac
}

sha256_of() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{ print $1 }'
	elif command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$1" | awk '{ print $1 }'
	else
		openssl dgst -sha256 "$1" | awk '{ print $NF }'
	fi
}

# The sha256 of a downloaded file, compared with the one the release
# published. A file that is not listed is refused.
verify_sha256() {
	[ -f "$1" ] || return 1
	[ -n "$2" ] || return 1
	[ "${#2}" -eq 64 ] || return 1
	case "$2" in *[!0-9a-f]*) return 1 ;; esac
	actual="$(sha256_of "$1")" || return 1
	[ "$actual" = "$2" ]
}

# The sha256 of an asset, taken from the SHA256SUMS file of the release.
sums_lookup() {
	awk -v name="$2" '$2 == "./" name || $2 == name { print $1; exit }' "$1"
}

# The browser download url of the first asset whose name matches the pattern.
asset_url() {
	printf '%s' "$1" | grep -oE "\"browser_download_url\": *\"[^\"]*/${2}\"" | sed -E 's/.*"([^"]+)".*/\1/' | head -n 1
}

# The sha256 digest the GitHub API recorded for an asset. The API response is
# fetched from api.github.com, which is not proxied by GH_PROXY, so this value
# anchors the downloaded SHA256SUMS/key to GitHub rather than to the transport
# proxy.
asset_digest() {
	printf '%s\n' "$1" | awk -v want="$2" '
		/"name": *"/ {
			name = $0
			sub(/.*"name": *"/, "", name)
			sub(/".*/, "", name)
			seen = (name == want)
			next
		}
		seen && /"digest": *"sha256:[0-9a-f]+"/ {
			digest = $0
			sub(/.*sha256:/, "", digest)
			sub(/".*/, "", digest)
			print digest
			exit
		}
	'
}

detect_sdk() {
	[ -r /etc/openwrt_release ] || return 1
	release="$(sed -n "s/^DISTRIB_RELEASE=['\"]\([^'\"]*\)['\"].*/\1/p" /etc/openwrt_release | head -n 1)"
	printf '%s\n' "$release" | grep -Eo '[0-9]+\.[0-9]+' | head -n 1
}

detect_manager() {
	# 24.10 and older ship opkg and are no longer supported: apk-tools 3 cannot
	# produce an ipk, and carrying a second packaging path for them is not worth
	# it. Those installs are rejected explicitly rather than failing later with
	# a confusing "no package found".
	sdk="$(detect_sdk || true)"
	case "$sdk" in
		2[5-9].*|[3-9][0-9].*)
			if command -v apk >/dev/null 2>&1; then echo apk; return; fi ;;
	esac
	if command -v opkg >/dev/null 2>&1; then echo opkg; return; fi
	if command -v apk >/dev/null 2>&1; then echo apk; return; fi
	echo unsupported
}

detect_arch() {
	pm="$1"
	if [ "$pm" = opkg ]; then
		opkg print-architecture | awk '/^arch / {print $2}' | tail -n 1
		return
	fi
	sed -n "s/^DISTRIB_ARCH=['\"]\([^'\"]*\)['\"].*/\1/p" /etc/openwrt_release 2>/dev/null | head -n 1
}

fallback_arch() {
	case "$1" in
		aarch64_generic) return 1 ;;
		aarch64_*) printf 'aarch64_generic\n' ;;
		*) return 1 ;;
	esac
}

geodata_installed() {
	[ -s /usr/share/v2ray/geoip.dat ] && [ -s /usr/share/v2ray/geosite.dat ] || return 1
	if [ "$PM" = apk ]; then
		apk info -e v2ray-geoip >/dev/null 2>&1 && apk info -e v2ray-geosite >/dev/null 2>&1
	else
		opkg list-installed v2ray-geoip | grep -q '^v2ray-geoip - ' &&
			opkg list-installed v2ray-geosite | grep -q '^v2ray-geosite - '
	fi
}

apk_file_version() {
	metadata="$(apk --allow-untrusted adbdump "$1")" || return 1
	name="$(printf '%s\n' "$metadata" | sed -n 's/^  name: //p' | head -n 1)"
	version="$(printf '%s\n' "$metadata" | sed -n 's/^  version: //p' | head -n 1)"
	[ "$name" = "$2" ] && [ -n "$version" ] || return 1
	printf '%s\n' "$version"
}

apk_installed_version() {
	apk list --installed "$1" | awk -v expected="$1-$2" '$1 == expected { found = 1 } END { exit !found }'
}

# The newest release that is not a pre-release and that carries an installable
# package for this architecture. A failed run leaves a "source-*" pre-release
# behind, and that one has no packages at all.
select_release() {
	for tag in $(fetch_text "$GH_API" | grep -oE '"tag_name": "[^"]+"' | sed 's/.*"tag_name": "//; s/"$//'); do
		[ -n "$tag" ] || continue
		json="$(fetch_text "$GH_RELEASE_API/$tag")" || continue
		case "$json" in
			*'"prerelease": true'*) continue ;;
		esac
		release_honk_asset="$(asset_url "$json" "honk-[^\"/]*${RELEASE_ARCH}\.${EXT}")"
		[ -n "$release_honk_asset" ] || continue
		release_luci_asset="$(asset_url "$json" "luci-app-honk-[^\"/]*\.${EXT}")"
		[ -n "$release_luci_asset" ] || continue
		release_sums_asset="$(asset_url "$json" "SHA256SUMS")"
		[ -n "$release_sums_asset" ] || continue
		release_key_asset="$(asset_url "$json" "luci-app-honk\.pub\.pem")"
		[ -n "$release_key_asset" ] || continue
		RELEASE_TAG=$tag
		RELEASE_JSON=$json
		RELEASE_HONK_ASSET=$release_honk_asset
		RELEASE_LUCI_ASSET=$release_luci_asset
		RELEASE_SUMS_ASSET=$release_sums_asset
		RELEASE_KEY_ASSET=$release_key_asset
		return 0
	done
	return 1
}

main() {
	PM="$(detect_manager)"
	[ "$PM" = unsupported ] && { echo "无法识别包管理器（opkg/apk）。" >&2; exit 1; }

	ARCH="$(detect_arch "$PM")"
	[ -n "$ARCH" ] || { echo "无法识别架构。" >&2; exit 1; }

	SDK="$(detect_sdk || true)"
	[ -n "$SDK" ] || SDK="24.10"

	if [ "$PM" = opkg ]; then
		echo "检测到 opkg：只支持 OpenWrt / ImmortalWrt 25.12 及更新版本（apk）。" >&2
		echo "当前系统版本：${SDK:-未知}（apk 通道）。" >&2
		exit 1
	fi
	EXT=apk

	# honk 的脚本用 curl 访问 native api 与更新源；官方镜像默认只有
	# uclient-fetch。curl 是包的依赖，装包时会自动补上，但源不可用时
	# 安装会失败，所以先提示。
	if ! command -v curl >/dev/null 2>&1; then
		echo "注意：系统缺少 curl，请确认软件源可用（否则安装会失败）：$PM add curl" >&2
	fi

	# 架构回退：aarch64_generic 的包也能装在别的 aarch64 上。
	RELEASE_ARCH=$ARCH
	alt="$(fallback_arch "$ARCH" || true)"
	[ -z "$alt" ] || RELEASE_ARCH=$alt

	echo "检测到：架构 $ARCH · SDK $SDK · $PM"
	[ "$RELEASE_ARCH" = "$ARCH" ] || echo "架构 $ARCH 无独立包，回退到 $RELEASE_ARCH。"

	select_release || { echo "未找到包含 $RELEASE_ARCH 安装包的正式 Release。" >&2; exit 1; }
	echo "使用 Release $RELEASE_TAG"

	TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/honk-install.XXXXXX") || {
		echo "无法创建临时目录。" >&2
		exit 1
	}
	chmod 0700 "$TMP_DIR"
	honk_file="$TMP_DIR/$(basename "$RELEASE_HONK_ASSET")"
	luci_file="$TMP_DIR/$(basename "$RELEASE_LUCI_ASSET")"
	sums_file="$TMP_DIR/SHA256SUMS"
	key_file="$TMP_DIR/luci-app-honk.pub.pem"

	echo "下载 $RELEASE_HONK_ASSET"
	download_file "$(proxy_url "$RELEASE_HONK_ASSET")" "$honk_file"
	echo "下载 $RELEASE_LUCI_ASSET"
	download_file "$(proxy_url "$RELEASE_LUCI_ASSET")" "$luci_file"
	echo "下载校验文件与签名公钥"
	download_file "$(proxy_url "$RELEASE_SUMS_ASSET")" "$sums_file"
	download_file "$(proxy_url "$RELEASE_KEY_ASSET")" "$key_file"

	# 先锚定校验文件本身：摘要来自 api.github.com（不受 GH_PROXY 影响），
	# 代理即使能替换 SHA256SUMS/公钥，也会在这里被拒。公钥摘要可用时同样校验。
	sums_digest=$(asset_digest "$RELEASE_JSON" "SHA256SUMS")
	[ -n "$sums_digest" ] || { echo "无法从 GitHub API 读取 SHA256SUMS 摘要，安装中止。" >&2; exit 1; }
	verify_sha256 "$sums_file" "$sums_digest" || {
		echo "SHA256SUMS 与 GitHub API 记录不一致（代理或下载被篡改），安装中止。" >&2
		exit 1
	}
	key_digest=$(asset_digest "$RELEASE_JSON" "luci-app-honk.pub.pem")
	if [ -n "$key_digest" ]; then
		verify_sha256 "$key_file" "$key_digest" || {
			echo "签名公钥与 GitHub API 记录不一致，安装中止。" >&2
			exit 1
		}
	fi

	# 逐包校验：下载到的文件必须与 release 公布的散列一致。
	honk_sum="$(sums_lookup "$sums_file" "$(basename "$honk_file")")"
	luci_sum="$(sums_lookup "$sums_file" "$(basename "$luci_file")")"
	verify_sha256 "$honk_file" "$honk_sum" || { echo "honk 包的 sha256 与 release 公布的不一致，安装中止。" >&2; exit 1; }
	verify_sha256 "$luci_file" "$luci_sum" || { echo "luci-app-honk 包的 sha256 与 release 公布的不一致，安装中止。" >&2; exit 1; }

	# 设备信任发布方的签名：公钥装进 /etc/apk/keys，之后 apk 用普通模式
	# 安装，签名不匹配就会拒绝。
	mkdir -p /etc/apk/keys
	cp "$key_file" "$APK_KEY_FILE" || { echo "无法安装签名公钥到 $APK_KEY_FILE。" >&2; exit 1; }
	chmod 0644 "$APK_KEY_FILE"

	set -- "$honk_file" "$luci_file"
	geo_files=""
	if geodata_installed; then
		echo "复用已安装的 v2ray-geoip/geosite 数据。"
	else
		geo_dir="$GEO_FEED/$SDK/$ARCH"
		geo_listing="$(fetch_text "$geo_dir/" || true)"
		for pkg in v2ray-geoip v2ray-geosite; do
			geo_name="$(printf '%s\n' "$geo_listing" | grep -oE "${pkg}-[0-9][^\"/<]*\\.apk" | head -n 1)"
			if [ -z "$geo_name" ]; then
				echo "未找到 $pkg 的 $SDK/$ARCH 安装包，将尝试设备现有软件源。" >&2
				continue
			fi
			geo_file="$TMP_DIR/$geo_name"
			echo "下载 $geo_dir/$geo_name"
			if download_file "$geo_dir/$geo_name" "$geo_file"; then
				# 第三方 feed 的包没有本仓库的签名，只能校验容器完整性。
				apk --allow-untrusted verify "$geo_file" || exit 1
				geo_files="$geo_files $geo_file"
			else
				echo "$pkg 下载失败，将尝试设备现有软件源。" >&2
			fi
		done
	fi

	echo "安装 honk、luci-app-honk 及所需 geo 数据"
	install_rc=0
	if [ -n "$geo_files" ]; then
		# shellcheck disable=SC2086
		apk add --allow-untrusted $geo_files 2>&1 || install_rc=$?
	fi
	honk_version="$(apk_file_version "$honk_file" honk)" || exit 1
	luci_version="$(apk_file_version "$luci_file" luci-app-honk)" || exit 1
	install_output="$(apk add "$honk_file" "$luci_file" 2>&1)" || install_rc=$?
	printf '%s\n' "$install_output"

	apk_installed_version honk "$honk_version" && apk_installed_version luci-app-honk "$luci_version" || {
		echo "apk 安装失败：目标版本未全部装入（退出码 $install_rc）。" >&2
		exit 1
	}
	if [ "$install_rc" -ne 0 ] && printf '%s\n' "$install_output" | grep -q '^ERROR:'; then
		echo "apk 安装脚本或依赖报错（退出码 $install_rc），请检查上方错误。" >&2
		exit "$install_rc"
	fi
	[ -x /usr/bin/honk-core ] && /usr/bin/honk-core --version >/dev/null 2>&1 &&
		[ -x /etc/init.d/honk ] && [ -x /usr/libexec/rpcd/honk ] &&
		[ -s /usr/share/doona/index.html ] &&
		[ -s /www/luci-static/resources/view/honk/overview.js ] &&
		jsonfilter -i /usr/share/rpcd/acl.d/luci-app-honk-admin.json -e '@' >/dev/null 2>&1 &&
		jsonfilter -i /usr/share/luci/menu.d/luci-app-honk.json -e '@' >/dev/null 2>&1 || {
			echo "安装后 Honk 或 LuCI 关键文件缺失或无效。" >&2
			exit 1
		}
	geodata_installed || { echo "安装后缺少 v2ray-geoip/geosite 数据。" >&2; exit 1; }
	if [ "$install_rc" -ne 0 ]; then
		echo "目标包已核对安装完成；但 apk 仍报告 $install_rc 个错误，请另行检查设备的包管理器状态。" >&2
	fi

	echo "完成。"
}

main "$@"
