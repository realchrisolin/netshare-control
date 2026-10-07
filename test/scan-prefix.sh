#!/usr/bin/env bash
# shellcheck source=harness.sh
source "$(dirname "$0")/harness.sh"
source_lib

grep -q '^  scan_access_points$' "$ROOT/lib/tunnel.sh" \
  || fail "up scan must not take a prefix"
grep -q 'scan_access_points "$CONNECTION_PREFIX"' "$ROOT/lib/bar.sh" \
  || fail "bar scan must take the connection prefix"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
probes=$tmp/probes
mkdir -p "$tmp/bin"
cat >"$tmp/bin/nmcli" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "-t" ]]; then
  printf '%s\n' \
    'eth-test:ethernet:connected' \
    'wlan-test:wifi:connected' \
    'ns0:tun:connected' \
    'lo:loopback:connected'
  exit 0
fi
if [[ "$1" == "-g" ]]; then
  printf '%s\n' '192.0.2.1'
  exit 0
fi
exit 0
EOF
cat >"$tmp/bin/ip" <<'EOF'
#!/usr/bin/env bash
dev=""
prev=""
for arg in "$@"; do
  if [[ "$prev" == "dev" ]]; then
    dev=$arg
  fi
  prev=$arg
done
case "$dev" in
  eth-test) printf '%s\n' '2: eth-test inet 192.0.2.20/24 scope global' ;;
  wlan-test) printf '%s\n' '3: wlan-test inet 198.51.100.20/24 scope global' ;;
esac
EOF
chmod 755 "$tmp/bin/nmcli" "$tmp/bin/ip"
export PATH="$tmp/bin:$PATH"

link_connection() {
  case "$1" in
    eth-test) printf '%s' 'NS-TEST-One' ;;
    wlan-test) printf '%s' 'OtherNet' ;;
  esac
}
on_link_cidr() {
  case "$1" in
    eth-test) printf '%s\n' '192.0.2.0/24' ;;
    wlan-test) printf '%s\n' '198.51.100.0/24' ;;
  esac
}
link_ssid() { printf '%s' "ssid-$1"; }
proxy_http_code() {
  printf '%s\n' "$1" >>"$probes"
  printf '200'
}

: >"$probes"
CONNECTION_PREFIX="NS-TEST-"
scan_access_points "$CONNECTION_PREFIX"
[[ "$(wc -l <"$probes")" -eq 1 ]] || fail "prefix probed $(wc -l <"$probes") links"
[[ "$(cat "$probes")" == "192.0.2.20" ]] || fail "prefix probed the wrong link"
[[ "${#netshare_hits[@]}" -eq 1 ]] || fail "prefix hits ${#netshare_hits[@]}"

: >"$probes"
scan_access_points
[[ "$(wc -l <"$probes")" -eq 2 ]] || fail "open scan probed $(wc -l <"$probes") links"
[[ "${#netshare_hits[@]}" -eq 2 ]] || fail "open hits ${#netshare_hits[@]}"

echo "ok scan-prefix"
