#!/usr/bin/env bash
# shellcheck source=harness.sh
source "$(dirname "$0")/harness.sh"
source_lib

DNS_SERVER_1=192.0.2.1
DNS_SERVER_2=192.0.2.2
RUN_DNS=$DNS_SERVER_1
text=$(runner_resolv_text)
[[ "$text" == $'nameserver 192.0.2.1\nnameserver 192.0.2.2\noptions timeout:8 attempts:1 single-request-reopen' ]] \
  || fail "default pair: ${text}"

RUN_DNS=192.0.2.9
text=$(runner_resolv_text)
[[ "$text" == $'nameserver 192.0.2.9\nnameserver 192.0.2.1\nnameserver 192.0.2.2\noptions timeout:8 attempts:1 single-request-reopen' ]] \
  || fail "custom first server: ${text}"

RUN_DNS=$DNS_SERVER_2
text=$(runner_resolv_text)
[[ "$text" == $'nameserver 192.0.2.2\nnameserver 192.0.2.1\noptions timeout:8 attempts:1 single-request-reopen' ]] \
  || fail "fallback first: ${text}"
[[ "$text" != *timeout:2* ]] || fail "old timeout remains"

echo "ok runner-resolv"
