#!/usr/bin/env bash
# Run the fixture tests. Does not call `netshare up` or `netshare down`.
set -euo pipefail
cd "$(dirname "$0")"
for test in ./*.sh; do
  name=$(basename "$test")
  [[ "$name" == "run.sh" || "$name" == "harness.sh" ]] && continue
  bash "$test"
done
node ./panel.js
