#!/usr/bin/env bash
# shellcheck source=harness.sh
source "$(dirname "$0")/harness.sh"
source_lib

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

sudo_grants_passwordless() { return 1; }
sudo_cached() { return 1; }
have_controlling_tty() { return 1; }
command() {
  if [[ "$1" == "-v" && "$2" == "xdg-terminal-exec" ]]; then
    return 1
  fi
  builtin command "$@"
}

mode=$(elevate_mode up) || true
[[ "$mode" == "none" ]] || fail "no prompt mode: $mode"

out=$(expect_fail "no prompt" require_root up)
[[ "$out" == *"no terminal is available"* ]] || fail "no prompt message: $out"

unset -f command
mode=$(elevate_mode up) || true
[[ "$mode" == "float" ]] || fail "float mode: $mode"

have_controlling_tty() { return 0; }
mode=$(elevate_mode up) || true
[[ "$mode" == "terminal" ]] || fail "terminal mode: $mode"

sudo_grants_passwordless() { return 0; }
have_controlling_tty() { return 1; }
mode=$(elevate_mode up) || true
[[ "$mode" == "passwordless" ]] || fail "passwordless mode: $mode"

out=$(
  exec_sudo() { printf 'CMD=%s\n' "$*"; }
  sudo_grants_passwordless() { return 0; }
  require_root up
)
[[ "$out" == "CMD=sudo -n ${PACKAGED_PATH} up" ]] || fail "passwordless exec: $out"

sudo_grants_passwordless() { return 1; }
sudo_cached() { return 0; }
mode=$(elevate_mode up) || true
[[ "$mode" == "cached" ]] || fail "cached skips prompt: $mode"

out=$(
  exec_sudo() { printf 'CMD=%s\n' "$*"; }
  sudo_grants_passwordless() { return 1; }
  sudo_cached() { return 0; }
  require_root up
)
[[ "$out" == "CMD=sudo -n ${PACKAGED_PATH} up" ]] || fail "cached exec: $out"

out=$(
  exec_sudo() { printf 'CMD=%s\n' "$*"; }
  sudo_grants_passwordless() { return 1; }
  sudo_cached() { return 1; }
  have_controlling_tty() { return 0; }
  require_root down
)
[[ "$out" == "CMD=sudo -p Password required for netshare:  ${PACKAGED_PATH} down" ]] \
  || fail "terminal exec: $out"

out=$(
  exec_sudo() { printf 'CMD=%s\n' "$*"; }
  sudo_grants_passwordless() { return 1; }
  sudo_cached() { return 1; }
  have_controlling_tty() { return 1; }
  require_root up
)
[[ "$out" == "CMD=launch_sudo_terminal netshare needs an administrator password to start the tunnel. Password required for netshare:  ${PACKAGED_PATH} up" ]] \
  || fail "float exec: $out"
[[ "$out" == *"SUDO_ASKPASS"* || "$out" == *"sudo -A"* ]] && fail "float used askpass: $out"

id() { printf '%s\n' 0; }
mode=$(elevate_mode) || true
[[ "$mode" == "root" ]] || fail "root mode: $mode"

detached=$(setsid bash -c '
  source "'"$ROOT"'/test/harness.sh"
  source_lib
  if have_controlling_tty; then echo yes; else echo no; fi
' </dev/null)
[[ "$detached" == "no" ]] || fail "detached tty: $detached"

pinentry=$tmp/pinentry
desc=$tmp/desc
cat >"$pinentry" <<EOF
#!/bin/bash
cat >"$desc"
printf '%s\n' 'D fixture%20pin' 'OK'
EOF
chmod 755 "$pinentry"
got=$(NETSHARE_PINENTRY=$pinentry "$ROOT/lib/askpass.sh" "Password required for netshare:") || fail "askpass helper failed"
[[ "$got" == "fixture pin" ]] || fail "askpass decode"
[[ "$(cat "$desc")" == *"SETDESC Password required for netshare:"* ]] || fail "askpass prompt"
[[ "$(cat "$desc")" == *GETPIN* ]] || fail "askpass getpin"

cancel=$tmp/cancel
cat >"$cancel" <<'EOF'
#!/bin/bash
cat >/dev/null
printf '%s\n' 'ERR 83886179 Operation cancelled'
exit 1
EOF
chmod 755 "$cancel"
set +e
cancelled=$(NETSHARE_PINENTRY=$cancel "$ROOT/lib/askpass.sh" "Password required for netshare:" 2>"$tmp/cancel.err")
rc=$?
set -e
[[ "$rc" -ne 0 ]] || fail "cancel exited 0"
[[ -z "$cancelled" ]] || fail "cancel wrote a password"

echo "ok elevate"
