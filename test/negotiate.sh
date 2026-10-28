#!/usr/bin/env bash
# Bounded data-plane negotiation. Stubs stand in for the phone and the tun.
# This does not call up or down, and it does not start or stop tun2proxy.
# shellcheck source=harness.sh
source "$(dirname "$0")/harness.sh"
source_lib

# A missed stub must not be able to delete the live tun.
TUN=nstest-negotiate
launch_engine() { echo "launch_engine was called" >&2; return 1; }
stop_engine() { echo "stop_engine was called" >&2; return 1; }

body=$(declare -f restart_dataplane)
[[ "$body" == *'stop_engine'* ]] || fail "restart does not stop the engine"
[[ "$body" == *'launch_engine "$engine_plane"'* ]] || fail "restart does not use engine_plane"
[[ "$body" == *'configure_tun_link'* ]] || fail "restart does not configure the tun"
[[ "$body" == *'write_state'* ]] || fail "restart does not record the new pid"
[[ "$body" != *nft* ]] || fail "restart touches nft"

ENGINE_TRIES=3
PROBE_PAUSE=0
errfile=$(mktemp)
trap 'rm -f "$errfile"' EXIT
probes=0
upstreams=0
restarts=0
dns_checks=0
restart_rc=0
probe_results=()
upstream_results=()
dns_results=()

reset_counts() {
  probes=0
  upstreams=0
  restarts=0
  dns_checks=0
  restart_rc=0
  probe_results=()
  upstream_results=()
  dns_results=()
  negotiate_detail=""
  probe_detail=""
  neg_rc=0
  neg_err=""
}

probe_marked_http() {
  local spec
  probes=$((probes + 1))
  if (( probes > ${#probe_results[@]} )); then
    probe_detail="unexpected probe ${probes}"
    return 1
  fi
  spec=${probe_results[probes - 1]}
  if [[ "$spec" == ok ]]; then
    probe_detail=""
    return 0
  fi
  probe_detail=${spec#fail:}
  return 1
}

proxy_upstream_ok() {
  local spec
  upstreams=$((upstreams + 1))
  if (( upstreams > ${#upstream_results[@]} )); then
    return 1
  fi
  spec=${upstream_results[upstreams - 1]}
  [[ "$spec" == ok ]]
}

restart_dataplane() {
  restarts=$((restarts + 1))
  return "$restart_rc"
}

verify_dns_gate() {
  dns_checks=$((dns_checks + 1))
  if (( dns_checks > ${#dns_results[@]} )); then
    return 1
  fi
  [[ ${dns_results[dns_checks - 1]} == ok ]]
}

run_neg() {
  neg_rc=0
  # Direct call. A command substitution would drop the counters and the detail.
  negotiate_transport 2>"$errfile" || neg_rc=$?
  neg_err=$(cat "$errfile")
}

expect() {
  local got=$1 want=$2 label=$3
  [[ "$got" == "$want" ]] || fail "${label}: got [${got}] want [${want}] (probes=${probes} upstreams=${upstreams} restarts=${restarts} detail=${negotiate_detail} err=${neg_err})"
}

# The phone answers, and the first tun probe succeeds. No restart.
reset_counts
upstream_results=(ok)
probe_results=(ok)
run_neg
expect "$neg_rc" 0 "first probe"
expect "$probes" 1 "first probe count"
expect "$restarts" 0 "first probe restarts"
expect "$upstreams" 1 "first probe upstreams"
[[ "$neg_err" != *restarting* ]] || fail "first probe restarted: ${neg_err}"

# The phone does not answer. Do not open a tun probe or a new data plane.
reset_counts
upstream_results=(fail)
probe_results=(ok)
run_neg
expect "$neg_rc" 1 "phone down"
expect "$probes" 0 "phone down probes"
expect "$restarts" 0 "phone down restarts"
expect "$negotiate_detail" "access point did not answer a direct request" "phone down detail"

# The tun probe fails, then the phone stops answering. Do not restart.
reset_counts
upstream_results=(ok fail)
probe_results=("fail:dns stuck after 3 attempts")
run_neg
expect "$neg_rc" 1 "phone dropped"
expect "$probes" 1 "phone dropped probes"
expect "$restarts" 0 "phone dropped restarts"
expect "$negotiate_detail" "dns stuck after 3 attempts; access point stopped answering direct requests" "phone dropped detail"
[[ "$neg_err" != *restarting* ]] || fail "phone dropped restarted: ${neg_err}"

# Two wedged generations, then the third carries traffic. Two restarts.
reset_counts
upstream_results=(ok ok ok)
probe_results=("fail:one" "fail:two" ok)
run_neg
expect "$neg_rc" 0 "third plane"
expect "$probes" 3 "third plane probes"
expect "$restarts" 2 "third plane restarts"
expect "$upstreams" 3 "third plane upstreams"
[[ "$neg_err" == *'(1/3)'* && "$neg_err" == *'(2/3)'* ]] || fail "third plane log: ${neg_err}"
[[ "$neg_err" != *'(3/3)'* ]] || fail "third plane restarted past success: ${neg_err}"

# Every generation fails while the phone still answers. One fewer restart
# than generations, and the failure says the direct request succeeded.
reset_counts
upstream_results=(ok ok ok ok)
probe_results=("fail:wedged after 3 attempts" "fail:wedged after 3 attempts" "fail:wedged after 3 attempts")
run_neg
expect "$neg_rc" 1 "exhausted"
expect "$probes" 3 "exhausted probes"
expect "$restarts" 2 "exhausted restarts"
expect "$upstreams" 4 "exhausted upstreams"
expect "$negotiate_detail" "wedged after 3 attempts; direct request succeeded through 3 data planes" "exhausted detail"

# The replacement process does not come up. Stop, and do not probe again.
reset_counts
upstream_results=(ok ok)
probe_results=("fail:wedged after 3 attempts" ok)
restart_rc=1
run_neg
expect "$neg_rc" 1 "restart failed"
expect "$probes" 1 "restart failed probes"
expect "$restarts" 1 "restart failed restarts"
expect "$negotiate_detail" "could not restart the data plane (wedged after 3 attempts)" "restart failed detail"

# One generation only: a failed probe with the phone still up does not restart.
reset_counts
ENGINE_TRIES=1
upstream_results=(ok ok)
probe_results=("fail:wedged after 3 attempts")
run_neg
expect "$neg_rc" 1 "single generation"
expect "$probes" 1 "single generation probes"
expect "$restarts" 0 "single generation restarts"
expect "$negotiate_detail" "wedged after 3 attempts; direct request succeeded through 1 data planes" "single generation detail"
ENGINE_TRIES=3

# DNS gate: two misses, then a public answer.
reset_counts
dns_results=(fail fail ok)
dns_rc=0
confirm_dns_gate || dns_rc=$?
expect "$dns_rc" 0 "dns recovered"
expect "$dns_checks" 3 "dns recovered checks"

# DNS gate: every try misses. Call it ENGINE_TRIES times and then stop.
reset_counts
dns_results=(fail fail fail fail)
dns_rc=0
confirm_dns_gate || dns_rc=$?
expect "$dns_rc" 1 "dns exhausted"
expect "$dns_checks" 3 "dns exhausted checks"

up_body=$(declare -f cmd_up)
[[ "$up_body" == *'negotiate_transport'* ]] || fail "up does not negotiate"
[[ "$up_body" == *'confirm_dns_gate'* ]] || fail "up does not confirm DNS"
[[ "$up_body" != *'launch_engine "$plane"'* || "$up_body" == *'engine_plane=$plane'* ]] || fail "up dropped engine_plane"
default_body=$(declare -f cmd_default)
[[ "$default_body" == *'confirm_dns_gate'* ]] || fail "default on does not confirm DNS"

echo "ok negotiate"
