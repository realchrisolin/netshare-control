#!/usr/bin/env bash
# shellcheck source=harness.sh
source "$(dirname "$0")/harness.sh"
source_lib

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
DNS_LINKS_FILE=$tmp/dns
printf '%s\n' $'eth-test\t192.0.2.1\texample.test ~routing.test' >"$DNS_LINKS_FILE"
BYPASS_CIDR=192.0.2.0/24

ip() {
  printf '%s\n' \
    '192.0.2.0/24 dev eth-test proto kernel scope link src 192.0.2.20' \
    '198.51.100.0/24 dev ns0 proto kernel scope link src 198.51.100.8' \
    '203.0.113.0/24 dev other0 proto kernel scope link src 203.0.113.10'
}

got=$(session_ignore_items)
has() { printf '%s\n' "$got" | grep -Fxq -- "$1" || fail "missing $1"; }
lacks() { printf '%s\n' "$got" | grep -Fxq -- "$1" && fail "kept $1" || true; }

has localhost
has '127.0.0.0/8'
has '::1'
has '203.0.113.0/24'
has '*.example.test'
has '.example.test'
lacks '192.0.2.0/24'
lacks '198.51.100.0/24'
lacks 'routing.test'
lacks '~routing.test'

echo "ok session-ignore"
