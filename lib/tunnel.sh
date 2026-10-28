#!/usr/bin/env bash
# netshare: give this host internet through a NetShare access point.
#
# The SSID is not an identity. NetShare (kha.prog.mikrotik) tells clients to
# use an HTTP proxy on the access point's DHCP gateway, port 8282. That same
# port accepts unauthenticated SOCKS5. Any connected Wi-Fi or Ethernet link
# whose gateway answers the HTTP proxy is eligible. The on-link subnet of
# that interface is the bypass, so the proxy session cannot loop into the tun.
#
# tun2proxy is the data plane and is started with socks5:// on that host and
# port. SOCKS5 UDP associate carries datagrams. HTTP CONNECT cannot.
# Discovery, the bar, and the session proxy keep the HTTP URL. This script
# owns routes, the fwmark, and DNS. It never passes --setup: that flag assigns
# 10.0.0.33/24 and installs routes itself. The tun address is the one
# kha.prog.mikrotik.vpn builds. setAddress
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
# DNS is Cloudflare's public resolvers, 1.1.1.1 and 1.0.0.1. The transport
# check asks both over HTTPS (port 443) through the tun before it opens any
# TCP port 53 socket. Port 53 can sit unanswered while the access point can
# already fetch a page, and a hung port 53 session stays until that data
# plane exits. Another data plane does not change that.
# Desktop lookups go to a forwarder on the tun address. That forwarder runs
# as the tunnel user and uses the same HTTPS path, so it does not need a
# second default route. The two resolver addresses still get host
# routes into the tun before any desktop rule exists. ns0's routing domain
# "~." keeps global lookups on the tun. Other links stay DNS default routes
# so NetworkManager can still resolve a name on that interface. If the lookup
# does not return a public address, up removes what it added and leaves the
# built-in resolver in place.
#
# The watch client uses SOCKS on 192.168.49.1 port 8282, which is why UDP
# works there. tun2proxy uses that same SOCKS5 endpoint. While the desktop
# rule is installed, the session proxy stays the HTTP URL on that host and
# port, for programs that ignore the routing table. libproxy on Hyprland
# does not read the GNOME proxy settings, so the same values are also written
# to /etc/sysconfig/proxy and to the desktop user's activation environment.
# Localhost and the other on-link LANs stay direct; the watch has no second
# network to protect.
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
# TCP to the proxy port only. Used when the gateway address is also local
# on another interface, so the phone would otherwise never see the connection.
GATEWAY_TABLE="848"
MARK="0x849"
RULE_PREF="5000"
# uid rule for the netshare runner. Ahead of Tailscale, and distinct from
# the fwmark rule so deletion of one does not remove the other.
RUNNER_RULE_PREF="5010"
# After Tailscale's lookup-52 rule at 5270, and before main at 32766.
DESKTOP_RULE_PREF="5300"
TUN_MTU="10000"
# tun2proxy's built-in cap is 200. A burst of hung TCP holds a slot until
# its 600s timeout, and --exit-on-fatal-error then quits the process.
MAX_SESSIONS="1024"
VIRTUAL_CIDR="198.18.0.0/15"
# Cloudflare public resolvers. RUN_DNS is the first server `netshare run`
# queries. DNS_SERVER_2 is the fallback. See runner_resolv_text.
DNS_SERVER_1="1.1.1.1"
DNS_SERVER_2="1.0.0.1"
# A UDP/53 packet becomes one tun2proxy DNS-over-TCP session, and that
# session can sit in the SOCKS handshake until the client gives up. Curl's
# connect timeout includes the lookup, so that wait also cancelled the
# second resolver. Each probe query is its own TCP socket, with this budget,
# and a failed check is repeated.
DNS_QUERY_TIMEOUT=3
PROBE_ATTEMPTS=3
PROBE_PAUSE=1
# A SOCKS session that never finishes is dropped only when tun2proxy exits.
# While a direct request to the access point still succeeds, up replaces
# that process and probes again, up to this many generations. The DNS gate
# uses the same bound.
ENGINE_TRIES=3
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
DOH_PID="${RUN_DIR}/doh.pid"
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
# cmd_up's plane is local. A later restart runs in another function and
# cannot see that local, so the SOCKS URL is kept here.
engine_plane=""
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
# Set while the proxy port is steered off a local gateway address.
shadow_active=0
shadow_accept_prev=""
shadow_rp_prev=""
shadow_parked_local=0
probe_accept_dev=""
probe_accept_prev=""
probe_rp_prev=""

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
  shadow_active=0
  shadow_accept_prev=""
  shadow_rp_prev=""
  shadow_parked_local=0
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
      shadow_active) shadow_active=$value ;;
      shadow_accept_prev) shadow_accept_prev=$value ;;
      shadow_rp_prev) shadow_rp_prev=$value ;;
      shadow_parked_local) shadow_parked_local=$value ;;
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
    printf 'shadow_active=%s\n' "$shadow_active"
    printf 'shadow_accept_prev=%s\n' "$shadow_accept_prev"
    printf 'shadow_rp_prev=%s\n' "$shadow_rp_prev"
    printf 'shadow_parked_local=%s\n' "$shadow_parked_local"
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
  remove_gateway_shadow
  restore_dns
  stop_doh_forwarder
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

# Resolvers for the runner, RUN_DNS first, without duplicates.
runner_servers() {
  printf '%s\n' "$RUN_DNS"
  if [[ "$DNS_SERVER_1" != "$RUN_DNS" ]]; then
    printf '%s\n' "$DNS_SERVER_1"
  fi
  if [[ "$DNS_SERVER_2" != "$RUN_DNS" && "$DNS_SERVER_2" != "$DNS_SERVER_1" ]]; then
    printf '%s\n' "$DNS_SERVER_2"
  fi
}

# Text of the resolv.conf bind-mounted for `netshare run`. use-vc forces
# TCP. tun2proxy proxies that as an ordinary TCP session. A UDP query takes
# the DNS-over-TCP helper instead, and that helper can sit in the SOCKS
# handshake until the client gives up. Curl's connect timeout includes DNS,
# so a hung UDP query also cancelled the second server.
runner_resolv_text() {
  local server
  while IFS= read -r server; do
    [[ -n "$server" ]] || continue
    printf 'nameserver %s\n' "$server"
  done < <(runner_servers)
  printf '%s\n' "options timeout:${DNS_QUERY_TIMEOUT} attempts:1 use-vc single-request-reopen"
}

ensure_etc() {
  install -d -m 0755 "$ETC_DIR"
  runner_resolv_text >"${ETC_DIR}/resolv.conf"
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
  [[ "$MAX_SESSIONS" =~ ^[1-9][0-9]*$ ]] || die "MAX_SESSIONS must be a positive integer"
  if [[ -n "$PROXY_URL" ]]; then
    # Discovery, the bar, and the session proxy use this HTTP URL.
    # tun2proxy receives the SOCKS5 form of the same host and port.
    [[ "$PROXY_URL" == http://* ]] || die "PROXY_URL must start with http://"
    [[ "$PROXY_URL" != *@* ]] || die "PROXY_URL must not carry credentials"
  fi
}

# SOCKS5 URL for tun2proxy. PROXY_URL itself stays http://host:port.
# Prints the URL on stdout. On rejection, prints the reason on stderr and
# returns 1 so a caller in the middle of setup can tear down.
data_plane_proxy() {
  local url=$1 rest hostport
  if [[ -z "$url" ]]; then
    echo "netshare: PROXY_URL is empty" >&2
    return 1
  fi
  if [[ "$url" == *@* ]]; then
    echo "netshare: PROXY_URL must not carry credentials" >&2
    return 1
  fi
  case "$url" in
    http://*|socks5://*) ;;
    *)
      echo "netshare: PROXY_URL must start with http://" >&2
      return 1
      ;;
  esac
  rest=${url#*://}
  hostport=${rest%%[/?#]*}
  if [[ "$hostport" != *:* || "$hostport" == :* || "$hostport" == *: ]]; then
    echo "netshare: PROXY_URL must include a host and port" >&2
    return 1
  fi
  printf 'socks5://%s\n' "$hostport"
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
  local src_addr=$1 proxy_url=$2 bind=${3:-$1} code
  if code=$(curl -sS -o /dev/null -w '%{http_code}' \
      --interface "$bind" \
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
  local dev type state cidr local_src gw bypass url code ssid conn want_host line bind holder
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
    # The gateway address may be local on another interface. Binding the
    # probe to this link reaches the phone; the source address does not.
    bind=$local_src
    holder=$(gateway_address_iface "$gw")
    if [[ -n "$holder" && "$holder" != "$dev" ]] && probe_prepare_shadow "$dev"; then
      bind=$dev
    fi
    code=$(proxy_http_code "$local_src" "$url" "$bind")
    probe_restore_shadow
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

# stdin is `ip -o -4 addr` lines. Prints the interface holding $1.
iface_holding_address() {
  local gw=$1
  awk -v gw="$gw" '$3 == "inet" { split($4, a, "/"); if (a[1] == gw) { print $2; exit } }'
}

gateway_address_iface() {
  local gw=$1 lines
  [[ "$gw" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 0
  lines=$(ip -o -4 addr show to "${gw}/32" 2>/dev/null || true)
  [[ -n "$lines" ]] || return 0
  printf '%s\n' "$lines" | iface_holding_address "$gw"
}

# The proxy port, not the address. A local gateway address still owns every
# other port. Optional arg is a uid for the lookup.
proxy_route_dev() {
  local uid=${1:-} line=""
  if [[ -n "$uid" ]]; then
    line=$(ip -4 route get "$gateway" ipproto tcp dport "$PROXY_PORT" uid "$uid" 2>/dev/null || true)
  else
    line=$(ip -4 route get "$gateway" ipproto tcp dport "$PROXY_PORT" 2>/dev/null || true)
  fi
  printf '%s\n' "$line" | awk '{
    for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit }
  }'
}

shadow_rule_present() {
  ip rule show pref 0 | grep -q "to ${gateway} ipproto tcp dport ${PROXY_PORT} lookup ${GATEWAY_TABLE}"
}

restore_shadow_sysctls() {
  local dev=${1:-$iface}
  [[ "$dev" =~ ^[A-Za-z0-9._-]+$ ]] || return 0
  if [[ "$shadow_accept_prev" =~ ^[0-9]+$ ]]; then
    sysctl -q -w "net.ipv4.conf.${dev}.accept_local=${shadow_accept_prev}" || true
  fi
  if [[ "$shadow_rp_prev" =~ ^[0-9]+$ ]]; then
    sysctl -q -w "net.ipv4.conf.${dev}.rp_filter=${shadow_rp_prev}" || true
  fi
}

# A new pref 0 rule is stored after the local rule, so it would never run.
# Park the local rule at pref 1, then the proxy-port rule is the first one.
rollback_gateway_shadow() {
  local gw=${gateway:-$NETSHARE_GATEWAY}
  ip rule del pref 0 to "$gw" ipproto tcp dport "$PROXY_PORT" lookup "$GATEWAY_TABLE" >/dev/null 2>&1 || true
  if ! ip rule show pref 0 | grep -q 'from all lookup local'; then
    ip rule add pref 0 from all lookup local >/dev/null 2>&1 || true
  fi
  if [[ "$shadow_parked_local" == "1" ]]; then
    ip rule del pref 1 from all lookup local >/dev/null 2>&1 || true
  fi
  ip route flush table "$GATEWAY_TABLE" >/dev/null 2>&1 || true
  restore_shadow_sysctls
  shadow_active=0
  shadow_parked_local=0
  rm -f "${RUN_DIR}/shadow"
}

remove_gateway_shadow() {
  local file="${RUN_DIR}/shadow" line key value dev=""
  if [[ -f "$file" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ "$line" == *=* ]] || continue
      key=${line%%=*}
      value=${line#*=}
      case "$key" in
        iface) dev=$value ;;
        gateway) gateway=${gateway:-$value} ;;
        accept_prev) shadow_accept_prev=$value ;;
        rp_prev) shadow_rp_prev=$value ;;
        parked_local) shadow_parked_local=$value ;;
      esac
    done <"$file"
    [[ -n "$dev" ]] && iface=$dev
    shadow_active=1
  fi
  [[ "$shadow_active" == "1" ]] || return 0
  [[ -n "$gateway" ]] || gateway=${state_gateway:-$NETSHARE_GATEWAY}
  rollback_gateway_shadow
}

install_gateway_shadow() {
  local holder prev_accept prev_rp
  shadow_active=0
  shadow_parked_local=0
  holder=$(gateway_address_iface "$gateway")
  [[ -n "$holder" && "$holder" != "$iface" ]] || return 0
  [[ "$iface" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
  [[ "$gateway" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  [[ "$src" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  [[ "$PROXY_PORT" =~ ^[0-9]+$ ]] || return 1

  prev_accept=$(sysctl -n "net.ipv4.conf.${iface}.accept_local" 2>/dev/null) || return 1
  prev_rp=$(sysctl -n "net.ipv4.conf.${iface}.rp_filter" 2>/dev/null) || return 1
  sysctl -q -w "net.ipv4.conf.${iface}.accept_local=1" || return 1
  if ! sysctl -q -w "net.ipv4.conf.${iface}.rp_filter=2"; then
    sysctl -q -w "net.ipv4.conf.${iface}.accept_local=${prev_accept}" || true
    return 1
  fi
  shadow_accept_prev=$prev_accept
  shadow_rp_prev=$prev_rp

  if ! ip route replace table "$GATEWAY_TABLE" "${gateway}/32" dev "$iface" src "$src"; then
    rollback_gateway_shadow
    return 1
  fi
  if ! ip rule show pref 1 | grep -q 'from all lookup local'; then
    if ! ip rule add pref 1 from all lookup local; then
      rollback_gateway_shadow
      return 1
    fi
  fi
  shadow_parked_local=1
  if ! shadow_rule_present; then
    if ! ip rule add pref 0 to "$gateway" ipproto tcp dport "$PROXY_PORT" lookup "$GATEWAY_TABLE"; then
      rollback_gateway_shadow
      return 1
    fi
  fi
  if ip rule show pref 0 | grep -q 'from all lookup local'; then
    if ! ip rule del pref 0 from all lookup local; then
      rollback_gateway_shadow
      return 1
    fi
  fi
  if [[ "$(proxy_route_dev)" != "$iface" || "$(route_dev "$gateway")" != "lo" ]]; then
    rollback_gateway_shadow
    return 1
  fi
  shadow_active=1
  install -d -m 0755 "$RUN_DIR"
  cat >"${RUN_DIR}/shadow" <<EOF
iface=${iface}
gateway=${gateway}
accept_prev=${shadow_accept_prev}
rp_prev=${shadow_rp_prev}
parked_local=${shadow_parked_local}
EOF
  chmod 0644 "${RUN_DIR}/shadow"
}

# The discovery probe is short. It puts accept_local back before it returns,
# including when status is not root and the sysctl is refused.
probe_prepare_shadow() {
  local dev=$1
  probe_accept_dev=""
  [[ "$dev" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
  probe_accept_prev=$(sysctl -n "net.ipv4.conf.${dev}.accept_local" 2>/dev/null) || return 1
  probe_rp_prev=$(sysctl -n "net.ipv4.conf.${dev}.rp_filter" 2>/dev/null) || return 1
  sysctl -q -w "net.ipv4.conf.${dev}.accept_local=1" >/dev/null 2>&1 || return 1
  if ! sysctl -q -w "net.ipv4.conf.${dev}.rp_filter=2" >/dev/null 2>&1; then
    sysctl -q -w "net.ipv4.conf.${dev}.accept_local=${probe_accept_prev}" >/dev/null 2>&1 || true
    return 1
  fi
  probe_accept_dev=$dev
}

probe_restore_shadow() {
  local dev=$probe_accept_dev
  [[ -n "$dev" ]] || return 0
  sysctl -q -w "net.ipv4.conf.${dev}.accept_local=${probe_accept_prev}" >/dev/null 2>&1 || true
  sysctl -q -w "net.ipv4.conf.${dev}.rp_filter=${probe_rp_prev}" >/dev/null 2>&1 || true
  probe_accept_dev=""
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
  # The forwarder listens on the tun address and asks the public resolvers
  # over HTTPS. DNS-over-TLS on this link would send port 853 at that
  # forwarder, which speaks ordinary DNS.
  [[ -n "$tun_ip" ]] || return 1
  if [[ ! -f "$DOH_PID" ]] || ! kill -0 "$(<"$DOH_PID")" 2>/dev/null; then
    echo "netshare: DNS forwarder is not running" >&2
    return 1
  fi
  resolvectl dns "$TUN" "$tun_ip" || return 1
  resolvectl domain "$TUN" '~.' || return 1
  resolvectl default-route "$TUN" true || return 1
  resolvectl dnsovertls "$TUN" no || return 1
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

# NetworkManager adopts a new tun and sends its connectivity check into it.
# Those sessions stay open on the phone proxy when the SOCKS handshake does
# not finish, and the transport probe then fails while a direct request to
# the same proxy still succeeds. Mark the tun unmanaged before it appears.
nm_unmanaged_rule() {
  printf '%s\n' "ACTION==\"add\", SUBSYSTEM==\"net\", KERNEL==\"${TUN}\", ENV{NM_UNMANAGED}=\"1\", ENV{ID_NET_MANAGED}=\"0\""
}

ensure_nm_unmanaged() {
  [[ "$TUN" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
  local dst=/etc/udev/rules.d/99-netshare-tun.rules tmp
  tmp=$(mktemp)
  nm_unmanaged_rule >"$tmp"
  if [[ ! -f "$dst" ]] || ! cmp -s "$tmp" "$dst"; then
    install -m 0644 "$tmp" "$dst"
  fi
  rm -f "$tmp"
  udevadm control --reload-rules >/dev/null 2>&1 || true
}

release_tun_from_nm() {
  local managed
  managed=$(nmcli -g GENERAL.NM-MANAGED device show "$TUN" 2>/dev/null || true)
  [[ "$managed" == "yes" ]] || return 0
  nmcli device set "$TUN" managed no >/dev/null 2>&1 || true
  sleep 0.3
}

# One direct request through the access-point proxy, bound to the client
# address so it cannot enter the tun. Proves the phone has upstream.
proxy_upstream_ok() {
  local code
  [[ -n "$src" && -n "$PROXY_URL" ]] || return 1
  code=$(curl -4 -sS -o /dev/null -w '%{http_code}' \
    --interface "$src" \
    --proxy "$PROXY_URL" \
    --connect-timeout 4 --max-time 8 \
    https://example.com 2>/dev/null) || return 1
  [[ "$code" =~ ^[23][0-9][0-9]$ ]]
}

launch_engine() {
  local plane=$1 ready=0 i
  # tun2proxy must not inherit the lock fd. An inherited flock stays
  # held for the life of the process, and later up/down/run block on it.
  setsid "$TUN2PROXY" \
    --proxy "$plane" \
    --tun "$TUN" \
    --mtu "$TUN_MTU" \
    --dns over-tcp \
    --dns-addr "$DNS_SERVER_1" \
    --bypass "$BYPASS_CIDR" \
    --verbosity info \
    --exit-on-fatal-error \
    --max-sessions "$MAX_SESSIONS" \
    >>"$LOG" 2>&1 </dev/null 9>&- &
  pid=$!
  printf '%s\n' "$pid" >"${RUN_DIR}/pid"
  for ((i = 0; i < 50; i++)); do
    if ! pid_alive; then
      echo "netshare: tun2proxy exited" >&2
      tail -n 40 "$LOG" >&2 || true
      return 1
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
    return 1
  fi
  release_tun_from_nm
  ip link show "$TUN" >/dev/null 2>&1
}

stop_engine() {
  local _
  if pid_alive; then
    kill -INT "$pid" >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      pid_alive || break
      sleep 0.2
    done
    if pid_alive; then
      kill -KILL "$pid" >/dev/null 2>&1 || true
    fi
  fi
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    ip link show "$TUN" >/dev/null 2>&1 || return 0
    sleep 0.1
  done
  ip link del "$TUN" >/dev/null 2>&1 || true
  if ip link show "$TUN" >/dev/null 2>&1; then
    return 1
  fi
}

# True when a neighbor inside the phone subnet was learned on another device.
# The desktop table would otherwise send it out the phone link.
keep_foreign_bypass_host() {
  local ipaddr=$1 dev=$2 nud=$3 ap=$4 tun=$5 bypass=$6
  [[ "$ipaddr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  [[ "$dev" =~ ^[A-Za-z0-9._-]+$ && "$dev" != "$ap" && "$dev" != "$tun" ]] || return 1
  case "$nud" in
    REACHABLE|STALE|DELAY|PROBE|PERMANENT) ;;
    *) return 1 ;;
  esac
  python3 -c '
import ipaddress, sys
host = ipaddress.ip_address(sys.argv[1])
net = ipaddress.ip_network(sys.argv[2], strict=False)
sys.exit(0 if host in net and host != net.network_address and host != net.broadcast_address else 1)
' "$ipaddr" "$bypass"
}

install_foreign_bypass_hosts() {
  local ipaddr dev nud src_on
  [[ -n "$BYPASS_CIDR" && -n "$iface" ]] || return 0
  while read -r ipaddr dev nud; do
    keep_foreign_bypass_host "$ipaddr" "$dev" "$nud" "$iface" "$TUN" "$BYPASS_CIDR" || continue
    src_on=$(ip -4 -o addr show dev "$dev" scope global 2>/dev/null | awk '{ split($4, a, "/"); print a[1]; exit }')
    [[ "$src_on" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || continue
    ip route replace table "$TABLE" "${ipaddr}/32" dev "$dev" src "$src_on" || return 1
  done < <(ip -4 neigh show | awk '{
    dev = ""
    for (i = 1; i <= NF; i++) if ($i == "dev") dev = $(i + 1)
    if (dev != "") print $1, dev, $NF
  }')
}

configure_tun_link() {
  sysctl -q -w "net.ipv6.conf.${TUN}.disable_ipv6=1" || true
  ip link set dev "$TUN" mtu "$TUN_MTU" up
  ip addr replace "${tun_ip}/32" dev "$TUN"
  tun_addr="${tun_ip}/32"
  ip route replace table "$TABLE" "$BYPASS_CIDR" dev "$iface" src "$src" || return 1
  ip route replace table "$TABLE" "${tun_ip}/32" dev "$TUN" || return 1
  ip route replace table "$TABLE" default dev "$TUN" src "$tun_ip" || return 1
  install_foreign_bypass_hosts || return 1
}

# New tun2proxy process, same routes. Does not touch nft or the uid rules.
restart_dataplane() {
  stop_engine || return 1
  launch_engine "$engine_plane" || return 1
  configure_tun_link || return 1
  write_state || return 1
  [[ "$(proxy_route_dev)" == "$iface" ]]
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
    start_doh_forwarder || exit 1
    point_runner_at_forwarder || exit 1
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

# TCP DNS A query. argv: server, name, timeout seconds, optional port.
# Port 53 is the resolver. A client TCP session is proxied as an ordinary
# tun2proxy TCP flow. The DNS-over-TCP helper is only used for UDP/53.
DNS_A_QUERY=$(cat <<'PY'
import socket, struct, sys, time

def encode(name):
    out = b''
    for part in name.rstrip('.').split('.'):
        try:
            raw = part.encode('ascii')
        except UnicodeEncodeError:
            return None
        if not raw or len(raw) > 63:
            return None
        out += bytes([len(raw)]) + raw
    return out + b'\x00'

def skip_name(data, i):
    hops = 0
    while hops < 16:
        if i >= len(data):
            raise ValueError('name')
        n = data[i]
        if n == 0:
            return i + 1
        if n & 0xC0 == 0xC0:
            if i + 1 >= len(data):
                raise ValueError('pointer')
            return i + 2
        if n & 0xC0:
            raise ValueError('label')
        nxt = i + 1 + n
        if nxt > len(data):
            raise ValueError('label')
        i = nxt
        hops += 1
    raise ValueError('loop')

def recvall(sock, n):
    buf = b''
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise EOFError
        buf += chunk
    return buf

def query():
    if len(sys.argv) not in (4, 5):
        return 1
    server, qname = sys.argv[1], sys.argv[2]
    timeout = float(sys.argv[3])
    port = int(sys.argv[4]) if len(sys.argv) == 5 else 53
    if not (0 < timeout <= 60) or not (0 < port < 65536):
        return 1
    qn = encode(qname)
    if qn is None:
        return 1
    msg = b'\xab\xcd\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00' + qn + b'\x00\x01\x00\x01'
    if len(msg) > 512:
        return 1
    deadline = time.monotonic() + timeout
    sock = socket.create_connection((server, port), timeout)
    try:
        left = deadline - time.monotonic()
        if left <= 0:
            return 1
        sock.settimeout(left)
        sock.sendall(struct.pack('!H', len(msg)) + msg)
        length = struct.unpack('!H', recvall(sock, 2))[0]
        if length < 12 or length > 4096:
            return 1
        data = recvall(sock, length)
    finally:
        sock.close()
    if data[3] & 0x0F:
        return 1
    qdcount, ancount = struct.unpack('!HH', data[4:8])
    i = 12
    for _ in range(qdcount):
        i = skip_name(data, i)
        if i + 4 > len(data):
            return 1
        i += 4
    for _ in range(ancount):
        i = skip_name(data, i)
        if i + 10 > len(data):
            return 1
        typ, clas, _ttl, rdlen = struct.unpack('!HHIH', data[i:i + 10])
        i += 10
        if i + rdlen > len(data):
            return 1
        rdata = data[i:i + rdlen]
        i += rdlen
        if typ == 1 and clas == 1 and rdlen == 4:
            sys.stdout.write('%d.%d.%d.%d\n' % (rdata[0], rdata[1], rdata[2], rdata[3]))
            return 0
    return 1

try:
    rc = query()
except Exception:
    rc = 1
sys.exit(rc)
PY
)

# One HTTPS DNS query, or a forwarder that speaks ordinary DNS and asks the
# resolvers over HTTPS. Port 53 through the proxy can time out while an
# ordinary page fetch already works. argv is documented on each mode.
DOH_PY=$(cat <<'PY'
import select
import socket
import ssl
import struct
import sys
import threading

SNI = 'cloudflare-dns.com'


def first_a(data):
    if len(data) < 12 or data[3] & 0x0F:
        return None

    def skip_name(i):
        hops = 0
        while hops < 16:
            if i >= len(data):
                raise ValueError('name')
            n = data[i]
            if n == 0:
                return i + 1
            if n & 0xC0 == 0xC0:
                if i + 1 >= len(data):
                    raise ValueError('pointer')
                return i + 2
            if n & 0xC0:
                raise ValueError('label')
            nxt = i + 1 + n
            if nxt > len(data):
                raise ValueError('label')
            i = nxt
            hops += 1
        raise ValueError('loop')

    qdcount, ancount = struct.unpack('!HH', data[4:8])
    i = 12
    for _ in range(qdcount):
        i = skip_name(i)
        if i + 4 > len(data):
            return None
        i += 4
    for _ in range(ancount):
        i = skip_name(i)
        if i + 10 > len(data):
            return None
        typ, clas, _ttl, rdlen = struct.unpack('!HHIH', data[i:i + 10])
        i += 10
        if i + rdlen > len(data):
            return None
        rdata = data[i:i + rdlen]
        i += rdlen
        if typ == 1 and clas == 1 and rdlen == 4:
            return '%d.%d.%d.%d' % (rdata[0], rdata[1], rdata[2], rdata[3])
    return None


def unchunk(body):
    out = b''
    while body:
        line, sep, body = body.partition(b'\r\n')
        if not sep:
            break
        n = int(line.split(b';', 1)[0] or b'0', 16)
        if n == 0:
            break
        out += body[:n]
        body = body[n:]
        if body.startswith(b'\r\n'):
            body = body[2:]
    return out


def header_map(head):
    headers = {}
    for line in head.split(b'\r\n')[1:]:
        if b':' not in line:
            continue
        key, value = line.split(b':', 1)
        headers[key.strip().lower()] = value.strip()
    return headers


def read_http(sock):
    data = b''
    while b'\r\n\r\n' not in data:
        chunk = sock.recv(8192)
        if not chunk:
            break
        data += chunk
        if len(data) > 65536:
            raise ValueError('long http header')
    head, sep, body = data.partition(b'\r\n\r\n')
    if not sep:
        raise ValueError('short http response')
    status = head.split(b'\r\n', 1)[0].split()
    if len(status) < 2 or status[1] != b'200':
        code = status[1].decode('ascii', 'replace') if len(status) > 1 else '?'
        raise ValueError('http %s' % code)
    headers = header_map(head)
    if headers.get(b'transfer-encoding', b'').lower() == b'chunked':
        while b'\r\n0' not in body and not body.endswith(b'\r\n0\r\n\r\n'):
            chunk = sock.recv(8192)
            if not chunk:
                break
            body += chunk
            if len(body) > 1024 * 1024:
                raise ValueError('long http response')
        return unchunk(body)
    if b'content-length' in headers:
        n = int(headers[b'content-length'])
        while len(body) < n:
            chunk = sock.recv(n - len(body))
            if not chunk:
                break
            body += chunk
        return body[:n]
    while True:
        chunk = sock.recv(8192)
        if not chunk:
            break
        body += chunk
        if len(body) > 1024 * 1024:
            raise ValueError('long http response')
    return body


def recvall(conn, n):
    buf = b''
    while len(buf) < n:
        chunk = conn.recv(n - len(buf))
        if not chunk:
            raise EOFError
        buf += chunk
    return buf


def doh_exchange(server, query, timeout, cafile, port):
    raw = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    raw.settimeout(timeout)
    ctx = ssl.create_default_context(cafile=cafile) if cafile else ssl.create_default_context()
    tls = ctx.wrap_socket(raw, server_hostname=SNI)
    try:
        tls.connect((server, port))
        head = (
            'POST /dns-query HTTP/1.1\r\n'
            'Host: %s\r\n'
            'Content-Type: application/dns-message\r\n'
            'Accept: application/dns-message\r\n'
            'Connection: close\r\n'
            'Content-Length: %d\r\n\r\n' % (SNI, len(query))
        ).encode()
        tls.sendall(head + query)
        body = read_http(tls)
    finally:
        tls.close()
    if len(body) < 12 or len(body) > 65535:
        raise ValueError('short dns answer')
    return body


def encode(name):
    out = b''
    for part in name.rstrip('.').split('.'):
        try:
            raw = part.encode('ascii')
        except UnicodeEncodeError:
            return None
        if not raw or len(raw) > 63:
            return None
        out += bytes([len(raw)]) + raw
    return out + b'\x00'


def ask_servers(servers, query, timeout, cafile, port):
    last = 'no dns answer'
    for server in servers:
        if not server:
            continue
        try:
            return doh_exchange(server, query, timeout, cafile, port)
        except Exception as exc:
            last = str(exc)
    raise RuntimeError(last)


def cmd_query():
    if len(sys.argv) not in (5, 6, 7):
        return 2
    server, qname = sys.argv[2], sys.argv[3]
    timeout = float(sys.argv[4])
    cafile = sys.argv[5] if len(sys.argv) >= 6 and sys.argv[5] else None
    port = int(sys.argv[6]) if len(sys.argv) == 7 else 443
    if not (0 < timeout <= 60) or not (0 < port < 65536):
        return 2
    qn = encode(qname)
    if qn is None:
        return 2
    query = b'\xab\xcd\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00' + qn + b'\x00\x01\x00\x01'
    body = ask_servers([server], query, timeout, cafile, port)
    addr = first_a(body)
    if addr is None:
        return 1
    sys.stdout.write(addr + '\n')
    return 0


def drop_priv(name):
    if not name or name == '-':
        return
    import os
    import pwd
    pw = pwd.getpwnam(name)
    os.setgroups([])
    os.setgid(pw.pw_gid)
    os.setuid(pw.pw_uid)


def serve():
    if len(sys.argv) not in (7, 8, 9):
        return 2
    bind, port_s, user, server_s, timeout_s = sys.argv[2:7]
    cafile = sys.argv[7] if len(sys.argv) >= 8 and sys.argv[7] else None
    upstream = int(sys.argv[8]) if len(sys.argv) == 9 else 443
    port = int(port_s)
    timeout = float(timeout_s)
    servers = [s for s in server_s.split(',') if s]
    # Port 0 asks the kernel for an ephemeral port. Callers read it from
    # the ready line. The upstream port is always explicit.
    if not servers or not (0 <= port < 65536) or not (0 < upstream < 65536):
        sys.stderr.write('bad forwarder arguments\n')
        return 2
    if timeout <= 0 or timeout > 60:
        return 2

    def handle(payload):
        return ask_servers(servers, payload, timeout, cafile, upstream)

    def reply_udp(data, addr):
        try:
            if len(data) < 12 or len(data) > 4096:
                return
            body = handle(data)
            udp.sendto(body, addr)
        except Exception:
            return

    def reply_tcp(conn):
        try:
            conn.settimeout(timeout)
            while True:
                ln = struct.unpack('!H', recvall(conn, 2))[0]
                if ln < 12 or ln > 4096:
                    break
                body = handle(recvall(conn, ln))
                conn.sendall(struct.pack('!H', len(body)) + body)
        except Exception:
            pass
        finally:
            conn.close()

    udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    tcp = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    udp.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    tcp.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    udp.bind((bind, port))
    tcp.bind((bind, port))
    tcp.listen(16)
    # Bind while still root, then become the tunnel user so upstream queries
    # use that uid's route into the tun. A mark is applied too late to choose
    # the source, and this process must not need a second default route.
    drop_priv(user)
    udp.setblocking(False)
    tcp.setblocking(False)
    sys.stdout.write('ready %d\n' % udp.getsockname()[1])
    sys.stdout.flush()
    while True:
        readable, _, _ = select.select([udp, tcp], [], [], 1.0)
        for sock in readable:
            if sock is udp:
                try:
                    data, addr = udp.recvfrom(4096)
                except BlockingIOError:
                    continue
                threading.Thread(target=reply_udp, args=(data, addr), daemon=True).start()
            else:
                try:
                    conn, _addr = tcp.accept()
                except BlockingIOError:
                    continue
                threading.Thread(target=reply_tcp, args=(conn,), daemon=True).start()


try:
    mode = sys.argv[1] if len(sys.argv) > 1 else ''
    if mode == 'doh-query':
        rc = cmd_query()
    elif mode == 'doh-serve':
        rc = serve()
    else:
        rc = 2
except Exception as exc:
    sys.stderr.write('%s\n' % exc)
    rc = 1
sys.exit(rc)
PY
)

# HTTPS to one resolver, through the tun. Prints one A record. The uid rule
# selects the tun before a source address is chosen, so this does not need a
# main-table default route.
query_doh() {
  local server=$1 name=$2 addr
  addr=$(unshare --mount --propagation private "$SCRIPT" --inside-run \
    python3 -c "$DOH_PY" doh-query "$server" "$name" "$DNS_QUERY_TIMEOUT") || return 1
  [[ "$addr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  printf '%s\n' "$addr"
}

# Ask one resolver for an A record over TCP. Prints the address. A new
# socket is a new tun2proxy session, so a handshake stuck on an earlier
# query is not reused. The netshare uid rule sends this through the tun.
query_resolver() {
  local server=$1 name=$2 addr
  addr=$(unshare --mount --propagation private "$SCRIPT" --inside-run \
    python3 -c "$DNS_A_QUERY" "$server" "$name" "$DNS_QUERY_TIMEOUT") || return 1
  [[ "$addr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  printf '%s\n' "$addr"
}

# Sets resolved_addr to one public A record, or returns 1 and sets
# resolve_detail. The address stays in the caller: printing it would run
# this function in a subshell and drop resolve_detail. Both resolvers are
# asked over HTTPS before any TCP port 53 socket is opened. A hung port 53
# session would otherwise sit ahead of the other resolver's HTTPS query,
# and that session stays until the data plane exits.
resolve_through_tun() {
  local name=$1 server raw addr errfile err mode
  local -a failed=()
  local last_err=""
  resolve_detail=""
  resolved_addr=""
  errfile=$(mktemp)
  for mode in https tcp; do
    while IFS= read -r server; do
      [[ -n "$server" ]] || continue
      : >"$errfile"
      raw=""
      if [[ "$mode" == https ]]; then
        raw=$(query_doh "$server" "$name" 2>"$errfile") || raw=""
      else
        raw=$(query_resolver "$server" "$name" 2>"$errfile") || raw=""
      fi
      if [[ -n "$raw" ]] && addr=$(printf '%s\n' "$raw" | classify_resolved_address "${BYPASS_CIDR:-0.0.0.0/32}"); then
        rm -f "$errfile"
        resolved_addr=$addr
        return 0
      fi
      failed+=("$server")
      [[ -s "$errfile" ]] || continue
      err=$(tr '\n' ' ' <"$errfile" | sed 's/[[:space:]]*$//')
      [[ -n "$err" ]] && last_err=${err:0:160}
    done < <(runner_servers)
  done
  rm -f "$errfile"
  resolve_detail="no public DNS answer from ${failed[*]}"
  [[ -n "$last_err" ]] && resolve_detail+=" (${last_err})"
  return 1
}

stop_doh_forwarder() {
  local p _
  [[ -f "$DOH_PID" ]] || return 0
  p=$(<"$DOH_PID")
  rm -f "$DOH_PID"
  [[ "$p" =~ ^[0-9]+$ ]] || return 0
  kill "$p" >/dev/null 2>&1 || return 0
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "$p" >/dev/null 2>&1 || return 0
    sleep 0.1
  done
  kill -KILL "$p" >/dev/null 2>&1 || true
}

# Ordinary DNS on the tun address. The process binds that port as root, then
# becomes the tunnel user, so each upstream query takes the same route as the
# transport check.
start_doh_forwarder() {
  local p i
  [[ "$tun_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  if [[ -f "$DOH_PID" ]]; then
    p=$(<"$DOH_PID")
    if [[ "$p" =~ ^[0-9]+$ ]] && kill -0 "$p" 2>/dev/null; then
      return 0
    fi
    rm -f "$DOH_PID"
  fi
  install -d -m 0755 "$RUN_DIR"
  : >"${RUN_DIR}/doh.ready"
  # setsid so this survives up returning. Drop the lock fd so down is not
  # blocked for the life of the forwarder.
  setsid python3 -c "$DOH_PY" doh-serve "$tun_ip" 53 "$RUN_USER" \
    "${DNS_SERVER_1},${DNS_SERVER_2}" "$DNS_QUERY_TIMEOUT" \
    </dev/null >"${RUN_DIR}/doh.ready" 2>"${RUN_DIR}/doh.log" 9>&- &
  printf '%s\n' "$!" >"$DOH_PID"
  for ((i = 0; i < 50; i++)); do
    if grep -q '^ready' "${RUN_DIR}/doh.ready" 2>/dev/null; then
      return 0
    fi
    p=$(<"$DOH_PID")
    if ! kill -0 "$p" 2>/dev/null; then
      return 1
    fi
    sleep 0.05
  done
  return 1
}

doh_fail_detail() {
  local line=""
  [[ -f "${RUN_DIR}/doh.log" ]] || return 0
  line=$(tail -n 1 "${RUN_DIR}/doh.log" 2>/dev/null || true)
  line=${line//$'\n'/ }
  [[ -n "$line" ]] || return 0
  printf ' (%s)' "${line:0:160}"
}

point_runner_at_forwarder() {
  [[ "$tun_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  install -d -m 0755 "$ETC_DIR"
  {
    printf 'nameserver %s\n' "$tun_ip"
    printf '%s\n' "options timeout:${DNS_QUERY_TIMEOUT} attempts:1 use-vc single-request-reopen"
  } >"${ETC_DIR}/resolv.conf"
}

# HTTPS to example.com at an address the tunnel already resolved.
# fetch_code and fetch_err are set. Returns curl's status.
fetch_resolved_https() {
  local addr=$1 errfile code err
  fetch_code=""
  fetch_err=""
  errfile=$(mktemp)
  if code=$(unshare --mount --propagation private "$SCRIPT" --inside-run \
      curl -4 -sS -o /dev/null -w '%{http_code}' \
        --resolve "example.com:443:${addr}" \
        --connect-timeout 8 --max-time 12 \
        https://example.com 2>"$errfile"); then
    fetch_code=$code
    rm -f "$errfile"
    return 0
  fi
  err=$(tr '\n' ' ' <"$errfile" | sed 's/[[:space:]]*$//')
  rm -f "$errfile"
  fetch_code=$code
  fetch_err=${err:0:200}
  return 1
}

# Gate 1. The netshare user is marked into table 849. Do not call
# `netshare run` here: this process holds the lock, and run takes it too.
# Name lookup is separate from curl so the connect timeout cannot cancel
# the second resolver. Each attempt opens new sockets.
probe_marked_http() {
  local attempt
  probe_detail=""
  for ((attempt = 1; attempt <= PROBE_ATTEMPTS; attempt++)); do
    if ! resolve_through_tun example.com; then
      probe_detail=${resolve_detail:-DNS failed}
    elif ! fetch_resolved_https "$resolved_addr"; then
      probe_detail="curl to ${resolved_addr} failed (${fetch_code:-no status})"
      [[ -n "$fetch_err" ]] && probe_detail+=": ${fetch_err}"
    elif [[ "$fetch_code" =~ ^[23][0-9][0-9]$ ]]; then
      probe_detail=""
      return 0
    else
      probe_detail="HTTP ${fetch_code:-no status} from ${resolved_addr}"
    fi
    (( attempt < PROBE_ATTEMPTS )) && sleep "$PROBE_PAUSE"
  done
  if [[ -n "$probe_detail" ]]; then
    probe_detail+=" after ${PROBE_ATTEMPTS} attempts"
  fi
  return 1
}

# Gate 2. Host routes only. The desktop uid rule is not installed yet,
# so ROUTE_PROBE must still follow the main-table default.
verify_dns_gate() {
  local out="" via="" ip_re dns1_re dns2_re url="" plane=""
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
  url=${PROXY_URL:-}
  [[ -n "$url" ]] || url=${state_proxy:-}
  if ! plane=$(data_plane_proxy "$url"); then
    return 1
  fi
  # tun2proxy 0.8.4 logs "Proxy socks5 server: <host>:<port>".
  if ! grep -F "Proxy socks5 server: ${plane#socks5://}" "$LOG" >/dev/null 2>&1; then
    echo "netshare: tun log does not show proxy ${plane#socks5://}" >&2
    return 1
  fi
  ip_re=${tun_ip//./\\.}
  dns1_re=${DNS_SERVER_1//./\\.}
  dns2_re=${DNS_SERVER_2//./\\.}
  local _
  for _ in 1 2 3 4 5 6 7 8; do
    if grep -E "TCP ${ip_re}:[0-9]+ -> (${dns1_re}|${dns2_re}):(443|853)" "$LOG" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.4
  done
  echo "netshare: tun log has no DNS session to ${DNS_SERVER_1} or ${DNS_SERVER_2} on port 443 or 853" >&2
  tail -n 40 "$LOG" >&2 || true
  return 1
}

# Gate 1 across data-plane generations. The direct request decides whether
# another process can help: the phone has to answer it before the first
# probe and after every failure. A phone that stops answering ends the loop.
negotiate_transport() {
  local try
  negotiate_detail=""
  if ! proxy_upstream_ok; then
    negotiate_detail="access point did not answer a direct request"
    return 1
  fi
  for ((try = 1; try <= ENGINE_TRIES; try++)); do
    if probe_marked_http; then
      return 0
    fi
    negotiate_detail=$probe_detail
    if ! proxy_upstream_ok; then
      negotiate_detail="${probe_detail:+$probe_detail; }access point stopped answering direct requests"
      return 1
    fi
    if (( try == ENGINE_TRIES )); then
      negotiate_detail="${probe_detail:+$probe_detail; }direct request succeeded through ${ENGINE_TRIES} data planes"
      return 1
    fi
    echo "netshare: access point has internet; restarting the data plane (${try}/${ENGINE_TRIES})" >&2
    if ! restart_dataplane; then
      negotiate_detail="could not restart the data plane${probe_detail:+ (${probe_detail})}"
      return 1
    fi
  done
  return 1
}

# Gate 2, repeated. One resolvectl miss is not enough to remove the tun
# after the transport check already passed.
confirm_dns_gate() {
  local try
  for ((try = 1; try <= ENGINE_TRIES; try++)); do
    if verify_dns_gate; then
      return 0
    fi
    if (( try < ENGINE_TRIES )); then
      sleep "$PROBE_PAUSE"
    fi
  done
  return 1
}

probe_desktop_http() {
  local uid=$1 gid home code="" attempt
  local -a curl_cmd
  gid=$(id -g "$uid")
  home=$(getent passwd "$uid" | cut -d: -f6)
  [[ -n "$home" ]] || home=/tmp
  # The DNS gate already accepted this address. Putting it on the command
  # keeps curl's connect timeout from waiting on another lookup.
  curl_cmd=(
    curl -4 -sS -o /dev/null -w '%{http_code}'
    --connect-timeout 8 --max-time 12
  )
  if [[ ${RESOLVED_EXAMPLE_IP:-} =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    curl_cmd+=(--resolve "example.com:443:${RESOLVED_EXAMPLE_IP}")
  fi
  curl_cmd+=(https://example.com)
  for ((attempt = 1; attempt <= PROBE_ATTEMPTS; attempt++)); do
    code=""
    if code=$(
      cd /tmp
      setpriv --reuid "$uid" --regid "$gid" --clear-groups \
        --no-new-privs --inh-caps=-all --reset-env \
        env PATH="/usr/bin:/bin" "HOME=${home}" \
        "${curl_cmd[@]}"
    ) && [[ "$code" =~ ^[23][0-9][0-9]$ ]]; then
      return 0
    fi
    (( attempt < PROBE_ATTEMPTS )) && sleep "$PROBE_PAUSE"
  done
  echo "netshare: desktop curl failed (${code:-no status})" >&2
  return 1
}

verify_desktop_gate() {
  local dev="" main_via="" main_dev="" domain="" saved_link="" shown="" qout="" lan_prefix="" v6="" mark code_ok=0
  dev=$(route_dev "$ROUTE_PROBE" "$desktop_uid")
  if [[ "$dev" != "$TUN" ]]; then
    echo "netshare: desktop route to ${ROUTE_PROBE} is ${dev:-missing}" >&2
    return 1
  fi
  dev=$(proxy_route_dev "$desktop_uid")
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
  local engine rule nft_state half bound_iface="" bound_src="" bound_proxy="" bound_ssid="" plane=""
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
    if [[ -n "$bound_proxy" ]]; then
      plane=$(data_plane_proxy "$bound_proxy" 2>/dev/null || true)
      if [[ -n "$plane" ]]; then
        echo "data-plane: ${plane}"
      fi
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
  local main_default detail plane=""
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
  plane=$(data_plane_proxy "$PROXY_URL") || plane=""
  if [[ -n "$plane" ]]; then
    echo "  data plane: ${plane}"
  fi
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
  local traffic_uid=0 plane=""
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
  plane=$(data_plane_proxy "$PROXY_URL") || exit 1
  engine_plane=$plane
  ensure_user
  ensure_etc
  ensure_dispatcher
  ensure_nm_unmanaged || fail_up "could not keep NetworkManager off ${TUN}"
  install -d -m 0755 "$LOG_DIR"
  : >"$LOG"
  chmod 0644 "$LOG"

  trap on_up_err ERR
  trap on_up_signal INT TERM
  # The device stays down and has no address unless --setup is passed.
  # launch_engine does not pass --setup. The proxy port has to leave this
  # host before tun2proxy connects, when the gateway address is local here.
  if ! install_gateway_shadow; then
    fail_up "could not reach ${gateway} on ${iface} while that address is local"
  fi
  if ! launch_engine "$plane"; then
    fail_up "tun2proxy did not stay up"
  fi
  # A /32 is a local address. It does not install a connected subnet.
  if ! configure_tun_link; then
    fail_up "could not configure ${TUN}"
  fi
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
  if [[ "$(proxy_route_dev)" != "$iface" ]]; then
    fail_up "gateway ${gateway} is not on ${iface}"
  fi
  if ! negotiate_transport; then
    fail_up "transport through the access-point proxy failed${negotiate_detail:+ (${negotiate_detail})}"
  fi

  # No account to move. Leave the host resolver alone. `netshare run` uses
  # the forwarder on the tun address.
  if (( traffic_uid == 0 )); then
    if ! start_doh_forwarder; then
      fail_up "could not start DNS on ${TUN}$(doh_fail_detail)"
    fi
    if ! point_runner_at_forwarder; then
      fail_up "could not point the runner at DNS"
    fi
    trap - ERR INT TERM
    start_reap
    report_up
    exit 0
  fi

  # Gate 2. DNS host routes only. No desktop rule and no /1 routes.
  if ! install_dns_host_routes; then
    fail_up "could not install DNS host routes"
  fi
  if ! start_doh_forwarder; then
    fail_up "could not start DNS on ${TUN}$(doh_fail_detail)"
  fi
  if ! point_runner_at_forwarder; then
    fail_up "could not point the runner at DNS"
  fi
  if ! record_dns_links; then
    fail_up "could not save the current resolver"
  fi
  if ! apply_tunnel_dns; then
    fail_up "could not point resolved at the tun"
  fi
  if ! confirm_dns_gate; then
    fail_up "resolver did not return a public address through the tun; desktop default was not changed"
  fi
  if [[ "$(route_dev "$ROUTE_PROBE")" == "$TUN" ]]; then
    fail_up "${ROUTE_PROBE} already uses ${TUN} before the desktop rule"
  fi
  if [[ "$(proxy_route_dev)" != "$iface" ]]; then
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
      if ! start_doh_forwarder; then
        die "could not start DNS on ${TUN}$(doh_fail_detail)"
      fi
      if ! point_runner_at_forwarder; then
        stop_doh_forwarder
        die "could not point the runner at DNS"
      fi
      if [[ ! -f "$DNS_LINKS_FILE" ]]; then
        record_dns_links
      fi
      if ! apply_tunnel_dns; then
        stop_doh_forwarder
        runner_resolv_text >"${ETC_DIR}/resolv.conf"
        restore_dns
        delete_dns_host_routes
        die "could not point resolved at the tun"
      fi
      if ! confirm_dns_gate; then
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

