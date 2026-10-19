#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Build LuCI's po2lmo from pinned upstream sources.
#
# The SDK used to build this host tool from the luci feed on demand. Without the
# SDK it is built here from the same six files, each hash-pinned in ci/pins.env.
#
# Two steps, because lib/lmo.c needs the plural-formula parser that lemon
# generates: build lemon from contrib/, run it over lib/plural_formula.y, then
# compile po2lmo.o + lib/lmo.o + lib/plural_formula.o exactly as
# modules/luci-base/src/Makefile does.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/ci/pins.env"

OUT=${PO2LMO_BIN:-"$ROOT/.cache/hostbin/po2lmo"}
if [ -x "$OUT" ]; then
	echo "po2lmo already built at $OUT"
	exit 0
fi

work="$ROOT/.cache/po2lmo"
rm -rf "$work"
mkdir -p "$work/contrib" "$work/lib" "$work/build"
mkdir -p "$(dirname "$OUT")"

# fetch <path-in-upstream> <sha256-variable>
fetch() {
	local path=$1 sum_var=$2 dest="$work/$1"
	curl -fsSL -o "$dest" "$LUCI_BASE_URL/$path"
	echo "${!sum_var}  $dest" | sha256sum -c - >/dev/null
}

fetch contrib/lemon.c PO2LMO_SHA256_CONTRIB_LEMON_C
fetch contrib/lempar.c PO2LMO_SHA256_CONTRIB_LEMPAR_C
fetch lib/plural_formula.y PO2LMO_SHA256_LIB_PLURAL_FORMULA_Y
fetch lib/lmo.c PO2LMO_SHA256_LIB_LMO_C
fetch lib/lmo.h PO2LMO_SHA256_LIB_LMO_H
fetch po2lmo.c PO2LMO_SHA256_PO2LMO_C

# Upstream rule: cc -std=gnu17 -o contrib/lemon contrib/lemon.c
cc -std=gnu17 -o "$work/contrib/lemon" "$work/contrib/lemon.c"
# Upstream rule: ./contrib/lemon -q lib/plural_formula.y
(cd "$work" && ./contrib/lemon -q lib/plural_formula.y)
test -s "$work/lib/plural_formula.c" || {
	echo "lemon produced no lib/plural_formula.c" >&2
	exit 1
}

CFLAGS_COMMON="-O2 -DNDEBUG -fPIC"
cc $CFLAGS_COMMON -I"$work" -I"$work/lib" -c -o "$work/build/po2lmo.o" "$work/po2lmo.c"
cc $CFLAGS_COMMON -I"$work" -I"$work/lib" -c -o "$work/build/lmo.o" "$work/lib/lmo.c"
cc $CFLAGS_COMMON -I"$work" -I"$work/lib" -c -o "$work/build/plural_formula.o" "$work/lib/plural_formula.c"
cc -o "$OUT" "$work/build/po2lmo.o" "$work/build/lmo.o" "$work/build/plural_formula.o"
chmod 0755 "$OUT"

# Prove it runs before anyone depends on the .lmo it produces: convert a
# one-entry catalogue and require a non-empty result. The exit status is read
# separately because po2lmo exits non-zero on its own usage errors, and a
# `po2lmo ... | grep` pipeline would report that failure instead of grep's.
cat > "$work/smoke.po" <<'EOF'
msgid ""
msgstr ""
"Content-Type: text/plain; charset=UTF-8\n"

msgid "honk"
msgstr "Honk"
EOF
"$OUT" "$work/smoke.po" "$work/smoke.lmo"
[ -s "$work/smoke.lmo" ] || {
	echo "po2lmo produced an empty .lmo" >&2
	exit 1
}
echo "po2lmo built at $OUT"
