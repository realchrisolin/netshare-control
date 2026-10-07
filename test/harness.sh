# Shared helpers. A test sources this. It does not bring the tunnel up.
set -euo pipefail

ROOT=$(dirname "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")")

fail() {
  echo "FAIL ${1:-unknown}" >&2
  exit 1
}

source_lib() {
  # shellcheck source=../lib/tunnel.sh
  source "$ROOT/lib/tunnel.sh"
  # Drop anything a local conf set, so a failure cannot print it.
  PROXY_URL=""
  BYPASS_CIDR=""
  IFACE=""
  CONNECTION_PREFIX=""
  NETSHARE_UID=""
  if [[ -n "${SUDO_UID+x}" ]]; then
    unset SUDO_UID
  fi
  if [[ -n "${NETSHARE_PROMPT+x}" ]]; then
    unset NETSHARE_PROMPT
  fi
  if [[ -n "${SUDO_ASKPASS+x}" ]]; then
    unset SUDO_ASKPASS
  fi
  if [[ -n "${NETSHARE_PINENTRY+x}" ]]; then
    unset NETSHARE_PINENTRY
  fi
}

expect_fail() {
  local label=$1
  shift
  local out rc
  set +e
  out=$("$@" 2>&1)
  rc=$?
  set -e
  [[ "$rc" -ne 0 ]] || fail "$label exited 0: $out"
  printf '%s\n' "$out"
}
