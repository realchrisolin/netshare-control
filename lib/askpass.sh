#!/usr/bin/env bash
# Desktop password prompt for `sudo -A`.
# The prompt is the first argument. The password is written to stdout only.
set -euo pipefail

prompt=${1:-Password required for netshare:}
prompt=${prompt//$'\n'/ }
prompt=${prompt//$'\r'/ }

pinentry_bin() {
  local name candidate
  if [[ -n "${NETSHARE_PINENTRY:-}" && -x "$NETSHARE_PINENTRY" ]]; then
    printf '%s\n' "$NETSHARE_PINENTRY"
    return 0
  fi
  for name in pinentry-qt pinentry-gnome3 /usr/bin/pinentry-qt /usr/bin/pinentry-gnome3; do
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

bin=$(pinentry_bin) || exit 1

conversation=$(
  {
    printf 'SETTITLE netshare\n'
    printf 'SETDESC %s\n' "$prompt"
    printf 'SETPROMPT Password:\n'
    printf 'GETPIN\n'
  } | "$bin"
) || exit 1

encoded=$(printf '%s\n' "$conversation" | awk 'index($0, "D ") == 1 { sub(/^D /, ""); print; exit }')
[[ -n "${encoded}" ]] || exit 1

decoded=$(printf '%s' "$encoded" | python3 -c 'import sys, urllib.parse; sys.stdout.write(urllib.parse.unquote(sys.stdin.read()))')
[[ -n "$decoded" ]] || exit 1
printf '%s\n' "$decoded"
