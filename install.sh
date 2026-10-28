#!/usr/bin/env bash
# Install the root-owned netshare command and its sudoers drop-in.
# Run this as root. It does not bring the tunnel up.
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "netshare: install must run as root" >&2
  exit 1
fi

src=$(dirname "$(readlink -f "$0")")
rule="$src/sudoers.d/netshare"
[[ -f "$rule" && -f "$src/netshare" && -f "$src/lib/tunnel.sh" && -f "$src/lib/bar.sh" ]] \
  || { echo "netshare: installer is missing the command or the sudoers file" >&2; exit 1; }

if [[ -e /usr/bin/netshare && ! -L /usr/bin/netshare ]]; then
  if ! grep -q '/usr/lib/netshare/netshare' /usr/bin/netshare; then
    echo "netshare: /usr/bin/netshare exists and is not the netshare wrapper" >&2
    exit 1
  fi
fi

if ! grep -Eq '^[[:space:]]*[#@]includedir[[:space:]]+/etc/sudoers\.d([[:space:]]|$)' /etc/sudoers; then
  echo "netshare: /etc/sudoers does not include /etc/sudoers.d" >&2
  exit 1
fi

visudo -cf "$rule"

install -d -o root -g root -m 0755 /usr/lib/netshare/lib
install -o root -g root -m 0755 "$src/netshare" /usr/lib/netshare/netshare
install -o root -g root -m 0644 "$src/lib/tunnel.sh" /usr/lib/netshare/lib/tunnel.sh
install -o root -g root -m 0644 "$src/lib/bar.sh" /usr/lib/netshare/lib/bar.sh

wrapper=$(mktemp)
cat >"$wrapper" <<'EOF'
#!/bin/bash
if [[ "$(id -u)" -eq 0 ]]; then
  export PATH=/usr/local/sbin:/usr/local/bin:/usr/bin:/usr/sbin:/bin:/sbin
fi
exec /usr/lib/netshare/netshare "$@"
EOF
rm -f /usr/bin/netshare
install -o root -g root -m 0755 "$wrapper" /usr/bin/netshare
rm -f "$wrapper"

install -o root -g root -m 0440 "$rule" /etc/sudoers.d/netshare
visudo -c

if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != root ]]; then
  home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
  if [[ -n "$home" && -d "$home/.local/bin" ]]; then
    ln -sfn /usr/bin/netshare "$home/.local/bin/netshare"
    chown -h "$SUDO_USER:$SUDO_USER" "$home/.local/bin/netshare"
  fi
fi

echo "netshare: installed /usr/bin/netshare and /etc/sudoers.d/netshare"
