#!/usr/bin/env bash
# The gateway address can be local on another interface. Parsing and the
# rule order are checked here. This does not call up or down, and it does
# not change live rules.
# shellcheck source=harness.sh
source "$(dirname "$0")/harness.sh"
source_lib

holder=$(printf '%s\n' \
  '14: p2p0 inet 192.168.49.1/24 scope global' \
  '3: wlan0 inet 192.168.49.64/24 scope global' \
  | iface_holding_address 192.168.49.1)
[[ "$holder" == "p2p0" ]] || fail "holder: ${holder}"

same=$(printf '%s\n' '3: wlan0 inet 192.168.49.1/24 scope global' | iface_holding_address 192.168.49.1)
[[ "$same" == "wlan0" ]] || fail "same iface: ${same}"

other=$(printf '%s\n' '3: wlan0 inet 192.168.49.64/24 scope global' | iface_holding_address 192.168.49.1)
[[ -z "$other" ]] || fail "unrelated address matched: ${other}"

body=$(declare -f install_gateway_shadow)
before=${body%%ip rule del pref 0 from all lookup local*}
[[ "$before" == *'ip rule add pref 1 from all lookup local'* ]] || fail "local rule is not parked first"
[[ "$before" == *'ip rule add pref 0 to "$gateway" ipproto tcp dport "$PROXY_PORT" lookup "$GATEWAY_TABLE"'* ]] || fail "proxy port rule is not added before the local rule moves"
[[ "$body" == *'route_dev "$gateway")" != "lo"'* ]] || fail "install does not keep other ports local"
[[ "$(declare -f remove_gateway_shadow)" == *rollback_gateway_shadow* ]] || fail "down does not remove the shadow"
[[ "$(declare -f teardown)" == *remove_gateway_shadow* ]] || fail "teardown misses the shadow"
[[ "$(declare -f proxy_route_dev)" == *'dport "$PROXY_PORT"'* ]] || fail "proxy route ignores the port"
[[ "$(declare -f scan_access_points)" == *probe_restore_shadow* ]] || fail "scan leaves accept_local raised"

keep_foreign_bypass_host 192.0.2.50 p2p0 STALE wlan0 ns0 192.0.2.0/24 \
  || fail "foreign host was dropped"
if keep_foreign_bypass_host 192.0.2.50 wlan0 REACHABLE wlan0 ns0 192.0.2.0/24; then
  fail "phone-link neighbor was kept"
fi
if keep_foreign_bypass_host 192.0.2.50 p2p0 FAILED wlan0 ns0 192.0.2.0/24; then
  fail "failed neighbor was kept"
fi
if keep_foreign_bypass_host 198.51.100.9 p2p0 STALE wlan0 ns0 192.0.2.0/24; then
  fail "outside host was kept"
fi

echo "ok gateway-shadow"
