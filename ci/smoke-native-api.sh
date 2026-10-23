#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Runtime smoke test for the native API and the CLI.
#
# The packaging CI proves that the packages can be built. This proves that the
# binary inside them still answers the API the panel talks to: the upstream
# move from the fork to daeuniverse/honk changed both the CLI surface and the
# native API, and "it compiles" did not catch the mismatch. The panel is not
# built here, so the endpoints it uses are checked directly.
#
# Usage: ci/smoke-native-api.sh <honk-core> [port]
set -euo pipefail

CORE=${1:?usage: smoke-native-api.sh <honk-core> [port]}
PORT=${2:-${SMOKE_PORT:-19527}}
BASE="http://127.0.0.1:$PORT"

for tool in curl python3; do
	command -v "$tool" >/dev/null || {
		echo "Missing required tool: $tool" >&2
		exit 1
	}
done
[ -x "$CORE" ] || {
	echo "$CORE is not executable" >&2
	exit 1
}

WORK=$(mktemp -d)
CORE_PID=""
cleanup() {
	if [ -n "$CORE_PID" ]; then
		kill "$CORE_PID" 2>/dev/null || true
		wait "$CORE_PID" 2>/dev/null || true
	fi
	rm -rf "$WORK"
}
trap cleanup EXIT

fail() {
	echo "smoke: $*" >&2
	if [ -f "$WORK/core.log" ]; then
		echo "--- core log ---" >&2
		cat "$WORK/core.log" >&2
	fi
	exit 1
}

# Read one value out of a JSON file.
json_get() { # <file> <expression over d>
	python3 - "$1" "$2" <<'PY'
import json
import sys

with open(sys.argv[1]) as handle:
    data = json.load(handle)
print(eval(sys.argv[2], {"d": data, "json": json}))
PY
}

# --- the CLI surface --------------------------------------------------------
version=$("$CORE" --version 2>&1) || fail "honk-core --version failed: $version"
[ -n "$version" ] || fail "honk-core --version printed nothing"
help=$("$CORE" --help 2>&1) || fail "honk-core --help failed: $help"
for command in admin reload mode proxy delay; do
	case "$help" in
		*"$command"*) ;;
		*) fail "the CLI help does not offer the $command subcommand" ;;
	esac
done

# --- a mock instance --------------------------------------------------------
mkdir -p "$WORK/state"
cat > "$WORK/mock.dae" <<EOF
global {
    wan_interface: auto
    lan_interface: ''
    data_dir: '$WORK'
    nfqueue_enable: false
    store_subscribe: false
}
routing {
    fallback: direct
}
experimental {
    native_api {
        enabled: true
        listen: '127.0.0.1:$PORT'
        password_auth: true
        allow_anonymous_loopback: false
        config_write: true
    }
}
EOF

start_core() {
	DAE_LOCATION_ASSET="$WORK" "$CORE" --config "$WORK/mock.dae" --mock-ebpf \
		--data-dir "$WORK" >"$WORK/core.log" 2>&1 &
	CORE_PID=$!
	attempt=0
	while [ "$attempt" -lt 30 ]; do
		if curl -fsS --noproxy '*' --connect-timeout 1 --max-time 2 \
			"$BASE/api" -o "$WORK/api.json" 2>/dev/null; then
			return 0
		fi
		if ! kill -0 "$CORE_PID" 2>/dev/null; then
			fail "the core exited during startup"
		fi
		sleep 1
		attempt=$((attempt + 1))
	done
	fail "the native api did not answer within 30 seconds"
}

stop_core() {
	[ -n "$CORE_PID" ] || return 0
	kill -TERM "$CORE_PID" 2>/dev/null || true
	attempt=0
	while kill -0 "$CORE_PID" 2>/dev/null && [ "$attempt" -lt 15 ]; do
		sleep 1
		attempt=$((attempt + 1))
	done
	kill -KILL "$CORE_PID" 2>/dev/null || true
	wait "$CORE_PID" 2>/dev/null || true
	CORE_PID=""
}

status_of() { # <method> <path> [token]
	local method=$1 path=$2 token=${3:-}
	if [ -n "$token" ]; then
		curl -sS --noproxy '*' --connect-timeout 2 --max-time 10 \
			-o "$WORK/body.json" -w '%{http_code}' -X "$method" \
			-H "Authorization: Bearer $token" "$BASE$path"
	else
		curl -sS --noproxy '*' --connect-timeout 2 --max-time 10 \
			-o "$WORK/body.json" -w '%{http_code}' -X "$method" "$BASE$path"
	fi
}

start_core

# --- discovery --------------------------------------------------------------
setup_required=$(json_get "$WORK/api.json" 'd["auth"]["setup_required"]')
[ "$setup_required" = "True" ] || fail "the first instance must ask for a setup, got $setup_required"

# --- setup, login and the panel's endpoints ---------------------------------
code=$(curl -sS --noproxy '*' --connect-timeout 2 --max-time 10 \
	-o "$WORK/setup.json" -w '%{http_code}' -X POST \
	-H 'Content-Type: application/json' \
	--data-binary '{"username":"smoke","password":"smoke-password"}' \
	"$BASE/api/v1/auth/setup")
[ "$code" = 201 ] || fail "the administrator setup returned $code instead of 201"

curl -fsS --noproxy '*' --connect-timeout 2 --max-time 10 "$BASE/api" -o "$WORK/api.json"
setup_required=$(json_get "$WORK/api.json" 'd["auth"]["setup_required"]')
[ "$setup_required" = "False" ] || fail "the setup did not close, got $setup_required"

code=$(curl -sS --noproxy '*' --connect-timeout 2 --max-time 10 \
	-o "$WORK/login.json" -w '%{http_code}' -X POST \
	-H 'Content-Type: application/json' \
	--data-binary '{"username":"smoke","password":"smoke-password"}' \
	"$BASE/api/v1/auth/login")
[ "$code" = 200 ] || fail "the login returned $code instead of 200"
token=$(json_get "$WORK/login.json" 'd["token"]')
case "$token" in
	hnk1_*) ;;
	*) fail "the login did not return a session token" ;;
esac

# The endpoints below are the ones the panel reads. None of them is public, so
# an unauthenticated call has to be refused.
code=$(status_of GET /api/v1/version)
[ "$code" = 401 ] || fail "an unauthenticated version request returned $code instead of 401"
for path in /api/v1/version /api/v1/capabilities /api/v1/nodes /api/v1/groups /api/v1/runtime/outbounds; do
	code=$(status_of GET "$path" "$token")
	[ "$code" = 200 ] || fail "$path returned $code instead of 200"
done

# --- the CLI against the same state ----------------------------------------
# `admin reset` is the command the maintenance path needs: it opens the setup
# again. It is refused while the core runs, so the instance is stopped first.
stop_core
reset_output=$("$CORE" admin reset --data-dir "$WORK" 2>&1) || fail "admin reset failed: $reset_output"
case "$reset_output" in
	*"Deleted the administrator"*) ;;
	*) fail "admin reset did not delete the administrator: $reset_output" ;;
esac

start_core
setup_required=$(json_get "$WORK/api.json" 'd["auth"]["setup_required"]')
[ "$setup_required" = "True" ] || fail "the reset did not open the setup again, got $setup_required"

stop_core
echo "Native API and CLI smoke passed."
