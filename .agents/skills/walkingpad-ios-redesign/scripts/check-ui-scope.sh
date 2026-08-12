#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "usage: $0 <base-sha> <allowed-path> [<allowed-path> ...]" >&2
  exit 64
fi

base_sha=$1
shift

if [[ ! "$base_sha" =~ ^[0-9a-fA-F]{40}$ ]]; then
  echo "base must be an exact 40-character commit SHA" >&2
  exit 65
fi

git rev-parse --verify "${base_sha}^{commit}" >/dev/null
git rev-parse --is-inside-work-tree >/dev/null

is_explicitly_allowed() {
  local candidate=$1
  shift
  local allowed
  for allowed in "$@"; do
    if [[ "$candidate" == "$allowed" ]]; then
      return 0
    fi
  done
  return 1
}

is_forbidden() {
  local path=$1
  case "$path" in
    *BluetoothManager.swift|*BLETransportCodec.swift|*HRDomainService.swift|*CooldownRuntimeEngine.swift|*TrainingTelemetryWriter.swift|*CommandQueueService.swift|*TreadmillSpeedBoundsService.swift|*Package.swift|*.xcodeproj/*|scan_ble.py|run_*.py|run_*.sh|scripts/*deploy*|tools/mcp_xcode_server.py)
      return 0
      ;;
  esac
  return 1
}

status=0
while IFS= read -r -d '' path; do
  [[ -n "$path" ]] || continue
  if is_forbidden "$path"; then
    echo "FORBIDDEN: $path" >&2
    status=1
  elif [[ "$path" == docs/design/* ]]; then
    printf 'ALLOWED: %s\n' "$path"
  elif is_explicitly_allowed "$path" "$@"; then
    printf 'ALLOWED: %s\n' "$path"
  else
    echo "OUT OF SCOPE: $path" >&2
    status=1
  fi
done < <(
  git diff --cached --name-only -z --no-renames --diff-filter=ACMRD "$base_sha" --
  git diff --name-only -z --no-renames --diff-filter=ACMRD --
  git ls-files --others --exclude-standard -z
)

exit "$status"
