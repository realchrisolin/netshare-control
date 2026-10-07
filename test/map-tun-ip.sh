#!/usr/bin/env bash
# shellcheck source=harness.sh
source "$(dirname "$0")/harness.sh"
source_lib

got=$(map_tun_ip 192.168.49.20)
[[ "$got" == "10.10.49.20" ]] || fail "map 192.168.49.20 -> $got"

for bad in 192.168.49.1 10.1.2.3 10.0.0.33 192.168.49.020 not-an-address; do
  if map_tun_ip "$bad" >/dev/null 2>&1; then
    fail "accepted $bad"
  fi
done

echo "ok map-tun-ip"
