#!/usr/bin/env bash
# shellcheck source=harness.sh
source "$(dirname "$0")/harness.sh"
source_lib

pid=""
if pid_alive; then
  fail "empty pid was alive"
fi

sleep 30 &
plain=$!
bash -c 'exec -a tun2proxy sleep 30' &
named=$!
trap 'kill "$plain" "$named" 2>/dev/null || true' EXIT
sleep 0.1

pid=$plain
if pid_alive; then
  fail "a process whose command line is not tun2proxy was alive"
fi

pid=$named
pid_alive || fail "tun2proxy command line was not alive"

pid=$plain
kill "$plain"
wait "$plain" 2>/dev/null || true
plain=""
if pid_alive; then
  fail "exited pid was alive"
fi

echo "ok pid-alive"
