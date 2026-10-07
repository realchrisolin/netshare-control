#!/usr/bin/env bash
# shellcheck source=harness.sh
source "$(dirname "$0")/harness.sh"
source_lib

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

TUN2PROXY=$tmp/missing-tun2proxy
out=$(expect_fail "missing tun2proxy" check_config)
[[ "$out" == *"missing $tmp/missing-tun2proxy"* ]] || fail "tun2proxy message: $out"

printf '#!/bin/sh\nexit 0\n' >"$tmp/tun2proxy"
chmod 755 "$tmp/tun2proxy"
TUN2PROXY=$tmp/tun2proxy

out=$(
  command() {
    if [[ "$1" == "-v" && "$2" == "nft" ]]; then
      return 1
    fi
    builtin command "$@"
  }
  check_config 2>&1
) && fail "missing nft was accepted"
[[ "$out" == *"nft is required"* ]] || fail "nft message: $out"

out=$(
  command() {
    if [[ "$1" == "-v" && "$2" == "sudo" ]]; then
      return 1
    fi
    builtin command "$@"
  }
  require_root up 2>&1
) && fail "missing sudo was accepted"
[[ "$out" == *"sudo is required"* ]] || fail "sudo message: $out"

echo "ok check-config"
