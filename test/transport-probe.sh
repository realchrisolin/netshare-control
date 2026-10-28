#!/usr/bin/env bash
# Gate 1 retries. Stubs stand in for the tun. This does not call up or down.
# shellcheck source=harness.sh
source "$(dirname "$0")/harness.sh"
source_lib

tmp=$(mktemp -d)
trap 'stop_dns; rm -rf "$tmp"' EXIT

stop_dns() {
  if [[ -f "$tmp/dns.pid" ]]; then
    kill "$(cat "$tmp/dns.pid")" 2>/dev/null || true
    wait "$(cat "$tmp/dns.pid")" 2>/dev/null || true
    rm -f "$tmp/dns.pid"
  fi
}

start_dns() {
  local mode=$1 portf=$tmp/port
  stop_dns
  rm -f "$portf"
  python3 - "$mode" "$portf" >>"$tmp/dns.log" 2>&1 <<'PY' &
import socket, struct, sys, time
mode, portf = sys.argv[1], sys.argv[2]

def enc(name):
    out = b''
    for part in name.rstrip('.').split('.'):
        raw = part.encode('ascii')
        out += bytes([len(raw)]) + raw
    return out + b'\x00'

def pack(flags, answers):
    qname = enc('example.com')
    header = struct.pack('!HHHHHH', 0xABCD, flags, 1, len(answers), 0, 0)
    question = qname + struct.pack('!HH', 1, 1)
    body = b''
    for typ, rdata in answers:
        body += b'\xc0\x0c' + struct.pack('!HHIH', typ, 1, 30, len(rdata)) + rdata
    return struct.pack('!H', len(header + question + body)) + header + question + body

def recvall(conn, n):
    buf = b''
    while len(buf) < n:
        chunk = conn.recv(n - len(buf))
        if not chunk:
            raise EOFError
        buf += chunk
    return buf

s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', 0))
s.listen(1)
with open(portf, 'w') as fh:
    fh.write(str(s.getsockname()[1]))
s.settimeout(5)
conn, _ = s.accept()
try:
    conn.settimeout(5)
    if mode == 'stall':
        time.sleep(4)
        raise SystemExit(0)
    ln = struct.unpack('!H', recvall(conn, 2))[0]
    recvall(conn, ln)
    if mode == 'a':
        payload = pack(0x8180, [(1, bytes((8, 8, 8, 8)))])
    elif mode == 'cname-a':
        payload = pack(0x8180, [(5, b'\x00'), (1, bytes((9, 9, 9, 9)))])
    elif mode == 'two-a':
        payload = pack(0x8180, [(1, bytes((1, 2, 3, 4))), (1, bytes((5, 6, 7, 8)))])
    elif mode == 'nx':
        payload = pack(0x8183, [])
    else:
        raise SystemExit(2)
    conn.sendall(payload)
finally:
    conn.close()
    s.close()
PY
  echo $! >"$tmp/dns.pid"
  local i
  for ((i = 0; i < 50; i++)); do
    [[ -s "$portf" ]] && break
    sleep 0.05
  done
  [[ -s "$portf" ]] || fail "dns listener did not start ($(cat "$tmp/dns.log" 2>/dev/null || true))"
  cat "$portf"
}

ask() {
  python3 -c "$DNS_A_QUERY" 127.0.0.1 example.com "$1" "$2"
}

port=$(start_dns a)
got=$(ask 2 "$port")
[[ "$got" == "8.8.8.8" ]] || fail "A record -> ${got}"
stop_dns

port=$(start_dns cname-a)
got=$(ask 2 "$port")
[[ "$got" == "9.9.9.9" ]] || fail "CNAME then A -> ${got}"
stop_dns

port=$(start_dns two-a)
got=$(ask 2 "$port")
[[ "$got" == "1.2.3.4" ]] || fail "first A -> ${got}"
stop_dns

port=$(start_dns nx)
set +e
ask 2 "$port" >/dev/null
rc=$?
set -e
[[ "$rc" -ne 0 ]] || fail "NXDOMAIN returned an address"
stop_dns

port=$(start_dns stall)
set +e
timeout 5 python3 -c "$DNS_A_QUERY" 127.0.0.1 example.com 1 "$port" >/dev/null
rc=$?
set -e
[[ "$rc" -ne 0 ]] || fail "stalled resolver returned an address"
[[ "$rc" -ne 124 ]] || fail "socket timeout did not fire"
stop_dns

closed=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
set +e
ask 1 "$closed" >/dev/null
rc=$?
set -e
[[ "$rc" -ne 0 ]] || fail "refused connection returned an address"

qlog=$tmp/qlog
dohlog=$tmp/dohlog
flog=$tmp/flog
answers=$tmp/answers
doh_answers=$tmp/doh_answers
fetch_answers=$tmp/fetch

# An empty answer file means this path did not answer. Lines are consumed
# in order. "fail" is an empty answer, same as a timeout.
query_doh() {
  printf '%s\n' "$1" >>"$dohlog"
  [[ -s "$doh_answers" ]] || return 1
  local line
  IFS= read -r line <"$doh_answers" || return 1
  tail -n +2 "$doh_answers" >"$doh_answers.next"
  mv "$doh_answers.next" "$doh_answers"
  [[ -n "$line" && "$line" != fail ]] || return 1
  printf '%s\n' "$line"
}

query_resolver() {
  printf '%s\n' "$1" >>"$qlog"
  local line
  IFS= read -r line <"$answers" || return 1
  tail -n +2 "$answers" >"$answers.next"
  mv "$answers.next" "$answers"
  [[ -n "$line" && "$line" != fail ]] || return 1
  printf '%s\n' "$line"
}

fetch_resolved_https() {
  printf '%s\n' "$1" >>"$flog"
  local line
  IFS= read -r line <"$fetch_answers" || return 1
  tail -n +2 "$fetch_answers" >"$fetch_answers.next"
  mv "$fetch_answers.next" "$fetch_answers"
  fetch_err=""
  case "$line" in
    ok:*)
      fetch_code=${line#ok:}
      return 0
      ;;
    err:*)
      fetch_code=${line#err:}
      fetch_err="stub failure"
      return 1
      ;;
    *)
      fetch_code=""
      return 1
      ;;
  esac
}

reset_probe() {
  : >"$qlog"
  : >"$dohlog"
  : >"$doh_answers"
  : >"$flog"
  BYPASS_CIDR=192.0.2.0/24
  DNS_SERVER_1=192.0.2.10
  DNS_SERVER_2=192.0.2.11
  RUN_DNS=$DNS_SERVER_1
  PROBE_ATTEMPTS=3
  PROBE_PAUSE=0
  probe_detail=""
  resolve_detail=""
}

run_probe() {
  set +e
  probe_marked_http
  rc=$?
  set -e
}

reset_probe
printf '%s\n' fail fail 8.8.8.8 >"$answers"
printf '%s\n' 'ok:200' >"$fetch_answers"
run_probe
[[ "$rc" -eq 0 ]] || fail "retry after DNS failure exited $rc ($probe_detail)"
[[ -z "$probe_detail" ]] || fail "success kept detail: $probe_detail"
[[ "$(cat "$qlog")" == $'192.0.2.10\n192.0.2.11\n192.0.2.10' ]] \
  || fail "query order: $(cat "$qlog")"
[[ "$(cat "$flog")" == "8.8.8.8" ]] || fail "fetch address: $(cat "$flog")"

# The first resolver's HTTPS query did not answer. The second did.
# Port 53 stays closed: a hung query there holds a session until the
# data plane exits, and it must not run ahead of the other HTTPS query.
reset_probe
printf '%s\n' fail 8.8.8.8 >"$doh_answers"
printf '%s\n' 'ok:200' >"$fetch_answers"
run_probe
[[ "$rc" -eq 0 ]] || fail "second HTTPS answer exited $rc ($probe_detail)"
[[ "$(cat "$dohlog")" == $'192.0.2.10\n192.0.2.11' ]] \
  || fail "HTTPS order: $(cat "$dohlog")"
[[ ! -s "$qlog" ]] || fail "TCP ran after HTTPS answered: $(cat "$qlog")"
[[ "$(cat "$flog")" == "8.8.8.8" ]] || fail "fetch used a TCP address: $(cat "$flog")"

reset_probe
printf '%s\n' 10.1.1.1 8.8.8.8 >"$answers"
printf '%s\n' 'ok:200' >"$fetch_answers"
run_probe
[[ "$rc" -eq 0 ]] || fail "private answer was kept ($probe_detail)"
[[ "$(cat "$flog")" == "8.8.8.8" ]] || fail "fetch used the private address: $(cat "$flog")"

reset_probe
printf '%s\n' 8.8.8.8 8.8.8.8 8.8.8.8 >"$answers"
printf '%s\n' 'ok:500' 'err:000' 'ok:200' >"$fetch_answers"
run_probe
[[ "$rc" -eq 0 ]] || fail "HTTPS retry exited $rc ($probe_detail)"
[[ "$(cat "$flog")" == $'8.8.8.8\n8.8.8.8\n8.8.8.8' ]] \
  || fail "fetch retries: $(cat "$flog")"

reset_probe
PROBE_ATTEMPTS=1
printf '%s\n' 10.1.1.1 192.0.2.5 >"$answers"
printf '%s\n' 'ok:200' >"$fetch_answers"
run_probe
[[ "$rc" -ne 0 ]] || fail "forbidden answers were accepted"
[[ ! -s "$flog" ]] || fail "fetch ran for a forbidden answer: $(cat "$flog")"
[[ "$probe_detail" == *"DNS"* ]] || fail "forbidden detail: $probe_detail"

reset_probe
printf '%s\n' fail fail fail fail fail fail >"$answers"
: >"$fetch_answers"
run_probe
[[ "$rc" -ne 0 ]] || fail "total DNS failure was accepted"
[[ "$probe_detail" == *"192.0.2.10"* && "$probe_detail" == *"192.0.2.11"* ]] \
  || fail "failure detail: $probe_detail"
[[ "$probe_detail" == *"after 3 attempts"* ]] || fail "attempt count missing: $probe_detail"
[[ ! -s "$flog" ]] || fail "fetch ran without a public address"

echo "ok transport-probe"
