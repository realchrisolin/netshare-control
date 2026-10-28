#!/usr/bin/env bash
# The drop-in is the grant. It must name the packaged command and the
# tunnel operations, and it must not name a checkout or an internal helper.
# shellcheck source=harness.sh
source "$(dirname "$0")/harness.sh"
source_lib

rule="$ROOT/sudoers.d/netshare"
[[ -f "$rule" ]] || fail "missing sudoers drop-in"

body=$(cat "$rule")
[[ "$body" == *'%wheel ALL=(root) NOPASSWD:'* ]] || fail "grant is not wheel: $body"
[[ "$body" == *'/usr/bin/netshare up'* ]] || fail "up missing"
[[ "$body" == *'/usr/bin/netshare down'* ]] || fail "down missing"
[[ "$body" == *'/usr/bin/netshare toggle'* ]] || fail "toggle missing"
[[ "$body" == *'/usr/bin/netshare default on'* ]] || fail "default on missing"
[[ "$body" == *'/usr/bin/netshare default off'* ]] || fail "default off missing"
[[ "$body" == *'/usr/bin/netshare run *'* ]] || fail "run missing"
[[ "$body" != *'/home/'* ]] || fail "drop-in names a home directory"
for denied in dns-reassert transport-down --inside-run reap SUDO_ASKPASS; do
  [[ "$body" != *"$denied"* ]] || fail "drop-in lists $denied"
done
[[ "$(declare -f require_root)" != *SUDO_ASKPASS* ]] || fail "require_root uses SUDO_ASKPASS"
[[ "$(declare -f require_root)" != *'sudo -A'* ]] || fail "require_root uses sudo -A"
[[ "$(declare -f launch_sudo_terminal)" == *'TUI.float'* ]] || fail "float class missing"

echo "ok sudoers"
