#!/usr/bin/env bash
# shellcheck source=harness.sh
source "$(dirname "$0")/harness.sh"
source_lib

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

sudo_cached() { return 1; }
have_controlling_tty() { return 1; }
pinentry_program() { return 1; }

mode=$(elevate_mode) || true
[[ "$mode" == "none" ]] || fail "no prompt mode: $mode"

out=$(expect_fail "no prompt" require_root up)
[[ "$out" == *"no terminal or desktop prompt"* ]] || fail "no prompt message: $out"

have_controlling_tty() { return 0; }
mode=$(elevate_mode) || true
[[ "$mode" == "terminal" ]] || fail "terminal mode: $mode"

NETSHARE_PROMPT=desktop
mode=$(elevate_mode) || true
[[ "$mode" == "none" ]] || fail "desktop without helper: $mode"

helper=$tmp/askpass
printf '#!/bin/sh\nexit 0\n' >"$helper"
chmod 755 "$helper"
SUDO_ASKPASS=$helper
mode=$(elevate_mode) || true
[[ "$mode" == "askpass" ]] || fail "desktop askpass mode: $mode"
got=$(askpass_program) || fail "askpass program"
[[ "$got" == "$helper" ]] || fail "sudo askpass helper"

unset SUDO_ASKPASS
pinentry_program() { printf '%s\n' "$helper"; }
mode=$(elevate_mode) || true
[[ "$mode" == "askpass" ]] || fail "bundled askpass mode: $mode"
got=$(askpass_program) || fail "bundled askpass program"
[[ "$got" == "$ASKPASS_HELPER" ]] || fail "bundled helper was not selected"

sudo_cached() { return 0; }
NETSHARE_PROMPT=desktop
have_controlling_tty() { return 0; }
mode=$(elevate_mode) || true
[[ "$mode" == "cached" ]] || fail "cached skips prompt: $mode"

out=$(
  exec_sudo() { printf 'ASKPASS=%s CMD=%s\n' "${SUDO_ASKPASS-<unset>}" "$*"; }
  sudo_cached() { return 0; }
  require_root up
)
[[ "$out" == ASKPASS=\<unset\>\ CMD=sudo\ -n\ *\ up ]] || fail "cached exec: $out"

out=$(
  exec_sudo() { printf 'CMD=%s\n' "$*"; }
  sudo_cached() { return 1; }
  have_controlling_tty() { return 0; }
  unset NETSHARE_PROMPT
  require_root down
)
[[ "$out" == CMD=sudo\ -p\ Password\ required\ for\ netshare:\ *\ down ]] || fail "terminal exec: $out"

out=$(
  exec_sudo() { printf 'ASKPASS=%s CMD=%s\n' "${SUDO_ASKPASS-<unset>}" "$*"; }
  sudo_cached() { return 1; }
  have_controlling_tty() { return 0; }
  NETSHARE_PROMPT=desktop
  SUDO_ASKPASS=$helper
  require_root up
)
[[ "$out" == "ASKPASS=$helper CMD=sudo -A -p Password required for netshare: "*" up" ]] || fail "askpass exec: $out"

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
got=$(NETSHARE_PINENTRY=$pinentry "$ASKPASS_HELPER" "Password required for netshare:") || fail "askpass helper failed"
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
cancelled=$(NETSHARE_PINENTRY=$cancel "$ASKPASS_HELPER" "Password required for netshare:" 2>"$tmp/cancel.err")
rc=$?
set -e
[[ "$rc" -ne 0 ]] || fail "cancel exited 0"
[[ -z "$cancelled" ]] || fail "cancel wrote a password"

echo "ok elevate"
