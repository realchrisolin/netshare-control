# netshare

Console controller for a NetShare HTTP-proxy tun. An Omarchy bar panel is
optional and is not required to bring the tunnel up.

NetShare tells clients to use an HTTP proxy on the access point's gateway.
This tree owns routes, policy routing, and DNS. [tun2proxy](https://github.com/tun2proxy/tun2proxy)
is the data plane. It is installed separately and is never started with
`--setup`. Checksums for the 0.8.4 static binary are in `TUN2PROXY.txt`.

The address mapping is the one that app builds: a client address in
`192.168.49.0/24` becomes `10.10.` plus those last two octets, as a `/32`,
through the gateway `192.168.49.1` port `8282`. Those values are the app's,
not a setting for some other LAN.

The tunnel code is `lib/tunnel.sh`. The panel readout is `lib/bar.sh`.
The `netshare` command is the console entry and works without the panel.

## Dependencies

`up` checks the required commands and stops before it changes routes when
one is missing. Python is the standard library only (`ipaddress` and
`urllib.parse`).

Required:

- `bash`
- `sudo`, when the command is not already root
- `tun2proxy` 0.8.4 at `/usr/local/bin/tun2proxy`, or `TUN2PROXY`. The upstream release, checksums, and attestation are in `TUN2PROXY.txt`
- `python3` (Arch `python`, Debian `python3`)
- `nmcli` from NetworkManager
- `curl`
- `resolvectl` from systemd
- `ip` from iproute2
- `nft` from nftables
- `flock` and `setpriv` from util-linux

The desktop password dialog, including the bar switch, needs `pinentry-qt`
or `pinentry-gnome3` from the `pinentry` package. `SUDO_ASKPASS` can name
another helper. A terminal prompt does not need pinentry.

The scripts also use coreutils, `grep`, `sed`, `awk`, and `cmp`.

Optional. The tun still comes up without them:

- `gsettings` publishes the GNOME proxy settings
- `systemctl --user` and `dbus-update-activation-environment` publish the session environment
- `iw` fills the SSID field
- `logger` writes the reap line

`bash test/run.sh` also needs `node` for `test/panel.js`.

## Install

Install the commands listed in Dependencies. `up` checks them before it
changes routes.

`tun2proxy` is a separate binary. Download the 0.8.4 release named in
`TUN2PROXY.txt`, check the zip and binary checksums there, then copy the
binary into place:

```bash
sudo install -m 0755 tun2proxy /usr/local/bin/tun2proxy
```

`TUN2PROXY` can name another path.

Put the controller on `PATH`. `~/.local/bin` is the usual place:

```bash
git clone https://github.com/realchrisolin/netshare-control.git
cd netshare-control
ln -s "$PWD/netshare" ~/.local/bin/netshare
```

Overrides are optional. `/etc/netshare.conf` must be owned by root. Copy the
example and keep the real file out of git:

```bash
sudo install -m 0644 -o root -g root netshare.conf.example /etc/netshare.conf
```

The Omarchy bar is optional. The shell loads `netshare.js` from beside the
QML file, so symlink both. Add this widget to the bar layout in
`~/.config/omarchy/shell.json`:

```json
{ "id": "netshare", "type": "qml" }
```

```bash
mkdir -p ~/.config/omarchy/bar/modules
ln -s "$PWD/bar/netshare.qml" ~/.config/omarchy/bar/modules/netshare.qml
ln -s "$PWD/bar/netshare.js" ~/.config/omarchy/bar/modules/netshare.js
```

Restart the shell after the module is in place. Refreshing the shell rewrites
the rest of the user config, so leave that command alone.

## How to use

Connect to the NetShare access point with NetworkManager. `up` then uses a
connected link whose gateway answers as an HTTP proxy on port 8282.

```bash
sudo netshare up
netshare status
sudo netshare run curl -sI https://example.com
sudo netshare down
```

`up`, `down`, `run`, `toggle`, and `default` need root. That root creates
the tun, installs its routes and firewall rules, and points the resolver at
it. sudo is how an account reaches that root, and the account that ran sudo
is the one whose traffic then uses the tun. `status` and `bar` only read
state.

A cached sudo ticket is reused. From a terminal, sudo asks on that terminal.
With no terminal, sudo opens a desktop password dialog (`pinentry-qt`, or
`pinentry-gnome3`). `SUDO_ASKPASS` overrides that helper. The bar sets
`NETSHARE_PROMPT=desktop` so the switch uses the dialog even when the session
still has a terminal. `NETSHARE_PROMPT=terminal` forces the terminal prompt.

`sudo netshare up` from an account sends that account through the tun after
public DNS through the tun succeeds. The main-table default stays where
NetworkManager put it. Root with no account selected still brings the tun up,
leaves the host resolver alone, and limits the tun to `netshare run`.

To choose the account from a root shell, set `NETSHARE_UID` in
`/etc/netshare.conf` to that account's numeric uid. `netshare default on`
installs the same uid rule later. `netshare default off` removes it and
leaves the tun up for `netshare run`. `toggle` brings the tun up, or down if
it is already up.

From the bar, a left click opens the panel. The switch runs the same `up` or
`down`. `netshare status` prints the live link. `netshare bar` prints one
JSON object for the panel and leaves routes alone. Keep either command's
output out of a commit.

## Settings

`/etc/netshare.conf` is sourced after these defaults. It must be owned by
root. Assignments use shell syntax, as in `netshare.conf.example`. Leave a
name out of the file to keep its default. An exported value is kept when the
file does not assign that name, and the file wins when it does.

Empty `PROXY_URL`, `BYPASS_CIDR`, `IFACE`, and `CONNECTION_PREFIX` mean
discover.

| Name | Default | Expected | What it does |
| --- | --- | --- | --- |
| `PROXY_PORT` | `8282` | TCP port | Port used to build `http://<gateway>:<port>` when `PROXY_URL` is empty. |
| `PROXY_URL` | empty | `http://host:port` with no user or password, or empty | Pins the proxy. A set value also ignores gateways that are a different host. |
| `BYPASS_CIDR` | empty | IPv4 CIDR, or empty | On-link prefix that stays off the tun. A set value keeps only a link whose on-link route is that CIDR. |
| `IFACE` | empty | NetworkManager device name, or empty | Limits the probe to one device. Required when two proxies answer. |
| `CONNECTION_PREFIX` | empty | start of a connection name, or empty | Used only by `bar`. Empty lists every link the probe accepted. |
| `NETSHARE_UID` | empty | numeric uid other than `0`, or empty | Account whose traffic follows the tun. Overrides `SUDO_UID`. Empty, with no sudo user, leaves side posture for `netshare run`. |
| `TUN2PROXY` | `/usr/local/bin/tun2proxy` | path of an executable | The data-plane binary. The environment supplies this default before the conf file is read. |
| `NETSHARE_PROMPT` | unset | `desktop`, `terminal`, or unset | Unset uses a terminal when there is one, and the desktop dialog otherwise. `desktop` forces the dialog. `terminal` forces the terminal. |
| `SUDO_ASKPASS` | unset | path of an executable, or unset | Desktop password program. Unset uses `lib/askpass.sh`. |
| `NETSHARE_PINENTRY` | unset | path of an executable, or unset | pinentry program for `lib/askpass.sh`. Unset tries `pinentry-qt`, then `pinentry-gnome3`. |

`sudo` sets `SUDO_UID` to the account that invoked it. A value of `0` is ignored. The password dialog text is `Password required for netshare: `.

These names are the working defaults. The same conf file can override them. `up` rejects a mark that overlaps `0xff0000`, a rule priority that is not ahead of Tailscale's `5210`, a runner priority that is outside that gap, and a desktop priority that is not between Tailscale's lookup rule at `5270` and the main rule at `32766`.

| Name | Default | Expected | What it does |
| --- | --- | --- | --- |
| `TUN` | `ns0` | device name | Tun interface. |
| `TABLE` | `849` | routing table number | Side table for tun traffic. |
| `MARK` | `0x849` | fwmark outside `0xff0000` | Mark on packets that use `TABLE`. |
| `RULE_PREF` | `5000` | integer below `5210` | Priority of the fwmark rule. |
| `RUNNER_RULE_PREF` | `5010` | integer between `RULE_PREF` and `5210` | Priority of the `RUN_USER` uid rule. |
| `DESKTOP_RULE_PREF` | `5300` | integer after `5270` and before `32766` | Priority of the selected account's uid rule. |
| `TUN_MTU` | `10000` | MTU | Tun MTU. |
| `VIRTUAL_CIDR` | `198.18.0.0/15` | IPv4 CIDR | tun2proxy's virtual address pool. It is not a resolver. |
| `DNS_SERVER_1` | `8.8.8.8` | IPv4 address | First resolver given to the tun. |
| `DNS_SERVER_2` | `8.8.4.4` | IPv4 address | Second resolver given to the tun. |
| `RUN_DNS` | `DNS_SERVER_1` | IPv4 address | Resolver for `netshare run`. |
| `NETSHARE_PREFIX` | `192.168.49.` | IPv4 prefix text | Client addresses must start with this. The tun address is `10.10.` plus the last two octets. |
| `NETSHARE_GATEWAY` | `192.168.49.1` | IPv4 address | Proxy gateway. It is not mapped to a tun address. |
| `RUN_USER` | `netshare` | user name | System user for `netshare run`. Created if missing. |
| `BAR_ICON` | U+F0EC | one character | Glyph drawn in the bar. |

Runtime files are not settings. State and session bookkeeping live under `/run/netshare`. The tun2proxy log is `/var/log/netshare/tun2proxy.log`. `netshare run` bind-mounts resolver files from `/etc/netshare`. The proxy file for programs that ignore the routing table is `/etc/sysconfig/proxy`.

## Access point

A connected Wi-Fi or Ethernet link qualifies when its gateway answers as an
HTTP proxy on the configured port. The SSID is not a selection key. Two
answering links need `IFACE` in `/etc/netshare.conf`.

`CONNECTION_PREFIX` is optional and applies only to `netshare bar`. Empty
lists every link the probe accepted. A non-empty value is a NetworkManager
connection-name prefix, so a panel can ignore other networks. `up` still
considers every connected link.

## Routing

The selected account's packets use a uid rule into a side table before the
kernel picks a source address. A mark set in a later netfilter hook is not
enough for that. The main-table default stays in place. There are no `/1`
routes. systemd-resolved is not pointed at `198.18.0.1`. ICMP, QUIC, and
arbitrary UDP are out of scope.

When an account is selected, `up` also publishes the access-point proxy for
programs that ignore the routing table. That is `/etc/sysconfig/proxy`, the
account's user environment when a session bus exists, and gsettings when
`gsettings` is installed. A host without those still gets the tun.

## Omarchy bar

`bar/netshare.qml` is an optional bar module. Install covers the symlinks
and the shell restart. Left click opens the panel and leaves the tunnel as
it is. The switch runs `netshare up` or `netshare down`.

The hero names the focused connection. The status line is Desktop or Side
while the tunnel is up (`desktop` and `side` are the posture values), and
Off, Stale, Starting, or Stopping otherwise. The rows are connection,
adapter, address, proxy host:port, and the tun address. While the tunnel is
up or the saved state is stale, those rows stay on the bound adapter.

The module polls `netshare bar`. Saving the QML does not reload a running
shell.

## Tests

```bash
bash test/run.sh
```

The tests source the tunnel library and stub `ip` and `nmcli`. They do not call `up` or `down`. `node` runs `test/panel.js`.

## Out of scope

A systemd unit, a general VPN manager, and editing a packaged desktop tree.
