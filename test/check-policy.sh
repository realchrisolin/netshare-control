#!/usr/bin/env bash
# shellcheck source=harness.sh
source "$(dirname "$0")/harness.sh"
source_lib

check_policy

reject() {
  local label=$1
  local assign=$2
  local needle=$3
  local out rc
  set +e
  out=$(
    # shellcheck source=harness.sh
    source "$(dirname "$0")/harness.sh"
    source_lib
    eval "$assign"
    check_policy 2>&1
  )
  rc=$?
  set -e
  [[ "$rc" -ne 0 ]] || fail "$label was accepted"
  [[ "$out" == *"$needle"* ]] || fail "$label message: $out"
}

reject "rule at tailscale" "RULE_PREF=5210" "not ahead of Tailscale"
reject "runner beside the mark rule" "RUNNER_RULE_PREF=5000" "must sit between"
reject "runner at tailscale" "RUNNER_RULE_PREF=5210" "must sit between"
reject "desktop at tailscale lookup" "DESKTOP_RULE_PREF=5270" "must follow Tailscale"
reject "desktop at main" "DESKTOP_RULE_PREF=32766" "must follow Tailscale"
reject "mark in tailscale mask" "MARK=0x10000" "overlaps the Tailscale"
reject "proxy scheme" "PROXY_URL=https://192.0.2.1:8282" "must start with http://"
reject "proxy credentials" "PROXY_URL=http://user:secret@192.0.2.1:8282" "must not carry credentials"

echo "ok check-policy"
