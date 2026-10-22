#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
#
# Keeps the native API port reachable from the lan zone and unreachable from
# every other zone. The core binds the API to every interface, so these rules
# are the boundary that keeps the management API off the wan.

HONK_FIREWALL_LAN_SECTION=honk_native_api_lan
HONK_FIREWALL_WAN_SECTION=honk_native_api_wan

honk_firewall_port() {
	case "$1" in
		''|*[!0-9]*) return 1 ;;
	esac
	[ "$1" -ge 1024 ] && [ "$1" -le 65535 ] || return 1
	printf '%s\n' "$1"
}

honk_firewall_apply() {
	port=$(honk_firewall_port "$1") || return 1
	command -v uci >/dev/null 2>&1 || return 1

	uci -q delete firewall."$HONK_FIREWALL_LAN_SECTION" >/dev/null 2>&1
	uci -q delete firewall."$HONK_FIREWALL_WAN_SECTION" >/dev/null 2>&1

	uci set firewall."$HONK_FIREWALL_LAN_SECTION"='rule'
	uci set firewall."$HONK_FIREWALL_LAN_SECTION".name='honk-native-api'
	uci set firewall."$HONK_FIREWALL_LAN_SECTION".src='lan'
	uci set firewall."$HONK_FIREWALL_LAN_SECTION".proto='tcp'
	uci set firewall."$HONK_FIREWALL_LAN_SECTION".dest_port="$port"
	uci set firewall."$HONK_FIREWALL_LAN_SECTION".target='ACCEPT'

	uci set firewall."$HONK_FIREWALL_WAN_SECTION"='rule'
	uci set firewall."$HONK_FIREWALL_WAN_SECTION".name='honk-native-api-wan'
	uci set firewall."$HONK_FIREWALL_WAN_SECTION".src='wan'
	uci set firewall."$HONK_FIREWALL_WAN_SECTION".proto='tcp'
	uci set firewall."$HONK_FIREWALL_WAN_SECTION".dest_port="$port"
	uci set firewall."$HONK_FIREWALL_WAN_SECTION".target='REJECT'

	uci commit firewall || return 1
	/etc/init.d/firewall reload >/dev/null 2>&1 || :
	return 0
}

honk_firewall_remove() {
	command -v uci >/dev/null 2>&1 || return 0
	uci -q delete firewall."$HONK_FIREWALL_LAN_SECTION" >/dev/null 2>&1
	uci -q delete firewall."$HONK_FIREWALL_WAN_SECTION" >/dev/null 2>&1
	uci commit firewall || return 1
	/etc/init.d/firewall reload >/dev/null 2>&1 || :
	return 0
}

# The port the lan rule currently opens, empty when there is no rule.
honk_firewall_current_port() {
	command -v uci >/dev/null 2>&1 || return 1
	uci -q get "firewall.$HONK_FIREWALL_LAN_SECTION.dest_port" 2>/dev/null
}

# Apply the rule only when the open port differs, so that a rollback does not
# reload the firewall for nothing. Both rules are checked: the wan reject is
# part of the same boundary.
honk_firewall_sync() {
	sync_port=$(honk_firewall_port "$1") || return 1
	[ "$(honk_firewall_current_port)" = "$sync_port" ] && \
		[ "$(uci -q get "firewall.$HONK_FIREWALL_WAN_SECTION.dest_port" 2>/dev/null)" = "$sync_port" ] && return 0
	honk_firewall_apply "$sync_port"
}
