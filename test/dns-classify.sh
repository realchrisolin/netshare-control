#!/usr/bin/env bash
# shellcheck source=harness.sh
source "$(dirname "$0")/harness.sh"
source_lib

ap=192.0.2.0/24

got=$(printf '%s\n' '1.1.1.1' | classify_resolved_address "$ap")
[[ "$got" == "1.1.1.1" ]] || fail "public address -> $got"

got=$(printf '%s\n' 'link: ns0' '1.1.1.1' '--' '198.18.0.1' | classify_resolved_address "$ap")
[[ "$got" == "1.1.1.1" ]] || fail "text after -- was kept: $got"

reject() {
  local label=$1
  local text=$2
  local rc
  set +e
  printf '%s\n' "$text" | classify_resolved_address "$ap" >/dev/null
  rc=$?
  set -e
  [[ "$rc" -eq 2 ]] || fail "$label exited $rc"
}

reject "virtual pool" "198.18.0.1"
reject "access-point address" "192.0.2.5"
reject "non-global" "10.1.1.1"

set +e
printf '%s\n' 'no address here' | classify_resolved_address "$ap" >/dev/null
rc=$?
set -e
[[ "$rc" -eq 1 ]] || fail "empty text exited $rc"

echo "ok dns-classify"
