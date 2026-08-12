#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <existing-build-log>" >&2
  exit 64
fi

log_path=$1
if [[ ! -f "$log_path" || ! -r "$log_path" ]]; then
  echo "build log is not a readable regular file: $log_path" >&2
  exit 66
fi

echo "Build diagnostics (first 80 matching lines):"
grep -E -i -m 80 '(^|[[:space:]])(error:|fatal error:|warning:)|BUILD (FAILED|SUCCEEDED)|TEST (FAILED|SUCCEEDED)|Command .* failed' "$log_path" || true

echo "Final status lines:"
tail -n 40 "$log_path" | grep -E -i 'BUILD (FAILED|SUCCEEDED)|TEST (FAILED|SUCCEEDED)|[0-9]+ tests?, [0-9]+ failures?' || true
