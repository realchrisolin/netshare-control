# Bar JSON for an optional panel. `netshare bar` sources this.
# Bringing the tunnel up does not use this file.

cmd_bar() {
  local tunnel_label="down" klass="" posture_text="" bound_text=""
  local saved_iface="" saved_proxy="" saved_posture="" saved_src="" saved_tun=""
  if [[ -f "$STATE" ]] && load_state; then
    saved_iface=$iface
    saved_proxy=$state_proxy
    saved_posture=$posture
    saved_src=$src
    saved_tun=$tun_addr
    if pid_alive && ip link show "$TUN" >/dev/null 2>&1; then
      tunnel_label="up"
      klass="active"
      posture_text="posture ${saved_posture:-unknown}"
      bound_text="bound ${saved_iface} ${saved_proxy}"
    else
      tunnel_label="stale"
    fi
  fi

  local -a tooltip_lines=()
  local -a link_lines=()
  if [[ -n "$posture_text" ]]; then
    tooltip_lines+=("tunnel: ${tunnel_label} ${posture_text}")
  else
    tooltip_lines+=("tunnel: ${tunnel_label}")
  fi

  local yes_count=0 note=""
  if command -v curl >/dev/null 2>&1; then
    scan_access_points "$CONNECTION_PREFIX"
    local hit dev local_src cidr bypass url name answer code conn line
    if ((${#netshare_hits[@]} == 0)); then
      tooltip_lines+=("access-point: none")
    fi
    for hit in "${netshare_hits[@]}"; do
      IFS=$'\t' read -r dev local_src cidr bypass url name answer code conn <<<"$hit"
      line="${conn:-$dev} ${cidr} proxy ${url} ${answer}"
      if [[ "$answer" == "yes" ]]; then
        line+=" (${code})"
        yes_count=$((yes_count + 1))
      fi
      tooltip_lines+=("$line")
      link_lines+=("${dev}"$'\t'"${cidr}"$'\t'"${url}"$'\t'"${name}"$'\t'"${answer}"$'\t'"${code}"$'\t'"${conn}")
    done
    if (( yes_count > 1 )); then
      tooltip_lines+=("ambiguous")
      note="ambiguous"
    fi
  else
    note="curl-missing"
    tooltip_lines+=("access-point: curl is not installed")
  fi
  if [[ "$tunnel_label" == "up" && -n "$bound_text" ]]; then
    tooltip_lines+=("$bound_text")
  fi

  {
    printf '%s\n' "${tooltip_lines[@]}"
    printf '\n'
    if ((${#link_lines[@]} > 0)); then
      printf '%s\n' "${link_lines[@]}"
    fi
  } | python3 -c '
import json
import sys
icon, klass, tunnel, posture, bound_device, bound_proxy, note, tun_addr, bound_address = sys.argv[1:10]
raw = sys.stdin.read().split("\n")
if "" in raw:
    split = raw.index("")
    tip, rest = raw[:split], raw[split + 1:]
else:
    tip, rest = raw, []
links = []
for line in rest:
    if not line:
        continue
    parts = line.split("\t")
    while len(parts) < 7:
        parts.append("")
    device, address, proxy, ssid, answer, code, connection = parts[:7]
    links.append({
        "device": device,
        "address": address,
        "ssid": ssid,
        "connection": connection,
        "proxy": proxy,
        "answer": answer,
        "code": code,
    })
print(json.dumps({
    "text": icon,
    "tooltip": "\n".join([line for line in tip if line != ""]),
    "class": klass,
    "tunnel": tunnel,
    "posture": posture,
    "boundDevice": bound_device,
    "boundProxy": bound_proxy,
    "boundAddress": bound_address,
    "tunAddr": tun_addr,
    "note": note,
    "links": links,
}, ensure_ascii=False))
' "$BAR_ICON" "$klass" "$tunnel_label" "$saved_posture" "$saved_iface" "$saved_proxy" "$note" "$saved_tun" "$saved_src" \
    || printf '%s\n' '{"text":"\uf0ec","tooltip":"NetShare","class":"","tunnel":"down","posture":"","boundDevice":"","boundProxy":"","boundAddress":"","tunAddr":"","note":"","links":[]}'
}

