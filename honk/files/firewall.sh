#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
#
# Keeps the native API port reachable from the lan zone and unreachable from
# every other zone. The core binds the API to every interface, so these rules
# are the boundary that keeps the management API off the wan.

HONK_FIREWALL_LAN_SECTION=honk_native_api_lan
HONK_FIREWALL_WAN_SECTION=honk_native_api_wan
HONK_FIREWALL_REJECT_PREFIX=honk_native_api_reject

honk_firewall_port() {
	case "$1" in
		''|*[!0-9]*) return 1 ;;
	esac
	[ "$1" -ge 1024 ] && [ "$1" -le 65535 ] || return 1
	printf '%s\n' "$1"
}

# The firewall zone a network belongs to, empty when the zone is unknown.
honk_firewall_network_zone() {
	fw_network=$1
	case "$fw_network" in ''|*[!A-Za-z0-9_.-]*) return 1 ;; esac
	for fw_entry in $(uci -q show firewall 2>/dev/null | sed -n "s/^firewall\.\([^.=]*\)\.network='\(.*\)'$/\1 \2/p"); do
		fw_name=${fw_entry%% *}
		fw_net=${fw_entry#* }
		[ "$fw_net" = "$fw_network" ] || continue
		printf '%s\n' "$fw_name"
		return 0
	done
	return 1
}

# The zone the management api may be reached in: the zone of the configured
# lan network. A lan network that lives in the wan zone keeps the default
# zone, because the api is never reachable from the wan.
honk_firewall_lan_zone() {
	fw_lan_network=$(uci -q get honk.main.lan_network 2>/dev/null)
	case "$fw_lan_network" in ''|*[!A-Za-z0-9_.-]*) fw_lan_network=lan ;; esac
	fw_zone=$(honk_firewall_network_zone "$fw_lan_network" 2>/dev/null) || fw_zone=
	[ -n "$fw_zone" ] && [ "$fw_zone" != wan ] || fw_zone=lan
	printf '%s\n' "$fw_zone"
}

# Every zone that carries a network.
honk_firewall_zones() {
	uci -q show firewall 2>/dev/null | sed -n "s/^firewall\.\([^.=]*\)\.network=.*/\1/p" | sort -u
}

honk_firewall_apply() {
	port=$(honk_firewall_port "$1") || return 1
	command -v uci >/dev/null 2>&1 || return 1

	# Remove the rules of an earlier run, including the ones for zones that
	# do not exist any more.
	for fw_section in $(uci -q show firewall 2>/dev/null | sed -n "s/^firewall\.\(honk_native_api[a-z0-9_]*\)=.*/\1/p"); do
		uci -q delete "firewall.$fw_section" >/dev/null 2>&1
	done

	lan_zone=$(honk_firewall_lan_zone)

	uci set firewall."$HONK_FIREWALL_LAN_SECTION"='rule'
	uci set firewall."$HONK_FIREWALL_LAN_SECTION".name='honk-native-api'
	uci set firewall."$HONK_FIREWALL_LAN_SECTION".src="$lan_zone"
	uci set firewall."$HONK_FIREWALL_LAN_SECTION".proto='tcp'
	uci set firewall."$HONK_FIREWALL_LAN_SECTION".dest_port="$port"
	uci set firewall."$HONK_FIREWALL_LAN_SECTION".target='ACCEPT'

	uci set firewall."$HONK_FIREWALL_WAN_SECTION"='rule'
	uci set firewall."$HONK_FIREWALL_WAN_SECTION".name='honk-native-api-wan'
	uci set firewall."$HONK_FIREWALL_WAN_SECTION".src='wan'
	uci set firewall."$HONK_FIREWALL_WAN_SECTION".proto='tcp'
	uci set firewall."$HONK_FIREWALL_WAN_SECTION".dest_port="$port"
	uci set firewall."$HONK_FIREWALL_WAN_SECTION".target='REJECT'

	# Every other zone rejects the port as well: the api belongs to the lan
	# only, not to whatever zone an operator happens to add.
	for fw_zone in $(honk_firewall_zones); do
		case "$fw_zone" in
			''|*[!A-Za-z0-9_]*) continue ;;
			"$lan_zone"|wan) continue ;;
		esac
		fw_section="${HONK_FIREWALL_REJECT_PREFIX}_$fw_zone"
		uci set firewall."$fw_section"='rule'
		uci set firewall."$fw_section".name="honk-native-api-reject-$fw_zone"
		uci set firewall."$fw_section".src="$fw_zone"
		uci set firewall."$fw_section".proto='tcp'
		uci set firewall."$fw_section".dest_port="$port"
		uci set firewall."$fw_section".target='REJECT'
	done

	uci commit firewall || return 1
	/etc/init.d/firewall reload >/dev/null 2>&1 || :
	return 0
}

honk_firewall_remove() {
	command -v uci >/dev/null 2>&1 || return 0
	for fw_section in $(uci -q show firewall 2>/dev/null | sed -n "s/^firewall\.\(honk_native_api[a-z0-9_]*\)=.*/\1/p"); do
		uci -q delete "firewall.$fw_section" >/dev/null 2>&1
	done
	uci commit firewall || return 1
	/etc/init.d/firewall reload >/dev/null 2>&1 || :
	return 0
}

# The port the lan rule currently opens, empty when there is no rule.
honk_firewall_current_port() {
	command -v uci >/dev/null 2>&1 || return 1
	uci -q get "firewall.$HONK_FIREWALL_LAN_SECTION.dest_port" 2>/dev/null
}

# Apply the rules only when the current state differs, so that a rollback does
# not reload the firewall for nothing. The lan rule's source zone matters as
# much as the port: settings/restore/reset can keep the same port while moving
# the network to another firewall zone, and a port-only comparison would leave
# the API open in the old zone and unreachable in the new one.
honk_firewall_sync() {
	sync_port=$(honk_firewall_port "$1") || return 1
	sync_lan_zone=$(honk_firewall_lan_zone 2>/dev/null) || sync_lan_zone=lan
	[ -n "$sync_lan_zone" ] || sync_lan_zone=lan
	if [ "$(honk_firewall_current_port)" != "$sync_port" ] || \
		[ "$(uci -q get "firewall.$HONK_FIREWALL_LAN_SECTION.src" 2>/dev/null)" != "$sync_lan_zone" ] || \
		[ "$(uci -q get "firewall.$HONK_FIREWALL_WAN_SECTION.dest_port" 2>/dev/null)" != "$sync_port" ]; then
		honk_firewall_apply "$sync_port"
		return $?
	fi
	# The reject rules for all other zones are part of the same boundary; a
	# zone that was added after the last apply must not stay open.
	for sync_zone in $(honk_firewall_zones); do
		case "$sync_zone" in
			''|*[!A-Za-z0-9_]*) continue ;;
			"$sync_lan_zone"|wan) continue ;;
		esac
		sync_section="${HONK_FIREWALL_REJECT_PREFIX}_$sync_zone"
		if [ "$(uci -q get "firewall.$sync_section.src" 2>/dev/null)" != "$sync_zone" ] || \
			[ "$(uci -q get "firewall.$sync_section.dest_port" 2>/dev/null)" != "$sync_port" ]; then
			honk_firewall_apply "$sync_port"
			return $?
		fi
	done
	return 0
}
