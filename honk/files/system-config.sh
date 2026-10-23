#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
#
# Helpers for the global.lan_interface list.
#
# The honk parser accepts a bare comma-separated list ("br-lan, ipsec0") and
# warns when each item is individually quoted. A single quoted device is still
# accepted. The package's managed templates used to assume exactly one quoted
# device; these helpers read the current list and keep it across rewrites.

# Print one normalized item per line, with surrounding whitespace and one pair
# of quotes removed. Returns non-zero when the setting is missing.
honk_lan_interface_items() {
	honk_iface_file=$1
	honk_iface_line=$(sed -n "s/^[[:space:]]*lan_interface:[[:space:]]*//p" "$honk_iface_file" 2>/dev/null | head -n 1)
	[ -n "$honk_iface_line" ] || return 1
	printf '%s\n' "$honk_iface_line" | tr ',' '\n' |
		sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
			-e "s/^'\(.*\)'$/\1/" -e 's/^"\(.*\)"$/\1/'
}

# Print the validated interface list as space-separated words. Returns non-zero
# when the setting is missing or contains an invalid device name.
honk_lan_interface_list() {
	honk_iface_file=$1
	honk_iface_items=
	for honk_iface_item in $(honk_lan_interface_items "$honk_iface_file"); do
		case "$honk_iface_item" in
			''|*[!A-Za-z0-9_.-]*) return 1 ;;
		esac
		honk_iface_items="${honk_iface_items:+$honk_iface_items }$honk_iface_item"
	done
	[ -n "$honk_iface_items" ] || return 1
	printf '%s\n' "$honk_iface_items"
}

# Render a comma-separated list for system.dae. A valid current list is kept;
# when it is missing or does not contain the managed device, the device alone
# is used.
honk_lan_interface_render() {
	honk_iface_file=$1
	honk_iface_device=$2
	honk_iface_list=$(honk_lan_interface_list "$honk_iface_file" 2>/dev/null) || honk_iface_list=
	case " $honk_iface_list " in
		*" $honk_iface_device "*) ;;
		*) honk_iface_list=$honk_iface_device ;;
	esac
	printf '%s\n' "$honk_iface_list" | sed 's/ /, /g'
}
