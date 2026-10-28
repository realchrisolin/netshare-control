#!/usr/bin/env bash
# DNS over HTTPS, and the forwarder that speaks ordinary DNS in front of it.
# This does not call up or down.
# shellcheck source=harness.sh
source "$(dirname "$0")/harness.sh"
source_lib

command -v openssl >/dev/null 2>&1 || fail "openssl is required"

body=$(declare -f resolve_through_tun)
[[ "$body" == *query_doh* ]] || fail "lookup does not try HTTPS"
[[ "$body" == *query_resolver* ]] || fail "lookup dropped TCP DNS"
doh_at=$(declare -f resolve_through_tun | grep -n 'query_doh ' | head -1 | cut -d: -f1)
tcp_at=$(declare -f resolve_through_tun | grep -n 'query_resolver ' | head -1 | cut -d: -f1)
[[ -n "$doh_at" && -n "$tcp_at" && "$doh_at" -lt "$tcp_at" ]] \
  || fail "TCP DNS is attempted before HTTPS"

fwd=$(declare -f start_doh_forwarder)
[[ "$fwd" == *setsid* ]] || fail "forwarder stays in the up process group"
[[ "$fwd" == *'9>&-'* ]] || fail "forwarder inherits the lock"
[[ "$fwd" == *'doh-serve "$tun_ip" 53 "$RUN_USER"'* ]] || fail "forwarder does not drop to the tunnel user"
down=$(declare -f teardown)
[[ "$down" == *stop_doh_forwarder* ]] || fail "teardown leaves the forwarder"
dns=$(declare -f apply_tunnel_dns)
[[ "$dns" == *'resolvectl dns "$TUN" "$tun_ip"'* ]] || fail "resolved is not pointed at the forwarder"
[[ "$dns" == *'dnsovertls "$TUN" no'* ]] || fail "resolved still uses DNS-over-TLS toward the forwarder"

tmp=$(mktemp -d)
trap 'stop_all; rm -rf "$tmp"' EXIT

stop_all() {
  local pidfile
  for pidfile in "$tmp/up.pid" "$tmp/fwd.pid"; do
    [[ -f "$pidfile" ]] || continue
    kill "$(cat "$pidfile")" 2>/dev/null || true
    wait "$(cat "$pidfile")" 2>/dev/null || true
  done
}

openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$tmp/key.pem" -out "$tmp/cert.pem" -days 1 \
  -subj '/CN=cloudflare-dns.com' \
  -addext 'subjectAltName=DNS:cloudflare-dns.com' \
  >/dev/null 2>&1 || fail "could not mint a certificate"

python3 - "$tmp" <<'PY' &
import socket, struct, sys, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import ssl

tmp = sys.argv[1]

def enc(name):
    out = b''
    for part in name.rstrip('.').split('.'):
        raw = part.encode('ascii')
        out += bytes([len(raw)]) + raw
    return out + b'\x00'

def answer():
    qname = enc('example.com')
    header = struct.pack('!HHHHHH', 0xABCD, 0x8180, 1, 1, 0, 0)
    question = qname + struct.pack('!HH', 1, 1)
    body = b'\xc0\x0c' + struct.pack('!HHIH', 1, 1, 30, 4) + bytes((8, 8, 8, 8))
    return header + question + body

class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def do_POST(self):
        n = int(self.headers.get('Content-Length', '0'))
        self.rfile.read(n)
        payload = answer()
        self.send_response(200)
        self.send_header('Content-Type', 'application/dns-message')
        self.send_header('Content-Length', str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, fmt, *args):
        return

server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(tmp + '/cert.pem', tmp + '/key.pem')
server.socket = ctx.wrap_socket(server.socket, server_side=True)
port = server.server_address[1]
with open(tmp + '/up.port', 'w') as fh:
    fh.write(str(port))
server.serve_forever()
PY
echo $! >"$tmp/up.pid"

i=0
while [[ ! -s "$tmp/up.port" && "$i" -lt 50 ]]; do
  sleep 0.05
  i=$((i + 1))
done
[[ -s "$tmp/up.port" ]] || fail "upstream did not start"
port=$(cat "$tmp/up.port")

got=$(python3 -c "$DOH_PY" doh-query 127.0.0.1 example.com 2 "$tmp/cert.pem" "$port") \
  || fail "doh-query failed"
[[ "$got" == "8.8.8.8" ]] || fail "doh-query -> ${got}"

python3 -c "$DOH_PY" doh-serve 127.0.0.1 0 - "127.0.0.1" 2 "$tmp/cert.pem" "$port" \
  >"$tmp/fwd.ready" 2>"$tmp/fwd.log" &
echo $! >"$tmp/fwd.pid"
i=0
while [[ ! -s "$tmp/fwd.ready" && "$i" -lt 50 ]]; do
  if ! kill -0 "$(cat "$tmp/fwd.pid")" 2>/dev/null; then
    fail "forwarder exited ($(cat "$tmp/fwd.log" 2>/dev/null || true))"
  fi
  sleep 0.05
  i=$((i + 1))
done
[[ -s "$tmp/fwd.ready" ]] || fail "forwarder did not become ready ($(cat "$tmp/fwd.log" 2>/dev/null || true))"
read -r _ fwd_port <"$tmp/fwd.ready"
[[ "$fwd_port" =~ ^[0-9]+$ ]] || fail "forwarder port: $(cat "$tmp/fwd.ready")"

udp_got=$(python3 - "$fwd_port" <<'PY'
import socket, struct, sys
port = int(sys.argv[1])
qname = b'\x07example\x03com\x00'
msg = b'\xab\xcd\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00' + qname + b'\x00\x01\x00\x01'
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(3)
s.sendto(msg, ('127.0.0.1', port))
data, _ = s.recvfrom(4096)
# First A record, the same shape the forwarder was given.
if len(data) < 12:
    sys.exit(1)
# Walk to the first 4-byte A. The fixture answer is a pointer at the name.
idx = data.find(bytes((8, 8, 8, 8)))
if idx < 0:
    sys.exit(1)
sys.stdout.write('8.8.8.8\n')
PY
) || fail "udp query failed"
[[ "$udp_got" == "8.8.8.8" ]] || fail "forwarder -> ${udp_got}"

echo "ok doh"
