#!/usr/bin/env bash
# shellcheck source=harness.sh
source "$(dirname "$0")/harness.sh"
source_lib

ip() {
  printf '%s\n' "192.0.2.0/24 dev eth-test scope link"
}

hit_yes=$'eth-test\t192.0.2.20\t192.0.2.20/24\t192.0.2.0/24\thttp://192.0.2.1:8282\tssid-one\tyes\t200\tNS-TEST-One'
hit_no=$'wlan-test\t198.51.100.20\t198.51.100.20/24\t198.51.100.0/24\thttp://198.51.100.1:8282\tssid-two\tno\t000\tNS-TEST-Two'
hit_yes_b=$'wlan-test\t198.51.100.20\t198.51.100.20/24\t198.51.100.0/24\thttp://198.51.100.1:8282\tssid-two\tyes\t204\tNS-TEST-Two'

netshare_hits=("$hit_no")
rc=0
select_access_point || rc=$?
[[ "$rc" -eq 1 ]] || fail "no answer returned $rc"

netshare_hits=("$hit_yes" "$hit_yes_b")
rc=0
select_access_point || rc=$?
[[ "$rc" -eq 2 ]] || fail "two answers returned $rc"

netshare_hits=("$hit_yes" "$hit_no")
iface=""
src=""
PROXY_URL=""
ssid=""
select_access_point || fail "one answer was rejected"
[[ "$iface" == "eth-test" ]] || fail "iface $iface"
[[ "$src" == "192.0.2.20" ]] || fail "src $src"
[[ "$PROXY_URL" == "http://192.0.2.1:8282" ]] || fail "proxy $PROXY_URL"
[[ "$ssid" == "ssid-one" ]] || fail "ssid $ssid"
[[ "$PROXY_URL" != *"NS-TEST-One"* && "$PROXY_URL" != *200* ]] || fail "proxy absorbed a later field"

echo "ok select-access-point"
