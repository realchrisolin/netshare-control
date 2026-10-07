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

## Console

`up` and `down` need root. A cached sudo ticket is reused. From a terminal,
sudo asks on that terminal. With no terminal, sudo opens a desktop password
dialog (`pinentry-qt`, or `pinentry-gnome3`). `SUDO_ASKPASS` overrides that
helper. The bar sets `NETSHARE_PROMPT=desktop` so the switch uses the dialog
even when the session still has a terminal. `NETSHARE_PROMPT=terminal` forces
the terminal prompt.

```
sudo netshare up
netshare status
sudo netshare run curl -sI https://example.com
sudo netshare default off
sudo netshare down
```

`sudo netshare up` from an account sends that account through the tun after
public DNS through the tun succeeds. The main-table default stays where
NetworkManager put it. Root with no account selected still brings the tun up,
leaves the host resolver alone, and limits the tun to `netshare run`.

To choose the account from a root shell, set `NETSHARE_UID` in
`/etc/netshare.conf` to that account's numeric uid. `netshare default on`
installs the same uid rule later. `netshare default off` removes it and
leaves the tun up for `netshare run`.

```
sudo netshare up
sudo netshare down
netshare status
netshare bar
sudo netshare toggle
sudo netshare run curl -sI https://example.com
sudo netshare default on|off
```

`status` prints the live link. `bar` prints one JSON object and does not
change routes. Neither command's output belongs in a commit.

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

## Install

Symlink the controller onto `PATH`:

```bash
ln -s /path/to/netshare/netshare ~/.local/bin/netshare
```

Optional overrides live in `/etc/netshare.conf`, which must be owned by root.
See `netshare.conf.example`. Copy it and keep the real file out of git.

`tun2proxy` belongs at `/usr/local/bin/tun2proxy`, or set `TUN2PROXY`. See Dependencies.

## Omarchy bar

`bar/netshare.qml` is an optional bar module. Left click opens the panel and
does not start the tunnel. The switch runs `netshare up` or `netshare down`.

The hero names the focused connection. The status line is Desktop or Side
while the tunnel is up (`desktop` and `side` are the posture values), and
Off, Stale, Starting, or Stopping otherwise. The rows are connection,
adapter, address, proxy host:port, and the tun address. While the tunnel is
up or the saved state is stale, those rows stay on the bound adapter.

The module polls `netshare bar`. Saving the QML does not reload a running
shell. Symlink the panel and add only this widget entry:

```json
{ "id": "netshare", "type": "qml" }
```

```bash
ln -s /path/to/netshare/bar/netshare.qml \
  ~/.config/omarchy/bar/modules/netshare.qml
```

Restart the shell after the module is in place. Do not refresh the shell
over the rest of the user config.

## Tests

```bash
bash test/run.sh
```

The tests source the tunnel library and stub `ip` and `nmcli`. They do not call `up` or `down`. `node` runs `test/panel.js`.

## Out of scope

A systemd unit, a general VPN manager, and editing a packaged desktop tree.
