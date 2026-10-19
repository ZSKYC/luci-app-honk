#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
#
# Stores the apk package signing key as a repository secret. The key is read
# from a file outside the repository and piped straight to `gh secret set`, so it
# never reaches the working tree, an argument list or the shell history.
#
# The key must be an EC prime256v1 PEM. That is what OpenWrt generates
# (package/Makefile:78) and what apk's trust loader expects:
#
#   mkdir -p ~/.config/honk
#   openssl ecparam -name prime256v1 -genkey -noout -out ~/.config/honk/apk-key.pem
#   chmod 600 ~/.config/honk/apk-key.pem
#   bash scripts/set-apk-key.sh
#
# The matching public key is republished with every release so a device can
# trust it; only this private half is a secret.
#
# HONK_APK_KEY overrides the key file location.
# HONK_APK_REPO overrides the target repository.

set -euo pipefail

KEY_FILE=${HONK_APK_KEY:-$HOME/.config/honk/apk-key.pem}
REPO=${HONK_APK_REPO:-szwjp/luci-app-honk}

if [ ! -f "$KEY_FILE" ]; then
	cat >&2 <<EOF
	Missing $KEY_FILE

	Create one with:

	  openssl ecparam -name prime256v1 -genkey -noout -out $KEY_FILE
	  chmod 600 $KEY_FILE

	Then run: bash scripts/set-apk-key.sh
EOF
	exit 64
fi

mode=$(stat -f '%Lp' "$KEY_FILE" 2>/dev/null || stat -c '%a' "$KEY_FILE" 2>/dev/null)
if [ "$mode" != "600" ]; then
	echo "Refusing to read $KEY_FILE: it must be mode 600, found $mode" >&2
	exit 64
fi

command -v gh >/dev/null 2>&1 || { echo "The gh command is missing" >&2; exit 69; }

if ! openssl ec -in "$KEY_FILE" -noout >/dev/null 2>&1; then
	echo "$KEY_FILE is not a PEM EC private key apk can load" >&2
	echo "Generate it with: openssl ecparam -name prime256v1 -genkey -noout -out $KEY_FILE" >&2
	exit 65
fi

# The value is never placed in an argument list.
cat "$KEY_FILE" | gh secret set APK_PRIVATE_KEY --repo "$REPO"
echo "set APK_PRIVATE_KEY on $REPO"
gh secret list --repo "$REPO"
