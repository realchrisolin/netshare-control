#!/usr/bin/env bash
# shellcheck source=harness.sh
source "$(dirname "$0")/harness.sh"
source_lib

TUN=nstest0
[[ "$(nm_unmanaged_rule)" == 'ACTION=="add", SUBSYSTEM=="net", KERNEL=="nstest0", ENV{NM_UNMANAGED}="1", ENV{ID_NET_MANAGED}="0"' ]] \
  || fail "rule: $(nm_unmanaged_rule)"

echo "ok nm-unmanaged"
