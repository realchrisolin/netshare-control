#!/usr/bin/env bash
# shellcheck source=harness.sh
source "$(dirname "$0")/harness.sh"
source_lib

if resolve_traffic_uid; then
  fail "missing uid was selected"
fi

out=$(expect_fail "uid 0" bash -c '
  source "'"$ROOT"'/test/harness.sh"
  source_lib
  NETSHARE_UID=0
  resolve_traffic_uid
')
[[ "$out" == *"non-root numeric uid"* ]] || fail "uid 0 message: $out"

out=$(expect_fail "uid text" bash -c '
  source "'"$ROOT"'/test/harness.sh"
  source_lib
  NETSHARE_UID=account
  resolve_traffic_uid
')
[[ "$out" == *"non-root numeric uid"* ]] || fail "text uid message: $out"

SUDO_UID=65534
resolve_traffic_uid || fail "sudo uid was not selected"
[[ "$desktop_uid" == "65534" ]] || fail "sudo uid value"

NETSHARE_UID=65533
SUDO_UID=65534
resolve_traffic_uid || fail "conf uid was not selected"
[[ "$desktop_uid" == "65533" ]] || fail "conf uid did not override sudo"

echo "ok traffic-uid"
