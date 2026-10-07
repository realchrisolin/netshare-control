#!/usr/bin/env bash
# shellcheck source=harness.sh
source "$(dirname "$0")/harness.sh"
source_lib
# shellcheck source=../lib/bar.sh
source "$ROOT/lib/bar.sh"

tmp=$(mktemp -d)
plain=""
named=""
trap 'rm -rf "$tmp"; kill "$plain" "$named" 2>/dev/null || true' EXIT
STATE=$tmp/state

scan_access_points() {
  netshare_hits=(
    $'eth-test\t192.0.2.20\t192.0.2.20/24\t192.0.2.0/24\thttp://192.0.2.1:8282\tssid-one\tyes\t200\tNS-TEST-One'
  )
}
ip() {
  [[ "$1" == "link" && "$2" == "show" ]]
}

write_state_file() {
  local posture=$1
  local use_pid=$2
  cat >"$STATE" <<EOF
pid=${use_pid}
iface=eth-test
src=192.0.2.20
tun_addr=10.10.49.20/32
posture=${posture}
default_installed=1
proxy=http://192.0.2.1:8282
bypass=192.0.2.0/24
ssid=ssid-one
gateway=192.0.2.1
desktop_uid=65534
EOF
}

json_get() {
  /usr/bin/python3 -c '
import json, sys
data = json.loads(sys.stdin.read().strip().splitlines()[-1])
want = sys.argv[1]
if want == "keys":
    need = ["text", "tooltip", "class", "tunnel", "posture", "boundDevice", "boundProxy", "boundAddress", "tunAddr", "note", "links"]
    missing = [key for key in need if key not in data]
    if missing:
        raise SystemExit("missing " + ",".join(missing))
    print("keys")
elif want == "link":
    link = data["links"][0]
    need = ["device", "address", "ssid", "connection", "proxy", "answer", "code"]
    missing = [key for key in need if key not in link]
    if missing:
        raise SystemExit("link missing " + ",".join(missing))
    print("\t".join([
        data["tunnel"], data["posture"], data["class"],
        link["connection"], link["answer"], link["proxy"],
    ]))
else:
    print(data.get(want, ""))
' "$1"
}

sleep 30 &
plain=$!
bash -c 'exec -a tun2proxy sleep 30' &
named=$!
sleep 0.1

write_state_file desktop "$plain"
row=$(cmd_bar | json_get link)
[[ "$row" == $'stale\tdesktop\t\tNS-TEST-One\tyes\thttp://192.0.2.1:8282' ]] \
  || fail "plain pid row: $row"

write_state_file desktop "$named"
row=$(cmd_bar | json_get link)
[[ "$row" == $'up\tdesktop\tactive\tNS-TEST-One\tyes\thttp://192.0.2.1:8282' ]] \
  || fail "named pid row: $row"
cmd_bar | json_get keys >/dev/null

write_state_file side "$named"
row=$(cmd_bar | json_get link)
[[ "$row" == $'up\tside\tactive\tNS-TEST-One\tyes\thttp://192.0.2.1:8282' ]] \
  || fail "side row: $row"

rm -f "$STATE"
down=$(cmd_bar | json_get tunnel)
[[ "$down" == "down" ]] || fail "missing state was $down"

python3() { return 1; }
fallback=$(cmd_bar)
[[ "$fallback" == *'"tunnel":"down"'* && "$fallback" == *'"links":[]'* ]] \
  || fail "fallback $fallback"
unset -f python3

echo "ok bar-json"
