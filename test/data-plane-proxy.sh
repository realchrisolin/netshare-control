#!/usr/bin/env bash
# shellcheck source=harness.sh
source "$(dirname "$0")/harness.sh"
source_lib

got=$(data_plane_proxy "http://192.0.2.1:8282")
[[ "$got" == "socks5://192.0.2.1:8282" ]] || fail "plain: $got"

got=$(data_plane_proxy "http://192.0.2.1:8282/ignored")
[[ "$got" == "socks5://192.0.2.1:8282" ]] || fail "path: $got"

got=$(data_plane_proxy "http://192.0.2.1:8282?x=1")
[[ "$got" == "socks5://192.0.2.1:8282" ]] || fail "query: $got"

got=$(data_plane_proxy "socks5://192.0.2.1:9")
[[ "$got" == "socks5://192.0.2.1:9" ]] || fail "already socks5: $got"

got=$(data_plane_proxy "http://[2001:db8::1]:8282")
[[ "$got" == "socks5://[2001:db8::1]:8282" ]] || fail "ipv6: $got"

out=$(expect_fail "credentials" data_plane_proxy "http://user:secret@192.0.2.1:8282")
[[ "$out" == *"must not carry credentials"* ]] || fail "credentials message: $out"

out=$(expect_fail "scheme" data_plane_proxy "https://192.0.2.1:8282")
[[ "$out" == *"must start with http://"* ]] || fail "scheme message: $out"

out=$(expect_fail "no port" data_plane_proxy "http://192.0.2.1")
[[ "$out" == *"host and port"* ]] || fail "port message: $out"

echo "ok data-plane-proxy"
