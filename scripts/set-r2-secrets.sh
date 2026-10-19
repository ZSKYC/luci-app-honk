#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
#
# Stores the Cloudflare R2 credentials as repository secrets. The values are
# read from a local file that never enters the repository, so the credentials
# stay out of the working tree and out of the shell history.
#
#   mkdir -p ~/.config/honk
#   cat > ~/.config/honk/r2-secrets <<'EOF'
#   R2_ACCESS_KEY_ID=...
#   R2_SECRET_ACCESS_KEY=...
#   R2_ENDPOINT=https://<account>.r2.cloudflarestorage.com
#   R2_BUCKET=...
#   EOF
#   chmod 600 ~/.config/honk/r2-secrets
#   bash scripts/set-r2-secrets.sh
#
# HONK_R2_SECRETS overrides the credential file location.
# HONK_R2_REPO overrides the target repository.

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SECRETS_FILE=${HONK_R2_SECRETS:-$HOME/.config/honk/r2-secrets}
REPO=${HONK_R2_REPO:-szwjp/luci-app-honk}

if [ ! -f "$SECRETS_FILE" ]; then
	cat >&2 <<EOF
Missing $SECRETS_FILE

Create it with one KEY=value per line:

  R2_ACCESS_KEY_ID=...
  R2_SECRET_ACCESS_KEY=...
  R2_ENDPOINT=https://<account>.r2.cloudflarestorage.com
  R2_BUCKET=...

Then run: bash scripts/set-r2-secrets.sh
EOF
	exit 64
fi

if [ "$(stat -f '%Lp' "$SECRETS_FILE" 2>/dev/null || stat -c '%a' "$SECRETS_FILE" 2>/dev/null)" != "600" ]; then
	echo "Refusing to read $SECRETS_FILE: it must be mode 600" >&2
	exit 64
fi

command -v gh >/dev/null 2>&1 || { echo "The gh command is missing" >&2; exit 69; }

required=(R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_ENDPOINT R2_BUCKET)
for name in "${required[@]}"; do
	if ! grep -qE "^${name}=." "$SECRETS_FILE"; then
		echo "Missing $name in $SECRETS_FILE" >&2
		exit 64
	fi
done

for name in "${required[@]}"; do
	value=$(sed -n "s/^${name}=//p" "$SECRETS_FILE" | head -1)
	# The value never reaches an argument list or the shell history.
	printf '%s' "$value" | gh secret set "$name" --repo "$REPO"
	echo "set $name"
done

echo
echo "Repository secrets of $REPO:"
gh secret list --repo "$REPO"
