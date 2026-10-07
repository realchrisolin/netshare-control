# netshare

Controller and Omarchy bar panel for a NetShare HTTP-proxy tun.

NetShare tells clients to use an HTTP proxy on the access point's gateway.
This tree owns routes, policy routing, and DNS. [tun2proxy](https://github.com/tun2proxy/tun2proxy)
is the data plane. It is installed separately and is never started with
`--setup`. Checksums for the 0.8.4 static binary are in `TUN2PROXY.txt`.

The address mapping is the one that app builds: a client address in
`192.168.49.0/24` becomes `10.10.` plus those last two octets, as a `/32`,
through the gateway `192.168.49.1` port `8282`. Those values are the app's,
not a setting for some other LAN.

## Commands

`up` and `down` need root. The bar calls them with passwordless sudo.

```
netshare up
netshare down
netshare status
netshare bar
netshare toggle
netshare run curl -sI https://example.com
netshare default on|off
```

`up` leaves the main-table default where NetworkManager put it. After public
DNS through the tun succeeds, desktop traffic uses a uid rule into a side
table. `default on` installs that desktop path. `default off` removes it and
leaves the tun up for `netshare run`.

`status` prints the live link. `bar` prints one JSON object and does not
change routes. Neither command's output belongs in a commit.

## Access point

A connected Wi-Fi or Ethernet link qualifies when its gateway answers as an
HTTP proxy on the configured port. The SSID is not a selection key. Two
answering links need `IFACE` in `/etc/netshare.conf`.

`CONNECTION_PREFIX` is optional and applies only to `netshare bar`. Empty
lists every link the probe accepted. A non-empty value is a NetworkManager
connection-name prefix, so the panel can ignore other networks. `up` still
considers every connected link.

## Bar panel

`bar/netshare.qml` is an Omarchy bar module. Left click opens the panel and
does not start the tunnel. The switch runs `netshare up` or `netshare down`
to match the position it is showing.

The hero names the focused connection. The status line is Desktop or Side
while the tunnel is up (`desktop` and `side` are the posture values), and
Off, Stale, Starting, or Stopping otherwise. The rows are connection,
adapter, address, proxy host:port, and the tun address. While the tunnel is
up or the saved state is stale, those rows stay on the bound adapter.

The module polls `netshare bar` about every 15 seconds. Saving the QML does
not reload a running shell.

## Routing

Desktop packets select the side table by uid before the kernel picks a
source address. A mark set in a later netfilter hook is not enough for that.
The main-table default stays in place. There are no `/1` routes. systemd-resolved
is not pointed at `198.18.0.1`. ICMP, QUIC, and arbitrary UDP are out of scope.

## Install

Symlink the controller onto `PATH`:

```bash
ln -s /path/to/netshare/netshare ~/.local/bin/netshare
```

Symlink the panel into the user bar modules and add the widget. The snippet
is only this entry:

```json
{ "id": "netshare", "type": "qml" }
```

```bash
ln -s /path/to/netshare/bar/netshare.qml \
  ~/.config/omarchy/bar/modules/netshare.qml
```

Restart the shell after the module is in place. Do not refresh the shell
over the rest of the user config.

Optional overrides live in `/etc/netshare.conf`, which must be owned by root.
See `netshare.conf.example`. Copy it and keep the real file out of git.

tun2proxy belongs at `/usr/local/bin/tun2proxy`, or set `TUN2PROXY`.

## Out of scope

A systemd unit, a general VPN manager, and editing the packaged Omarchy tree.
