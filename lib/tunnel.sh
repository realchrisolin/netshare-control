#!/usr/bin/env bash
# netshare: give this host internet through a NetShare access point.
#
# The SSID is not an identity. NetShare (kha.prog.mikrotik) tells clients to
# use an HTTP proxy on the access point's DHCP gateway, port 8282. Any
# connected Wi-Fi or Ethernet link whose gateway answers there is eligible.
# The on-link subnet of that interface is the bypass, so the proxy session
# cannot loop into the tun.
#
# tun2proxy is the data plane. This script owns routes, the fwmark, and DNS.
# It never passes --setup: that flag assigns 10.0.0.33/24 and installs routes
# itself. The tun address is the one kha.prog.mikrotik.vpn builds. setAddress
# keeps the local address that starts with 192.168.49. and stores the literal
# 192.168.49.1 as the gateway. startVPN splits that local address and
# concatenates 10.10. with the last two octets. Builder.addAddress installs
# it with prefix 32 and setMtu(10000). excludeRoute
# keeps the 192.168.49.0/24 prefix on the radio. 198.18.0.0/15 is tun2proxy's
# virtual pool, not a resolver, and this script does not point systemd-resolved
# at it.
#
# The main-table default stays where NetworkManager put it. Desktop traffic
# reaches the tun through a later uid rule into table 849, which is the same
# shape as the watch (default via the tun, the access-point subnet thrown
# back to the radio). tun2proxy itself stays unmarked on the main table, so
# its proxy socket is sourced from the access-point address.
#
# DNS is Cloudflare's public resolvers, 1.1.1.1 and 1.0.0.1, with
# opportunistic DNS-over-TLS. Those two addresses get host routes into the tun
# before any desktop rule exists. ns0's routing domain "~." keeps global
# lookups on the tun. Other links stay DNS default routes so NetworkManager
# can still resolve a name on that interface. If the lookup does not return a
# public address, up removes what it added and leaves the built-in resolver
# in place.
#
# The watch Wi-Fi network uses a static HTTP proxy, 192.168.49.1 port 8282,
# with an empty exclusion list. tun2proxy uses that same proxy. While the
# desktop rule is installed, the session proxy is set to the same host and
# port. libproxy on Hyprland does not read the GNOME proxy settings, so the
# same values are also written to /etc/sysconfig/proxy and to the desktop
# user's activation environment. Localhost and the other on-link LANs stay
# direct; the watch has no second network to protect.
#
# Tailscale installs "from all lookup 52" at priority 5270. The fwmark rule
# and the netshare user's uid rule are pinned below 5210. nft sets the mark
# in the output hook, which is after the kernel has chosen a source address,
# so the mark alone still uses the main-table source. Without a main default
# that source does not exist and the probe fails before a packet reaches the
# tun. The uid rule is what selects 10.10.x.x. The desktop uid rule is pinned
# at 5300 so a Tailscale prefix in table 52 still wins.
#
# rp_filter is strict (net.ipv4.conf.all.rp_filter=1). The per-interface
# value cannot go below all. src_valid_mark is on, so packets arriving on
# the tun are marked before routing and the reverse lookup uses table 849.
# Without --setup, tun2proxy creates the device and leaves it down, with
# no address. This script brings that link up and assigns only the /32.

set -euo pipefail

# This file is the tunnel library. The console command sources it.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  echo "netshare: this file is a library; run netshare" >&2
  exit 1
fi

# Empty PROXY_URL, BYPASS_CIDR, and IFACE mean "discover". A root-owned
# /etc/netshare.conf may pin them. The SSID is never a selection key.
PROXY_PORT="8282"
PROXY_URL=""
BYPASS_CIDR=""
IFACE=""
TUN="ns0"
TABLE="849"
MARK="0x849"
RULE_PREF="5000"
# uid rule for the netshare runner. Ahead of Tailscale, and distinct from
# the fwmark rule so deletion of one does not remove the other.
RUNNER_RULE_PREF="5010"
# After Tailscale's lookup-52 rule at 5270, and before main at 32766.
DESKTOP_RULE_PREF="5300"
TUN_MTU="10000"
VIRTUAL_CIDR="198.18.0.0/15"
# Cloudflare public resolvers. RUN_DNS is what `netshare run` queries over TCP.
DNS_SERVER_1="1.1.1.1"
DNS_SERVER_2="1.0.0.1"
# Public address used only for route lookups. It must not be either DNS
# server: those have host routes into the tun before the desktop rule exists.
ROUTE_PROBE="9.9.9.9"
# vpn.setAddress stores this literal gateway. The client address has to
# start with the same prefix and be a different host.
NETSHARE_PREFIX="192.168.49."
NETSHARE_GATEWAY="192.168.49.1"
RUN_DNS="$DNS_SERVER_1"
RUN_USER="netshare"
# Tool mark drawn in the bar. Not a network identity.
BAR_ICON=$'\uf0ec'
# Empty lists every link the proxy probe accepted. A root-owned
# /etc/netshare.conf may set a NetworkManager connection-name prefix.
# Only `bar` uses it. `up` still considers every connected link.
CONNECTION_PREFIX=""
TUN2PROXY="${TUN2PROXY:-/usr/local/bin/tun2proxy}"
RUN_DIR="/run/netshare"
ETC_DIR="/etc/netshare"
LOG_DIR="/var/log/netshare"
STATE="${RUN_DIR}/state"
LOG="${LOG_DIR}/tun2proxy.log"
CONF="/etc/netshare.conf"
DNS_LINKS_FILE="${RUN_DIR}/dns-links"
SESSION_PROXY_FILE="${RUN_DIR}/session-proxy"
SESSION_ENV_FILE="${RUN_DIR}/session-env"
# libproxy's GNOME plugin stays disabled unless XDG_CURRENT_DESKTOP contains
# GNOME, MATE, Pantheon, or Cinnamon. This file is the plugin it does read.
SYSCONFIG_PROXY="/etc/sysconfig/proxy"

if [[ -f "$CONF" ]]; then
  conf_owner=$(stat -c %u "$CONF")
  if [[ "$conf_owner" -ne 0 ]]; then
    echo "netshare: refusing to read $CONF (not owned by root)" >&2
    exit 1
  fi
  # shellcheck disable=SC1090
  source "$CONF"
fi

SCRIPT=$(readlink -f "$0")
pid=""
iface=""
src=""
tun_addr=""
posture=""
default_installed=0
ssid=""
gateway=""
state_proxy=""
state_ssid=""
state_bypass=""
state_gateway=""
desktop_uid=""
tun_ip=""

die() {
  echo "netshare: $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
usage: netshare <command>

  up               start the tun from the console
  down             stop the tun and restore the resolver this tool saved
  status           show the tun and which link answered the proxy probe
  bar              print one panel object from a live lookup
  toggle           bring the tun up, or down if it is already up
  run CMD...       run CMD through the tun as the netshare user
  default on|off   install or remove one account's uid rule and tun DNS

`up` leaves the main-table default in place. The access point is chosen by
its gateway proxy, not by SSID. sudo, or NETSHARE_UID in the root-owned
conf, selects the account whose traffic then uses the tun. With neither,
the tun stays up for `netshare run` and the host resolver is left as it was.
A cached sudo ticket is reused. A terminal asks for the password there.
With no terminal, sudo opens a desktop password dialog. `bar` does not
change routes. It is the readout for an optional panel.
EOF
}

load_state() {
  pid=""
  iface=""
  src=""
  tun_addr=""
  posture=""
  default_installed=0
  state_proxy=""
  state_ssid=""
  state_bypass=""
  state_gateway=""
  desktop_uid=""
  tun_ip=""
  [[ -f "$STATE" ]] || return 1
  local line key value
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == *=* ]] || continue
    key=${line%%=*}
    value=${line#*=}
    case "$key" in
      pid) pid=$value ;;
      iface) iface=$value ;;
      src) src=$value ;;
      tun_addr) tun_addr=$value ;;
      posture) posture=$value ;;
      default_installed) default_installed=$value ;;
      proxy) state_proxy=$value ;;
      ssid) state_ssid=$value ;;
      bypass) state_bypass=$value ;;
      gateway) state_gateway=$value ;;
      desktop_uid) desktop_uid=$value ;;
    esac
  done <"$STATE"
  tun_ip=${tun_addr%%/*}
  if [[ ! "$tun_ip" =~ ^[0-9]+(\.[0-9]+){3}$ ]]; then
    tun_ip=""
  fi
}

write_state() {
  install -d -m 0755 "$RUN_DIR"
  local tmp="${STATE}.tmp"
  ssid=${ssid//$'\n'/}
  ssid=${ssid//$'\r'/}
  {
    printf 'pid=%s\n' "$pid"
    printf 'iface=%s\n' "$iface"
    printf 'src=%s\n' "$src"
    printf 'tun_addr=%s\n' "$tun_addr"
    printf 'posture=%s\n' "$posture"
    printf 'default_installed=%s\n' "$default_installed"
    printf 'proxy=%s\n' "$PROXY_URL"
    printf 'bypass=%s\n' "$BYPASS_CIDR"
    printf 'ssid=%s\n' "$ssid"
    printf 'gateway=%s\n' "$gateway"
    printf 'desktop_uid=%s\n' "$desktop_uid"
  } >"$tmp"
  chmod 0644 "$tmp"
  mv "$tmp" "$STATE"
}

pid_alive() {
  # tun2proxy is root-owned. An unprivileged status check cannot signal it:
  # kill -0 exits non-zero with "Operation not permitted" even while the
  # process is running, which made the bar draw the tunnel as down and a
  # later toggle shut it off. A readable command line is the identity check.
  # EPERM with no readable command line still means the pid exists.
  local cmd err
  [[ -n "${pid}" && "${pid}" =~ ^[0-9]+$ ]] || return 1
  if [[ -r "/proc/${pid}/cmdline" ]]; then
    cmd=$(tr '\0' ' ' <"/proc/${pid}/cmdline" 2>/dev/null || true)
    if [[ "$cmd" == *tun2proxy* ]]; then
      return 0
    fi
    if [[ -n "$cmd" ]]; then
      return 1
    fi
  fi
  err=$(kill -0 "$pid" 2>&1 || true)
  if [[ -z "$err" ]]; then
    return 0
  fi
  [[ "$err" == *"not permitted"* ]]
}

# A cached sudo ticket is reused. Otherwise a terminal asks on that terminal.
# NETSHARE_PROMPT=desktop, and any caller with no terminal, asks through a
# desktop dialog. sudo -A refreshes the same ticket, so the next call within
# the timestamp window does not ask again. sudo -n is only the cached path:
# it never prompts, and a missing ticket used to fail the bar switch.
SUDO_PROMPT='Password required for netshare: '
ASKPASS_HELPER=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/askpass.sh
PINENTRY_CANDIDATES=(
  pinentry-qt
  pinentry-gnome3
)

exec_sudo() {
  exec "$@"
}

sudo_cached() {
  sudo -n true >/dev/null 2>&1
}

have_controlling_tty() {
  local fd
  if { exec {fd}<>/dev/tty; } 2>/dev/null; then
    exec {fd}>&-
    return 0
  fi
  return 1
}

pinentry_program() {
  local name candidate
  if [[ -n "${NETSHARE_PINENTRY:-}" && -x "$NETSHARE_PINENTRY" ]]; then
    printf '%s\n' "$NETSHARE_PINENTRY"
    return 0
  fi
  for name in "${PINENTRY_CANDIDATES[@]}"; do
    if [[ "$name" == /* ]]; then
      candidate=$name
    else
      candidate=$(command -v "$name" 2>/dev/null || true)
    fi
    if [[ -n "$candidate" && -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

askpass_program() {
  if [[ -n "${SUDO_ASKPASS:-}" && -x "$SUDO_ASKPASS" ]]; then
    printf '%s\n' "$SUDO_ASKPASS"
    return 0
  fi
  if [[ -x "$ASKPASS_HELPER" ]] && pinentry_program >/dev/null; then
    printf '%s\n' "$ASKPASS_HELPER"
    return 0
  fi
  return 1
}

elevate_mode() {
  local mode_prompt=${NETSHARE_PROMPT:-}
  if [[ "$(id -u)" -eq 0 ]]; then
    printf '%s\n' root
    return 0
  fi
  if sudo_cached; then
    printf '%s\n' cached
    return 0
  fi
  case "$mode_prompt" in
    desktop)
      if askpass_program >/dev/null; then
        printf '%s\n' askpass
        return 0
      fi
      printf '%s\n' none
      return 1
      ;;
    terminal)
      if have_controlling_tty; then
        printf '%s\n' terminal
        return 0
      fi
      printf '%s\n' none
      return 1
      ;;
  esac
  if have_controlling_tty; then
    printf '%s\n' terminal
    return 0
  fi
  if askpass_program >/dev/null; then
    printf '%s\n' askpass
    return 0
  fi
  printf '%s\n' none
  return 1
}

require_root() {
  local mode helper
  if [[ "$(id -u)" -eq 0 ]]; then
    return 0
  fi
  command -v sudo >/dev/null 2>&1 || die "sudo is required"
  mode=$(elevate_mode) || true
  case "$mode" in
    cached)
      exec_sudo sudo -n "$SCRIPT" "$@"
      ;;
    terminal)
      exec_sudo sudo -p "$SUDO_PROMPT" "$SCRIPT" "$@"
      ;;
    askpass)
      helper=$(askpass_program) || die "a sudo password is required and no desktop prompt is available"
      SUDO_ASKPASS=$helper exec_sudo sudo -A -p "$SUDO_PROMPT" "$SCRIPT" "$@"
      ;;
    *)
      die "a sudo password is required and there is no terminal or desktop prompt"
      ;;
  esac
}

lock() {
  install -d -m 0755 "$RUN_DIR"
  exec 9>"${RUN_DIR}/lock"
  flock 9
}

unlock_fd() {
  exec 9>&-
}

teardown() {
  set +e
  # Resolver first, then the routes that would still steer lookups into the tun.
  # None of this needs the access-point interface to still exist.
  restore_session_proxy
  restore_dns
  delete_dns_host_routes
  delete_desktop_rules
  nft delete table ip netshare >/dev/null 2>&1
  nft delete table ip6 netshare >/dev/null 2>&1
  while ip rule del pref "$RULE_PREF" >/dev/null 2>&1; do
    :
  done
  while ip rule del pref "$RUNNER_RULE_PREF" >/dev/null 2>&1; do
    :
  done
  ip route del 0.0.0.0/1 dev "$TUN" >/dev/null 2>&1
  ip route del 128.0.0.0/1 dev "$TUN" >/dev/null 2>&1
  ip route del "$VIRTUAL_CIDR" dev "$TUN" >/dev/null 2>&1
  if [[ -z "${pid}" && -f "${RUN_DIR}/pid" ]]; then
    pid=$(<"${RUN_DIR}/pid")
  fi
  if pid_alive; then
    kill -INT "$pid" >/dev/null 2>&1
    local _
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
      pid_alive || break
      sleep 0.2
    done
    if pid_alive; then
      kill -KILL "$pid" >/dev/null 2>&1
    fi
  fi
  ip link del "$TUN" >/dev/null 2>&1
  ip route flush table "$TABLE" >/dev/null 2>&1
  ip -6 route flush table "$TABLE" >/dev/null 2>&1
  rm -f "$STATE" "${RUN_DIR}/pid"
}

fail_up() {
  echo "netshare: $*" >&2
  trap - ERR INT TERM
  teardown
  exit 1
}

on_up_err() {
  local status=$?
  trap - ERR INT TERM
  echo "netshare: up failed" >&2
  if [[ -f "$LOG" ]]; then
    tail -n 40 "$LOG" >&2 || true
  fi
  teardown
  exit "$status"
}

on_up_signal() {
  trap - ERR INT TERM
  echo "netshare: up interrupted" >&2
  teardown
  exit 130
}

ensure_user() {
  if ! id -u "$RUN_USER" >/dev/null 2>&1; then
    useradd --system --no-create-home --user-group \
      --shell /usr/bin/nologin \
      --comment "netshare tunnel runner" \
      "$RUN_USER"
  fi
}

ensure_etc() {
  install -d -m 0755 "$ETC_DIR"
  cat >"${ETC_DIR}/resolv.conf" <<EOF
nameserver ${RUN_DNS}
options timeout:2 attempts:2 single-request-reopen
EOF
  cat >"${ETC_DIR}/nsswitch.conf" <<'EOF'
passwd: files
group: files
shadow: files
hosts: files dns
networks: files
protocols: files
services: files
ethers: files
rpc: files
EOF
  chmod 0644 "${ETC_DIR}/resolv.conf" "${ETC_DIR}/nsswitch.conf"
}

check_policy() {
  local mark_num=$((MARK))
  if (( (mark_num & 0xff0000) != 0 )); then
    die "mark ${MARK} overlaps the Tailscale fwmark mask 0xff0000"
  fi
  if (( RULE_PREF >= 5210 )); then
    die "rule priority ${RULE_PREF} is not ahead of Tailscale priority 5210"
  fi
  if (( RUNNER_RULE_PREF <= RULE_PREF || RUNNER_RULE_PREF >= 5210 )); then
    die "runner rule priority ${RUNNER_RULE_PREF} must sit between ${RULE_PREF} and Tailscale priority 5210"
  fi
  if (( DESKTOP_RULE_PREF <= 5270 || DESKTOP_RULE_PREF >= 32766 )); then
    die "desktop rule priority ${DESKTOP_RULE_PREF} must follow Tailscale priority 5270"
  fi
  if [[ -n "$PROXY_URL" ]]; then
    [[ "$PROXY_URL" == http://* ]] || die "PROXY_URL must start with http://"
    [[ "$PROXY_URL" != *@* ]] || die "PROXY_URL must not carry credentials"
  fi
}

check_config() {
  local cmd
  check_policy
  [[ -x "$TUN2PROXY" ]] || die "missing ${TUN2PROXY}"
  for cmd in python3 nmcli curl resolvectl ip nft flock setpriv; do
    command -v "$cmd" >/dev/null 2>&1 || die "${cmd} is required"
  done
}

link_ssid() {
  local dev=$1
  iw dev "$dev" link 2>/dev/null | sed -n 's/^[[:space:]]*SSID: //p' | head -n 1
}

link_connection() {
  local dev=$1 name
  name=$(nmcli -g GENERAL.CONNECTION device show "$dev" 2>/dev/null | head -n 1 || true)
  name=${name//$'\t'/ }
  printf '%s' "$name"
}

dhcp_router() {
  local dev=$1
  nmcli -f DHCP4.OPTION device show "$dev" 2>/dev/null \
    | sed -n 's/^DHCP4.OPTION\[[0-9]*\]:routers = //p' \
    | head -n 1
}

on_link_cidr() {
  local dev=$1 local_src=$2
  ip -4 route show dev "$dev" scope link | awk -v src="$local_src" '{
    for (i = 1; i <= NF; i++) if ($i == "src" && $(i + 1) == src) { print $1; exit }
  }'
}

proxy_http_code() {
  local src_addr=$1 proxy_url=$2 code
  if code=$(curl -sS -o /dev/null -w '%{http_code}' \
      --interface "$src_addr" \
      --proxy "$proxy_url" \
      --connect-timeout 2 --max-time 5 \
      https://example.com 2>/dev/null); then
    printf '%s' "$code"
  else
    printf 'fail'
  fi
}

# Fill netshare_hits with one tab-separated record per connected link:
# dev, src, address, bypass, proxy url, ssid, result, http code, connection.
# result is "yes" when that link's gateway proxy returned an HTTP status.
# connection is set only when a name prefix was passed. `up` leaves it empty.
scan_access_points() {
  netshare_hits=()
  # An optional connection-name prefix skips every other interface before
  # the proxy probe. `up` passes none, so it still considers every link.
  local name_prefix=${1:-}
  local dev type state cidr local_src gw bypass url code ssid conn want_host line
  want_host=""
  if [[ -n "$PROXY_URL" ]]; then
    want_host=${PROXY_URL#http://}
    want_host=${want_host%%/*}
    want_host=${want_host%%:*}
  fi
  while IFS=: read -r dev type state; do
    [[ "$state" == connected* ]] || continue
    [[ "$type" == "wifi" || "$type" == "ethernet" ]] || continue
    [[ -n "$IFACE" && "$dev" != "$IFACE" ]] && continue
    [[ "$dev" == "$TUN" ]] && continue
    conn=""
    if [[ -n "$name_prefix" ]]; then
      conn=$(link_connection "$dev")
      [[ "$conn" == "$name_prefix"* ]] || continue
    fi
    cidr=$(ip -4 -o addr show dev "$dev" scope global 2>/dev/null | awk '{ print $4; exit }')
    [[ -n "$cidr" ]] || continue
    local_src=${cidr%%/*}
    gw=$(nmcli -g IP4.GATEWAY device show "$dev" 2>/dev/null | head -n 1 || true)
    if [[ -z "$gw" ]]; then
      gw=$(dhcp_router "$dev" || true)
    fi
    if [[ -z "$gw" ]]; then
      gw=$(python3 -c 'import ipaddress, sys
iface = ipaddress.ip_interface(sys.argv[1])
print(next(iface.network.hosts()))' "$cidr" 2>/dev/null || true)
    fi
    [[ -n "$gw" && "$gw" != "$local_src" ]] || continue
    if [[ -n "$want_host" && "$gw" != "$want_host" ]]; then
      continue
    fi
    bypass=$(on_link_cidr "$dev" "$local_src")
    [[ -n "$bypass" ]] || continue
    if [[ -n "$BYPASS_CIDR" && "$bypass" != "$BYPASS_CIDR" ]]; then
      continue
    fi
    if [[ -n "$PROXY_URL" ]]; then
      url=$PROXY_URL
    else
      url="http://${gw}:${PROXY_PORT}"
    fi
    ssid=$(link_ssid "$dev" || true)
    ssid=${ssid//$'\t'/ }
    code=$(proxy_http_code "$local_src" "$url")
    if [[ "$code" =~ ^[23][0-9][0-9]$ ]]; then
      line="yes"
    else
      line="no"
    fi
    netshare_hits+=("${dev}"$'\t'"${local_src}"$'\t'"${cidr}"$'\t'"${bypass}"$'\t'"${url}"$'\t'"${ssid}"$'\t'"${line}"$'\t'"${code}"$'\t'"${conn}")
  done < <(nmcli -t -f DEVICE,TYPE,STATE device status)
}

select_access_point() {
  local hit dev local_src bypass url name answer count=0 chosen=""
  for hit in "${netshare_hits[@]}"; do
    IFS=$'\t' read -r dev local_src _ bypass url name answer _ _ <<<"$hit"
    if [[ "$answer" == "yes" ]]; then
      count=$((count + 1))
      chosen=$hit
    fi
  done
  if (( count == 0 )); then
    return 1
  fi
  if (( count > 1 )); then
    return 2
  fi
  IFS=$'\t' read -r iface src _ BYPASS_CIDR PROXY_URL ssid _ _ _ <<<"$chosen"
  gateway=${PROXY_URL#http://}
  gateway=${gateway%%/*}
  gateway=${gateway%%:*}
  python3 -c '
import ipaddress, sys
src, net, host = sys.argv[1:]
network = ipaddress.ip_network(net, strict=False)
ok = ipaddress.ip_address(src) in network and ipaddress.ip_address(host) in network
sys.exit(0 if ok else 1)
' "$src" "$BYPASS_CIDR" "$gateway" \
    || die "proxy ${gateway} is outside ${BYPASS_CIDR} on ${iface}"
  if ! ip -4 route show "$BYPASS_CIDR" | grep -q "dev ${iface}\\b"; then
    die "no on-link route for ${BYPASS_CIDR} on ${iface}"
  fi
}

format_access_points() {
  local hit dev local_src cidr bypass url name answer code
  if ((${#netshare_hits[@]} == 0)); then
    echo "access-point: none"
    return
  fi
  echo "access-point:"
  for hit in "${netshare_hits[@]}"; do
    IFS=$'\t' read -r dev local_src cidr bypass url name answer code _ <<<"$hit"
    printf '  %s %s proxy %s %s' "$dev" "$cidr" "$url" "$answer"
    if [[ "$answer" == "yes" ]]; then
      printf ' (%s)' "$code"
    fi
    if [[ -n "$name" ]]; then
      printf ' ssid %s' "$name"
    fi
    printf '\n'
  done
}

find_netshare() {
  scan_access_points
  local rc=0
  select_access_point || rc=$?
  if (( rc == 1 )); then
    format_access_points >&2
    die "no NetShare proxy answered on a connected link"
  fi
  if (( rc == 2 )); then
    format_access_points >&2
    die "more than one NetShare proxy answered; set IFACE in ${CONF}"
  fi
}

half_routes_present() {
  ip -4 route show | grep -q "^0\\.0\\.0\\.0/1 dev ${TUN}\\b"
}

# stdin is resolvectl query text. $1 is the access-point prefix.
# Prints one public IPv4 address, or exits 2 for a forbidden address and
# 1 when none was found. Text after the first "--" is ignored.
classify_resolved_address() {
  python3 -c '
import ipaddress, sys
text = sys.stdin.read().split("--", 1)[0]
ap = ipaddress.ip_network(sys.argv[1], strict=False)
virtual = ipaddress.ip_network("198.18.0.0/15")
found = []
for token in text.replace(",", " ").replace("(", " ").replace(")", " ").split():
    token = token.strip(".")
    try:
        ip = ipaddress.ip_address(token)
    except ValueError:
        continue
    if ip.version != 4:
        continue
    if (not ip.is_global) or ip in virtual or ip in ap:
        sys.exit(2)
    found.append(str(ip))
if not found:
    sys.exit(1)
print(found[0])
' "$1"
}

# vpn.startVPN: split the 192.168.49 client address and build
# "10.10." + octet[2] + "." + octet[3]. 192.168.49.1 is the gateway
# literal, not a client address. 10.0.0.33 is tun2proxy --setup.
map_tun_ip() {
  python3 -c '
import sys
addr = sys.argv[1]
prefix = sys.argv[2]
gateway = sys.argv[3]
if not addr.startswith(prefix) or addr == gateway:
    sys.exit(1)
parts = addr.split(".")
if len(parts) != 4:
    sys.exit(1)
try:
    nums = [int(p) for p in parts]
except ValueError:
    sys.exit(1)
if any(n < 0 or n > 255 for n in nums):
    sys.exit(1)
if [str(n) for n in nums] != parts:
    sys.exit(1)
print("10.10.%d.%d" % (nums[2], nums[3]))
' "$1" "$NETSHARE_PREFIX" "$NETSHARE_GATEWAY"
}

delete_dns_host_routes() {
  ip route del "${DNS_SERVER_1}/32" dev "$TUN" >/dev/null 2>&1 || true
  ip route del "${DNS_SERVER_2}/32" dev "$TUN" >/dev/null 2>&1 || true
}

install_dns_host_routes() {
  [[ -n "$tun_ip" ]] || return 1
  ip route replace "${DNS_SERVER_1}/32" dev "$TUN" src "$tun_ip" || return 1
  ip route replace "${DNS_SERVER_2}/32" dev "$TUN" src "$tun_ip" || return 1
}

delete_desktop_rules() {
  while ip rule del pref "$DESKTOP_RULE_PREF" >/dev/null 2>&1; do
    :
  done
  while ip -6 rule del pref "$DESKTOP_RULE_PREF" >/dev/null 2>&1; do
    :
  done
  ip -6 route del unreachable default table "$TABLE" >/dev/null 2>&1 || true
}

# Throw every other on-link prefix so a lookup in table 849 falls through
# to the main table. The access-point subnet stays as a real route, and
# the tun /32 is not thrown.
install_throws() {
  local line prefix
  while IFS= read -r line; do
    [[ "$line" == *" dev ${TUN} "* || "$line" == *" dev ${TUN}" ]] && continue
    prefix=${line%% *}
    [[ "$prefix" == */* ]] || continue
    [[ "$prefix" == "$BYPASS_CIDR" ]] && continue
    ip route replace table "$TABLE" throw "$prefix" || return 1
  done < <(ip -4 route show table main scope link)
}

link_has_ipv4() {
  ip -4 addr show dev "$1" 2>/dev/null | grep -q '[[:space:]]inet '
}

# The runner's own lookup. nft's output mark is applied after source
# selection, so without this rule a missing main default makes connect()
# fail with "network unreachable" and the packet never enters the tun.
install_runner_rule() {
  local uid
  uid=$(id -u "$RUN_USER")
  [[ "$uid" =~ ^[0-9]+$ && "$uid" != "0" ]] || return 1
  if ip rule show pref "$RUNNER_RULE_PREF" | grep -q .; then
    ip rule show pref "$RUNNER_RULE_PREF" | grep -q "uidrange ${uid}-${uid} lookup ${TABLE}" || return 1
  else
    ip rule add pref "$RUNNER_RULE_PREF" uidrange "${uid}-${uid}" lookup "$TABLE" || return 1
  fi
}

install_desktop_rules() {
  [[ "$desktop_uid" =~ ^[0-9]+$ && "$desktop_uid" != "0" ]] || return 1
  if ip rule show pref "$DESKTOP_RULE_PREF" | grep -q .; then
    ip rule show pref "$DESKTOP_RULE_PREF" | grep -q "uidrange ${desktop_uid}-${desktop_uid} lookup ${TABLE}" || return 1
  else
    ip rule add pref "$DESKTOP_RULE_PREF" uidrange "${desktop_uid}-${desktop_uid}" lookup "$TABLE" || return 1
  fi
  if ip -6 rule show pref "$DESKTOP_RULE_PREF" | grep -q .; then
    ip -6 rule show pref "$DESKTOP_RULE_PREF" | grep -q "uidrange ${desktop_uid}-${desktop_uid} lookup ${TABLE}" || return 1
  else
    ip -6 rule add pref "$DESKTOP_RULE_PREF" uidrange "${desktop_uid}-${desktop_uid}" lookup "$TABLE" || return 1
  fi
  ip -6 route replace unreachable default table "$TABLE" || return 1
}

route_dev() {
  # Optional second arg is a uid for the fib lookup.
  if [[ -n "${2:-}" ]]; then
    ip -4 route get "$1" uid "$2" 2>/dev/null | awk '{
      for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit }
    }'
  else
    ip -4 route get "$1" 2>/dev/null | awk '{
      for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit }
    }'
  fi
}

dns_status_words() {
  # $1 link, $2 label ("DNS Servers" or "DNS Domain")
  local link=$1 label=$2
  resolvectl status "$link" 2>/dev/null | awk -v label="$label" '
    $0 ~ "^[[:space:]]*" label ":" {
      line = $0
      sub("^[[:space:]]*" label ":[[:space:]]*", "", line)
      if (line != "") print line
      capture = 1
      next
    }
    capture && /^[[:space:]]+/ && $0 !~ /:/ {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      if (line != "") print line
      next
    }
    { capture = 0 }
  '
}

# One line per link that was the system DNS default:
# link<TAB>servers<TAB>domains
# Servers are saved because `resolvectl revert` drops DHCP servers and
# NetworkManager does not put them back. Search domains are left as they
# are. A plain domain is already a routing domain, so it stays on that
# link and is more specific than ~. on the tun. Adding the routing-only
# form replaces the search domain.
record_dns_links() {
  install -d -m 0755 "$RUN_DIR"
  local tmp="${DNS_LINKS_FILE}.tmp" link route servers domains
  : >"$tmp"
  while IFS= read -r link; do
    [[ -n "$link" && "$link" != "$TUN" && "$link" != "lo" ]] || continue
    route=$(resolvectl status "$link" 2>/dev/null | awk -F: '/^[[:space:]]*Default Route:/ { gsub(/[[:space:]]/, "", $2); print $2; exit }' || true)
    [[ "$route" == "yes" ]] || continue
    servers=$(dns_status_words "$link" "DNS Servers" | paste -sd ' ' -)
    domains=$(dns_status_words "$link" "DNS Domain" | paste -sd ' ' -)
    # A disconnected link can keep the flag and lose its servers. Skipping
    # it is not a failed save; there is nothing to put back.
    [[ -n "$servers" ]] || continue
    printf '%s\t%s\t%s\n' "$link" "$servers" "$domains" >>"$tmp"
  done < <(ip -o link show | awk -F': ' '{ split($2, a, "@"); print a[1] }')
  chmod 0644 "$tmp"
  mv "$tmp" "$DNS_LINKS_FILE"
}

apply_tunnel_dns() {
  # ns0's "~." routing domain sends global names through the tun. A saved
  # link that still has an address stays a DNS default route: clearing that
  # flag on a live NetworkManager link makes its per-interface lookup fail
  # with NoNameServers, which the bar shows as limited internet access.
  # A saved link with no address is kept false so a disconnected radio's
  # old server is not queried. The access-point link is always false while
  # the tunnel is up: its DHCP server refuses direct queries, and promoting
  # it (what NetworkManager does once the other radio is gone) makes
  # resolved return REFUSED for public names.
  local line link
  if [[ -f "$DNS_LINKS_FILE" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -n "$line" ]] || continue
      link=${line%%$'\t'*}
      [[ -n "$link" ]] || continue
      ip link show "$link" >/dev/null 2>&1 || continue
      if [[ "$link" != "$iface" ]] && link_has_ipv4 "$link"; then
        resolvectl default-route "$link" true || return 1
      else
        resolvectl default-route "$link" false || return 1
      fi
    done <"$DNS_LINKS_FILE"
  fi
  if [[ -n "${iface:-}" ]] && ip link show "$iface" >/dev/null 2>&1; then
    resolvectl default-route "$iface" false || return 1
  fi
  resolvectl dns "$TUN" "$DNS_SERVER_1" "$DNS_SERVER_2" || return 1
  resolvectl domain "$TUN" '~.' || return 1
  resolvectl default-route "$TUN" true || return 1
  resolvectl dnsovertls "$TUN" opportunistic || return 1
}

desktop_bus() {
  local uid=${desktop_uid:-} gid home runtime
  [[ "$uid" =~ ^[0-9]+$ && "$uid" != "0" ]] || return 1
  runtime="/run/user/${uid}"
  [[ -S "${runtime}/bus" ]] || return 1
  gid=$(id -g "$uid") || return 1
  home=$(getent passwd "$uid" | cut -d: -f6)
  [[ -n "$home" ]] || home=/tmp
  setpriv --reuid "$uid" --regid "$gid" --clear-groups \
    --no-new-privs --inh-caps=-all --reset-env \
    env PATH="/usr/bin:/bin" "HOME=${home}" \
      XDG_RUNTIME_DIR="$runtime" \
      DBUS_SESSION_BUS_ADDRESS="unix:path=${runtime}/bus" \
      "$@"
}

gsettings_get() {
  desktop_bus gsettings get "$@"
}

# One ignore token per line. libproxy matches "*.domain"; curl matches
# ".domain". The access-point subnet is not ignored: the watch exclusion
# list is empty. Other on-link prefixes are ignored so this machine's other
# LAN is not sent to the phone.
session_ignore_items() {
  local line prefix domains one
  printf '%s\n' localhost '127.0.0.0/8' '::1'
  while IFS= read -r line; do
    [[ "$line" == *" dev ${TUN} "* || "$line" == *" dev ${TUN}" ]] && continue
    prefix=${line%% *}
    [[ "$prefix" == */* ]] || continue
    [[ -n "${BYPASS_CIDR:-}" && "$prefix" == "$BYPASS_CIDR" ]] && continue
    printf '%s\n' "$prefix"
  done < <(ip -4 route show table main scope link)
  if [[ -f "$DNS_LINKS_FILE" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -n "$line" ]] || continue
      domains=""
      IFS=$'\t' read -r _ _ domains <<<"$line"
      for one in $domains; do
        [[ "$one" == "~"* || -z "$one" ]] && continue
        printf '%s\n' "*.${one}" ".${one}"
      done
    done <"$DNS_LINKS_FILE"
  fi
}

session_ignore_csv() {
  session_ignore_items | paste -sd, -
}

session_ignore_gvariant() {
  local rendered="" item
  while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    rendered+="'${item}', "
  done < <(session_ignore_items)
  printf '%s\n' "[${rendered%, }]"
}

# libproxy reads this on a non-GNOME session. The marker line is how down
# knows the file is ours.
write_sysconfig_proxy() {
  local no_proxy tmp
  no_proxy=$(session_ignore_csv)
  [[ -n "$no_proxy" && -n "$gateway" ]] || return 1
  if [[ -e "$SYSCONFIG_PROXY" ]] && ! grep -q '^# netshare$' "$SYSCONFIG_PROXY"; then
    echo "netshare: ${SYSCONFIG_PROXY} exists and is not ours" >&2
    return 1
  fi
  install -d -m 0755 "$(dirname "$SYSCONFIG_PROXY")"
  tmp=$(mktemp "${SYSCONFIG_PROXY}.XXXXXX")
  chmod 0644 "$tmp"
  cat >"$tmp" <<EOF
# netshare
PROXY_ENABLED="yes"
HTTP_PROXY="http://${gateway}:${PROXY_PORT}"
HTTPS_PROXY="http://${gateway}:${PROXY_PORT}"
NO_PROXY="${no_proxy}"
EOF
  mv "$tmp" "$SYSCONFIG_PROXY"
}

clear_sysconfig_proxy() {
  if [[ -f "$SYSCONFIG_PROXY" ]] && grep -q '^# netshare$' "$SYSCONFIG_PROXY"; then
    rm -f "$SYSCONFIG_PROXY"
  fi
}

publish_user_proxy_env() {
  local no_proxy url env_dump tmp key val
  no_proxy=$(session_ignore_csv)
  url="http://${gateway}:${PROXY_PORT}"
  [[ -n "$no_proxy" && -n "$gateway" ]] || return 1
  if [[ ! -f "$SESSION_ENV_FILE" ]]; then
    env_dump=$(desktop_bus systemctl --user show-environment || true)
    tmp=$(mktemp "${RUN_DIR}/session-env.XXXXXX")
    chmod 0644 "$tmp"
    for key in http_proxy https_proxy HTTP_PROXY HTTPS_PROXY no_proxy NO_PROXY; do
      val=$(awk -F= -v k="$key" '$1==k { print substr($0, length(k)+2); found=1 } END { if (!found) print "<unset>" }' <<<"$env_dump")
      printf '%s=%s\n' "$key" "$val" >>"$tmp"
    done
    mv "$tmp" "$SESSION_ENV_FILE"
  fi
  desktop_bus systemctl --user set-environment \
    "http_proxy=${url}" "https_proxy=${url}" \
    "HTTP_PROXY=${url}" "HTTPS_PROXY=${url}" \
    "no_proxy=${no_proxy}" "NO_PROXY=${no_proxy}" || return 1
  desktop_bus env \
    "http_proxy=${url}" "https_proxy=${url}" \
    "HTTP_PROXY=${url}" "HTTPS_PROXY=${url}" \
    "no_proxy=${no_proxy}" "NO_PROXY=${no_proxy}" \
    dbus-update-activation-environment --systemd \
      http_proxy https_proxy HTTP_PROXY HTTPS_PROXY no_proxy NO_PROXY || return 1
}

restore_user_proxy_env() {
  [[ -f "$SESSION_ENV_FILE" ]] || return 0
  local line key val
  local -a unset_keys=() set_args=() set_keys=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] || continue
    key=${line%%=*}
    val=${line#*=}
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    if [[ "$val" == "<unset>" ]]; then
      unset_keys+=("$key")
    else
      set_args+=("${key}=${val}")
      set_keys+=("$key")
    fi
  done <"$SESSION_ENV_FILE"
  if ((${#unset_keys[@]})); then
    desktop_bus systemctl --user unset-environment "${unset_keys[@]}" >/dev/null 2>&1 || true
    desktop_bus dbus-update-activation-environment --systemd --unset "${unset_keys[@]}" >/dev/null 2>&1 || true
  fi
  if ((${#set_args[@]})); then
    desktop_bus systemctl --user set-environment "${set_args[@]}" >/dev/null 2>&1 || true
    desktop_bus env "${set_args[@]}" dbus-update-activation-environment --systemd "${set_keys[@]}" >/dev/null 2>&1 || true
  fi
  rm -f "$SESSION_ENV_FILE"
}

# Watch Wi-Fi proxy: static host NETSHARE_GATEWAY port 8282, exclusion list
# empty. The session proxy uses that host and port. Ignore localhost and any
# other on-link prefix so the built-in LAN is not sent to the phone.
apply_session_proxy() {
  local rendered
  [[ -n "$gateway" && "$gateway" == "$NETSHARE_GATEWAY" ]] || return 1
  write_sysconfig_proxy || return 1
  if ! publish_user_proxy_env; then
    echo "netshare: user proxy environment was not published" >&2
  fi
  # A console host may have no user bus and no gsettings. The tun does not
  # depend on either. libproxy still reads the sysconfig file written above.
  if ! desktop_bus true; then
    return 0
  fi
  if ! desktop_bus bash -c 'command -v gsettings >/dev/null'; then
    return 0
  fi
  rendered=$(session_ignore_gvariant)
  if [[ -f "$SESSION_PROXY_FILE" ]]; then
    desktop_bus gsettings set org.gnome.system.proxy ignore-hosts "$rendered" >/dev/null 2>&1 || true
    return 0
  fi
  local mode http_host http_port https_host https_port ignore_hosts
  mode=$(gsettings_get org.gnome.system.proxy mode) || return 1
  http_host=$(gsettings_get org.gnome.system.proxy.http host) || return 1
  http_port=$(gsettings_get org.gnome.system.proxy.http port) || return 1
  https_host=$(gsettings_get org.gnome.system.proxy.https host) || return 1
  https_port=$(gsettings_get org.gnome.system.proxy.https port) || return 1
  ignore_hosts=$(gsettings_get org.gnome.system.proxy ignore-hosts) || return 1
  local tmp
  tmp=$(mktemp "${RUN_DIR}/session-proxy.XXXXXX")
  chmod 0644 "$tmp"
  printf 'uid=%s\nmode=%s\nhttp_host=%s\nhttp_port=%s\nhttps_host=%s\nhttps_port=%s\nignore=%s\n' \
    "$desktop_uid" "$mode" "$http_host" "$http_port" "$https_host" "$https_port" "$ignore_hosts" \
    >"$tmp"
  if ! desktop_bus gsettings set org.gnome.system.proxy.http host "'${gateway}'" \
    || ! desktop_bus gsettings set org.gnome.system.proxy.http port "$PROXY_PORT" \
    || ! desktop_bus gsettings set org.gnome.system.proxy.https host "'${gateway}'" \
    || ! desktop_bus gsettings set org.gnome.system.proxy.https port "$PROXY_PORT" \
    || ! desktop_bus gsettings set org.gnome.system.proxy ignore-hosts "$rendered" \
    || ! desktop_bus gsettings set org.gnome.system.proxy mode "'manual'"; then
    desktop_bus gsettings set org.gnome.system.proxy mode "$mode" >/dev/null 2>&1 || true
    desktop_bus gsettings set org.gnome.system.proxy.http host "$http_host" >/dev/null 2>&1 || true
    desktop_bus gsettings set org.gnome.system.proxy.http port "$http_port" >/dev/null 2>&1 || true
    desktop_bus gsettings set org.gnome.system.proxy.https host "$https_host" >/dev/null 2>&1 || true
    desktop_bus gsettings set org.gnome.system.proxy.https port "$https_port" >/dev/null 2>&1 || true
    desktop_bus gsettings set org.gnome.system.proxy ignore-hosts "$ignore_hosts" >/dev/null 2>&1 || true
    rm -f "$tmp"
    clear_sysconfig_proxy
    restore_user_proxy_env
    return 1
  fi
  mv "$tmp" "$SESSION_PROXY_FILE"
}

restore_session_proxy() {
  clear_sysconfig_proxy
  restore_user_proxy_env
  [[ -f "$SESSION_PROXY_FILE" ]] || return 0
  local uid mode http_host http_port https_host https_port ignore_hosts
  uid=$(awk -F= '$1=="uid"{print $2}' "$SESSION_PROXY_FILE")
  mode=$(awk -F= '$1=="mode"{print substr($0,6)}' "$SESSION_PROXY_FILE")
  http_host=$(awk -F= '$1=="http_host"{print substr($0,11)}' "$SESSION_PROXY_FILE")
  http_port=$(awk -F= '$1=="http_port"{print substr($0,11)}' "$SESSION_PROXY_FILE")
  https_host=$(awk -F= '$1=="https_host"{print substr($0,12)}' "$SESSION_PROXY_FILE")
  https_port=$(awk -F= '$1=="https_port"{print substr($0,12)}' "$SESSION_PROXY_FILE")
  ignore_hosts=$(awk -F= '$1=="ignore"{print substr($0,8)}' "$SESSION_PROXY_FILE")
  if [[ "$uid" =~ ^[0-9]+$ ]]; then
    desktop_uid=$uid
  fi
  desktop_bus gsettings set org.gnome.system.proxy mode "$mode" >/dev/null 2>&1 || true
  desktop_bus gsettings set org.gnome.system.proxy.http host "$http_host" >/dev/null 2>&1 || true
  desktop_bus gsettings set org.gnome.system.proxy.http port "$http_port" >/dev/null 2>&1 || true
  desktop_bus gsettings set org.gnome.system.proxy.https host "$https_host" >/dev/null 2>&1 || true
  desktop_bus gsettings set org.gnome.system.proxy.https port "$https_port" >/dev/null 2>&1 || true
  desktop_bus gsettings set org.gnome.system.proxy ignore-hosts "$ignore_hosts" >/dev/null 2>&1 || true
  rm -f "$SESSION_PROXY_FILE"
}

restore_dns() {
  local line link servers domains
  local -a server_list domain_list
  if [[ -f "$DNS_LINKS_FILE" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -n "$line" ]] || continue
      link=""
      servers=""
      domains=""
      IFS=$'\t' read -r link servers domains <<<"$line"
      [[ -n "$link" ]] || continue
      server_list=()
      domain_list=()
      if [[ -n "$servers" ]]; then
        read -r -a server_list <<<"$servers"
      fi
      if [[ -n "$domains" ]]; then
        read -r -a domain_list <<<"$domains"
      fi
      if ((${#server_list[@]})); then
        resolvectl dns "$link" "${server_list[@]}" >/dev/null 2>&1 \
          || echo "netshare: could not restore DNS servers on ${link}" >&2
      fi
      if ((${#domain_list[@]})); then
        resolvectl domain "$link" "${domain_list[@]}" >/dev/null 2>&1 || true
      fi
      resolvectl default-route "$link" true >/dev/null 2>&1 || true
    done <"$DNS_LINKS_FILE"
    rm -f "$DNS_LINKS_FILE"
  fi
  resolvectl revert "$TUN" >/dev/null 2>&1 || true
  resolvectl flush-caches >/dev/null 2>&1 || true
}

ensure_dispatcher() {
  # The repo file stays free of this machine's path. The installed copy
  # execs the resolved controller so NetworkManager's PATH does not matter.
  local dst="/etc/NetworkManager/dispatcher.d/netshare-dns"
  local tmp bin
  bin=$(printf '%q' "$SCRIPT")
  tmp=$(mktemp)
  cat >"$tmp" <<EOF
#!/bin/bash
# Generated by netshare. NetworkManager passes the interface and the action.
iface=\${1:-}
action=\${2:-}
case "\$action" in
  pre-down|down)
    exec ${bin} transport-down "\$iface"
    ;;
  *)
    exec ${bin} dns-reassert
    ;;
esac
EOF
  if [[ ! -f "$dst" ]] || ! cmp -s "$tmp" "$dst"; then
    install -m 0755 "$tmp" "$dst"
  fi
  rm -f "$tmp"
}

cmd_dns_reassert() {
  require_root dns-reassert
  [[ -f "$DNS_LINKS_FILE" ]] || exit 0
  lock
  [[ -f "$DNS_LINKS_FILE" ]] || exit 0
  ip link show "$TUN" >/dev/null 2>&1 || exit 0
  load_state || true
  set +e
  if [[ -n "$tun_ip" ]]; then
    install_dns_host_routes
  fi
  apply_tunnel_dns
  exit 0
}

cmd_transport_down() {
  require_root transport-down "$@"
  local gone=${1:-}
  [[ -n "$gone" ]] || exit 0
  lock
  if [[ ! -f "$STATE" ]] || ! load_state; then
    exit 0
  fi
  [[ "$iface" == "$gone" ]] || exit 0
  echo "netshare: ${gone} went down; removing the tunnel" >&2
  teardown
  exit 0
}

cmd_reap() {
  require_root reap
  load_state || exit 0
  local watch=$pid
  [[ "$watch" =~ ^[0-9]+$ ]] || exit 0
  while true; do
    pid=$watch
    if ! pid_alive; then
      break
    fi
    sleep 1
  done
  lock
  if [[ ! -f "$STATE" ]] || ! load_state; then
    exit 0
  fi
  if [[ "$pid" != "$watch" ]] || pid_alive; then
    exit 0
  fi
  echo "netshare: tun2proxy exited; restoring the resolver" >&2
  logger -t netshare "tun2proxy exited; restoring the resolver" || true
  teardown
  exit 0
}

start_reap() {
  install -d -m 0755 "$LOG_DIR"
  setsid "$SCRIPT" reap >>"${LOG_DIR}/reap.log" 2>&1 </dev/null 9>&- &
}

# Gate 1. The netshare user is marked into table 849. Do not call
# `netshare run` here: this process holds the lock, and run takes it too.
probe_marked_http() {
  local code=""
  if ! code=$(unshare --mount --propagation private "$SCRIPT" --inside-run \
      curl -4 -sS -o /dev/null -w '%{http_code}' \
        --connect-timeout 8 --max-time 20 \
        https://example.com); then
    echo "netshare: transport curl failed (${code:-no status})" >&2
    return 1
  fi
  [[ "$code" =~ ^[23][0-9][0-9]$ ]]
}

# Gate 2. Host routes only. The desktop uid rule is not installed yet,
# so ROUTE_PROBE must still follow the main-table default.
verify_dns_gate() {
  local out="" via="" ip_re dns1_re dns2_re
  resolvectl reset-server-features >/dev/null 2>&1 || true
  resolvectl flush-caches >/dev/null 2>&1 || true
  if ! out=$(timeout 20 resolvectl query -4 example.com 2>&1); then
    echo "netshare: resolvectl query failed" >&2
    printf '%s\n' "$out" >&2
    return 1
  fi
  if [[ "$out" == *"Data from: cache"* ]]; then
    resolvectl flush-caches >/dev/null 2>&1 || true
    if ! out=$(timeout 20 resolvectl query -4 example.com 2>&1); then
      echo "netshare: resolvectl query failed after flushing the cache" >&2
      printf '%s\n' "$out" >&2
      return 1
    fi
  fi
  if [[ "$out" != *"link: ${TUN}"* ]]; then
    echo "netshare: example.com was not answered on ${TUN}" >&2
    printf '%s\n' "$out" >&2
    return 1
  fi
  if ! RESOLVED_EXAMPLE_IP=$(printf '%s\n' "$out" | classify_resolved_address "$BYPASS_CIDR"); then
    echo "netshare: example.com did not resolve to a public address" >&2
    printf '%s\n' "$out" >&2
    return 1
  fi
  via=$(ip -4 route get "$DNS_SERVER_1" 2>/dev/null || true)
  if [[ "$via" != *" dev ${TUN} "* || "$via" != *" src ${tun_ip} "* ]]; then
    echo "netshare: ${DNS_SERVER_1} is not routed via ${TUN} src ${tun_ip}" >&2
    printf '%s\n' "$via" >&2
    return 1
  fi
  if ! grep -F "Proxy http server: ${gateway}:${PROXY_PORT}" "$LOG" >/dev/null 2>&1; then
    echo "netshare: tun log does not show proxy ${gateway}:${PROXY_PORT}" >&2
    return 1
  fi
  ip_re=${tun_ip//./\\.}
  dns1_re=${DNS_SERVER_1//./\\.}
  dns2_re=${DNS_SERVER_2//./\\.}
  local _
  for _ in 1 2 3 4 5 6 7 8; do
    if grep -E "TCP ${ip_re}:[0-9]+ -> (${dns1_re}|${dns2_re}):853" "$LOG" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.4
  done
  echo "netshare: tun log has no DNS-over-TLS session to ${DNS_SERVER_1} or ${DNS_SERVER_2} port 853" >&2
  tail -n 40 "$LOG" >&2 || true
  return 1
}

probe_desktop_http() {
  local uid=$1 gid home code=""
  gid=$(id -g "$uid")
  home=$(getent passwd "$uid" | cut -d: -f6)
  [[ -n "$home" ]] || home=/tmp
  if ! code=$(
    cd /tmp
    setpriv --reuid "$uid" --regid "$gid" --clear-groups \
      --no-new-privs --inh-caps=-all --reset-env \
      env PATH="/usr/bin:/bin" "HOME=${home}" \
      curl -4 -sS -o /dev/null -w '%{http_code}' \
        --connect-timeout 8 --max-time 20 \
        https://example.com
  ); then
    echo "netshare: desktop curl failed (${code:-no status})" >&2
    return 1
  fi
  [[ "$code" =~ ^[23][0-9][0-9]$ ]]
}

verify_desktop_gate() {
  local dev="" main_via="" main_dev="" domain="" saved_link="" shown="" qout="" lan_prefix="" v6="" mark code_ok=0
  dev=$(route_dev "$ROUTE_PROBE" "$desktop_uid")
  if [[ "$dev" != "$TUN" ]]; then
    echo "netshare: desktop route to ${ROUTE_PROBE} is ${dev:-missing}" >&2
    return 1
  fi
  dev=$(route_dev "$gateway" "$desktop_uid")
  if [[ "$dev" != "$iface" ]]; then
    echo "netshare: desktop route to ${gateway} is ${dev:-missing}" >&2
    return 1
  fi
  main_via=$(ip -4 route show default | awk '{ for (i = 1; i <= NF; i++) if ($i == "via") { print $(i + 1); exit } }')
  main_dev=$(ip -4 route show default | awk '{ for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit } }')
  if [[ -n "$main_via" && -n "$main_dev" ]]; then
    dev=$(route_dev "$main_via" "$desktop_uid")
    if [[ "$dev" != "$main_dev" || "$dev" == "$TUN" ]]; then
      echo "netshare: desktop route to the built-in gateway ${main_via} is ${dev:-missing}" >&2
      return 1
    fi
  fi
  dev=$(route_dev "$ROUTE_PROBE")
  if [[ "$dev" == "$TUN" || "$dev" == "$iface" ]]; then
    echo "netshare: unmarked route to ${ROUTE_PROBE} uses ${dev}" >&2
    return 1
  fi
  domain=$(awk -F '\t' 'NF >= 3 && $3 != "" { print $3; exit }' "$DNS_LINKS_FILE" 2>/dev/null | awk '{ print $1; exit }' || true)
  saved_link=$(awk -F '\t' 'NF >= 1 && $1 != "" { print $1; exit }' "$DNS_LINKS_FILE" 2>/dev/null || true)
  if [[ -n "$domain" && -n "$saved_link" ]]; then
    shown=$(resolvectl domain "$saved_link" 2>/dev/null || true)
    if [[ "$shown" != *": ${domain}"* && "$shown" != *" ${domain}"* ]]; then
      echo "netshare: search domain ${domain} is no longer on ${saved_link} (${shown})" >&2
      return 1
    fi
  fi
  if [[ -n "$domain" && -n "$main_dev" ]]; then
    lan_prefix=$(ip -4 route show dev "$main_dev" scope link | awk '{ print $1; exit }')
    if [[ -z "$lan_prefix" ]]; then
      echo "netshare: no on-link prefix on ${main_dev} for ${domain}" >&2
      return 1
    fi
    if ! qout=$(timeout 10 resolvectl query -4 "bigbrain.${domain}" 2>&1); then
      echo "netshare: bigbrain.${domain} did not resolve on the built-in resolver" >&2
      printf '%s\n' "$qout" >&2
      return 1
    fi
    if ! printf '%s\n' "$qout" | python3 -c '
import ipaddress, sys
text = sys.stdin.read().split("--", 1)[0]
net = ipaddress.ip_network(sys.argv[1], strict=False)
for token in text.replace(",", " ").split():
    token = token.strip(".")
    try:
        ip = ipaddress.ip_address(token)
    except ValueError:
        continue
    if ip.version == 4 and ip in net:
        sys.exit(0)
sys.exit(1)
' "$lan_prefix"; then
      echo "netshare: bigbrain.${domain} was not answered from ${lan_prefix}" >&2
      printf '%s\n' "$qout" >&2
      return 1
    fi
  fi
  # An unreachable route comes back as "No route to host".
  # "Network is unreachable" is this host with no matching ipv6 rule at all.
  v6=$(ip -6 route get 2606:4700:4700::1111 uid "$desktop_uid" 2>&1 || true)
  if [[ "$v6" == *"Network is unreachable"* || ( "$v6" != *"No route to host"* && "$v6" != *unreachable* ) ]]; then
    echo "netshare: desktop ipv6 is not unreachable (${v6})" >&2
    return 1
  fi
  if [[ -n "$main_dev" && "$v6" == *"dev ${main_dev}"* ]]; then
    echo "netshare: desktop ipv6 lookup uses ${main_dev}" >&2
    return 1
  fi
  mark=$(wc -l <"$LOG")
  if ! probe_desktop_http "$desktop_uid"; then
    return 1
  fi
  code_ok=1
  if ! tail -n +"$((mark + 1))" "$LOG" | grep -E 'TCP .+ -> [0-9.]+:443' >/dev/null 2>&1; then
    echo "netshare: desktop HTTP did not appear as TCP on the tun" >&2
    return 1
  fi
  [[ "$code_ok" -eq 1 ]]
}

cmd_status() {
  local engine rule nft_state half bound_iface="" bound_src="" bound_proxy="" bound_ssid=""
  if [[ -x "$TUN2PROXY" ]]; then
    engine=$("$TUN2PROXY" --version 2>/dev/null || echo "unknown")
  else
    engine="missing ${TUN2PROXY}"
  fi
  echo "engine: ${engine}"
  if [[ -f "$STATE" ]] && load_state; then
    bound_iface=$iface
    bound_src=$src
    bound_proxy=$state_proxy
    bound_ssid=$state_ssid
    if pid_alive && ip link show "$TUN" >/dev/null 2>&1; then
      echo "tunnel: up (${TUN}, pid ${pid}, ${tun_addr:-unknown})"
      echo "posture: ${posture:-unknown}"
      echo "bound: ${bound_iface} ${bound_src} ${bound_proxy} ${bound_ssid}"
    else
      echo "tunnel: stale (state present, process or ${TUN} is missing)"
      echo "posture: ${posture:-unknown}"
    fi
  else
    echo "tunnel: down"
    echo "posture: off"
  fi
  if command -v curl >/dev/null 2>&1; then
    scan_access_points
    format_access_points
  else
    echo "access-point: curl is not installed"
  fi
  if ip -4 route show default | grep -q .; then
    echo "default: $(ip -4 route show default | head -n 1)"
  else
    echo "default: none"
  fi
  if ip rule show pref "$RULE_PREF" 2>/dev/null | grep -q .; then
    rule=$(ip rule show pref "$RULE_PREF")
    echo "rule: ${rule}"
  else
    echo "rule: absent"
  fi
  if half_routes_present; then
    half="present"
  else
    half="absent"
  fi
  echo "desktop-half-routes: ${half}"
  if ip rule show pref "$DESKTOP_RULE_PREF" 2>/dev/null | grep -q .; then
    echo "desktop-rule: $(ip rule show pref "$DESKTOP_RULE_PREF")"
  else
    echo "desktop-rule: absent"
  fi
  if ip -4 route show "${DNS_SERVER_1}/32" 2>/dev/null | grep -q "dev ${TUN}\\b"; then
    echo "dns-host-routes: ${DNS_SERVER_1} ${DNS_SERVER_2} dev ${TUN}"
  else
    echo "dns-host-routes: absent"
  fi
  if ip -4 route show "$VIRTUAL_CIDR" 2>/dev/null | grep -q "dev ${TUN}\\b"; then
    echo "virtual-dns-route: ${VIRTUAL_CIDR} dev ${TUN}"
  else
    echo "virtual-dns-route: absent"
  fi
  if [[ "$(id -u)" -ne 0 ]]; then
    nft_state="not checked"
  elif nft list table ip netshare >/dev/null 2>&1; then
    nft_state="present"
  else
    nft_state="absent"
  fi
  echo "nft: ${nft_state}"
}

tunnel_is_up() {
  [[ -f "$STATE" ]] || return 1
  load_state || return 1
  pid_alive || return 1
  ip link show "$TUN" >/dev/null 2>&1
}

require_up() {
  tunnel_is_up || die "tunnel is down"
}

cmd_toggle() {
  local out rc
  require_root toggle
  if tunnel_is_up; then
    if out=$(cmd_down 2>&1); then
      printf '%s\n' "$out"
    else
      rc=$?
      printf '%s\n' "$out" >&2
      exit "$rc"
    fi
  else
    if out=$(cmd_up 2>&1); then
      printf '%s\n' "$out"
    else
      rc=$?
      printf '%s\n' "$out" >&2
      exit "$rc"
    fi
  fi
}

# sudo sets SUDO_UID. NETSHARE_UID in the root-owned conf overrides it.
# Root with neither gets a tun for `netshare run` and no account rule.
resolve_traffic_uid() {
  if [[ -n "${NETSHARE_UID:-}" ]]; then
    [[ "$NETSHARE_UID" =~ ^[0-9]+$ && "$NETSHARE_UID" != "0" ]] || die "NETSHARE_UID must be a non-root numeric uid"
    desktop_uid=$NETSHARE_UID
    return 0
  fi
  if [[ -n "${SUDO_UID:-}" && "$SUDO_UID" != "0" ]]; then
    desktop_uid=$SUDO_UID
    return 0
  fi
  return 1
}

report_up() {
  local main_default detail
  main_default=$(ip -4 route show default | head -n 1)
  if [[ "$posture" == "desktop" ]]; then
    detail="dns: ${DNS_SERVER_1} ${DNS_SERVER_2} opportunistic"
    detail+=$'\n'"  desktop uid ${desktop_uid} uses table ${TABLE}; the main-table default is still: ${main_default:-none}"
  else
    detail="dns: host resolver unchanged"
    detail+=$'\n'"  no traffic uid; 'netshare run' uses the tun. The main-table default is still: ${main_default:-none}"
  fi
  echo "netshare: up"
  echo "  posture: ${posture}"
  echo "  access point: ${ssid:-unnamed} on ${iface} ${src}"
  echo "  tun: ${TUN} ${tun_addr}"
  echo "  proxy: ${PROXY_URL}"
  printf '  %s\n' "$detail"
}

cmd_up() {
  require_root up
  lock
  check_config
  if [[ -f "$STATE" ]]; then
    load_state || true
    if pid_alive && ip link show "$TUN" >/dev/null 2>&1; then
      echo "netshare: already up"
      cmd_status
      exit 0
    fi
    echo "netshare: cleaning a stale tunnel" >&2
    teardown
  fi
  local traffic_uid=0
  if resolve_traffic_uid; then
    traffic_uid=1
  fi
  if ip link show "$TUN" >/dev/null 2>&1; then
    die "${TUN} already exists and is not a netshare tunnel"
  fi
  if ip rule show pref "$RULE_PREF" | grep -q .; then
    die "ip rule priority ${RULE_PREF} is already in use"
  fi
  if ip rule show pref "$RUNNER_RULE_PREF" | grep -q .; then
    die "ip rule priority ${RUNNER_RULE_PREF} is already in use"
  fi
  if ip rule show pref "$DESKTOP_RULE_PREF" | grep -q .; then
    die "ip rule priority ${DESKTOP_RULE_PREF} is already in use"
  fi
  if ip -6 rule show pref "$DESKTOP_RULE_PREF" | grep -q .; then
    die "ipv6 rule priority ${DESKTOP_RULE_PREF} is already in use"
  fi
  if nft list table ip netshare >/dev/null 2>&1; then
    die "nft table ip netshare already exists"
  fi

  find_netshare
  if [[ "$gateway" != "$NETSHARE_GATEWAY" ]]; then
    die "gateway ${gateway} is not ${NETSHARE_GATEWAY}"
  fi
  if ! tun_ip=$(map_tun_ip "$src"); then
    die "refusing to map ${src}; the tun address is 10.10 plus the last two octets of a ${NETSHARE_PREFIX} client address"
  fi
  if [[ "$tun_ip" != 10.10.49.* || "$tun_ip" == "10.10.49.1" || "$tun_ip" == "10.0.0.33" ]]; then
    die "refusing tun address ${tun_ip}"
  fi
  ensure_user
  ensure_etc
  ensure_dispatcher
  install -d -m 0755 "$LOG_DIR"
  : >"$LOG"
  chmod 0644 "$LOG"

  trap on_up_err ERR
  trap on_up_signal INT TERM
  local -a args=(
    --proxy "$PROXY_URL"
    --tun "$TUN"
    --mtu "$TUN_MTU"
    --dns over-tcp
    --dns-addr "$DNS_SERVER_1"
    --bypass "$BYPASS_CIDR"
    --verbosity info
    --exit-on-fatal-error
  )
  local arg
  for arg in "${args[@]}"; do
    if [[ "$arg" == "--setup" || "$arg" == "--virtual-dns-pool" ]]; then
      fail_up "refusing to pass ${arg}"
    fi
  done
  # tun2proxy must not inherit the lock fd. An inherited flock stays
  # held for the life of the process, and later up/down/run block on it.
  setsid "$TUN2PROXY" "${args[@]}" >>"$LOG" 2>&1 </dev/null 9>&- &
  pid=$!
  printf '%s\n' "$pid" >"${RUN_DIR}/pid"

  # The device appears when the process opens it. It stays down and has
  # no address unless --setup is passed, and --setup is refused above.
  local ready=0 i
  for ((i = 0; i < 50; i++)); do
    if ! pid_alive; then
      echo "netshare: tun2proxy exited" >&2
      tail -n 40 "$LOG" >&2 || true
      fail_up "tun2proxy exited during startup"
    fi
    if ip link show "$TUN" >/dev/null 2>&1; then
      ready=1
      break
    fi
    sleep 0.1
  done
  if (( ready == 0 )); then
    echo "netshare: ${TUN} did not appear" >&2
    tail -n 40 "$LOG" >&2 || true
    fail_up "${TUN} did not come up"
  fi
  sysctl -q -w "net.ipv6.conf.${TUN}.disable_ipv6=1" || true
  ip link set dev "$TUN" mtu "$TUN_MTU" up
  # A /32 is a local address. It does not install a connected subnet.
  ip addr replace "${tun_ip}/32" dev "$TUN"
  tun_addr="${tun_ip}/32"

  ip route replace table "$TABLE" "$BYPASS_CIDR" dev "$iface" src "$src"
  ip route replace table "$TABLE" "${tun_ip}/32" dev "$TUN"
  ip route replace table "$TABLE" default dev "$TUN" src "$tun_ip"
  ip rule add pref "$RULE_PREF" fwmark "$MARK" lookup "$TABLE"
  if ! install_runner_rule; then
    fail_up "could not install the runner policy rule"
  fi

  local uid
  uid=$(id -u "$RUN_USER")
  nft add table ip netshare
  nft add chain ip netshare output '{ type route hook output priority mangle; policy accept; }'
  nft add rule ip netshare output meta skuid "$uid" meta mark set "$MARK"
  nft add chain ip netshare prerouting '{ type filter hook prerouting priority mangle; policy accept; }'
  nft add rule ip netshare prerouting iifname "$TUN" meta mark set "$MARK"
  nft add table ip6 netshare
  nft add chain ip6 netshare output '{ type filter hook output priority filter; policy accept; }'
  nft add rule ip6 netshare output meta skuid "$uid" drop

  posture=side
  default_installed=0
  write_state

  # Gate 1. The built-in default and systemd-resolved are still untouched.
  if [[ "$(route_dev "$gateway")" != "$iface" ]]; then
    fail_up "gateway ${gateway} is not on ${iface}"
  fi
  if ! probe_marked_http; then
    fail_up "transport through the access-point proxy failed"
  fi

  # No account to move. Leave the host resolver alone. `netshare run` uses
  # the runner rule installed above.
  if (( traffic_uid == 0 )); then
    trap - ERR INT TERM
    start_reap
    report_up
    exit 0
  fi

  # Gate 2. DNS host routes only. No desktop rule and no /1 routes.
  if ! install_dns_host_routes; then
    fail_up "could not install DNS host routes"
  fi
  if ! record_dns_links; then
    fail_up "could not save the current resolver"
  fi
  if ! apply_tunnel_dns; then
    fail_up "could not point resolved at the tun"
  fi
  if ! verify_dns_gate; then
    fail_up "resolver did not return a public address through the tun; desktop default was not changed"
  fi
  if [[ "$(route_dev "$ROUTE_PROBE")" == "$TUN" ]]; then
    fail_up "${ROUTE_PROBE} already uses ${TUN} before the desktop rule"
  fi
  if [[ "$(route_dev "$gateway")" != "$iface" ]]; then
    fail_up "gateway ${gateway} left ${iface} during DNS setup"
  fi

  # Gate 3. Side table for the desktop uid. tun2proxy stays on the main table.
  if ! install_throws; then
    fail_up "could not keep on-link routes out of the tun"
  fi
  if ! install_desktop_rules; then
    fail_up "could not install the desktop policy rule"
  fi
  if ! verify_desktop_gate; then
    fail_up "desktop traffic did not pass through the tun"
  fi

  posture=desktop
  default_installed=1
  write_state
  if ! apply_session_proxy; then
    echo "netshare: session proxy was not set to ${gateway}:${PROXY_PORT}" >&2
  fi
  trap - ERR INT TERM
  start_reap
  report_up
}

cmd_down() {
  require_root down
  lock
  local owned=0
  if [[ -f "$STATE" || -f "${RUN_DIR}/pid" ]]; then
    owned=1
    load_state || true
  fi
  if (( owned == 0 )); then
    if ip link show "$TUN" >/dev/null 2>&1 \
      || nft list table ip netshare >/dev/null 2>&1 \
      || ip rule show pref "$RULE_PREF" | grep -q . \
      || ip rule show pref "$RUNNER_RULE_PREF" | grep -q . \
      || ip rule show pref "$DESKTOP_RULE_PREF" | grep -q .; then
      die "found ${TUN} or netshare rules without state; left them in place"
    fi
    echo "netshare: already down"
    exit 0
  fi
  teardown
  echo "netshare: down"
}

cmd_default() {
  require_root default "$@"
  lock
  case "${1:-}" in
    on)
      require_up
      if [[ -z "$desktop_uid" ]]; then
        resolve_traffic_uid || die "no traffic uid; set NETSHARE_UID or start with sudo"
      fi
      ip route del 0.0.0.0/1 dev "$TUN" >/dev/null 2>&1 || true
      ip route del 128.0.0.0/1 dev "$TUN" >/dev/null 2>&1 || true
      if ! install_dns_host_routes; then
        die "could not install DNS host routes"
      fi
      if [[ ! -f "$DNS_LINKS_FILE" ]]; then
        record_dns_links
      fi
      if ! apply_tunnel_dns; then
        restore_dns
        delete_dns_host_routes
        die "could not point resolved at the tun"
      fi
      if ! verify_dns_gate; then
        restore_dns
        delete_dns_host_routes
        die "resolver did not return a public address through the tun"
      fi
      if ! install_throws || ! install_desktop_rules; then
        delete_desktop_rules
        restore_dns
        delete_dns_host_routes
        die "could not install the desktop policy rule"
      fi
      if ! verify_desktop_gate; then
        delete_desktop_rules
        restore_dns
        delete_dns_host_routes
        die "desktop traffic did not pass through the tun"
      fi
      posture=desktop
      default_installed=1
      write_state
      if ! apply_session_proxy; then
        echo "netshare: session proxy was not set to ${gateway}:${PROXY_PORT}" >&2
      fi
      echo "netshare: default on"
      echo "desktop uid ${desktop_uid} uses table ${TABLE}; the main-table default was left in place"
      ;;
    off)
      require_up
      ip route del 0.0.0.0/1 dev "$TUN" >/dev/null 2>&1 || true
      ip route del 128.0.0.0/1 dev "$TUN" >/dev/null 2>&1 || true
      delete_desktop_rules
      delete_dns_host_routes
      restore_session_proxy
      restore_dns
      default_installed=0
      posture=side
      write_state
      echo "netshare: default off"
      echo "desktop traffic is back on the main table; the tun is still up for 'netshare run'"
      ;;
    *)
      die "usage: netshare default on|off"
      ;;
  esac
}

inside_run() {
  shift
  [[ "$(id -u)" -eq 0 ]] || die "internal run helper requires root"
  [[ "$#" -ge 1 ]] || die "usage: netshare run CMD..."
  [[ -f "${ETC_DIR}/resolv.conf" && -f "${ETC_DIR}/nsswitch.conf" ]] \
    || die "missing ${ETC_DIR} resolver files"
  mount --bind "${ETC_DIR}/resolv.conf" /etc/resolv.conf
  mount --bind "${ETC_DIR}/nsswitch.conf" /etc/nsswitch.conf
  if ! setpriv --reuid "$RUN_USER" --regid "$RUN_USER" --clear-groups \
      test -r "$PWD" -a -x "$PWD"; then
    cd /
  fi
  exec setpriv --reuid "$RUN_USER" --regid "$RUN_USER" --clear-groups \
    --no-new-privs --inh-caps=-all --reset-env \
    env PATH="/usr/local/sbin:/usr/local/bin:/usr/bin:/bin" \
      "TERM=${TERM:-dumb}" "LANG=${LANG:-C.UTF-8}" \
    "$@"
}

cmd_run() {
  require_root run "$@"
  lock
  require_up
  ensure_user
  ensure_etc
  [[ "$#" -ge 1 ]] || die "usage: netshare run CMD..."
  unlock_fd
  exec unshare --mount --propagation private "$SCRIPT" --inside-run "$@"
}

